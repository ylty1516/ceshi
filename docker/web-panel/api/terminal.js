/**
 * Terminal API - Interactive terminal via WebSocket
 * Connects to SMAPI stdin/stdout for Steam Guard code input
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');
const config = require('../server');

// Only allow one terminal session at a time
let activeTerminal = null;
let activeWs = null;
let idleTimeout = null;
const IDLE_TIMEOUT = 5 * 60 * 1000; // 5 minutes
const configuredCommandTimeoutMs = parseInt(process.env.PANEL_COMMAND_TIMEOUT_MS || '1500', 10);
const COMMAND_TIMEOUT_MS = Number.isFinite(configuredCommandTimeoutMs) && configuredCommandTimeoutMs > 0
  ? configuredCommandTimeoutMs
  : 1500;
const HOST_COMMANDS = new Set([
  'autohide_expansion_mode start',
  'autohide_expansion_mode finish',
  'hidehost',
  'showhost',
]);

function resetIdleTimeout() {
  if (idleTimeout) clearTimeout(idleTimeout);
  idleTimeout = setTimeout(() => {
    if (activeWs && activeWs.readyState === 1) {
      activeWs.send(JSON.stringify({
        type: 'terminal:output',
        data: '\r\n[System] Terminal closed due to inactivity (5 min timeout)\r\n',
      }));
    }
    closeTerminal();
  }, IDLE_TIMEOUT);
}

function closeTerminal() {
  if (idleTimeout) {
    clearTimeout(idleTimeout);
    idleTimeout = null;
  }
  if (activeTerminal) {
    try { activeTerminal.kill(); } catch (e) {}
    activeTerminal = null;
  }
  if (activeWs) {
    activeWs._terminalProc = null;
    activeWs = null;
  }
}

function writeHostCommandFallback(command) {
  if (!HOST_COMMANDS.has(String(command || '').trim().toLowerCase()) || !config.HOST_COMMAND_FILE) {
    return false;
  }

  const payload = {
    id: crypto.randomUUID ? crypto.randomUUID() : `${Date.now().toString(36)}-${crypto.randomBytes(8).toString('hex')}`,
    command: String(command || '').trim().toLowerCase(),
    requestedAt: new Date().toISOString(),
    requestedBy: 'web-terminal-fallback',
  };
  fs.mkdirSync(path.dirname(config.HOST_COMMAND_FILE), { recursive: true });
  const tmpPath = `${config.HOST_COMMAND_FILE}.tmp-terminal-${process.pid}`;
  fs.writeFileSync(tmpPath, JSON.stringify(payload, null, 2), 'utf-8');
  fs.renameSync(tmpPath, config.HOST_COMMAND_FILE);
  return payload.id;
}

function openTerminal(ws) {
  // Only one terminal at a time
  if (activeTerminal && activeWs && activeWs !== ws) {
    ws.send(JSON.stringify({
      type: 'terminal:error',
      data: 'Another terminal session is active. Only one terminal allowed at a time.',
    }));
    return;
  }

  // Close existing
  closeTerminal();

  try {
    // Find SMAPI process PID to connect to its stdin/stdout
    // We use a helper approach: tail the SMAPI log for output,
    // and write to a named pipe or directly to process stdin for input

    // Method: Use docker's internal process - write to /proc/PID/fd/0
    let smapiPid;
    try {
      smapiPid = execSync('pgrep -f StardewModdingAPI', { encoding: 'utf-8', timeout: COMMAND_TIMEOUT_MS }).trim().split('\n')[0];
    } catch (e) {
      ws.send(JSON.stringify({
        type: 'terminal:error',
        data: 'SMAPI process not found. Game may not be running yet.',
      }));
      return;
    }

    // Start tailing the SMAPI log for output
    const config = require('../server');
    const logPath = config.SMAPI_LOG;
    const tail = spawn('tail', ['-f', '-n', '30', logPath], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });

    activeTerminal = tail;
    activeWs = ws;
    ws._terminalProc = tail;
    ws._smapiPid = smapiPid;

    tail.stdout.on('data', (data) => {
      if (ws.readyState === 1) {
        ws.send(JSON.stringify({
          type: 'terminal:output',
          data: data.toString(),
        }));
      }
    });

    tail.stderr.on('data', (data) => {
      if (ws.readyState === 1) {
        ws.send(JSON.stringify({
          type: 'terminal:output',
          data: data.toString(),
        }));
      }
    });

    tail.on('close', () => {
      if (ws.readyState === 1) {
        ws.send(JSON.stringify({
          type: 'terminal:closed',
          data: 'Terminal session ended.',
        }));
      }
      closeTerminal();
    });

    ws.send(JSON.stringify({
      type: 'terminal:opened',
      data: `Connected to SMAPI (PID: ${smapiPid}). This is not a Linux shell; type SMAPI commands or Steam Guard codes below.\r\n`,
    }));

    resetIdleTimeout();

  } catch (e) {
    ws.send(JSON.stringify({
      type: 'terminal:error',
      data: `Failed to open terminal: ${e.message}`,
    }));
  }
}

function handleInput(ws, data) {
  if (!ws._smapiPid) {
    ws.send(JSON.stringify({
      type: 'terminal:error',
      data: 'No active terminal session. Open terminal first.',
    }));
    return;
  }

  resetIdleTimeout();

  try {
    // Write to SMAPI process stdin via /proc/PID/fd/0
    const { writeFileSync } = require('fs');
    const input = data.endsWith('\n') ? data : data + '\n';
    writeFileSync(`/proc/${ws._smapiPid}/fd/0`, input);

    // Echo back the input
    ws.send(JSON.stringify({
      type: 'terminal:output',
      data: `> ${data}\r\n`,
    }));
  } catch (e) {
    try {
      const fallbackId = writeHostCommandFallback(input.trim());
      if (fallbackId) {
        ws.send(JSON.stringify({
          type: 'terminal:output',
          data: `[Panel] Direct SMAPI stdin was denied, so this built-in host command was queued through AutoHideHost (${fallbackId}).\r\n`,
        }));
        return;
      }
    } catch (fallbackError) {
      ws.send(JSON.stringify({
        type: 'terminal:error',
        data: `Failed to send input and host-command fallback failed: ${fallbackError.message}`,
      }));
      return;
    }

    ws.send(JSON.stringify({
      type: 'terminal:error',
      data: `Failed to send input: ${e.message}. If this is a normal SMAPI command, use docker attach puppy-stardew or VNC. Built-in host buttons use the safer file command channel.`,
    }));
  }
}

module.exports = { openTerminal, handleInput, closeTerminal };
