/**
 * Diagnostics API - health checks and support report export.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const config = require('../server');
const { AppError, commandError, sendError } = require('../errors');
const { buildDiagnostics } = require('../diagnostics');
const statusAPI = require('./status');
const modsAPI = require('./mods');

function runCommand(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf-8',
    ...options,
  });

  if (!result || result.status !== 0) {
    throw commandError(command, args, result);
  }

  return result.stdout || '';
}

function checkCommand(command, label) {
  const result = spawnSync('sh', ['-lc', `command -v ${command}`], {
    encoding: 'utf-8',
    timeout: 5000,
  });

  return {
    id: `command_${command}`,
    label,
    status: result.status === 0 ? 'ok' : 'error',
    detail: result.status === 0
      ? String(result.stdout || '').trim()
      : `${command} is not available in PATH`,
    action: result.status === 0 ? '' : `Install ${command} in the Docker image and restart the container.`,
  };
}

function checkPath(targetPath, label, options = {}) {
  const exists = fs.existsSync(targetPath);
  if (!exists) {
    return {
      id: `path_${label.replace(/[^a-z0-9]+/gi, '_').toLowerCase()}`,
      label,
      status: options.required === false ? 'warn' : 'error',
      detail: `${targetPath} does not exist`,
      action: options.required === false
        ? 'This may be created automatically after the server starts.'
        : 'Check Docker volume mounts and container permissions.',
    };
  }

  try {
    fs.accessSync(targetPath, options.writable ? fs.constants.R_OK | fs.constants.W_OK : fs.constants.R_OK);
    return {
      id: `path_${label.replace(/[^a-z0-9]+/gi, '_').toLowerCase()}`,
      label,
      status: 'ok',
      detail: options.writable ? `${targetPath} is readable and writable` : `${targetPath} is readable`,
      action: '',
    };
  } catch (error) {
    return {
      id: `path_${label.replace(/[^a-z0-9]+/gi, '_').toLowerCase()}`,
      label,
      status: 'error',
      detail: error.message,
      action: 'Fix ownership or permissions for the mounted directory.',
    };
  }
}

function readRecentLogLines(limit = 700) {
  try {
    if (!fs.existsSync(config.SMAPI_LOG)) {
      return [];
    }

    return fs.readFileSync(config.SMAPI_LOG, 'utf-8')
      .split(/\r?\n/)
      .filter(line => line.trim())
      .slice(-limit);
  } catch (error) {
    return [];
  }
}

function buildHealth(req = null) {
  const status = statusAPI.collectStatus(req);
  const logLines = readRecentLogLines();
  const logDiagnostics = buildDiagnostics(logLines, {
    source: path.basename(config.SMAPI_LOG),
  });

  const checks = [
    checkCommand('zip', 'zip command'),
    checkCommand('unzip', 'unzip command'),
    checkCommand('tar', 'tar command'),
    checkCommand('gzip', 'gzip command'),
    checkPath(config.DATA_DIR, 'Panel data directory', { writable: true }),
    checkPath(config.SAVES_DIR, 'Stardew saves directory', { writable: true, required: false }),
    checkPath(path.join(config.GAME_DIR, 'Mods'), 'Game Mods directory', { writable: true, required: false }),
    checkPath(config.LOG_DIR, 'Panel log directory', { writable: true, required: false }),
  ];

  checks.push({
    id: 'game_process',
    label: 'Stardew/SMAPI process',
    status: status.gameRunning ? 'ok' : 'warn',
    detail: status.gameRunning ? 'Game process is running' : 'Game process is not running',
    action: status.gameRunning ? '' : 'Start or restart the server before players try to join.',
  });

  checks.push({
    id: 'smapi_state_bridge',
    label: 'SMAPI state bridge',
    status: status.modRuntime?.active ? 'ok' : (status.gameRunning ? 'warn' : 'error'),
    detail: status.modRuntime?.active
      ? `Fresh state, age ${status.modRuntime.ageSeconds || 0}s`
      : `State bridge ${status.modRuntime?.state || 'unknown'}`,
    action: status.modRuntime?.active ? '' : 'Check whether AutoHideHost is loaded and can write game-state.json.',
  });

  checks.push({
    id: 'joinability',
    label: 'Player joinability',
    status: status.joinability?.joinable ? 'ok' : 'warn',
    detail: status.joinability?.label || status.joinability?.reason || 'Unknown',
    action: status.joinability?.joinable ? '' : (status.joinability?.action || 'Check SMAPI logs and host state.'),
  });

  if (logDiagnostics.issues.length > 0) {
    const hasError = logDiagnostics.issues.some(issue => issue.severity === 'error');
    checks.push({
      id: 'recent_log_diagnostics',
      label: 'Recent log diagnostics',
      status: hasError ? 'error' : 'warn',
      detail: `${logDiagnostics.issues.length} known issue(s) detected`,
      action: 'Open the Logs page or export a crash report for details.',
    });
  } else {
    checks.push({
      id: 'recent_log_diagnostics',
      label: 'Recent log diagnostics',
      status: 'ok',
      detail: 'No known issue patterns detected in recent logs',
      action: '',
    });
  }

  const summary = checks.reduce((acc, check) => {
    acc[check.status] = (acc[check.status] || 0) + 1;
    return acc;
  }, { ok: 0, warn: 0, error: 0 });

  return {
    generatedAt: new Date().toISOString(),
    overall: summary.error > 0 ? 'error' : (summary.warn > 0 ? 'warn' : 'ok'),
    summary,
    checks,
    status,
    diagnostics: logDiagnostics,
  };
}

function getHealth(req, res) {
  try {
    res.json(buildHealth(req));
  } catch (error) {
    return sendError(res, req, error, {
      status: 500,
      code: 'HEALTH_CHECK_FAILED',
      message: 'Failed to run health checks',
      cause: 'The panel could not collect one or more health check inputs.',
      details: error.message,
      action: 'Check panel logs and file permissions.',
    });
  }
}

function copyIfExists(sourcePath, targetDir, filename = '') {
  if (!sourcePath || !fs.existsSync(sourcePath)) {
    return false;
  }

  fs.cpSync(sourcePath, path.join(targetDir, filename || path.basename(sourcePath)), { recursive: true });
  return true;
}

function exportCrashReport(req, res) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'puppy-report-'));
  const archiveName = `ylty-stardew-report-${new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19)}.tar.gz`;
  const archivePath = path.join(os.tmpdir(), archiveName);

  try {
    const health = buildHealth(req);
    let modManifest = null;
    try {
      modManifest = modsAPI.getPublicModManifest(req);
    } catch (error) {
      modManifest = { error: error.message };
    }

    fs.writeFileSync(path.join(tempRoot, 'health.json'), JSON.stringify(health, null, 2), 'utf-8');
    fs.writeFileSync(path.join(tempRoot, 'mod-manifest.json'), JSON.stringify(modManifest, null, 2), 'utf-8');
    fs.writeFileSync(path.join(tempRoot, 'recent-smapi-lines.txt'), readRecentLogLines(1200).join('\n'), 'utf-8');

    copyIfExists(config.SMAPI_LOG, tempRoot, 'SMAPI-latest.txt');
    copyIfExists(config.STATUS_FILE, tempRoot, 'status.json');
    copyIfExists(config.GAME_STATE_FILE, tempRoot, 'game-state.json');
    copyIfExists(config.MANUAL_PAUSE_FILE, tempRoot, 'manual-pause.json');
    copyIfExists(config.AUTO_PAUSE_FILE, tempRoot, 'auto-pause.json');
    copyIfExists(path.join(config.LOG_DIR, 'categorized'), tempRoot, 'categorized-logs');

    runCommand('tar', ['-czf', archivePath, '-C', tempRoot, '.'], {
      timeout: 180000,
    });

    res.download(archivePath, archiveName, (error) => {
      fs.rmSync(tempRoot, { recursive: true, force: true });
      fs.rmSync(archivePath, { force: true });
      if (error && !res.headersSent) {
        return sendError(res, req, error, {
          status: 500,
          code: 'REPORT_DOWNLOAD_FAILED',
          message: 'Failed to download crash report',
          cause: 'The report archive was created, but the panel could not send it to the browser.',
          details: error.message,
          action: 'Retry the export and check panel logs if it fails again.',
        });
      }
    });
  } catch (error) {
    fs.rmSync(tempRoot, { recursive: true, force: true });
    fs.rmSync(archivePath, { force: true });
    return sendError(res, req, error, {
      status: 500,
      code: 'REPORT_CREATE_FAILED',
      message: 'Failed to create crash report',
      cause: error.cause || 'The panel could not create the diagnostic report archive.',
      details: error.details || error.message,
      action: error.action || 'Check tar/gzip availability, disk space, and panel data permissions.',
    });
  }
}

module.exports = {
  getHealth,
  exportCrashReport,
};
