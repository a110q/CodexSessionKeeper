const assert = require('node:assert/strict');
const test = require('node:test');

const { AGENT_VERSION, MANIFEST_VERSION } = require('../../src/backup/models');
const { backupPaths } = require('../../src/backup/paths');

const homeDir = 'C:\\Users\\Ada';

test('backup model constants are exported', () => {
  assert.equal(MANIFEST_VERSION, 1);
  assert.equal(AGENT_VERSION, '1.0.0');
});

test('backupPaths returns the Windows backup layout', () => {
  const paths = backupPaths(homeDir);

  assert.equal(paths.codexRoot, 'C:\\Users\\Ada\\.codex');
  assert.equal(paths.vaultRoot, 'C:\\Users\\Ada\\.codex-session-vault');
  assert.equal(paths.backupRoot, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups');
  assert.equal(paths.manifestPath, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\manifest.json');
  assert.equal(paths.cursorDatabasePath, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\cursors.sqlite');
  assert.equal(paths.statusPath, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\status.json');
  assert.equal(paths.sessionsRoot, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\sessions');
  assert.equal(paths.logsRoot, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\logs');
  assert.equal(paths.logPath, 'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\logs\\backup-agent.log');
});

test('backupFilePath uses UTC date parts', () => {
  const paths = backupPaths(homeDir);

  assert.equal(
    paths.backupFilePath('session-123', new Date('2026-01-02T03:04:05.000Z')),
    'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\sessions\\2026\\01\\02\\session-123.jsonl',
  );
});

test('backupFilePath sanitizes unsafe session IDs', () => {
  const paths = backupPaths(homeDir);
  const firstSeenAt = new Date('2026-01-02T03:04:05.000Z');

  assert.equal(
    paths.backupFilePath('---Alpha/Beta::Gamma 42!!!', firstSeenAt),
    'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\sessions\\2026\\01\\02\\Alpha-Beta-Gamma-42.jsonl',
  );
  assert.equal(
    paths.backupFilePath('!!!', firstSeenAt),
    'C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\sessions\\2026\\01\\02\\session.jsonl',
  );
});

test('relativeBackupPath returns paths inside the backup root', () => {
  const paths = backupPaths(homeDir);

  assert.equal(
    paths.relativeBackupPath('C:\\Users\\Ada\\.codex-session-vault\\incremental-backups\\sessions\\2026\\01\\02\\abc.jsonl'),
    'sessions\\2026\\01\\02\\abc.jsonl',
  );
});

test('relativeBackupPath returns null outside or equal to the backup root', () => {
  const paths = backupPaths(homeDir);

  assert.equal(paths.relativeBackupPath(paths.backupRoot), null);
  assert.equal(paths.relativeBackupPath('C:\\Users\\Ada\\.codex-session-vault\\incremental-backups-other\\abc.jsonl'), null);
  assert.equal(paths.relativeBackupPath('C:\\Users\\Ada\\.codex\\sessions\\abc.jsonl'), null);
});
