/**
 * Players API - Online player information
 */

const fs = require('fs');
const config = require('../server');
const { MAX_PLAYERS, getVisiblePlayers, readFreshGameState } = require('./game-state');

// Player history (in-memory)
const playerHistory = [];
const configuredPlayerHistoryLimit = parseInt(process.env.PANEL_PLAYER_HISTORY_LIMIT || '144', 10);
const configuredPlayerLogTailBytes = parseInt(process.env.PANEL_PLAYER_LOG_TAIL_BYTES || String(128 * 1024), 10);
const MAX_PLAYER_HISTORY = Number.isFinite(configuredPlayerHistoryLimit) && configuredPlayerHistoryLimit > 0
  ? configuredPlayerHistoryLimit
  : 144;
const PLAYER_LOG_TAIL_BYTES = Number.isFinite(configuredPlayerLogTailBytes) && configuredPlayerLogTailBytes > 0
  ? configuredPlayerLogTailBytes
  : 128 * 1024;

// Track connected players from log parsing
let connectedPlayers = [];
let lastLogParse = 0;

function getPlayersFromGameState(gameState) {
  const visiblePlayers = getVisiblePlayers(gameState);
  if (!gameState || !Array.isArray(gameState.onlinePlayers)) {
    return null;
  }

  return visiblePlayers.map(player => ({
    id: player.id || player.name || 'unknown',
    name: player.name || normalizePlayerLabel(player.id || ''),
    location: player.location || '',
    inBed: player.inBed === true,
  }));
}

function normalizePlayerLabel(value) {
  if (!value) {
    return 'Player';
  }

  if (/^\d+$/.test(value)) {
    return `Farmhand ${value.slice(-6)}`;
  }

  return value;
}

function parsePlayersFromLogs() {
  const now = Date.now();
  if (now - lastLogParse < 10000) return connectedPlayers; // Cache 10s

  try {
    const logPath = config.SMAPI_LOG;
    if (!fs.existsSync(logPath)) return connectedPlayers;

    const stat = fs.statSync(logPath);
    const bytesToRead = Math.min(stat.size, Number.isFinite(PLAYER_LOG_TAIL_BYTES) ? PLAYER_LOG_TAIL_BYTES : 128 * 1024);
    const start = Math.max(0, stat.size - bytesToRead);
    const fd = fs.openSync(logPath, 'r');
    let content = '';
    try {
      const buffer = Buffer.alloc(bytesToRead);
      const bytesRead = fs.readSync(fd, buffer, 0, bytesToRead, start);
      content = buffer.subarray(0, bytesRead).toString('utf-8');
    } finally {
      fs.closeSync(fd);
    }
    const lines = content.split('\n');

    const players = new Map();

    for (const line of lines) {
      // Detect player connections
      const joinMatch = line.match(/(\w+) connected/i) ||
                        line.match(/peer (\w+) joined/i) ||
                        line.match(/(\w+) joined the game/i) ||
                        line.match(/farmhand (\w+) connected/i) ||
                        line.match(/client (\w+) connected/i) ||
                        line.match(/Received connection for vanilla player ([A-Za-z0-9_]+)/i) ||
                        line.match(/Approved request for farmhand ([A-Za-z0-9_]+)/i);
      if (joinMatch) {
        const id = joinMatch[1];
        if (id !== 'Server' && id !== 'SMAPI') {
          players.set(id, {
            id,
            name: normalizePlayerLabel(id),
            joinedAt: new Date().toISOString(),
          });
        }
      }

      // Detect player disconnections
      const leaveMatch = line.match(/(\w+) disconnected/i) ||
                         line.match(/peer (\w+) left/i) ||
                         line.match(/(\w+) left the game/i) ||
                         line.match(/farmhand (\w+) disconnected/i) ||
                         line.match(/client (\w+) disconnected/i) ||
                         line.match(/connection ([A-Za-z0-9_]+) disconnected/i) ||
                         line.match(/player ([A-Za-z0-9_]+) disconnected/i);
      if (leaveMatch) {
        players.delete(leaveMatch[1]);
      }
    }

    connectedPlayers = Array.from(players.values());
    lastLogParse = now;
  } catch (e) {
    // Log parsing failed, keep last known state
  }

  return connectedPlayers;
}

function getOnlineCount() {
  const gameState = readFreshGameState();
  const players = getPlayersFromGameState(gameState);
  if (players) {
    return players.length;
  }

  return 0;
}

// Record player count history every 5 minutes
setInterval(() => {
  const count = getOnlineCount();
  playerHistory.push({
    timestamp: new Date().toISOString(),
    count,
  });
  if (playerHistory.length > MAX_PLAYER_HISTORY) {
    playerHistory.shift();
  }
}, 5 * 60 * 1000);

// ─── Route Handler ───────────────────────────────────────────────

function getPlayers(req, res) {
  const gameState = readFreshGameState();
  const statePlayers = getPlayersFromGameState(gameState);
  if (statePlayers) {
    return res.json({
      online: statePlayers.length,
      max: MAX_PLAYERS,
      players: statePlayers,
      source: 'smapi-state-bridge',
      trusted: true,
      refreshedAt: gameState.updatedAt || null,
      ageSeconds: typeof gameState.ageSeconds === 'number' ? gameState.ageSeconds : null,
      history: playerHistory,
    });
  }

  parsePlayersFromLogs();

  res.json({
    online: 0,
    max: MAX_PLAYERS,
    players: [],
    source: 'untrusted',
    trusted: false,
    refreshedAt: null,
    ageSeconds: null,
    history: playerHistory,
  });
}

module.exports = { getPlayers };
