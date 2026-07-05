function escapeHtml(value) {
  const div = document.createElement('div');
  div.textContent = value == null ? '' : String(value);
  return div.innerHTML;
}

function formatSize(bytes) {
  if (!bytes) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB'];
  let size = bytes;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toFixed(1)} ${units[index]}`;
}

function formatDate(value) {
  if (!value) return '--';
  return new Date(value).toLocaleString('zh-CN');
}

async function loadPublicMods() {
  const list = document.getElementById('publicModsList');
  const packStatus = document.getElementById('packStatus');
  const packFingerprint = document.getElementById('packFingerprint');
  const manifestMeta = document.getElementById('manifestMeta');
  const downloadPackBtn = document.getElementById('downloadPackBtn');

  try {
    const response = await fetch('/api/public/mods', { cache: 'no-store' });
    const data = await response.json();
    if (!response.ok) {
      throw new Error(data.cause || data.error || `HTTP ${response.status}`);
    }

    const modCount = data.total || 0;
    packStatus.textContent = modCount > 0
      ? `已整理 ${modCount} 个玩家需要安装的 Mod。建议优先下载整包。`
      : '当前没有需要玩家额外安装的 Mod。';
    const fingerprint = data.clientPack?.fingerprint || data.clientLock?.pack?.fingerprint || '';
    const lockFile = data.clientPack?.lockFile || data.clientLock?.pack?.lockFile || 'ylty-client-mod-lock.json';
    if (packFingerprint) {
      packFingerprint.textContent = fingerprint
        ? `整包指纹 ${fingerprint} · 锁定清单 ${lockFile}`
        : '';
    }
    manifestMeta.textContent = `生成时间：${formatDate(data.generatedAt)}${fingerprint ? ` · 整包指纹 ${fingerprint.slice(0, 12)}` : ''}`;
    if (downloadPackBtn) {
      downloadPackBtn.classList.toggle('is-disabled', modCount === 0);
      downloadPackBtn.setAttribute('aria-disabled', modCount === 0 ? 'true' : 'false');
      downloadPackBtn.href = modCount > 0 ? '/api/public/mods/client-pack' : '#';
    }

    if (!data.mods || data.mods.length === 0) {
      list.innerHTML = '<div class="empty-state">暂无需要下载的玩家 Mod。</div>';
      return;
    }

    list.innerHTML = data.mods.map(mod => `
      <article class="public-mod-item">
        <div class="public-mod-main">
          <div class="mod-name">${escapeHtml(mod.name || mod.folder)}</div>
          <div class="mod-meta">
            v${escapeHtml(mod.version || 'unknown')} · ${escapeHtml(mod.id || '')}
          </div>
          <div class="mod-meta">
            ${formatSize(mod.size)} · ${escapeHtml(String(mod.fileCount || 0))} 个文件 · 更新 ${formatDate(mod.updatedAt)}
          </div>
          <div class="checksum-line">SHA256 ${escapeHtml(mod.sha256 || '')}</div>
        </div>
        <div class="public-actions">
          <a class="btn btn-sm btn-primary" href="${escapeHtml(mod.downloadUrl)}">下载</a>
        </div>
      </article>
    `).join('');
  } catch (error) {
    packStatus.textContent = '读取 Mod 清单失败。';
    if (packFingerprint) {
      packFingerprint.textContent = '';
    }
    manifestMeta.textContent = '';
    list.innerHTML = `<div class="empty-state">读取失败：${escapeHtml(error.message)}</div>`;
  }
}

loadPublicMods();
