/**
 * Changelog API.
 * Reads project CHANGELOG.md through the manager container.
 */

const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { AppError, sendError } = require('../errors');

const MANAGER_TIMEOUT_MS = 5000;
const LOCAL_CHANGELOG_FILE = path.join(__dirname, '..', 'CHANGELOG.md');

function parseChangelogMarkdown(content) {
  const lines = String(content || '').replace(/\r\n/g, '\n').split('\n');
  const entries = [];
  let title = 'Changelog';
  let current = null;
  let currentSection = null;

  function pushEntry() {
    if (current) entries.push(current);
  }

  for (const line of lines) {
    const h1 = line.match(/^#\s+(.+)/);
    if (h1 && entries.length === 0 && !current) {
      title = h1[1].trim();
      continue;
    }

    const h2 = line.match(/^##\s+(.+)/);
    if (h2) {
      pushEntry();
      current = { title: h2[1].trim(), body: [], sections: [] };
      currentSection = null;
      continue;
    }

    if (!current) continue;

    const h3 = line.match(/^###\s+(.+)/);
    if (h3) {
      currentSection = { title: h3[1].trim(), items: [] };
      current.sections.push(currentSection);
      continue;
    }

    const bullet = line.match(/^\s*[-*]\s+(.+)/);
    if (bullet) {
      if (!currentSection) {
        currentSection = { title: '', items: [] };
        current.sections.push(currentSection);
      }
      currentSection.items.push(bullet[1].trim());
      continue;
    }

    const text = line.trim();
    if (text) current.body.push(text);
  }

  pushEntry();
  return { title, entries: entries.slice(0, 80) };
}

function readLocalChangelog() {
  if (!fs.existsSync(LOCAL_CHANGELOG_FILE)) {
    return null;
  }

  const content = fs.readFileSync(LOCAL_CHANGELOG_FILE, 'utf8');
  const stat = fs.statSync(LOCAL_CHANGELOG_FILE);
  const parsed = parseChangelogMarkdown(content);
  return {
    success: true,
    source: 'local',
    file: 'CHANGELOG.md',
    updatedAt: stat.mtime ? stat.mtime.toISOString() : '',
    ...parsed,
  };
}

function requestManagerChangelog() {
  const managerUrl = process.env.MANAGER_URL || '';
  if (!managerUrl) {
    return Promise.reject(new AppError('Manager service is not configured', {
      status: 503,
      code: 'MANAGER_NOT_CONFIGURED',
      cause: 'MANAGER_URL is empty, so the panel cannot read the project changelog from the manager container.',
      action: 'Recreate the stack with the latest docker-compose.yml so the stardew-manager service is available.',
    }));
  }

  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL('/changelog', managerUrl);
    } catch (error) {
      reject(new AppError('Invalid manager URL', {
        status: 500,
        code: 'INVALID_MANAGER_URL',
        cause: 'MANAGER_URL is not a valid URL.',
        action: 'Set MANAGER_URL to a valid internal manager URL.',
      }));
      return;
    }

    const client = parsed.protocol === 'https:' ? https : http;
    const request = client.request({
      protocol: parsed.protocol,
      hostname: parsed.hostname,
      port: parsed.port,
      path: parsed.pathname,
      method: 'GET',
      timeout: MANAGER_TIMEOUT_MS,
    }, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        body += chunk;
      });
      response.on('end', () => {
        let data = {};
        try {
          data = body ? JSON.parse(body) : {};
        } catch (error) {
          data = { error: body || `HTTP ${response.statusCode}` };
        }

        if (response.statusCode && response.statusCode >= 200 && response.statusCode < 300) {
          resolve({
            ...data,
            source: data.source || 'manager',
          });
          return;
        }

        reject(new AppError(data.message || data.error || 'Failed to read changelog', {
          status: response.statusCode || 500,
          code: 'CHANGELOG_MANAGER_FAILED',
          cause: 'The manager service could not read CHANGELOG.md from the project directory.',
          details: data.message || data.error || body,
          action: 'Check that CHANGELOG.md exists in the project root and that stardew-manager can read it.',
        }));
      });
    });

    request.on('timeout', () => {
      request.destroy(new Error('Manager request timed out'));
    });
    request.on('error', reject);
    request.end();
  });
}

async function getChangelog(req, res) {
  try {
    const data = await requestManagerChangelog();
    res.json(data);
  } catch (error) {
    const local = readLocalChangelog();
    if (local) {
      res.json({
        ...local,
        managerError: error.message,
      });
      return;
    }

    return sendError(res, req, error, {
      status: 503,
      code: 'CHANGELOG_UNAVAILABLE',
      message: 'Failed to read changelog',
      cause: 'The panel could not reach the manager service and no local changelog fallback exists.',
      details: error.message,
      action: 'Check the stardew-manager container and project CHANGELOG.md.',
    });
  }
}

module.exports = {
  getChangelog,
};
