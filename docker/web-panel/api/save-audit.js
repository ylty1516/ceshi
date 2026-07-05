/**
 * Lightweight Stardew save slot audit.
 *
 * This intentionally avoids a full XML parser so status/health checks stay
 * cheap on 2c/2g servers. The audit reads only the selected main save file and
 * startup_preferences, then reports evidence instead of silently guessing.
 */

const fs = require('fs');
const path = require('path');
const config = require('../server');

const CACHE_TTL_MS = parseInt(process.env.PANEL_SAVE_SLOT_AUDIT_CACHE_MS || '60000', 10);
const MAX_SAVE_AUDIT_BYTES = parseInt(process.env.PANEL_SAVE_AUDIT_MAX_BYTES || String(64 * 1024 * 1024), 10);

let cachedAudit = null;
let cachedAt = 0;

function normalizeSaveName(value) {
  return String(value || '').trim();
}

function isSafeSaveName(value) {
  const name = normalizeSaveName(value);
  return !!name && !name.includes('/') && !name.includes('\\') && name !== '.' && name !== '..';
}

function parseEnvValue(rawValue) {
  const raw = String(rawValue ?? '').trim();
  if (!raw) return '';

  if (raw.startsWith("'") && raw.endsWith("'") && raw.length >= 2) {
    return raw.slice(1, -1).replace(/\\'/g, "'");
  }

  if (raw.startsWith('"') && raw.endsWith('"') && raw.length >= 2) {
    return raw.slice(1, -1)
      .replace(/\\n/g, '\n')
      .replace(/\\r/g, '\r')
      .replace(/\\t/g, '\t')
      .replace(/\\"/g, '"')
      .replace(/\\\\/g, '\\');
  }

  return raw.replace(/\s+#.*$/, '').trim();
}

function readText(filePath, fallback = '') {
  try {
    if (!filePath || !fs.existsSync(filePath)) {
      return fallback;
    }
    return fs.readFileSync(filePath, 'utf-8');
  } catch (error) {
    return fallback;
  }
}

function readJson(filePath, fallback = null) {
  try {
    if (!filePath || !fs.existsSync(filePath)) {
      return fallback;
    }
    return JSON.parse(fs.readFileSync(filePath, 'utf-8'));
  } catch (error) {
    return {
      error: error.message,
      file: filePath,
    };
  }
}

function parseEnvFile(filePath) {
  const env = {};
  if (!filePath || !fs.existsSync(filePath)) {
    return env;
  }

  const content = readText(filePath);
  for (const line of content.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) {
      continue;
    }

    const eqIndex = trimmed.indexOf('=');
    if (eqIndex === -1) {
      continue;
    }

    const key = trimmed.slice(0, eqIndex).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
      continue;
    }

    env[key] = parseEnvValue(trimmed.slice(eqIndex + 1));
  }

  return env;
}

function getRuntimeEnv() {
  const candidates = [
    config.ENV_FILE,
    '/home/steam/.env',
    path.join(process.cwd(), '.env'),
  ];
  const merged = {};

  for (const envPath of candidates) {
    Object.assign(merged, parseEnvFile(envPath));
  }

  return merged;
}

function readSelectedSaveMarker() {
  const markerPath = path.join(config.SAVES_DIR, '.selected_save');
  const selected = normalizeSaveName(readText(markerPath));
  return {
    file: markerPath,
    saveName: selected,
    exists: !!selected,
  };
}

function getStartupPreferencesPath() {
  return process.env.STARTUP_PREFERENCES_FILE ||
    path.join(path.dirname(config.SAVES_DIR), 'startup_preferences');
}

function extractTagValue(content, tagName) {
  if (!content) {
    return '';
  }

  const match = content.match(new RegExp(`<${tagName}\\b[^>]*>([\\s\\S]*?)<\\/${tagName}>`, 'i'));
  return match ? match[1].trim() : '';
}

function parseBoolText(value) {
  const normalized = String(value || '').trim().toLowerCase();
  if (normalized === 'true') return true;
  if (normalized === 'false') return false;
  return null;
}

function readStartupPreferences() {
  const file = getStartupPreferencesPath();
  const content = readText(file);
  const playerLimitText = extractTagValue(content, 'playerLimit');
  const playerLimit = parseInt(playerLimitText, 10);

  return {
    file,
    exists: !!content,
    playerLimit: Number.isFinite(playerLimit) ? playerLimit : null,
    enableFarmhandCreation: parseBoolText(extractTagValue(content, 'enableFarmhandCreation')),
    enableServer: parseBoolText(extractTagValue(content, 'enableServer')),
    ipConnectionsEnabled: parseBoolText(extractTagValue(content, 'ipConnectionsEnabled')),
  };
}

function readServerAutoLoadConfig() {
  const file = path.join(config.GAME_DIR, 'Mods', 'ServerAutoLoad', 'config.json');
  const data = readJson(file, null);
  if (!data || data.error) {
    return {
      file,
      exists: false,
      enabled: null,
      saveFileName: '',
      useSelectedSaveMarker: true,
      autoSelectMostRecentSave: true,
      error: data && data.error ? data.error : '',
    };
  }

  return {
    file,
    exists: true,
    enabled: data.Enabled !== false,
    saveFileName: normalizeSaveName(data.SaveFileName),
    useSelectedSaveMarker: data.UseSelectedSaveMarker !== false,
    autoSelectMostRecentSave: data.AutoSelectMostRecentSave !== false,
  };
}

function isValidSaveDirectory(saveDir) {
  const name = path.basename(saveDir);
  return fs.existsSync(path.join(saveDir, 'SaveGameInfo')) &&
    fs.existsSync(path.join(saveDir, name));
}

function listSaveDirectories() {
  if (!fs.existsSync(config.SAVES_DIR)) {
    return [];
  }

  return fs.readdirSync(config.SAVES_DIR, { withFileTypes: true })
    .filter(entry => entry.isDirectory() && !entry.name.startsWith('.'))
    .map(entry => {
      const saveDir = path.join(config.SAVES_DIR, entry.name);
      const mainSavePath = path.join(saveDir, entry.name);
      let mtimeMs = 0;
      let size = 0;
      try {
        const stat = fs.statSync(mainSavePath);
        mtimeMs = stat.mtimeMs;
        size = stat.size;
      } catch (error) {
        try {
          mtimeMs = fs.statSync(saveDir).mtimeMs;
        } catch (dirError) {}
      }

      return {
        name: entry.name,
        path: saveDir,
        mainSavePath,
        saveGameInfoPath: path.join(saveDir, 'SaveGameInfo'),
        valid: isValidSaveDirectory(saveDir),
        mtimeMs,
        size,
        updatedAt: mtimeMs ? new Date(mtimeMs).toISOString() : '',
      };
    })
    .sort((a, b) => b.mtimeMs - a.mtimeMs);
}

function resolveSelectedSave(autoLoadConfig, marker, runtimeEnv, saves) {
  const processSaveName = normalizeSaveName(process.env.SAVE_NAME);
  const runtimeSaveName = normalizeSaveName(runtimeEnv.SAVE_NAME);
  const sources = {
    serverAutoLoadConfig: autoLoadConfig.saveFileName || '',
    processEnv: processSaveName,
    runtimeEnv: runtimeSaveName,
    selectedMarker: marker.saveName || '',
    newestValidSave: (saves.find(save => save.valid) || {}).name || '',
  };

  let selectedSave = '';
  let source = 'none';

  if (sources.serverAutoLoadConfig) {
    selectedSave = sources.serverAutoLoadConfig;
    source = 'ServerAutoLoad config SaveFileName';
  } else if (sources.processEnv) {
    selectedSave = sources.processEnv;
    source = 'process SAVE_NAME';
  } else if (autoLoadConfig.useSelectedSaveMarker !== false && sources.selectedMarker) {
    selectedSave = sources.selectedMarker;
    source = '.selected_save marker';
  } else if (autoLoadConfig.autoSelectMostRecentSave !== false && sources.newestValidSave) {
    selectedSave = sources.newestValidSave;
    source = 'newest valid save';
  }

  const selected = selectedSave && isSafeSaveName(selectedSave)
    ? saves.find(save => save.name === selectedSave)
    : null;

  return {
    selectedSave,
    selected,
    source,
    sources,
  };
}

function readMainSave(save) {
  if (!save || !save.mainSavePath || !fs.existsSync(save.mainSavePath)) {
    return {
      available: false,
      content: '',
      truncated: false,
      error: 'Main save file is missing.',
    };
  }

  const stat = fs.statSync(save.mainSavePath);
  const maxBytes = Number.isFinite(MAX_SAVE_AUDIT_BYTES) && MAX_SAVE_AUDIT_BYTES > 0
    ? MAX_SAVE_AUDIT_BYTES
    : 64 * 1024 * 1024;
  if (stat.size > maxBytes) {
    const fd = fs.openSync(save.mainSavePath, 'r');
    try {
      const buffer = Buffer.alloc(maxBytes);
      const bytesRead = fs.readSync(fd, buffer, 0, maxBytes, 0);
      return {
        available: true,
        content: buffer.subarray(0, bytesRead).toString('utf-8'),
        truncated: true,
        error: '',
      };
    } finally {
      fs.closeSync(fd);
    }
  }

  return {
    available: true,
    content: fs.readFileSync(save.mainSavePath, 'utf-8'),
    truncated: false,
    error: '',
  };
}

function countMatches(content, regex) {
  const matches = content.match(regex);
  return matches ? matches.length : 0;
}

function countFarmhands(content) {
  const farmhandsMatch = content.match(/<farmhands\b[^>]*>([\s\S]*?)<\/farmhands>/i);
  if (!farmhandsMatch) {
    return {
      count: 0,
      confidence: 'low',
      foundSection: false,
    };
  }

  return {
    count: countMatches(farmhandsMatch[1], /<Farmer\b/gi),
    confidence: 'high',
    foundSection: true,
  };
}

function countCabins(content) {
  const buildingTypeCabins = countMatches(content, /<buildingType>\s*Cabin\s*<\/buildingType>/gi);
  const buildingXsiCabins = countMatches(content, /<Building\b[^>]*xsi:type=["']Cabin["'][^>]*>/gi);
  const indoorCabins = countMatches(content, /<indoors\b[^>]*xsi:type=["']Cabin["'][^>]*>/gi);
  const namedIndoorCabins = countMatches(content, /<nameOfIndoors>\s*Cabin/gi);
  const count = buildingTypeCabins || Math.max(buildingXsiCabins, indoorCabins, namedIndoorCabins);

  return {
    count,
    confidence: buildingTypeCabins > 0 || buildingXsiCabins > 0 ? 'medium' : 'low',
    evidence: {
      buildingTypeCabins,
      buildingXsiCabins,
      indoorCabins,
      namedIndoorCabins,
    },
  };
}

function readServerAutoLoadState() {
  const data = readJson(config.SERVER_AUTOLOAD_STATE_FILE, null);
  if (!data || data.error) {
    return {
      available: false,
      phase: '',
      ok: null,
      targetSave: '',
      message: '',
      file: config.SERVER_AUTOLOAD_STATE_FILE,
      error: data && data.error ? data.error : '',
    };
  }

  return {
    available: true,
    file: config.SERVER_AUTOLOAD_STATE_FILE,
    phase: data.phase || '',
    ok: data.ok === true,
    targetSave: normalizeSaveName(data.targetSave),
    message: data.message || '',
    updatedAt: data.updatedAt || '',
  };
}

function buildIssue(severity, code, message, action) {
  return { severity, code, message, action };
}

function summarizeAudit(audit) {
  const errors = audit.issues.filter(issue => issue.severity === 'error');
  const warnings = audit.issues.filter(issue => issue.severity === 'warn');
  const slot = audit.slotEstimate;

  if (errors.length > 0) {
    return {
      status: 'error',
      label: 'Save slot audit found a blocker',
      action: errors[0].action,
    };
  }

  if (warnings.length > 0) {
    return {
      status: 'warn',
      label: 'Save slot audit needs attention',
      action: warnings[0].action,
    };
  }

  if (slot.estimatedFreeFarmhandSlots !== null && slot.estimatedFreeFarmhandSlots > 0) {
    return {
      status: 'ok',
      label: 'Save slot audit found free farmhand capacity',
      action: '',
    };
  }

  return {
    status: 'ok',
    label: 'Save slot audit did not find a slot blocker',
    action: '',
  };
}

function buildSaveSlotAudit(options = {}) {
  const now = Date.now();
  if (!options.force && cachedAudit && now - cachedAt < CACHE_TTL_MS) {
    return cachedAudit;
  }

  const runtimeEnv = getRuntimeEnv();
  const marker = readSelectedSaveMarker();
  const autoLoadConfig = readServerAutoLoadConfig();
  const startupPreferences = readStartupPreferences();
  const saves = listSaveDirectories();
  const selection = resolveSelectedSave(autoLoadConfig, marker, runtimeEnv, saves);
  const selected = selection.selected || null;
  const mainSave = readMainSave(selected);
  const farmhands = mainSave.available ? countFarmhands(mainSave.content) : { count: null, confidence: 'none', foundSection: false };
  const cabins = mainSave.available ? countCabins(mainSave.content) : { count: null, confidence: 'none', evidence: {} };
  const playerLimit = startupPreferences.playerLimit;
  const maxFarmhandsByLimit = Number.isFinite(playerLimit) ? Math.max(0, Math.min(playerLimit, 8) - 1) : null;
  const cabinCount = Number.isFinite(cabins.count) ? cabins.count : null;
  const farmhandCount = Number.isFinite(farmhands.count) ? farmhands.count : null;
  const capacity = maxFarmhandsByLimit !== null && cabinCount !== null
    ? Math.min(maxFarmhandsByLimit, cabinCount)
    : null;
  const estimatedFreeFarmhandSlots = capacity !== null && farmhandCount !== null
    ? Math.max(0, capacity - farmhandCount)
    : null;
  const autoLoadState = readServerAutoLoadState();

  const audit = {
    generatedAt: new Date().toISOString(),
    status: 'unknown',
    label: '',
    action: '',
    savesDir: config.SAVES_DIR,
    saveCount: saves.length,
    validSaveCount: saves.filter(save => save.valid).length,
    selection: {
      source: selection.source,
      selectedSave: selection.selectedSave,
      selectedPath: selected ? selected.path : '',
      selectedExists: !!selected,
      selectedValid: !!(selected && selected.valid),
      sources: selection.sources,
      markerFile: marker.file,
    },
    startupPreferences,
    serverAutoLoad: {
      config: autoLoadConfig,
      state: autoLoadState,
    },
    saveXml: {
      available: mainSave.available,
      truncated: mainSave.truncated,
      error: mainSave.error,
      size: selected ? selected.size : 0,
      updatedAt: selected ? selected.updatedAt : '',
    },
    farmhands,
    cabins,
    slotEstimate: {
      playerLimit,
      maxFarmhandsByLimit,
      cabinCount,
      farmhandCount,
      capacity,
      estimatedFreeFarmhandSlots,
      enableFarmhandCreation: startupPreferences.enableFarmhandCreation,
    },
    issues: [],
  };

  if (!fs.existsSync(config.SAVES_DIR)) {
    audit.issues.push(buildIssue(
      'error',
      'SAVES_DIR_MISSING',
      `${config.SAVES_DIR} does not exist.`,
      'Check the Docker volume mount for data/saves and restart the container.'
    ));
  } else if (audit.validSaveCount === 0) {
    audit.issues.push(buildIssue(
      'error',
      'NO_VALID_SAVE',
      'No folder contains both SaveGameInfo and a matching main save file.',
      'Upload a valid Stardew Valley save zip from the Saves page, then set it as default.'
    ));
  }

  const processSave = selection.sources.processEnv || '';
  if (/^(['"]).*\1$/.test(processSave)) {
    const unquoted = parseEnvValue(processSave);
    if (unquoted && saves.some(save => save.name === unquoted)) {
      audit.issues.push(buildIssue(
        'error',
        'SAVE_NAME_HAS_LITERAL_QUOTES',
        `The running SAVE_NAME is ${processSave}, so the game may search for a save with quote characters instead of ${unquoted}.`,
        'Update to this build, restart the container once, then confirm the Save slot audit shows the unquoted save name.'
      ));
    }
  }

  if (selection.selectedSave && !selected) {
    audit.issues.push(buildIssue(
      'error',
      'SELECTED_SAVE_NOT_FOUND',
      `Selected save ${selection.selectedSave} was not found in ${config.SAVES_DIR}.`,
      'Open Saves, choose the intended save again, then restart the game container.'
    ));
  } else if (selected && !selected.valid) {
    audit.issues.push(buildIssue(
      'error',
      'SELECTED_SAVE_INVALID',
      `Selected save ${selected.name} is missing SaveGameInfo or the matching main save file.`,
      'Restore/upload a complete Stardew save folder and set it as the default save.'
    ));
  }

  if (autoLoadConfig.enabled === false) {
    audit.issues.push(buildIssue(
      'error',
      'SERVER_AUTOLOAD_DISABLED',
      'ServerAutoLoad is disabled, so the native Co-op Host flow will not auto-load the save.',
      'Enable ServerAutoLoad and restart the container.'
    ));
  }

  const conflictingSources = [
    ['ServerAutoLoad SaveFileName', selection.sources.serverAutoLoadConfig],
    ['process SAVE_NAME', selection.sources.processEnv],
    ['runtime.env SAVE_NAME', selection.sources.runtimeEnv],
    ['.selected_save', selection.sources.selectedMarker],
  ].filter(item => item[1]);
  const uniqueSourceValues = Array.from(new Set(conflictingSources.map(item => item[1])));
  if (uniqueSourceValues.length > 1) {
    audit.issues.push(buildIssue(
      'warn',
      'SAVE_SELECTION_SOURCES_CONFLICT',
      `Save selection sources disagree: ${conflictingSources.map(item => `${item[0]}=${item[1]}`).join(', ')}.`,
      'Use the Saves page to set the intended save, then restart once so runtime.env, .selected_save and the game process agree.'
    ));
  }

  if (!startupPreferences.exists) {
    audit.issues.push(buildIssue(
      'warn',
      'STARTUP_PREFERENCES_MISSING',
      `${startupPreferences.file} does not exist yet.`,
      'Start the game once so startup_preferences is generated, then refresh diagnostics.'
    ));
  } else {
    if (!Number.isFinite(playerLimit)) {
      audit.issues.push(buildIssue(
        'warn',
        'PLAYER_LIMIT_UNKNOWN',
        'startup_preferences does not contain a readable playerLimit.',
        'Open Configuration, set Max Players to 8, save, then restart the container.'
      ));
    } else if (playerLimit < 2) {
      audit.issues.push(buildIssue(
        'error',
        'PLAYER_LIMIT_TOO_LOW',
        `playerLimit is ${playerLimit}, which leaves no farmhand slots.`,
        'Set Max Players to 8 in the panel configuration and restart the container.'
      ));
    } else if (playerLimit < 8) {
      audit.issues.push(buildIssue(
        'warn',
        'PLAYER_LIMIT_BELOW_EIGHT',
        `playerLimit is ${playerLimit}; this can cap free farmhand slots even when more cabins exist.`,
        'Set Max Players to 8 if you want seven real players plus the hidden host.'
      ));
    }

    if (startupPreferences.enableFarmhandCreation === false) {
      audit.issues.push(buildIssue(
        'warn',
        'FARMHAND_CREATION_DISABLED',
        'enableFarmhandCreation is false, so brand-new players may not be able to create a farmhand.',
        'Enable farmhand creation in startup_preferences or through the game settings, then restart.'
      ));
    }
  }

  if (mainSave.truncated) {
    audit.issues.push(buildIssue(
      'warn',
      'SAVE_AUDIT_TRUNCATED',
      `The selected save is larger than ${MAX_SAVE_AUDIT_BYTES} bytes, so only the first part was inspected.`,
      'Increase PANEL_SAVE_AUDIT_MAX_BYTES temporarily if the cabin/farmhand counts look wrong.'
    ));
  }

  if (selected && mainSave.available) {
    if (cabinCount === 0 && cabins.confidence !== 'none') {
      audit.issues.push(buildIssue(
        'warn',
        'NO_CABINS_DETECTED',
        'The selected save audit did not detect any Cabin buildings.',
        'Confirm the selected save is the intended co-op save and that cabins were built before uploading it.'
      ));
    }

    if (estimatedFreeFarmhandSlots === 0 && capacity !== null) {
      audit.issues.push(buildIssue(
        'error',
        'NO_ESTIMATED_FREE_FARMHAND_SLOTS',
        `Estimated free farmhand slots are 0: capacity=${capacity}, existing farmhands=${farmhandCount}.`,
        'Add more cabins, remove unused farmhand records, or have players reuse existing farmhands.'
      ));
    }
  }

  if (autoLoadState.available && autoLoadState.ok === false) {
    audit.issues.push(buildIssue(
      'warn',
      'SERVER_AUTOLOAD_NOT_OK',
      `ServerAutoLoad phase ${autoLoadState.phase}: ${autoLoadState.message || 'no message'}.`,
      'Check whether the selected save appears in the in-game Co-op Host list and whether the save source names agree.'
    ));
  }

  if (autoLoadState.available && autoLoadState.targetSave && selection.selectedSave && autoLoadState.targetSave !== selection.selectedSave) {
    audit.issues.push(buildIssue(
      'warn',
      'AUTOLOAD_TARGET_MISMATCH',
      `ServerAutoLoad targeted ${autoLoadState.targetSave}, but the panel audit selected ${selection.selectedSave}.`,
      'Restart the container after setting the intended save so ServerAutoLoad and the panel read the same source.'
    ));
  }

  const summary = summarizeAudit(audit);
  audit.status = summary.status;
  audit.label = summary.label;
  audit.action = summary.action;

  cachedAudit = audit;
  cachedAt = now;
  return audit;
}

module.exports = {
  buildSaveSlotAudit,
  parseEnvValue,
};
