const state = {
  appVersion: '',
  section: 'sessions',
  sessions: [],
  snapshots: [],
  currentState: {},
  backupStatus: {},
  nasSetup: { state: 'unconfigured', configured: false },
  nasDepartments: [],
  nasEmployees: [],
  nasCatalogLoading: false,
  nasDetected: false,
  nasUiError: '',
  nasReconfiguring: false,
  nasRecoveryDevices: [],
  selectedNasRecoveryDeviceId: null,
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
  snapshotSource: 'snapshots',
  snapshotFilter: 'all',
  snapshotSessionsLoading: false,
  backupRestoreCatalog: null,
  backupRestoreCandidates: [],
  backupRestoreSearch: '',
  showExistingBackupRestore: false,
  checkedBackupRestoreIds: new Set(),
  selectedBackupRestoreId: null,
  backupRestoreLoading: false,
  settings: {
    autoRestoreOnLaunch: false,
    onboardingVersion: 0,
    onboardingInProgress: false,
  },
  autoRestorePromptedSnapshotId: null,
  sessionPreviewId: null,
  sessionPreviewMessages: [],
  sessionPreviewLoading: false,
  sessionPreviewError: ''
};

let sessionSearchTimer = null;
const BACKUP_STATUS_REFRESH_INTERVAL_MS = 10000;
let backupStatusRefreshTimer = null;
let backupStatusRefreshInFlight = false;

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
  snapshotSource: $('#snapshotSource'),
  nasRecoveryDevice: $('#nasRecoveryDevice'),
  snapshotName: $('#snapshotName'),
  snapshotFilter: $('#snapshotFilter'),
  checkAllSnapshotsBtn: $('#checkAllSnapshotsBtn'),
  clearCheckedSnapshotsBtn: $('#clearCheckedSnapshotsBtn'),
  deleteCheckedSnapshotsBtn: $('#deleteCheckedSnapshotsBtn'),
  autoRestoreSwitch: $('#autoRestoreSwitch'),
  backupStatusText: $('#backupStatusText'),
  backupStatusDetail: $('#backupStatusDetail'),
  nasStatusRetryBtn: $('#nasStatusRetryBtn'),
  nasReconfigureBtn: $('#nasReconfigureBtn'),
  launchAtLoginWarning: $('#launchAtLoginWarning'),
  launchAtLoginMessage: $('#launchAtLoginMessage'),
  retryLaunchAtLoginBtn: $('#retryLaunchAtLoginBtn'),
  openLoginItemSettingsBtn: $('#openLoginItemSettingsBtn'),
  nasSetupModal: $('#nasSetupModal'),
  nasSetupTitle: $('#nasSetupTitle'),
  nasDetectionBadge: $('#nasDetectionBadge'),
  nasSetupError: $('#nasSetupError'),
  nasSetupErrorDetail: $('#nasSetupErrorDetail'),
  nasOnboardingStatus: $('#nasOnboardingStatus'),
  nasOnboardingDetail: $('#nasOnboardingDetail'),
  nasOnboardingCounts: $('#nasOnboardingCounts'),
  nasDepartment: $('#nasDepartment'),
  nasEmployee: $('#nasEmployee'),
  nasTargetPreview: $('#nasTargetPreview'),
  nasRetryBtn: $('#nasRetryBtn'),
  nasConfirmBtn: $('#nasConfirmBtn'),
  nasCancelReconfigureBtn: $('#nasCancelReconfigureBtn'),
  employeeHelpBtn: $('#employeeHelpBtn'),
  employeeHelpModal: $('#employeeHelpModal'),
  employeeHelpVersion: $('#employeeHelpVersion'),
  employeeHelpTopics: $('#employeeHelpTopics'),
  employeeHelpCloseBtn: $('#employeeHelpCloseBtn'),
  employeeHelpRetryBtn: $('#employeeHelpRetryBtn'),
  employeeHelpReconfigureBtn: $('#employeeHelpReconfigureBtn'),
  employeeHelpRecoveryBtn: $('#employeeHelpRecoveryBtn'),
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

function formatRelativeTime(value) {
  if (!value) return '-';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '-';
  const diffMs = Date.now() - date.getTime();
  if (diffMs < 0) return formatDate(value);
  const minutes = Math.floor(diffMs / 60000);
  if (minutes < 1) return '刚刚';
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  const days = Math.floor(hours / 24);
  if (days < 7) return `${days} 天前`;
  if (days < 30) return `${Math.floor(days / 7)} 周前`;
  return date.toLocaleDateString('zh-CN');
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

function freshDotClass(session) {
  if (!session.existsOnDisk) return 'missing';
  const updated = new Date(session.updatedAt);
  if (Number.isNaN(updated.getTime())) return 'stale';
  const ageDays = (Date.now() - updated.getTime()) / 86400000;
  if (ageDays < 1) return 'today';
  if (ageDays > 7) return 'stale';
  return '';
}

function shortPath(value) {
  const text = String(value || '').replaceAll('\\', '/');
  if (!text) return '-';
  const homeIndex = text.lastIndexOf('/Users/');
  if (homeIndex >= 0) {
    const pieces = text.slice(homeIndex).split('/').filter(Boolean);
    if (pieces.length > 2) return `~/${pieces.slice(2).join('/')}`;
  }
  const pieces = text.split('/').filter(Boolean);
  if (pieces.length <= 3) return text;
  return `.../${pieces.slice(-3).join('/')}`;
}

function displaySource(value) {
  const text = String(value || '').trim();
  if (text.toLowerCase() === 'vscode') return 'Codex 桌面端';
  return text || 'unknown';
}

function renderMessageHtml(message, options = {}) {
  const text = String(message.text || '');
  const limit = options.limit || 16000;
  const clipped = text.length > limit;
  const visible = clipped ? `${text.slice(0, limit)}\n\n... 内容较长，已截断展示。可打开完整对话继续查看。` : text;
  const role = message.role === '用户' ? 'user' : message.role === '助手' ? 'assistant' : 'other';
  const roleClass = role === 'user' ? 'role-user' : role === 'assistant' ? 'role-assistant' : '';
  const rowClass = role === 'user' ? 'from-user' : role === 'assistant' ? 'from-assistant' : '';
  return `
    <div class="${options.preview ? 'preview-message' : 'message-row'} ${rowClass}">
      <div class="message-role">
        <span class="role-badge ${roleClass}">${escapeHtml(message.role || '记录')}</span>
        ${message.phase ? `<div class="message-phase" title="${escapeHtml(message.phase)}">${escapeHtml(message.phase)}</div>` : ''}
      </div>
      <div class="message-card">
        <div class="message-time">${formatDate(message.timestamp)}</div>
        ${escapeHtml(visible)}
      </div>
    </div>
  `;
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
      displaySource(session.source),
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

function backupRestoreStatusLabel(status) {
  if (status === 'missing') return '可恢复';
  if (status === 'existing') return '已存在';
  if (status === 'backupFileMissing') return '文件缺失';
  return '备份异常';
}

function filteredBackupRestoreCandidates() {
  const query = state.backupRestoreSearch.trim().toLowerCase();
  return state.backupRestoreCandidates.filter((candidate) => {
    if (!state.showExistingBackupRestore && candidate.status === 'existing') return false;
    if (!query) return true;
    return [
      candidate.sessionId,
      candidate.title,
      candidate.error || ''
    ].join(' ').toLowerCase().includes(query);
  });
}

function selectedBackupRestoreCandidate() {
  return state.backupRestoreCandidates.find((candidate) => candidate.sessionId === state.selectedBackupRestoreId);
}

function checkedRestorableBackupRestoreCandidates() {
  return state.backupRestoreCandidates.filter((candidate) => state.checkedBackupRestoreIds.has(candidate.sessionId) && candidate.isRestorable);
}

function selectFirstVisibleBackupRestoreIfNeeded() {
  const candidates = filteredBackupRestoreCandidates();
  if (state.selectedBackupRestoreId && candidates.some((candidate) => candidate.sessionId === state.selectedBackupRestoreId)) return;
  state.selectedBackupRestoreId = candidates[0]?.sessionId || null;
}

function pruneCheckedItems() {
  const sessionIds = new Set(state.sessions.map((session) => session.id));
  state.checkedSessionIds = new Set([...state.checkedSessionIds].filter((id) => sessionIds.has(id)));
  const snapshotIds = new Set(state.snapshots.map((snapshot) => snapshot.id));
  state.checkedSnapshotIds = new Set([...state.checkedSnapshotIds].filter((id) => snapshotIds.has(id)));
  const snapshotSessionIds = new Set(state.snapshotSessions.map((session) => session.id));
  state.checkedSnapshotSessionIds = new Set([...state.checkedSnapshotSessionIds].filter((id) => snapshotSessionIds.has(id)));
  const backupRestoreIds = new Set(state.backupRestoreCandidates.map((candidate) => candidate.sessionId));
  state.checkedBackupRestoreIds = new Set([...state.checkedBackupRestoreIds].filter((id) => backupRestoreIds.has(id)));
}

function renderBatchControls() {
  const snapshotMode = state.snapshotSource === 'snapshots';
  els.nasRecoveryDevice.classList.toggle('hidden', snapshotMode);
  els.snapshotName.classList.toggle('hidden', !snapshotMode);
  $('#createSnapshotBtn').classList.toggle('hidden', !snapshotMode);
  els.snapshotFilter.classList.toggle('hidden', !snapshotMode);
  els.checkAllSnapshotsBtn.classList.toggle('hidden', !snapshotMode);

  const checkedSessionCount = state.checkedSessionIds.size;
  els.checkVisibleSessionsBtn.disabled = filteredSessions().length === 0;
  els.clearCheckedSessionsBtn.classList.toggle('hidden', checkedSessionCount === 0);
  els.deleteCheckedSessionsBtn.classList.toggle('hidden', checkedSessionCount === 0);
  els.deleteCheckedSessionsBtn.textContent = `删除选中 ${checkedSessionCount}`;

  const checkedSnapshotCount = state.checkedSnapshotIds.size;
  els.checkAllSnapshotsBtn.disabled = filteredSnapshots().length === 0;
  els.clearCheckedSnapshotsBtn.classList.toggle('hidden', !snapshotMode || checkedSnapshotCount === 0);
  els.deleteCheckedSnapshotsBtn.classList.toggle('hidden', !snapshotMode || checkedSnapshotCount === 0);
  els.deleteCheckedSnapshotsBtn.textContent = `删除选中 ${checkedSnapshotCount}`;
}

function renderStateCard() {
  $('#stateProvider').textContent = state.currentState.modelProvider || 'unknown';
  $('#stateModel').textContent = state.currentState.model || 'unknown';
  $('#stateAccount').textContent = state.currentState.accountFingerprint || 'none';
  $('#stateSessions').textContent = `${state.currentState.sessionCount || 0} active / ${state.currentState.archivedSessionCount || 0} archived`;
  els.autoRestoreSwitch.checked = Boolean(state.settings?.autoRestoreOnLaunch);
}

function replaceSelectOptions(select, values, placeholder, selectedValue = '') {
  const options = [`<option value="">${escapeHtml(placeholder)}</option>`]
    .concat(values.map((value) => `<option value="${escapeHtml(value)}">${escapeHtml(value)}</option>`));
  select.innerHTML = options.join('');
  select.value = values.includes(selectedValue) ? selectedValue : '';
}

function effectiveNasSetup() {
  const setup = state.nasSetup || {};
  const backupState = state.backupStatus?.status;
  let runtimeState = backupState && backupState !== 'waiting'
    ? backupState
    : setup.state || 'unconfigured';
  if (state.nasUiError) runtimeState = state.nasDetected ? 'error' : 'disconnected';
  return {
    ...setup,
    state: runtimeState,
    progress: state.backupStatus?.progress || setup.progress || null,
  };
}

function renderNasSetup() {
  const setup = effectiveNasSetup();
  const department = els.nasDepartment.value;
  const employee = els.nasEmployee.value;
  const validDepartment = state.nasDepartments.includes(department);
  const validEmployee = state.nasEmployees.includes(employee);
  const decision = window.EmployeeGuidance.onboardingDecision({
    setup,
    settings: state.settings,
    catalogReady: state.nasDetected,
    selectionValid: validDepartment && validEmployee,
  });
  const visible = decision.presentSetup || state.nasReconfiguring;
  const busy = ['validating', 'seeding', 'verifying'].includes(setup.state);
  els.nasSetupModal.classList.toggle('hidden', !visible);
  els.nasSetupTitle.textContent = state.nasReconfiguring
    ? '更换 NAS 备份身份'
    : '配置公司 NAS 会话备份';
  els.nasCancelReconfigureBtn.classList.toggle('hidden', !setup.configured || !state.nasReconfiguring);

  document.querySelectorAll('[data-onboarding-step]').forEach((element) => {
    const step = Number(element.dataset.onboardingStep);
    element.classList.toggle('active', step === decision.step);
    element.classList.toggle('complete', step < decision.step);
  });

  const guidance = window.EmployeeGuidance.stateGuidance(setup.state);
  els.nasOnboardingStatus.textContent = guidance.title;
  els.nasOnboardingDetail.textContent = guidance.detail;
  const progress = setup.progress || {};
  const total = Number(progress.totalFiles || 0);
  const completed = Number(progress.completedFiles || 0);
  const failed = Number(progress.failedFiles || 0);
  const pending = Number(progress.pendingFiles || 0);
  els.nasOnboardingCounts.textContent = total > 0
    ? failed > 0
      ? `已发现 ${total} · 成功 ${completed - failed} · 异常 ${failed} · 待处理 ${pending}`
      : `已发现 ${total} · 已检查 ${completed} · 待处理 ${pending}`
    : '';

  let detectionText = '等待检测';
  if (state.nasCatalogLoading) detectionText = '正在检测';
  else if (state.nasDetected) detectionText = '已连接';
  else if (state.nasUiError || setup.state === 'disconnected') detectionText = '未连接';
  els.nasDetectionBadge.textContent = detectionText;
  els.nasDetectionBadge.className = `nas-detection-badge ${state.nasDetected ? 'connected' : ''}`;
  const diagnostic = state.nasUiError || setup.lastError || state.backupStatus?.lastError || '';
  els.nasSetupErrorDetail.textContent = diagnostic;
  els.nasSetupError.classList.toggle('hidden', !diagnostic);
  if (!diagnostic) els.nasSetupError.open = false;

  els.nasDepartment.disabled = state.nasCatalogLoading || busy || !state.nasDetected;
  els.nasEmployee.disabled = state.nasCatalogLoading || busy || !validDepartment;
  const canActivate = state.nasReconfiguring
    ? validDepartment && validEmployee
    : decision.canActivate;
  els.nasConfirmBtn.disabled = state.nasCatalogLoading || busy || !canActivate;
  els.nasRetryBtn.disabled = state.nasCatalogLoading || busy;
  els.nasRetryBtn.textContent = state.nasCatalogLoading
    ? '正在检测...'
    : state.nasDetected
      ? '重新检测'
      : '检测公司 NAS';
  els.nasTargetPreview.textContent = validDepartment && validEmployee
    ? `公司 NAS / ${department} / ${employee}`
    : '请选择部门和姓名';
}

function mergeOnboardingSettings(backupStatus) {
  state.settings = {
    ...state.settings,
    onboardingVersion: Number(backupStatus?.onboardingVersion || 0),
    onboardingInProgress: Boolean(backupStatus?.onboardingInProgress),
  };
}

function renderEmployeeHelp() {
  els.employeeHelpVersion.textContent = `版本 ${state.appVersion || '未知'}`;
  els.employeeHelpTopics.replaceChildren();
  for (const topic of window.EmployeeGuidance.helpTopics) {
    const section = document.createElement('section');
    const title = document.createElement('h3');
    const body = document.createElement('p');
    title.textContent = topic.title;
    body.textContent = topic.body;
    section.append(title, body);
    els.employeeHelpTopics.append(section);
  }
}

function openEmployeeHelp() {
  renderEmployeeHelp();
  els.employeeHelpModal.classList.remove('hidden');
  els.employeeHelpCloseBtn.focus();
}

function closeEmployeeHelp() {
  els.employeeHelpModal.classList.add('hidden');
  els.employeeHelpBtn.focus();
}

async function loadNasEmployees(department, preferredEmployee = '') {
  state.nasEmployees = [];
  replaceSelectOptions(els.nasEmployee, [], department ? '正在读取姓名...' : '请先选择部门');
  renderNasSetup();
  if (!state.nasDepartments.includes(department)) return;

  try {
    state.nasEmployees = await window.codexManager.listNasEmployees(department) || [];
    replaceSelectOptions(els.nasEmployee, state.nasEmployees, '请选择姓名', preferredEmployee);
  } catch (error) {
    state.nasUiError = error.message || String(error);
    replaceSelectOptions(els.nasEmployee, [], '姓名读取失败');
  }
  renderNasSetup();
}

async function detectAndLoadNasCatalogs() {
  if (state.nasCatalogLoading) return;
  state.nasCatalogLoading = true;
  state.nasDetected = false;
  state.nasUiError = '';
  renderNasSetup();

  try {
    await window.codexManager.detectCompanyNas();
    state.nasDepartments = await window.codexManager.listNasDepartments() || [];
    state.nasDetected = true;
    const preferredDepartment = state.nasSetup?.department || '';
    replaceSelectOptions(els.nasDepartment, state.nasDepartments, '请选择部门', preferredDepartment);
    state.nasCatalogLoading = false;
    if (els.nasDepartment.value) {
      await loadNasEmployees(els.nasDepartment.value, state.nasSetup?.employee || '');
    } else {
      replaceSelectOptions(els.nasEmployee, [], '请先选择部门');
    }
  } catch (error) {
    state.nasDepartments = [];
    state.nasEmployees = [];
    state.nasUiError = error.message || String(error);
    replaceSelectOptions(els.nasDepartment, [], '公司 NAS 未连接');
    replaceSelectOptions(els.nasEmployee, [], '请先连接公司 NAS');
  } finally {
    state.nasCatalogLoading = false;
    renderNasSetup();
  }
}

async function beginNasSetup(reconfigure = false) {
  state.nasReconfiguring = reconfigure;
  state.nasUiError = '';
  renderNasSetup();
  await detectAndLoadNasCatalogs();
}

async function activateNasBackup() {
  const department = els.nasDepartment.value;
  const employee = els.nasEmployee.value;
  if (!state.nasDepartments.includes(department) || !state.nasEmployees.includes(employee)) return;
  const previous = state.nasSetup || {};
  if (previous.configured && (previous.department !== department || previous.employee !== employee)) {
    const approved = confirm(
      `确认更改公司 NAS 备份身份？\n\n当前：${previous.department} / ${previous.employee}\n新的：${department} / ${employee}\n\n验证成功后，后续会话将写入新的个人目录。`
    );
    if (!approved) return;
  }

  state.nasCatalogLoading = true;
  state.nasUiError = '';
  if (!previous.configured) {
    state.settings = { ...state.settings, onboardingInProgress: true };
  }
  els.nasConfirmBtn.textContent = '正在验证并启动...';
  renderNasSetup();
  try {
    state.nasSetup = await window.codexManager.activateNasBackup(department, employee);
    state.nasReconfiguring = false;
    state.backupStatus = await window.codexManager.loadBackupStatus() || {};
    mergeOnboardingSettings(state.backupStatus);
    renderAll();
    await loadNasRecoveryDevices();
    showToast(`公司 NAS 会话备份已配置：${department} / ${employee}`);
  } catch (error) {
    state.nasUiError = error.message || String(error);
  } finally {
    state.nasCatalogLoading = false;
    els.nasConfirmBtn.textContent = '验证并开始备份';
    renderNasSetup();
  }
}

async function retryNasBackup() {
  if (!state.nasSetup?.configured) {
    await beginNasSetup(false);
    return;
  }
  try {
    state.nasSetup = await window.codexManager.retryNasBackup();
    state.backupStatus = await window.codexManager.loadBackupStatus() || {};
    state.nasUiError = '';
    mergeOnboardingSettings(state.backupStatus);
    renderAll();
    showToast('公司 NAS 已重新连接');
  } catch (error) {
    state.nasSetup = await window.codexManager.getNasSetupState();
    state.nasUiError = error.message || String(error);
    renderAll();
    showToast(state.nasUiError, true);
  }
}

function applyLaunchAtLoginState(launchAtLogin) {
  state.nasSetup = { ...state.nasSetup, launchAtLogin };
  state.backupStatus = {
    ...state.backupStatus,
    autoStartEnabled: Boolean(launchAtLogin?.enabled),
    launchAtLogin,
  };
}

async function retryLaunchAtLogin() {
  try {
    const launchAtLogin = await window.codexManager.retryLaunchAtLogin();
    applyLaunchAtLoginState(launchAtLogin);
    renderBackupStatus();
    showToast(launchAtLogin.enabled ? '开机自启已启用' : (launchAtLogin.message || '无法启用开机自启'), !launchAtLogin.enabled);
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function openLoginItemSettings() {
  try {
    const launchAtLogin = await window.codexManager.openLoginItemSettings();
    applyLaunchAtLoginState(launchAtLogin);
    renderBackupStatus();
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function loadNasRecoveryDevices() {
  state.nasRecoveryDevices = (await window.codexManager.listNasBackupDevices() || [])
    .sort((a, b) => Number(b.isCurrent) - Number(a.isCurrent) || String(a.deviceName).localeCompare(String(b.deviceName), 'zh-CN'));
  if (!state.nasRecoveryDevices.some((device) => device.deviceId === state.selectedNasRecoveryDeviceId)) {
    state.selectedNasRecoveryDeviceId = state.nasRecoveryDevices[0]?.deviceId || null;
  }
  els.nasRecoveryDevice.innerHTML = state.nasRecoveryDevices.map((device) => {
    const suffix = device.isCurrent ? '当前设备' : `旧设备${device.lastBackupAt ? ` · ${formatDate(device.lastBackupAt)}` : ''}`;
    return `<option value="${escapeHtml(device.deviceId)}">${escapeHtml(device.deviceName)} · ${suffix}</option>`;
  }).join('');
  els.nasRecoveryDevice.value = state.selectedNasRecoveryDeviceId || '';
  els.nasRecoveryDevice.disabled = state.nasRecoveryDevices.length === 0;
}

function renderBackupStatus() {
  const backup = state.backupStatus || {};
  const launchAtLogin = backup.launchAtLogin || state.nasSetup?.launchAtLogin || {};
  const status = backup.status || 'waiting';
  const mode = backup.mode || 'unknown';
  const labels = {
    running: '备份已验证',
    seeding: '首次备份中',
    verifying: '正在校验',
    pending: '正在补传',
    validating: '正在验证',
    disconnected: 'NAS 未连接',
    unconfigured: '尚未配置',
    error: '异常',
    waiting: '等待中'
  };
  const statusClass = status === 'running'
    ? 'running'
    : status === 'error' || status === 'disconnected'
      ? 'error'
      : ['seeding', 'pending', 'validating', 'verifying'].includes(status)
        ? 'working'
        : 'waiting';
  els.backupStatusText.textContent = labels[status] || '等待中';
  els.backupStatusText.className = `backup-status-text ${statusClass}`;

  const lastBackup = backup.lastBackupAt ? formatDate(backup.lastBackupAt) : '暂无备份';
  const progress = backup.progress;
  els.backupStatusDetail.textContent = backup.lastError
    ? backup.lastError
    : status === 'verifying'
      ? `正在回读校验已上传备份 · ${progress?.completedFiles || 0} / ${progress?.totalFiles || 0}`
    : progress?.pendingFiles > 0
      ? `已处理 ${progress.completedFiles || 0} / ${progress.totalFiles || 0}，剩余 ${progress.pendingFiles}`
    : `模式：${mode} · 最近备份：${lastBackup} · 会话：${backup.sessionCount || 0}`;
  els.nasStatusRetryBtn.classList.toggle('hidden', !['disconnected', 'error', 'waiting'].includes(status));
  els.nasReconfigureBtn.classList.toggle('hidden', !state.nasSetup?.configured);
  const launchWarningVisible = Boolean(state.nasSetup?.configured && !launchAtLogin.enabled);
  els.launchAtLoginWarning.classList.toggle('hidden', !launchWarningVisible);
  els.launchAtLoginMessage.textContent = launchAtLogin.message || '开机自启尚未启用；关闭窗口后备份将无法长期常驻。';
  renderNasSetup();
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
      <div class="fresh-dot ${freshDotClass(session)}" title="${session.existsOnDisk ? '会话文件存在' : '会话文件缺失'}"></div>
      <div class="row-content">
        <div class="row-title">
          ${escapeHtml(session.title || session.id)}
          ${session.archived ? '<span class="tag archive">归档</span>' : ''}
        </div>
        <div class="row-meta">${escapeHtml(session.model)} · ${escapeHtml(shortPath(session.cwd || session.rolloutPath))}</div>
      </div>
      <div class="row-side">
        <div class="row-time" title="${formatDate(session.updatedAt)}">${formatRelativeTime(session.updatedAt)}</div>
        ${session.existsOnDisk ? '' : '<span class="tag missing">缺文件</span>'}
        <div class="row-stats">${formatBytes(session.sizeBytes)} · ${escapeHtml(displaySource(session.source))}</div>
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
    displaySource(session.source),
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

function renderPreviewMessages() {
  const preview = $('#sessionConversationPreview');
  const meta = $('#sessionPreviewMeta');
  if (!preview) return;

  if (state.sessionPreviewLoading) {
    preview.innerHTML = '<div class="preview-loading">正在读取对话预览...</div>';
    if (meta) meta.textContent = '加载中';
    return;
  }

  if (state.sessionPreviewError) {
    preview.innerHTML = `<div class="preview-empty">${escapeHtml(state.sessionPreviewError)}</div>`;
    if (meta) meta.textContent = '打开失败';
    return;
  }

  const messages = state.sessionPreviewMessages || [];
  if (!messages.length) {
    preview.innerHTML = '<div class="preview-empty">没有解析到可预览的用户或助手消息。</div>';
    if (meta) meta.textContent = '0 条消息';
    return;
  }

  if (meta) meta.textContent = `${messages.length} 条消息，预览前 ${Math.min(messages.length, 20)} 条`;
  preview.innerHTML = messages.slice(0, 20).map((message) => renderMessageHtml(message, {
    preview: true,
    limit: 200
  })).join('');
}

async function loadSessionPreview(session) {
  if (!session || !session.existsOnDisk) {
    state.sessionPreviewId = session?.id || null;
    state.sessionPreviewMessages = [];
    state.sessionPreviewLoading = false;
    state.sessionPreviewError = session ? '这个会话文件缺失，无法生成预览。' : '';
    renderPreviewMessages();
    return;
  }

  const previewId = session.id;
  state.sessionPreviewId = previewId;
  state.sessionPreviewMessages = [];
  state.sessionPreviewLoading = true;
  state.sessionPreviewError = '';
  renderPreviewMessages();
  try {
    const messages = await window.codexManager.loadConversation(previewId);
    if (state.sessionPreviewId !== previewId) return;
    state.sessionPreviewMessages = messages || [];
    state.sessionPreviewLoading = false;
    renderPreviewMessages();
  } catch (error) {
    if (state.sessionPreviewId !== previewId) return;
    state.sessionPreviewMessages = [];
    state.sessionPreviewLoading = false;
    state.sessionPreviewError = error.message || String(error);
    renderPreviewMessages();
  }
}

function renderSessionDetail(session) {
  if (!session) {
    els.sessionDetail.className = 'detail-empty';
    els.sessionDetail.innerHTML = '<div class="empty-icon">⌁</div><h3>没有选中会话</h3><p>从左侧选择一个会话，或调整搜索条件。</p>';
    state.sessionPreviewId = null;
    state.sessionPreviewMessages = [];
    state.sessionPreviewLoading = false;
    state.sessionPreviewError = '';
    return;
  }

  els.sessionDetail.className = '';
  const sessionTitle = session.title || session.id;
  els.sessionDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div class="detail-title-copy">
          <h2 class="detail-title" title="${escapeHtml(sessionTitle)}">${escapeHtml(sessionTitle)}</h2>
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

    <div class="detail-card conversation-preview-card">
      <div class="preview-header">
        <div>
          <h3>会话预览</h3>
          <p id="sessionPreviewMeta" class="row-meta">正在准备</p>
        </div>
        <button class="ghost-button" data-detail-action="view">查看完整对话</button>
      </div>
      <div id="sessionConversationPreview" class="preview-messages"></div>
    </div>

    <div class="metric-grid detail-card">
      <div class="metric"><span>模型供应商</span><strong>${escapeHtml(session.provider)}</strong></div>
      <div class="metric"><span>模型</span><strong>${escapeHtml(session.model)}</strong></div>
      <div class="metric"><span>来源</span><strong>${escapeHtml(displaySource(session.source))}</strong></div>
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

  if (state.sessionPreviewId === session.id) {
    renderPreviewMessages();
  } else {
    loadSessionPreview(session);
  }
}

function renderBackupRestoreList() {
  const catalog = state.backupRestoreCatalog || {};
  const candidates = filteredBackupRestoreCandidates();
  els.snapshotCount.textContent = state.backupRestoreLoading
    ? '读取中'
    : `${catalog.missingCount || 0} / ${catalog.totalCount || 0}`;

  if (state.backupRestoreLoading) {
    els.snapshotList.innerHTML = '<div class="detail-empty"><h3>正在读取公司 NAS 会话备份</h3><p>正在验证设备和备份记录。</p></div>';
    renderBackupRestoreDetail(null);
    renderBatchControls();
    return;
  }

  if (candidates.length === 0) {
    els.snapshotList.innerHTML = '<div class="detail-empty"><h3>没有可显示的备份会话</h3><p>当前没有缺失会话；打开“显示已存在”可排查全部备份记录。</p></div>';
    renderBackupRestoreDetail(null);
    renderBatchControls();
    return;
  }

  selectFirstVisibleBackupRestoreIfNeeded();
  els.snapshotList.innerHTML = candidates.map((candidate) => `
    <article class="snapshot-row backup-restore-row ${candidate.sessionId === state.selectedBackupRestoreId ? 'selected' : ''}" data-backup-restore-id="${escapeHtml(candidate.sessionId)}">
      <button class="row-check ${state.checkedBackupRestoreIds.has(candidate.sessionId) ? 'checked' : ''}" data-check-backup-restore="${escapeHtml(candidate.sessionId)}" ${candidate.isRestorable ? '' : 'disabled'}>✓</button>
      <div class="row-content">
        <div class="row-title">${escapeHtml(candidate.title || candidate.sessionId)} <span class="tag ${candidate.isRestorable ? 'manual' : 'archive'}">${backupRestoreStatusLabel(candidate.status)}</span></div>
        <div class="row-meta">${escapeHtml(candidate.sessionId)} · ${formatBytes(candidate.bytesBackedUp)}</div>
        <div class="row-time">${formatDate(candidate.lastBackedUpAt || candidate.firstSeenAt)}</div>
      </div>
    </article>
  `).join('');

  renderBackupRestoreDetail(selectedBackupRestoreCandidate());
  renderBatchControls();
}

function renderBackupRestoreDetail(candidate) {
  if (!candidate) {
    els.snapshotDetail.className = 'detail-empty';
    els.snapshotDetail.innerHTML = '<div class="empty-icon">↺</div><h3>没有选中备份会话</h3><p>选择一个缺失会话后可从公司 NAS 备份恢复。</p>';
    return;
  }

  const checked = checkedRestorableBackupRestoreCandidates();
  const canRestore = checked.length || candidate.isRestorable;
  els.snapshotDetail.className = '';
  els.snapshotDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div class="detail-title-copy">
          <h2 class="detail-title" title="${escapeHtml(candidate.title || candidate.sessionId)}">${escapeHtml(candidate.title || candidate.sessionId)}</h2>
          <p class="mono">${escapeHtml(candidate.sessionId)}</p>
        </div>
        <span class="count-pill">${escapeHtml(backupRestoreStatusLabel(candidate.status))}</span>
      </div>
    </div>

    <div class="primary-action-card">
      <div class="action-row wrap">
        <button class="primary-button" data-backup-restore-action="restoreSelected" ${canRestore ? '' : 'disabled'}>${checked.length ? `恢复选中 ${checked.length}` : '恢复这个缺失会话'}</button>
        <button class="ghost-button" data-backup-restore-action="refresh">刷新备份</button>
        <label class="mini-switch"><span>显示已存在</span><input id="showExistingBackupRestore" type="checkbox" ${state.showExistingBackupRestore ? 'checked' : ''} /></label>
      </div>
      <p>只恢复当前 Codex 中缺失的会话，已存在会话不会覆盖。恢复完成后请重启 Codex。</p>
    </div>

    <div class="detail-card">
      <div class="snapshot-session-tools">
        <input id="backupRestoreSearch" class="search-input" placeholder="搜索备份会话" value="${escapeHtml(state.backupRestoreSearch)}" />
        <button class="ghost-button" data-backup-restore-action="clearSearch">清空</button>
        <button class="ghost-button" data-backup-restore-action="checkAllMissing">全选缺失</button>
        <button class="ghost-button" data-backup-restore-action="clearChecked">清空选择</button>
      </div>
    </div>

    <div class="metric-grid detail-card">
      <div class="metric"><span>状态</span><strong>${escapeHtml(backupRestoreStatusLabel(candidate.status))}</strong></div>
      <div class="metric"><span>行数</span><strong>${candidate.lineCount || 0}</strong></div>
      <div class="metric"><span>大小</span><strong>${formatBytes(candidate.bytesBackedUp)}</strong></div>
      <div class="metric"><span>最近备份</span><strong>${formatDate(candidate.lastBackedUpAt || candidate.firstSeenAt)}</strong></div>
    </div>

    <div class="detail-card">
      <h3 style="margin-bottom: 12px;">备份信息</h3>
      <div class="info-lines">
        <div class="info-line"><span>备份设备</span><strong>${escapeHtml(state.nasRecoveryDevices.find((device) => device.deviceId === state.selectedNasRecoveryDeviceId)?.deviceName || '-')}</strong></div>
        <div class="info-line"><span>会话 ID</span><strong class="mono">${escapeHtml(candidate.sessionId)}</strong></div>
        ${candidate.error ? `<div class="info-line"><span>错误</span><strong>${escapeHtml(candidate.error)}</strong></div>` : ''}
      </div>
    </div>
  `;
}

function renderSnapshots() {
  if (state.snapshotSource === 'backupRestore') {
    renderBackupRestoreList();
    return;
  }

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
  const snapshotTitle = snapshot.name || snapshot.id;
  els.snapshotDetail.innerHTML = `
    <div class="detail-card">
      <div class="detail-title-row">
        <div class="detail-title-copy">
          <h2 class="detail-title" title="${escapeHtml(snapshotTitle)}">${escapeHtml(snapshotTitle)}</h2>
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
  renderBackupStatus();
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

async function loadBackupRestoreCatalog() {
  state.backupRestoreLoading = true;
  renderSnapshots();
  try {
    if (!state.selectedNasRecoveryDeviceId) await loadNasRecoveryDevices();
    if (!state.selectedNasRecoveryDeviceId) throw new Error('没有找到可读取的 NAS 备份设备。');
    const catalog = await window.codexManager.loadIncrementalBackupSessions(state.selectedNasRecoveryDeviceId);
    state.backupRestoreCatalog = catalog;
    state.backupRestoreCandidates = catalog.candidates || [];
    state.checkedBackupRestoreIds = new Set(
      [...state.checkedBackupRestoreIds].filter((id) => state.backupRestoreCandidates.some((item) => item.sessionId === id))
    );
    selectFirstVisibleBackupRestoreIfNeeded();
  } catch (error) {
    state.backupRestoreCatalog = null;
    state.backupRestoreCandidates = [];
    state.nasRecoveryDevices = [];
    state.selectedNasRecoveryDeviceId = null;
    els.nasRecoveryDevice.innerHTML = '';
    els.nasRecoveryDevice.disabled = true;
    state.checkedBackupRestoreIds.clear();
    state.selectedBackupRestoreId = null;
    showToast(error.message || String(error), true);
  } finally {
    state.backupRestoreLoading = false;
    renderSnapshots();
  }
}

async function restoreBackupRestoreCandidates() {
  const checked = checkedRestorableBackupRestoreCandidates();
  const selected = selectedBackupRestoreCandidate();
  const candidates = checked.length ? checked : (selected?.isRestorable ? [selected] : []);
  if (!candidates.length) {
    showToast('没有可恢复的缺失会话。', true);
    return;
  }

  const preview = candidates.slice(0, 8).map((candidate) => candidate.title || candidate.sessionId).join('\n');
  const suffix = candidates.length > 8 ? `\n等 ${candidates.length} 个会话` : '';
  const protectionMode = await chooseRestoreProtectionMode(
    '从公司 NAS 备份恢复缺失会话？',
    `将恢复 ${candidates.length} 个当前 Codex 中缺失的会话，不覆盖已存在会话。\n\n${preview}${suffix}`,
    'lightweight'
  );
  if (!protectionMode) return;

  const result = await withBusy(
    '正在从公司 NAS 备份恢复缺失会话...',
    () => window.codexManager.restoreIncrementalBackupSessions(state.selectedNasRecoveryDeviceId, candidates.map((candidate) => candidate.sessionId), protectionMode)
  );
  if (busyWasCancelled(result)) return;
  state.checkedBackupRestoreIds.clear();
  showRestoreComplete(result.message || '备份恢复完成');
  await refresh({ skipAutoRestore: true });
  state.snapshotSource = 'backupRestore';
  if (els.snapshotSource) els.snapshotSource.value = state.snapshotSource;
  await loadBackupRestoreCatalog();
  setSection('snapshots');
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
    state.appVersion = data.appVersion || state.appVersion;
    state.sessions = data.sessions || [];
    state.snapshots = data.snapshots || [];
    state.currentState = data.currentState || {};
    state.backupStatus = data.backupStatus || {};
    state.nasSetup = data.nasSetup || state.nasSetup;
    state.settings = data.settings || state.settings;
    pruneCheckedItems();
    renderAll();
    if (state.snapshotSource === 'backupRestore') {
      await loadBackupRestoreCatalog();
    } else {
      await loadSelectedSnapshotSessions();
    }
    showToast(`已刷新：${state.sessions.length} 个会话，${state.snapshots.length} 个快照`);
    if (!state.nasSetup.configured && !state.nasCatalogLoading && !state.nasDetected) {
      await beginNasSetup(false);
    }
    if (state.nasSetup.configured && (options.forceAutoRestore || !options.skipAutoRestore)) {
      await maybeRunLaunchAutoRestore(data.autoRestoreSuggestion);
    }
  } catch (error) {
    showToast(error.message || String(error), true);
  }
}

async function refreshBackupStatusOnly() {
  if (backupStatusRefreshInFlight) return;
  backupStatusRefreshInFlight = true;

  try {
    const backupStatus = await window.codexManager.loadBackupStatus() || {};
    state.backupStatus = backupStatus;
    mergeOnboardingSettings(backupStatus);
    renderBackupStatus();
  } catch {
    // Lightweight polling should not interrupt the main UI or show a toast.
  } finally {
    backupStatusRefreshInFlight = false;
  }
}

function startBackupStatusPolling() {
  if (backupStatusRefreshTimer) return;
  backupStatusRefreshTimer = setInterval(refreshBackupStatusOnly, BACKUP_STATUS_REFRESH_INTERVAL_MS);
}

function stopBackupStatusPolling() {
  if (!backupStatusRefreshTimer) return;
  clearInterval(backupStatusRefreshTimer);
  backupStatusRefreshTimer = null;
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
    els.conversationBody.innerHTML = messages.map((message) => renderMessageHtml(message)).join('');
  } catch (error) {
    els.conversationMeta.textContent = '打开失败';
    els.conversationBody.innerHTML = `<div class="detail-empty"><h3>打开失败</h3><p>${escapeHtml(error.message || String(error))}</p></div>`;
  }
}

async function runSessionAction(action, session) {
  if (!session) return;
  try {
    if (action === 'view') await openConversation(session);
    if (action === 'open') await window.codexManager.openSessionFile(session.id);
    if (action === 'reveal') await window.codexManager.revealSessionFile(session.id);
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

  const backupRestoreCheck = event.target.closest('[data-check-backup-restore]');
  if (backupRestoreCheck) {
    const id = backupRestoreCheck.dataset.checkBackupRestore;
    const candidate = state.backupRestoreCandidates.find((item) => item.sessionId === id);
    if (!candidate?.isRestorable) return;
    if (state.checkedBackupRestoreIds.has(id)) state.checkedBackupRestoreIds.delete(id);
    else state.checkedBackupRestoreIds.add(id);
    state.selectedBackupRestoreId = id;
    renderSnapshots();
    return;
  }

  const sessionRow = event.target.closest('.session-row');
  if (sessionRow) {
    selectSession(sessionRow.dataset.id);
  }

  const backupRestoreRow = event.target.closest('[data-backup-restore-id]');
  if (backupRestoreRow) {
    state.selectedBackupRestoreId = backupRestoreRow.dataset.backupRestoreId;
    renderSnapshots();
    return;
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

  const backupRestoreAction = event.target.closest('[data-backup-restore-action]');
  if (backupRestoreAction) {
    const action = backupRestoreAction.dataset.backupRestoreAction;
    if (action === 'refresh') await loadBackupRestoreCatalog();
    if (action === 'restoreSelected') await restoreBackupRestoreCandidates();
    if (action === 'clearSearch') {
      state.backupRestoreSearch = '';
      selectFirstVisibleBackupRestoreIfNeeded();
      renderSnapshots();
    }
    if (action === 'checkAllMissing') {
      filteredBackupRestoreCandidates().filter((candidate) => candidate.isRestorable).forEach((candidate) => state.checkedBackupRestoreIds.add(candidate.sessionId));
      selectFirstVisibleBackupRestoreIfNeeded();
      renderSnapshots();
    }
    if (action === 'clearChecked') {
      state.checkedBackupRestoreIds.clear();
      renderSnapshots();
    }
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
  if (event.target.id === 'snapshotSessionSearch') {
    state.snapshotSessionSearch = event.target.value;
    selectFirstVisibleSnapshotSessionIfNeeded();
    renderSnapshotDetail(selectedSnapshot());
    const input = $('#snapshotSessionSearch');
    if (input) {
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
    return;
  }

  if (event.target.id === 'backupRestoreSearch') {
    state.backupRestoreSearch = event.target.value;
    selectFirstVisibleBackupRestoreIfNeeded();
    renderSnapshots();
    const input = $('#backupRestoreSearch');
    if (input) {
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
    return;
  }

  if (event.target.id === 'showExistingBackupRestore') {
    state.showExistingBackupRestore = event.target.checked;
    selectFirstVisibleBackupRestoreIfNeeded();
    renderSnapshots();
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
els.employeeHelpBtn.addEventListener('click', openEmployeeHelp);
els.employeeHelpCloseBtn.addEventListener('click', closeEmployeeHelp);
els.employeeHelpRetryBtn.addEventListener('click', () => { void retryNasBackup(); });
els.employeeHelpReconfigureBtn.addEventListener('click', () => {
  closeEmployeeHelp();
  void beginNasSetup(true);
});
els.employeeHelpRecoveryBtn.addEventListener('click', () => {
  closeEmployeeHelp();
  setSection('snapshots');
});
els.employeeHelpModal.addEventListener('click', (event) => {
  if (event.target === els.employeeHelpModal) closeEmployeeHelp();
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !els.employeeHelpModal.classList.contains('hidden')) {
    event.preventDefault();
    closeEmployeeHelp();
  }
});
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
els.snapshotSource.addEventListener('change', async () => {
  state.snapshotSource = els.snapshotSource.value;
  if (state.snapshotSource === 'backupRestore') {
    await loadBackupRestoreCatalog();
  } else {
    renderSnapshots();
    await loadSelectedSnapshotSessions();
  }
});
els.nasRecoveryDevice.addEventListener('change', async () => {
  state.selectedNasRecoveryDeviceId = els.nasRecoveryDevice.value || null;
  state.backupRestoreCatalog = null;
  state.backupRestoreCandidates = [];
  state.checkedBackupRestoreIds.clear();
  state.selectedBackupRestoreId = null;
  await loadBackupRestoreCatalog();
});
els.nasDepartment.addEventListener('change', async () => {
  state.nasUiError = '';
  await loadNasEmployees(els.nasDepartment.value);
});
els.nasEmployee.addEventListener('change', renderNasSetup);
els.nasRetryBtn.addEventListener('click', detectAndLoadNasCatalogs);
els.nasConfirmBtn.addEventListener('click', activateNasBackup);
els.nasStatusRetryBtn.addEventListener('click', retryNasBackup);
els.nasReconfigureBtn.addEventListener('click', () => beginNasSetup(true));
els.retryLaunchAtLoginBtn.addEventListener('click', retryLaunchAtLogin);
els.openLoginItemSettingsBtn.addEventListener('click', openLoginItemSettings);
els.nasCancelReconfigureBtn.addEventListener('click', () => {
  state.nasReconfiguring = false;
  state.nasUiError = '';
  renderNasSetup();
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
  if (session) await window.codexManager.openSessionFile(session.id);
});
els.conversationRevealFile.addEventListener('click', async () => {
  const session = state.sessions.find((item) => item.id === state.conversationSessionId);
  if (session) await window.codexManager.revealSessionFile(session.id);
});

window.addEventListener('beforeunload', stopBackupStatusPolling);
startBackupStatusPolling();
refresh();
