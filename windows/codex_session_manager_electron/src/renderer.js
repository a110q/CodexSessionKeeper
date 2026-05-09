const state = {
  section: 'sessions',
  sessions: [],
  snapshots: [],
  currentState: {},
  selectedSessionId: null,
  selectedSnapshotId: null,
  checkedSessionIds: new Set(),
  checkedSnapshotIds: new Set(),
  checkedSnapshotSessionIds: new Set(),
  contextSessionId: null,
  conversationSessionId: null,
  snapshotSessions: [],
  selectedSnapshotSessionId: null,
  snapshotSessionSearch: '',
  snapshotFilter: 'all',
  snapshotSessionsLoading: false,
  settings: { autoRestoreOnLaunch: false },
  autoRestorePromptedSnapshotId: null
};

let sessionSearchTimer = null;

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => Array.from(document.querySelectorAll(selector));

const els = {
  sessionList: $('#sessionList'),
  snapshotList: $('#snapshotList'),
  sessionDetail: $('#sessionDetail'),
  snapshotDetail: $('#snapshotDetail'),
  sessionSearch: $('#sessionSearch'),
  showArchived: $('#showArchived'),
  checkVisibleSessionsBtn: $('#checkVisibleSessionsBtn'),
  clearCheckedSessionsBtn: $('#clearCheckedSessionsBtn'),
  deleteCheckedSessionsBtn: $('#deleteCheckedSessionsBtn'),
  sessionCount: $('#sessionCount'),
  snapshotCount: $('#snapshotCount'),
  snapshotName: $('#snapshotName'),
  snapshotFilter: $('#snapshotFilter'),
  checkAllSnapshotsBtn: $('#checkAllSnapshotsBtn'),
  clearCheckedSnapshotsBtn: $('#clearCheckedSnapshotsBtn'),
  deleteCheckedSnapshotsBtn: $('#deleteCheckedSnapshotsBtn'),
  autoRestoreSwitch: $('#autoRestoreSwitch'),
  openDirsMenu: $('#openDirsMenu'),
  contextMenu: $('#contextMenu'),
  toast: $('#toast'),
  modal: $('#conversationModal'),
  conversationTitle: $('#conversationTitle'),
  conversationMeta: $('#conversationMeta'),
  conversationBody: $('#conversationBody'),
  conversationOpenFile: $('#conversationOpenFile'),
  conversationRevealFile: $('#conversationRevealFile'),
  busyOverlay: $('#busyOverlay'),
  busyTitle: $('#busyTitle'),
  busyDetail: $('#busyDetail'),
  busyCancelBtn: $('#busyCancelBtn')
};

let activeBusyController = null;

function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function formatDate(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '-';
  return date.toLocaleString('zh-CN', { hour12: false });
}

function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (value < 1024) return `${value} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let size = value / 1024;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return `${size.toFixed(size >= 10 ? 1 : 2)} ${units[index]}`;
}

function showToast(message, isError = false) {
  els.toast.textContent = message;
  els.toast.style.background = isError ? 'rgba(194, 65, 45, 0.96)' : 'rgba(31, 122, 90, 0.96)';
  els.toast.classList.remove('hidden');
  const textLength = String(message || '').length;
  setTimeout(() => els.toast.classList.add('hidden'), textLength > 80 ? 9000 : 3600);
}

function showRestoreComplete(message) {
  const text = message || '恢复完成';
  alert(`${text}\n\n如果 Codex 客户端已经打开，请重启 Codex 后再查看恢复结果。`);
  showToast(text);
}

async function chooseRestoreProtectionMode(title, message, defaultMode = 'lightweight') {
  return window.codexManager.chooseRestoreProtectionMode({ title, message, defaultMode });
}

function busyDetailFor(message) {
  const text = String(message || '');
  if (text.includes('删除')) {
    return '正在创建轻量恢复点并清理 Codex 会话文件、索引和 SQLite 线程记录。会话文件多时会慢一些，请耐心等待，不是卡住。';
  }
  if (text.includes('恢复') || text.includes('找回')) {
    return '正在复制会话文件并合并 Codex 本地索引。大快照或归档会话较多时需要更久，请不要关闭应用。';
  }
  if (text.includes('快照')) {
    return '正在扫描 Codex 数据目录、复制必要文件并校验会话索引。数据目录较大时需要一些时间。';
  }
  if (text.includes('刷新')) {
    return '正在重新读取 Codex 会话列表和快照目录，文件较多时会稍慢。';
  }
  return '正在处理本地 Codex 数据。文件较多或磁盘较忙时会需要一些时间，请耐心等待。';
}

function showBusy(message, controller) {
  activeBusyController = controller;
  els.busyTitle.textContent = message || '正在处理...';
  els.busyDetail.textContent = busyDetailFor(message);
  els.busyCancelBtn.textContent = '取消';
  els.busyCancelBtn.disabled = false;
  els.busyOverlay.classList.remove('hidden');
}

function hideBusy() {
  els.busyOverlay.classList.add('hidden');
  activeBusyController = null;
}

async function withBusy(message, operation) {
  const controller = { cancelled: false };
  showBusy(message, controller);
  await new Promise((resolve) => requestAnimationFrame(resolve));
  try {
    const result = await operation();
    if (controller.cancelled) {
      return { cancelled: true };
    }
    return result;
  } finally {
    hideBusy();
  }
}

function busyWasCancelled(result) {
  return Boolean(result?.cancelled);
}

function cancelActiveBusyOperation() {
  if (!activeBusyController || activeBusyController.cancelled) return;
  activeBusyController.cancelled = true;
  els.busyCancelBtn.textContent = '正在取消...';
  els.busyCancelBtn.disabled = true;
  els.busyDetail.textContent = '已请求取消。Windows 版会等待当前文件步骤结束后停止后续刷新和提示，请稍等。';
}

function setSection(section) {
  state.section = section;
  $$('.section').forEach((item) => item.classList.toggle('active', item.id === `${section}Section`));
  $$('.segment, .nav-button').forEach((button) => {
    button.classList.toggle('active', button.dataset.section === section);
  });
}

function filteredSessions() {
  const query = els.sessionSearch.value.trim().toLowerCase();
  return state.sessions.filter((session) => {
    if (!els.showArchived.checked && session.archived) return false;
    if (!query) return true;
    return [
      session.id,
      session.title,
      session.cwd,
      session.provider,
      session.model,
      session.source,
      session.rolloutPath
    ].join(' ').toLowerCase().includes(query);
  });
}

function isManualSnapshot(snapshot) {
  if (snapshot.isManualSnapshot !== undefined) return Boolean(snapshot.isManualSnapshot);
  if (snapshot.kind) return snapshot.kind === 'manual';
  const id = String(snapshot.id || '');
  const reason = snapshot.reason || (id.length > 16 ? id.slice(16) : '');
  return reason === 'manual';
}

function filteredSnapshots() {
  if (state.snapshotFilter === 'manual') return state.snapshots.filter(isManualSnapshot);
  if (state.snapshotFilter === 'system') return state.snapshots.filter((snapshot) => !isManualSnapshot(snapshot));
  return state.snapshots;
}

function pruneCheckedItems() {
  const sessionIds = new Set(state.sessions.map((session) => session.id));
  state.checkedSessionIds = new Set([...state.checkedSessionIds].filter((id) => sessionIds.has(id)));
  const snapshotIds = new Set(state.snapshots.map((snapshot) => snapshot.id));
  state.checkedSnapshotIds = new Set([...state.checkedSnapshotIds].filter((id) => snapshotIds.has(id)));
  const snapshotSessionIds = new Set(state.snapshotSessions.map((session) => session.id));
  state.checkedSnapshotSessionIds = new Set([...state.checkedSnapshotSessionIds].filter((id) => snapshotSessionIds.has(id)));
}

function renderBatchControls() {
  const checkedSessionCount = state.checkedSessionIds.size;
  els.checkVisibleSessionsBtn.disabled = filteredSessions().length === 0;
  els.clearCheckedSessionsBtn.classList.toggle('hidden', checkedSessionCount === 0);
  els.deleteCheckedSessionsBtn.classList.toggle('hidden', checkedSessionCount === 0);
  els.deleteCheckedSessionsBtn.textContent = `删除选中 ${checkedSessionCount}`;

  const checkedSnapshotCount = state.checkedSnapshotIds.size;
  els.checkAllSnapshotsBtn.disabled = filteredSnapshots().length === 0;
  els.clearCheckedSnapshotsBtn.classList.toggle('hidden', checkedSnapshotCount === 0);
  els.deleteCheckedSnapshotsBtn.classList.toggle('hidden', checkedSnapshotCount === 0);
  els.deleteCheckedSnapshotsBtn.textContent = `删除选中 ${checkedSnapshotCount}`;
}

function renderStateCard() {
  $('#stateProvider').textContent = state.currentState.modelProvider || 'unknown';
  $('#stateModel').textContent = state.currentState.model || 'unknown';
  $('#stateAccount').textContent = state.currentState.accountFingerprint || 'none';
  $('#stateSessions').textContent = `${state.currentState.sessionCount || 0} active / ${state.currentState.archivedSessionCount || 0} archived`;
  els.autoRestoreSwitch.checked = Boolean(state.settings?.autoRestoreOnLaunch);
}

function renderSessions() {
  const sessions = filteredSessions();
  els.sessionCount.textContent = `${sessions.length} / ${state.sessions.length}`;

  if (sessions.length === 0) {
    els.sessionList.innerHTML = '<div class="detail-empty"><h3>没有匹配会话</h3><p>换个关键词，或清空搜索条件。</p></div>';
    renderSessionDetail(null);
    renderBatchControls();
    return;
  }

  if (!state.selectedSessionId || !sessions.some((session) => session.id === state.selectedSessionId)) {
    state.selectedSessionId = sessions[0].id;
  }

  els.sessionList.innerHTML = sessions.map((session) => `
    <article class="session-row ${session.id === state.selectedSessionId ? 'selected' : ''}" data-id="${escapeHtml(session.id)}">
      <button class="row-check ${state.checkedSessionIds.has(session.id) ? 'checked' : ''}" data-check-session="${escapeHtml(session.id)}">✓</button>
      <div class="row-content">
        <div class="row-title">
          ${escapeHtml(session.title || session.id)}
          ${session.archived ? '<span class="tag archive">归档</span>' : ''}
          ${session.existsOnDisk ? '' : '<span class="tag missing">缺文件</span>'}
        </div>
        <div class="row-meta">${escapeHtml(session.provider)} / ${escapeHtml(session.model)} · ${escapeHtml(session.source)}</div>
        <div class="row-time">${formatDate(session.updatedAt)}</div>
      </div>
    </article>
  `).join('');

  renderSessionDetail(state.sessions.find((session) => session.id === state.selectedSessionId));
  renderBatchControls();
}

function selectSession(sessionId) {
  state.selectedSessionId = sessionId;
  document.querySelectorAll('.session-row').forEach((row) => {
    row.classList.toggle('selected', row.dataset.id === sessionId);
  });
  renderSessionDetail(state.sessions.find((session) => session.id === state.selectedSessionId));
}

function selectedSnapshot() {
  return state.snapshots.find((snapshot) => snapshot.id === state.selectedSnapshotId);
}

function selectedSnapshotSession() {
  return state.snapshotSessions.find((session) => session.id === state.selectedSnapshotSessionId);
}

function filteredSnapshotSessions() {
  const query = state.snapshotSessionSearch.trim().toLowerCase();
  if (!query) return state.snapshotSessions;
  return state.snapshotSessions.filter((session) => [
    session.id,
    session.title,
    session.cwd,
    session.provider,
    session.model,
    session.source,
    session.rolloutPath
  ].join(' ').toLowerCase().includes(query));
}

function selectFirstVisibleSnapshotSessionIfNeeded() {
  const sessions = filteredSnapshotSessions();
  if (state.selectedSnapshotSessionId && sessions.some((session) => session.id === state.selectedSnapshotSessionId)) return;
  state.selectedSnapshotSessionId = sessions[0]?.id || null;
}

function selectSnapshotSession(sessionId) {
  state.selectedSnapshotSessionId = sessionId;
  document.querySelectorAll('.snapshot-session-row').forEach((row) => {
    row.classList.toggle('selected', row.dataset.id === sessionId);
  });
  const selected = selectedSnapshotSession();
  const selectedLabel = $('#snapshotSelectedSession');
  if (selectedLabel) selectedLabel.textContent = selected ? `已选：${selected.title || selected.id}` : '先从上面选择一个会话。';
  const restoreButton = $('#restoreSnapshotSessionBtn');
  if (restoreButton) restoreButton.disabled = !selected || !selected.existsOnDisk;
  const batchButton = $('#restoreCheckedSnapshotSessionsBtn');
  if (batchButton) batchButton.disabled = checkedRestorableSnapshotSessions().length === 0;
}

function toggleCheckedSnapshotSession(sessionId) {
  if (state.checkedSnapshotSessionIds.has(sessionId)) {
    state.checkedSnapshotSessionIds.delete(sessionId);
    if (state.selectedSnapshotSessionId === sessionId) {
      state.selectedSnapshotSessionId = checkedRestorableSnapshotSessions()[0]?.id || filteredSnapshotSessions()[0]?.id || null;
    }
  } else {
    state.checkedSnapshotSessionIds.add(sessionId);
    state.selectedSnapshotSessionId = sessionId;
  }
}

function checkedRestorableSnapshotSessions() {
  return state.snapshotSessions.filter((session) => state.checkedSnapshotSessionIds.has(session.id) && session.existsOnDisk);
}

function scheduleRenderSessions() {
  if (sessionSearchTimer) clearTimeout(sessionSearchTimer);
  sessionSearchTimer = setTimeout(() => {
    sessionSearchTimer = null;
    renderSessions();
  }, 220);
}

function renderSessionDetail(session) {
  if (!session) {
    els.sessionDetail.className = 'detail-empty';
    els.sessionDetail.innerHTML = '<div class="empty-icon">⌁</div><h3>没有选中会话</h3><p>从左侧选择一个会话，或调整搜索条件。</p>';
    return;
  }

  els.sessionDetail.className = '';
  els.sessionDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div>
          <h2 class="detail-title">${escapeHtml(session.title || session.id)}</h2>
          <p class="mono">${escapeHtml(session.id)}</p>
        </div>
        <span class="count-pill">${formatBytes(session.sizeBytes)}</span>
      </div>
    </div>

    <div class="detail-card">
      <div class="action-row">
        <button class="primary-button" data-detail-action="view">查看对话记录</button>
        <button class="ghost-button" data-detail-action="open">打开会话文件</button>
        <button class="ghost-button" data-detail-action="reveal">在文件夹中显示</button>
      </div>
      <p class="row-meta" style="margin-top: 10px;">常用操作放在这里：先打开文件或定位文件，再决定是否清理。</p>
    </div>

    <div class="metric-grid detail-card">
      <div class="metric"><span>模型供应商</span><strong>${escapeHtml(session.provider)}</strong></div>
      <div class="metric"><span>模型</span><strong>${escapeHtml(session.model)}</strong></div>
      <div class="metric"><span>来源</span><strong>${escapeHtml(session.source)}</strong></div>
      <div class="metric"><span>文件状态</span><strong>${session.existsOnDisk ? '存在' : '缺失'}</strong></div>
    </div>

    <div class="detail-card">
      <h3 style="margin-bottom: 12px;">位置和时间</h3>
      <div class="info-lines">
        <div class="info-line"><span>创建时间</span><strong>${formatDate(session.createdAt)}</strong></div>
        <div class="info-line"><span>更新时间</span><strong>${formatDate(session.updatedAt)}</strong></div>
        <div class="info-line"><span>工作目录</span><strong class="mono">${escapeHtml(session.cwd || '-')}</strong></div>
        <div class="info-line"><span>会话文件</span><strong class="mono">${escapeHtml(session.rolloutPath || '-')}</strong></div>
      </div>
    </div>

    <div class="detail-card danger-zone">
      <div class="detail-title-row">
        <div>
          <h3>删除会话</h3>
          <p class="row-meta">会先创建轻量恢复点，只保存将被删除的会话，然后清理会话文件、索引和线程记录。</p>
        </div>
        <button class="danger-button" data-detail-action="delete">删除会话</button>
      </div>
    </div>
  `;
}

function renderSnapshots() {
  const snapshots = filteredSnapshots();
  els.snapshotCount.textContent = `${snapshots.length} / ${state.snapshots.length}`;
  if (snapshots.length === 0) {
    els.snapshotList.innerHTML = '<div class="detail-empty"><h3>没有匹配快照</h3><p>切换筛选条件，或创建一个手动快照。</p></div>';
    renderSnapshotDetail(null);
    renderBatchControls();
    return;
  }

  if (!state.selectedSnapshotId || !snapshots.some((snapshot) => snapshot.id === state.selectedSnapshotId)) {
    state.selectedSnapshotId = snapshots[0].id;
  }

  els.snapshotList.innerHTML = snapshots.map((snapshot) => `
    <article class="snapshot-row ${snapshot.id === state.selectedSnapshotId ? 'selected' : ''}" data-id="${escapeHtml(snapshot.id)}">
      <button class="row-check ${state.checkedSnapshotIds.has(snapshot.id) ? 'checked' : ''}" data-check-snapshot="${escapeHtml(snapshot.id)}">✓</button>
      <div class="row-content">
        <div class="row-title">${escapeHtml(snapshot.name || snapshot.id)} <span class="tag ${isManualSnapshot(snapshot) ? 'manual' : 'archive'}">${escapeHtml(snapshot.kindLabel || (isManualSnapshot(snapshot) ? '手动' : '系统自动'))}</span></div>
        <div class="row-meta">${escapeHtml(snapshot.modelProvider || 'unknown')} / ${escapeHtml(snapshot.model || 'unknown')}</div>
        <div class="row-time">${formatDate(snapshot.createdAt)}</div>
      </div>
    </article>
  `).join('');

  renderSnapshotDetail(state.snapshots.find((snapshot) => snapshot.id === state.selectedSnapshotId));
  renderBatchControls();
}

function renderSnapshotDetail(snapshot) {
  if (!snapshot) {
    els.snapshotDetail.className = 'detail-empty';
    els.snapshotDetail.innerHTML = '<div class="empty-icon">▧</div><h3>没有选中快照</h3><p>先创建一个快照，或从左侧选择已有快照。</p>';
    return;
  }

  const snapshotSessions = filteredSnapshotSessions();
  const selected = selectedSnapshotSession();
  const checkedRestorable = checkedRestorableSnapshotSessions();
  const sessionListHtml = state.snapshotSessionsLoading
    ? '<div class="snapshot-session-empty">正在读取快照内会话...</div>'
    : state.snapshotSessions.length === 0
      ? '<div class="snapshot-session-empty">这个快照里没有可读取的会话文件或索引。</div>'
      : snapshotSessions.length === 0
        ? '<div class="snapshot-session-empty">没有匹配会话，换个关键词试试。</div>'
        : snapshotSessions.map((session) => `
            <article class="snapshot-session-row ${session.id === state.selectedSnapshotSessionId ? 'selected' : ''}" data-id="${escapeHtml(session.id)}">
              <button class="row-check ${state.checkedSnapshotSessionIds.has(session.id) ? 'checked' : ''}" data-check-snapshot-session="${escapeHtml(session.id)}" ${session.existsOnDisk ? '' : 'disabled'}>✓</button>
              <div class="select-dot">${session.id === state.selectedSnapshotSessionId ? '✓' : ''}</div>
              <div class="snapshot-session-main">
                <div class="snapshot-session-title">${escapeHtml(session.title || session.id)}</div>
                <div class="row-meta">${escapeHtml(session.provider)} / ${escapeHtml(session.model)} · ${formatDate(session.updatedAt)}</div>
              </div>
              ${session.existsOnDisk ? '' : '<span class="tag missing">缺文件</span>'}
            </article>
          `).join('');

  els.snapshotDetail.className = '';
  els.snapshotDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div>
          <h2 class="detail-title">${escapeHtml(snapshot.name || snapshot.id)}</h2>
          <p class="row-meta"><span class="tag ${isManualSnapshot(snapshot) ? 'manual' : 'archive'}">${escapeHtml(snapshot.kindLabel || (isManualSnapshot(snapshot) ? '手动' : '系统自动'))}</span> ${formatDate(snapshot.createdAt)}</p>
        </div>
        <span class="count-pill">${formatBytes(snapshot.sizeBytes)}</span>
      </div>
    </div>

    <div class="primary-action-card">
      <div class="action-row wrap">
        <button class="primary-button" data-snapshot-action="restoreConversations">只恢复对话</button>
        <button class="ghost-button" data-snapshot-action="openSnapshot">打开快照目录</button>
      </div>
      <p>推荐操作：只恢复对话会保留当前账号、登录态和模型供应商配置。</p>
    </div>

    <div class="metric-grid detail-card">
      <div class="metric"><span>类型</span><strong>${escapeHtml(snapshot.kindLabel || (isManualSnapshot(snapshot) ? '手动' : '系统自动'))}</strong></div>
      <div class="metric"><span>模型供应商</span><strong>${escapeHtml(snapshot.modelProvider || 'unknown')}</strong></div>
      <div class="metric"><span>模型</span><strong>${escapeHtml(snapshot.model || 'unknown')}</strong></div>
      <div class="metric"><span>账号指纹</span><strong>${escapeHtml(snapshot.accountFingerprint || 'none')}</strong></div>
      <div class="metric"><span>会话</span><strong>${snapshot.sessionCount || 0} / ${snapshot.archivedSessionCount || 0}</strong></div>
    </div>
    <div class="detail-card">
      <h3 style="margin-bottom: 12px;">包含内容</h3>
      <div class="info-lines">
        ${(snapshot.includedPaths || []).map((item) => `<div class="info-line"><span>path</span><strong class="mono">${escapeHtml(item)}</strong></div>`).join('')}
      </div>
    </div>

    <div class="detail-card">
      <div class="section-card-title">
        <div>
          <h3>单个会话恢复</h3>
          <p>只恢复选中这一条会话，不覆盖当前账号、登录态和模型供应商配置。</p>
        </div>
        <span class="count-pill small">${snapshotSessions.length}</span>
      </div>
      <div class="snapshot-session-tools">
        <input id="snapshotSessionSearch" class="search-input" placeholder="搜索快照内会话" value="${escapeHtml(state.snapshotSessionSearch)}" />
        <button class="ghost-button" data-snapshot-action="clearSnapshotSessionSearch">清空</button>
        <button class="ghost-button" data-snapshot-action="checkAllSnapshotSessions">全选可恢复</button>
        <button class="ghost-button" data-snapshot-action="clearCheckedSnapshotSessions">清空选择</button>
        <button class="primary-button" id="restoreCheckedSnapshotSessionsBtn" data-snapshot-action="restoreCheckedSnapshotSessions" ${checkedRestorable.length ? '' : 'disabled'}>批量恢复选中 ${checkedRestorable.length}</button>
        <button class="ghost-button" data-snapshot-action="restoreConversations">恢复本快照全部对话</button>
      </div>
      <div class="snapshot-session-list">${sessionListHtml}</div>
      <div class="snapshot-session-footer">
        <span id="snapshotSelectedSession">${checkedRestorable.length ? `已勾选：${checkedRestorable.length} 个可恢复会话` : (selected ? `已选：${escapeHtml(selected.title || selected.id)}` : '先从上面选择一个会话。')}</span>
        <button id="restoreSnapshotSessionBtn" class="primary-button" data-snapshot-action="${checkedRestorable.length ? 'restoreCheckedSnapshotSessions' : 'restoreSnapshotSession'}" ${checkedRestorable.length || (selected && selected.existsOnDisk) ? '' : 'disabled'}>${checkedRestorable.length ? '恢复勾选会话' : '恢复高亮会话'}</button>
      </div>
    </div>

    <div class="detail-card warning-card">
      <div class="detail-title-row">
        <div>
          <h3>高级恢复</h3>
          <p class="row-meta">完整恢复会把账号、登录态和 config.toml 一起回滚到快照状态。只有明确需要回滚配置时再用。</p>
        </div>
        <button class="ghost-button" data-snapshot-action="restoreFull">完整恢复</button>
      </div>
    </div>

    <div class="detail-card danger-zone">
      <div class="detail-title-row">
        <div>
          <h3>删除快照</h3>
          <p class="row-meta">删除后无法从这个快照恢复。不会影响当前 Codex 会话。</p>
        </div>
        <button class="danger-button" data-snapshot-action="deleteSnapshot">删除快照</button>
      </div>
    </div>
  `;
}

function renderAll() {
  renderStateCard();
  renderSessions();
  renderSnapshots();
}

async function loadSelectedSnapshotSessions() {
  const snapshot = selectedSnapshot();
  if (!snapshot) {
    state.snapshotSessions = [];
    state.selectedSnapshotSessionId = null;
    state.checkedSnapshotSessionIds.clear();
    state.snapshotSessionsLoading = false;
    renderSnapshotDetail(null);
    return;
  }

  const snapshotId = snapshot.id;
  state.snapshotSessions = [];
  state.selectedSnapshotSessionId = null;
  state.checkedSnapshotSessionIds.clear();
  state.snapshotSessionsLoading = true;
  renderSnapshotDetail(snapshot);
  try {
    const sessions = await window.codexManager.loadSnapshotSessions(snapshotId);
    if (state.selectedSnapshotId !== snapshotId) return;
    state.snapshotSessions = sessions || [];
    state.snapshotSessionsLoading = false;
    selectFirstVisibleSnapshotSessionIfNeeded();
    renderSnapshotDetail(selectedSnapshot());
  } catch (error) {
    if (state.selectedSnapshotId !== snapshotId) return;
    state.snapshotSessions = [];
    state.selectedSnapshotSessionId = null;
    state.checkedSnapshotSessionIds.clear();
    state.snapshotSessionsLoading = false;
    renderSnapshotDetail(selectedSnapshot());
    showToast(error.message || String(error), true);
  }
}

async function maybeRunLaunchAutoRestore(suggestion) {
  if (!suggestion || state.autoRestorePromptedSnapshotId === suggestion.snapshotId) return;
  state.autoRestorePromptedSnapshotId = suggestion.snapshotId;
  const ok = confirm(
    `发现可找回的 Codex 会话，是否恢复？\n\n当前检测到 ${suggestion.currentCount} 个会话，快照“${suggestion.snapshotName}”中有 ${suggestion.snapshotCount} 个会话。\n\n继续后只会合并恢复对话，不会覆盖当前 auth.json、config.toml、账号登录态或模型供应商配置。`
  );
  if (!ok) return;
  const result = await withBusy('正在自动找回会话...', () => window.codexManager.restoreSnapshotConversations(suggestion.snapshotId));
  if (busyWasCancelled(result)) return;
  showRestoreComplete(result.message || '已自动找回会话');
  await refresh({ skipAutoRestore: true });
  setSection('sessions');
}

async function refresh(options = {}) {
  try {
    showToast('正在刷新...');
    const data = await window.codexManager.loadState();
    state.sessions = data.sessions || [];
    state.snapshots = data.snapshots || [];
    state.currentState = data.currentState || {};
    state.settings = data.settings || state.settings;
    pruneCheckedItems();
    renderAll();
    await loadSelectedSnapshotSessions();
    showToast(`已刷新：${state.sessions.length} 个会话，${state.snapshots.length} 个快照`);
    if (options.forceAutoRestore || !options.skipAutoRestore) await maybeRunLaunchAutoRestore(data.autoRestoreSuggestion);
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

function selectedSession() {
  return state.sessions.find((session) => session.id === state.selectedSessionId);
}

async function selectSnapshot(snapshotId) {
  state.selectedSnapshotId = snapshotId;
  state.snapshotSessionSearch = '';
  state.snapshotSessions = [];
  state.selectedSnapshotSessionId = null;
  state.checkedSnapshotSessionIds.clear();
  renderSnapshots();
  await loadSelectedSnapshotSessions();
}

function contextSession() {
  return state.sessions.find((session) => session.id === state.contextSessionId) || selectedSession();
}

function hideContextMenu() {
  els.contextMenu.classList.add('hidden');
}

function hideOpenDirsMenu() {
  els.openDirsMenu.classList.add('hidden');
}

function showContextMenu(event, sessionId) {
  event.preventDefault();
  state.contextSessionId = sessionId;
  const margin = 12;
  els.contextMenu.style.left = `${event.clientX}px`;
  els.contextMenu.style.top = `${event.clientY}px`;
  els.contextMenu.classList.remove('hidden');
  const rect = els.contextMenu.getBoundingClientRect();
  const left = Math.max(margin, Math.min(event.clientX, window.innerWidth - rect.width - margin));
  const top = Math.max(margin, Math.min(event.clientY, window.innerHeight - rect.height - margin));
  els.contextMenu.style.left = `${left}px`;
  els.contextMenu.style.top = `${top}px`;
}

async function openConversation(session) {
  if (!session) return;
  state.conversationSessionId = session.id;
  els.modal.classList.remove('hidden');
  els.conversationTitle.textContent = session.title || session.id;
  els.conversationMeta.textContent = '正在加载对话记录...';
  els.conversationBody.innerHTML = '<div class="detail-empty"><h3>正在读取并解析会话记录</h3><p>大文件会在后台处理，窗口不会卡死。</p></div>';

  try {
    const messages = await window.codexManager.loadConversation(session.id);
    els.conversationMeta.textContent = `${messages.length} 条消息 · ${formatDate(session.updatedAt)}`;
    if (!messages.length) {
      els.conversationBody.innerHTML = '<div class="detail-empty"><h3>没有解析到对话内容</h3><p>这个会话文件存在，但没有找到用户或助手消息。</p></div>';
      return;
    }
    els.conversationBody.innerHTML = messages.map((message) => {
      const roleClass = message.role === '用户' ? 'role-user' : 'role-assistant';
      const text = String(message.text || '');
      const clipped = text.length > 16000;
      const visible = clipped ? `${text.slice(0, 16000)}\n\n... 内容较长，已截断展示。可打开原始文件查看完整内容。` : text;
      return `
        <div class="message-row">
          <div>
            <span class="role-badge ${roleClass}">${escapeHtml(message.role || '记录')}</span>
            ${message.phase ? `<div class="row-meta" style="margin-top: 6px;">${escapeHtml(message.phase)}</div>` : ''}
          </div>
          <div class="message-card">
            <div class="message-time">${formatDate(message.timestamp)}</div>
            ${escapeHtml(visible)}
          </div>
        </div>
      `;
    }).join('');
  } catch (error) {
    els.conversationMeta.textContent = '打开失败';
    els.conversationBody.innerHTML = `<div class="detail-empty"><h3>打开失败</h3><p>${escapeHtml(error.message || String(error))}</p></div>`;
  }
}

async function runSessionAction(action, session) {
  if (!session) return;
  try {
    if (action === 'view') await openConversation(session);
    if (action === 'open') await window.codexManager.openPath(session.rolloutPath);
    if (action === 'reveal') await window.codexManager.revealPath(session.rolloutPath);
    if (action === 'restore') {
      const protectionMode = await chooseRestoreProtectionMode(
        '从最近快照恢复这个会话？',
        `将恢复会话：\n${session.title || session.id}\n\n只恢复这一条会话的文件、历史索引和线程记录，不会覆盖当前账号、登录态和模型供应商配置。`,
        'lightweight'
      );
      if (!protectionMode) return;
      const result = await withBusy('正在恢复单个会话...', () => window.codexManager.restoreSession(session.id, protectionMode));
      if (busyWasCancelled(result)) return;
      showRestoreComplete(result.message || '恢复完成');
      await refresh();
      state.selectedSessionId = session.id;
      renderSessions();
    }
    if (action === 'delete') {
      if (!confirm(`删除这个 Codex 会话？\n\n${session.title}\n\n删除前会自动创建轻量恢复点，只保存将被删除的会话。`)) return;
      const result = await withBusy('正在删除会话...', () => window.codexManager.deleteSession(session.id));
      if (busyWasCancelled(result)) return;
      showToast(result.message || '删除完成');
      await refresh();
    }
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function deleteCheckedSessions() {
  const sessions = state.sessions.filter((session) => state.checkedSessionIds.has(session.id));
  if (!sessions.length) return;
  const preview = sessions.slice(0, 6).map((session) => session.title || session.id).join('\n');
  const suffix = sessions.length > 6 ? `\n等 ${sessions.length} 个会话` : '';
  if (!confirm(`批量删除 Codex 会话？\n\n将删除 ${sessions.length} 个会话，并清理会话文件、索引和线程记录。删除前会自动创建轻量恢复点，只保存将被删除的会话。\n\n${preview}${suffix}`)) return;
  try {
    const result = await withBusy('正在批量删除会话...', () => window.codexManager.deleteSessions(sessions.map((session) => session.id)));
    if (busyWasCancelled(result)) return;
    state.checkedSessionIds.clear();
    showToast(result.message || '批量删除完成');
    await refresh({ skipAutoRestore: true });
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function runSnapshotAction(action) {
  const snapshot = selectedSnapshot();
  if (!snapshot) return;
  try {
    if (action === 'openSnapshot') {
      await window.codexManager.openSnapshot(snapshot.id);
      return;
    }
    if (action === 'clearSnapshotSessionSearch') {
      state.snapshotSessionSearch = '';
      selectFirstVisibleSnapshotSessionIfNeeded();
      renderSnapshotDetail(snapshot);
      return;
    }
    if (action === 'checkAllSnapshotSessions') {
      filteredSnapshotSessions().filter((session) => session.existsOnDisk).forEach((session) => state.checkedSnapshotSessionIds.add(session.id));
      renderSnapshotDetail(snapshot);
      return;
    }
    if (action === 'clearCheckedSnapshotSessions') {
      state.checkedSnapshotSessionIds.clear();
      renderSnapshotDetail(snapshot);
      return;
    }
    if (action === 'restoreConversations') {
      const protectionMode = await chooseRestoreProtectionMode(
        '只恢复 Codex 对话？',
        `快照：${snapshot.name}\n\n当前账号、登录态和模型供应商配置会保留。建议先退出 Codex 再恢复。`,
        'lightweight'
      );
      if (!protectionMode) return;
      const result = await withBusy('正在恢复对话...', () => window.codexManager.restoreSnapshotConversations(snapshot.id, protectionMode));
      if (busyWasCancelled(result)) return;
      showRestoreComplete(result.message || '恢复完成');
      await refresh({ skipAutoRestore: true });
      return;
    }
    if (action === 'restoreFull') {
      const protectionMode = await chooseRestoreProtectionMode(
        '完整恢复 Codex 快照？',
        `快照：${snapshot.name}\n\n这会回滚 auth.json、config.toml、账号登录态和模型供应商配置。建议先退出 Codex 再恢复。`,
        'full'
      );
      if (!protectionMode) return;
      const result = await withBusy('正在完整恢复快照...', () => window.codexManager.restoreSnapshotFull(snapshot.id, protectionMode));
      if (busyWasCancelled(result)) return;
      showRestoreComplete(result.message || '完整恢复完成');
      await refresh({ skipAutoRestore: true });
      return;
    }
    if (action === 'restoreSnapshotSession') {
      const session = selectedSnapshotSession();
      if (!session) return;
      if (!session.existsOnDisk) {
        showToast('这个快照只有会话索引，没有真实会话文件，无法恢复到 Codex 客户端。', true);
        return;
      }
      const protectionMode = await chooseRestoreProtectionMode(
        '只恢复这个会话？',
        `将从快照 “${snapshot.name}” 恢复以下会话：\n${session.title || session.id}\n\n只会恢复这一条会话的文件、历史索引和线程记录，不会覆盖当前账号、登录态和模型供应商配置。`,
        'lightweight'
      );
      if (!protectionMode) return;
      const result = await withBusy('正在恢复单个会话...', () => window.codexManager.restoreSnapshotSession(snapshot.id, session.id, protectionMode));
      if (busyWasCancelled(result)) return;
      showRestoreComplete(result.message || '单个会话已恢复');
      await refresh({ skipAutoRestore: true });
      state.selectedSessionId = session.id;
      renderSessions();
      return;
    }
    if (action === 'restoreCheckedSnapshotSessions') {
      const sessions = checkedRestorableSnapshotSessions();
      if (!sessions.length) return;
      const preview = sessions.slice(0, 8).map((session) => session.title || session.id).join('\n');
      const suffix = sessions.length > 8 ? `\n等 ${sessions.length} 个会话` : '';
      const protectionMode = await chooseRestoreProtectionMode(
        '批量恢复选中会话？',
        `快照：${snapshot.name}\n\n将恢复 ${sessions.length} 个会话，不覆盖当前账号、登录态和模型供应商配置。\n\n${preview}${suffix}`,
        'lightweight'
      );
      if (!protectionMode) return;
      const result = await withBusy('正在批量恢复会话...', () => window.codexManager.restoreSnapshotSessions(snapshot.id, sessions.map((session) => session.id), protectionMode));
      if (busyWasCancelled(result)) return;
      showRestoreComplete(result.message || '批量恢复完成');
      state.checkedSnapshotSessionIds.clear();
      await refresh({ skipAutoRestore: true });
      setSection('sessions');
      return;
    }
    if (action === 'deleteSnapshot') {
      if (!confirm(`删除这个快照？\n\n${snapshot.name}\n\n删除后无法从这个快照恢复，不会影响当前 Codex 会话。`)) return;
      const result = await withBusy('正在删除快照...', () => window.codexManager.deleteSnapshot(snapshot.id));
      if (busyWasCancelled(result)) return;
      showToast(result.message || '快照已删除');
      state.selectedSnapshotId = null;
      state.snapshotSessions = [];
      state.selectedSnapshotSessionId = null;
      await refresh({ skipAutoRestore: true });
    }
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function deleteCheckedSnapshots() {
  const snapshots = state.snapshots.filter((snapshot) => state.checkedSnapshotIds.has(snapshot.id));
  if (!snapshots.length) return;
  const preview = snapshots.slice(0, 6).map((snapshot) => snapshot.name || snapshot.id).join('\n');
  const suffix = snapshots.length > 6 ? `\n等 ${snapshots.length} 个快照` : '';
  if (!confirm(`批量删除快照？\n\n将删除 ${snapshots.length} 个快照，该操作不可撤销。不会影响当前 Codex 会话。\n\n${preview}${suffix}`)) return;
  try {
    const result = await withBusy('正在批量删除快照...', () => window.codexManager.deleteSnapshots(snapshots.map((snapshot) => snapshot.id)));
    if (busyWasCancelled(result)) return;
    state.checkedSnapshotIds.clear();
    state.selectedSnapshotId = null;
    showToast(result.message || '批量删除完成');
    await refresh({ skipAutoRestore: true });
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

document.addEventListener('click', async (event) => {
  hideContextMenu();
  if (!event.target.closest('.open-dir-wrap')) hideOpenDirsMenu();
  const sectionButton = event.target.closest('[data-section]');
  if (sectionButton) setSection(sectionButton.dataset.section);

  const sessionCheck = event.target.closest('[data-check-session]');
  if (sessionCheck) {
    const id = sessionCheck.dataset.checkSession;
    if (state.checkedSessionIds.has(id)) state.checkedSessionIds.delete(id);
    else state.checkedSessionIds.add(id);
    renderSessions();
    return;
  }

  const snapshotCheck = event.target.closest('[data-check-snapshot]');
  if (snapshotCheck) {
    const id = snapshotCheck.dataset.checkSnapshot;
    if (state.checkedSnapshotIds.has(id)) state.checkedSnapshotIds.delete(id);
    else state.checkedSnapshotIds.add(id);
    renderSnapshots();
    return;
  }

  const snapshotSessionCheck = event.target.closest('[data-check-snapshot-session]');
  if (snapshotSessionCheck) {
    const id = snapshotSessionCheck.dataset.checkSnapshotSession;
    toggleCheckedSnapshotSession(id);
    renderSnapshotDetail(selectedSnapshot());
    return;
  }

  const sessionRow = event.target.closest('.session-row');
  if (sessionRow) {
    selectSession(sessionRow.dataset.id);
  }

  const snapshotRow = event.target.closest('.snapshot-row');
  if (snapshotRow) {
    await selectSnapshot(snapshotRow.dataset.id);
  }

  const snapshotSessionRow = event.target.closest('.snapshot-session-row');
  if (snapshotSessionRow) {
    selectSnapshotSession(snapshotSessionRow.dataset.id);
  }

  const detailAction = event.target.closest('[data-detail-action]');
  if (detailAction) {
    runSessionAction(detailAction.dataset.detailAction, selectedSession());
  }

  const snapshotAction = event.target.closest('[data-snapshot-action]');
  if (snapshotAction) {
    runSnapshotAction(snapshotAction.dataset.snapshotAction);
  }
});

els.sessionList.addEventListener('dblclick', (event) => {
  const row = event.target.closest('.session-row');
  if (!row) return;
  const session = state.sessions.find((item) => item.id === row.dataset.id);
  openConversation(session);
});

els.sessionList.addEventListener('contextmenu', (event) => {
  const row = event.target.closest('.session-row');
  if (!row) return;
  selectSession(row.dataset.id);
  showContextMenu(event, row.dataset.id);
});

els.snapshotDetail.addEventListener('input', (event) => {
  if (event.target.id !== 'snapshotSessionSearch') return;
  state.snapshotSessionSearch = event.target.value;
  selectFirstVisibleSnapshotSessionIfNeeded();
  renderSnapshotDetail(selectedSnapshot());
  const input = $('#snapshotSessionSearch');
  if (input) {
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
  }
});

els.snapshotDetail.addEventListener('dblclick', (event) => {
  const row = event.target.closest('.snapshot-session-row');
  if (!row) return;
  selectSnapshotSession(row.dataset.id);
  runSnapshotAction('restoreSnapshotSession');
});

els.snapshotDetail.addEventListener('contextmenu', (event) => {
  const row = event.target.closest('.snapshot-session-row');
  if (!row) return;
  event.preventDefault();
  selectSnapshotSession(row.dataset.id);
  runSnapshotAction('restoreSnapshotSession');
});

els.contextMenu.addEventListener('click', (event) => {
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const session = contextSession();
  hideContextMenu();
  runSessionAction(button.dataset.action, session);
});

$('#refreshBtn').addEventListener('click', refresh);
$('#openDirsBtn').addEventListener('click', (event) => {
  event.stopPropagation();
  els.openDirsMenu.classList.toggle('hidden');
});
els.openDirsMenu.addEventListener('click', async (event) => {
  const button = event.target.closest('[data-dir-action]');
  if (!button) return;
  event.stopPropagation();
  hideOpenDirsMenu();
  if (button.dataset.dirAction === 'codex') await window.codexManager.openCodexRoot();
  if (button.dataset.dirAction === 'vault') await window.codexManager.openVaultRoot();
});
els.autoRestoreSwitch.addEventListener('change', async () => {
  try {
    const enabled = els.autoRestoreSwitch.checked;
    const result = await window.codexManager.setAutoRestore(els.autoRestoreSwitch.checked);
    state.settings = result.settings || { autoRestoreOnLaunch: enabled };
    renderStateCard();
    showToast(enabled ? '已开启打开时自动找回' : '已关闭打开时自动找回');
    if (enabled) {
      await refresh({ forceAutoRestore: true });
    }
  } catch (error) {
    els.autoRestoreSwitch.checked = Boolean(state.settings?.autoRestoreOnLaunch);
    showToast(error.message || String(error), true);
  }
});
els.sessionSearch.addEventListener('input', scheduleRenderSessions);
els.showArchived.addEventListener('change', renderSessions);
els.snapshotFilter.addEventListener('change', async () => {
  state.snapshotFilter = els.snapshotFilter.value;
  state.selectedSnapshotId = null;
  state.snapshotSessions = [];
  state.selectedSnapshotSessionId = null;
  state.checkedSnapshotSessionIds.clear();
  renderSnapshots();
  await loadSelectedSnapshotSessions();
});
els.checkVisibleSessionsBtn.addEventListener('click', () => {
  filteredSessions().forEach((session) => state.checkedSessionIds.add(session.id));
  renderSessions();
});
els.clearCheckedSessionsBtn.addEventListener('click', () => {
  state.checkedSessionIds.clear();
  renderSessions();
});
els.deleteCheckedSessionsBtn.addEventListener('click', deleteCheckedSessions);
els.busyCancelBtn.addEventListener('click', cancelActiveBusyOperation);
$('#createSnapshotBtn').addEventListener('click', async () => {
  try {
    const result = await withBusy('正在创建快照...', () => window.codexManager.createSnapshot(els.snapshotName.value.trim()));
    if (busyWasCancelled(result)) return;
    els.snapshotName.value = '';
    showToast(result.message || '快照已创建');
    await refresh();
    setSection('snapshots');
  } catch (error) {
    showToast(error.message || String(error), true);
  }
});
els.checkAllSnapshotsBtn.addEventListener('click', () => {
  filteredSnapshots().forEach((snapshot) => state.checkedSnapshotIds.add(snapshot.id));
  renderSnapshots();
});
els.clearCheckedSnapshotsBtn.addEventListener('click', () => {
  state.checkedSnapshotIds.clear();
  renderSnapshots();
});
els.deleteCheckedSnapshotsBtn.addEventListener('click', deleteCheckedSnapshots);
$('#closeConversation').addEventListener('click', () => els.modal.classList.add('hidden'));
els.modal.addEventListener('click', (event) => {
  if (event.target === els.modal) els.modal.classList.add('hidden');
});
els.conversationOpenFile.addEventListener('click', async () => {
  const session = state.sessions.find((item) => item.id === state.conversationSessionId);
  if (session) await window.codexManager.openPath(session.rolloutPath);
});
els.conversationRevealFile.addEventListener('click', async () => {
  const session = state.sessions.find((item) => item.id === state.conversationSessionId);
  if (session) await window.codexManager.revealPath(session.rolloutPath);
});

refresh();
