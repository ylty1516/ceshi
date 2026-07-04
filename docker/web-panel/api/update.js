/**
 * Panel update API.
 * Proxies update requests to the manager container and reads persisted status.
 */

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const config = require('../server');
const { AppError, sendError } = require('../errors');

const UPDATE_STATUS_FILE = path.join(config.DATA_DIR, 'update-status.json');
const UPDATE_LOG_FILE = path.join(config.DATA_DIR, 'update.log');
const MANAGER_TIMEOUT_MS = 8000;
const UPDATE_QUEUED_TIMEOUT_MS = parseInt(process.env.PUPPY_UPDATE_QUEUED_TIMEOUT_MS || '90000', 10);

function readTextTail(filePath, maxBytes = 32000) {
  try {
    if (!fs.existsSync(filePath)) return '';
    const stat = fs.statSync(filePath);
    const bytesToRead = Math.min(stat.size, maxBytes);
    const fd = fs.openSync(filePath, 'r');
    try {
      const buffer = Buffer.alloc(bytesToRead);
      const start = Math.max(0, stat.size - bytesToRead);
      const bytesRead = fs.readSync(fd, buffer, 0, bytesToRead, start);
      return buffer.subarray(0, bytesRead).toString('utf8');
    } finally {
      fs.closeSync(fd);
    }
  } catch (error) {
    return '';
  }
}

function readLocalStatus() {
  let status = {
    state: 'idle',
    phase: 'idle',
    message: 'No update has been started yet.',
    startedAt: '',
    updatedAt: '',
    completedAt: '',
    backupDir: '',
    logFile: UPDATE_LOG_FILE,
    exitCode: 0,
  };

  try {
    if (fs.existsSync(UPDATE_STATUS_FILE)) {
      status = {
        ...status,
        ...JSON.parse(fs.readFileSync(UPDATE_STATUS_FILE, 'utf8')),
      };
    }
  } catch (error) {
    status = {
      ...status,
      state: 'unknown',
      phase: 'status_read_failed',
      message: error.message || 'Failed to read update status.',
    };
  }

  if (status.state === 'running' && status.phase === 'queued') {
    const lastUpdateMs = Date.parse(status.updatedAt || status.startedAt || '');
    const queuedTimeoutMs = Number.isFinite(UPDATE_QUEUED_TIMEOUT_MS) && UPDATE_QUEUED_TIMEOUT_MS > 0
      ? UPDATE_QUEUED_TIMEOUT_MS
      : 90000;
    if (Number.isFinite(lastUpdateMs) && Date.now() - lastUpdateMs > queuedTimeoutMs) {
      status = {
        ...status,
        state: 'failed',
        phase: 'queued_timeout',
        message: 'Updater container stayed queued for too long. The manager or Docker runner did not advance to execution.',
        updatedAt: new Date().toISOString(),
        completedAt: new Date().toISOString(),
        exitCode: status.exitCode || 124,
      };
    }
  }

  return {
    ...status,
    running: status.state === 'running',
    managerAvailable: false,
    logTail: readTextTail(UPDATE_LOG_FILE),
  };
}

function describeManagerError(error) {
  const rawMessage = error && error.message ? String(error.message) : 'Manager service is unavailable';
  const rawDetails = error && error.details ? String(error.details) : '';
  const text = [rawMessage, rawDetails, error && error.code].filter(Boolean).join('\n');

  if (/MANAGER_NOT_CONFIGURED/i.test(text)) {
    return {
      code: 'MANAGER_NOT_CONFIGURED',
      message: 'Update manager is not configured.',
      cause: 'MANAGER_URL is empty, so the web panel cannot contact the stardew-manager service.',
      action: 'Recreate the stack with the latest docker-compose.yml, then check that MANAGER_URL points to http://stardew-manager:18700.',
    };
  }

  if (/timeout|timed out/i.test(text)) {
    return {
      code: 'MANAGER_TIMEOUT',
      message: 'Update manager request timed out.',
      cause: 'The stardew-manager container did not respond before the panel timeout.',
      action: 'Run "docker logs puppy-stardew-manager" and check whether the container is stuck or restarting.',
    };
  }

  if (/ECONNREFUSED|ENOTFOUND|EAI_AGAIN|socket hang up|502|Bad Gateway/i.test(text)) {
    return {
      code: 'MANAGER_UNREACHABLE',
      message: 'Update manager is unreachable.',
      cause: 'The web panel cannot reach the stardew-manager container that runs Docker update tasks.',
      action: 'Run "docker ps | grep puppy-stardew-manager", then "docker logs puppy-stardew-manager". If it is missing, run "docker compose up -d --build stardew-manager stardew-server".',
    };
  }

  return {
    code: 'MANAGER_STATUS_FAILED',
    message: 'Failed to read update manager status.',
    cause: 'The stardew-manager service returned an unexpected error.',
    action: 'Check docker logs puppy-stardew-manager and verify Docker socket and project directory mounts.',
  };
}

function requestManager(method, route, body = null) {
  const managerUrl = process.env.MANAGER_URL || '';
  if (!managerUrl) {
    return Promise.reject(new AppError('Manager service is not configured', {
      status: 503,
      code: 'MANAGER_NOT_CONFIGURED',
      cause: 'MANAGER_URL is empty, so the panel cannot ask the manager container to update the host project.',
      action: 'Recreate the stack with the latest docker-compose.yml so the stardew-manager service is available.',
    }));
  }

  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(route, managerUrl);
    } catch (error) {
      reject(new AppError('Invalid manager URL', {
        status: 500,
        code: 'INVALID_MANAGER_URL',
        cause: 'MANAGER_URL is not a valid URL.',
        action: 'Set MANAGER_URL to a valid internal manager URL.',
      }));
      return;
    }

    const payload = body ? JSON.stringify(body) : '';
    const client = parsed.protocol === 'https:' ? https : http;
    let timedOut = false;
    const request = client.request({
      protocol: parsed.protocol,
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname + parsed.search,
      method,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: MANAGER_TIMEOUT_MS,
    }, (response) => {
      let responseBody = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        responseBody += chunk;
      });
      response.on('end', () => {
        let data = {};
        try {
          data = responseBody ? JSON.parse(responseBody) : {};
        } catch (error) {
          data = { error: responseBody || `HTTP ${response.statusCode}` };
        }

        if (response.statusCode && response.statusCode >= 200 && response.statusCode < 300) {
          resolve({
            ...data,
            managerAvailable: true,
          });
          return;
        }

        reject(new AppError(data.error || `HTTP ${response.statusCode}`, {
          status: response.statusCode || 500,
          code: 'MANAGER_UPDATE_FAILED',
          cause: 'The manager service rejected the update request.',
          details: data.error || responseBody,
          action: 'Open the update log in the panel, or check docker logs puppy-stardew-manager.',
        }));
      });
    });

    request.on('timeout', () => {
      timedOut = true;
      request.destroy(new Error('Manager request timed out'));
    });
    request.on('error', (error) => {
      reject(new AppError(timedOut ? 'Manager request timed out' : 'Manager service is unreachable', {
        status: 503,
        code: timedOut ? 'MANAGER_TIMEOUT' : 'MANAGER_UNREACHABLE',
        cause: timedOut
          ? 'The stardew-manager container did not respond before the panel timeout.'
          : 'The web panel could not connect to the stardew-manager container.',
        details: error.message,
        action: 'Check that the stardew-manager container is running and reachable at MANAGER_URL.',
      }));
    });
    if (payload) request.write(payload);
    request.end();
  });
}

async function getUpdateStatus(req, res) {
  try {
    const status = await requestManager('GET', '/update/status');
    res.json(status);
  } catch (error) {
    const localStatus = readLocalStatus();
    const managerIssue = describeManagerError(error);
    if (localStatus.state !== 'idle') {
      res.json({
        ...localStatus,
        canStart: false,
        managerAvailable: false,
        managerUnavailable: true,
        managerError: error.message,
        code: managerIssue.code,
        cause: managerIssue.cause,
        action: managerIssue.action,
      });
      return;
    }

    res.json({
      ...localStatus,
      state: 'unknown',
      phase: 'manager_unavailable',
      message: managerIssue.message,
      messageKey: 'update.managerUnavailable',
      updatedAt: new Date().toISOString(),
      managerAvailable: false,
      managerUnavailable: true,
      canStart: false,
      managerError: error.message,
      code: managerIssue.code,
      cause: managerIssue.cause,
      action: managerIssue.action,
    });
  }
}

async function startUpdate(req, res) {
  try {
    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const result = await requestManager('POST', '/update', {
      force: body.force === true,
      skipSaveBackup: body.skipSaveBackup === true,
      noBuild: body.noBuild === true,
    });

    res.status(result.alreadyRunning ? 200 : 202).json({
      success: true,
      ...result,
    });
  } catch (error) {
    return sendError(res, req, error, {
      status: 500,
      code: 'UPDATE_START_FAILED',
      message: 'Failed to start panel update',
      cause: 'The panel could not start the updater through the manager service.',
      details: error.message,
      action: 'Check MANAGER_URL, the stardew-manager container, Docker socket access, and project directory permissions.',
    });
  }
}

module.exports = {
  getUpdateStatus,
  startUpdate,
};
