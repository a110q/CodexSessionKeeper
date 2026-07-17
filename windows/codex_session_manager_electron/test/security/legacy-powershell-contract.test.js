'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const legacyRoot = path.join(__dirname, '..', '..', '..', 'codex_session_manager_win10');
const scriptPath = path.join(legacyRoot, 'app', 'codex_session_manager_win10.ps1');
const securityModulePath = path.join(legacyRoot, 'app', 'session-data-security.ps1');

function source() {
  return fs.readFileSync(scriptPath, 'utf8');
}

function securitySource() {
  return fs.readFileSync(securityModulePath, 'utf8');
}

test('legacy PowerShell loads centralized session data security helpers', () => {
  const text = source();
  assert.match(text, /session-data-security\.ps1/);
  assert.doesNotMatch(text, /function\s+(?:Merge|Remove)-LinesContaining\b/i);
  assert.doesNotMatch(text, /-like\s+['"]\*\$Needle\*/i);
  assert.doesNotMatch(text, /Get-ChildItem[^\r\n]+-Filter\s+['"]\*\$SessionId\*\.jsonl/i);
});

test('legacy PowerShell never deletes a raw database rollout path', () => {
  const text = source();
  assert.doesNotMatch(text, /Remove-Item\s+-Path\s+\$Session\.RolloutPath/i);
  assert.match(text, /New-SessionDeletionPlan/);
  assert.match(text, /Invoke-SessionDeletionPlan/);
});

test('legacy PowerShell merges all six conversation tables without replacement semantics', () => {
  const text = source();
  assert.doesNotMatch(text, /INSERT\s+OR\s+REPLACE/i);
  for (const table of [
    'threads',
    'thread_goals',
    'thread_dynamic_tools',
    'thread_spawn_edges',
    'stage1_outputs',
    'agent_job_items',
  ]) {
    assert.match(text, new RegExp(`\\b${table}\\b`));
  }
  assert.match(text, /SQLITE_RESTORE_CONFLICT/);
  assert.match(text, /\$rolloutUpdate\s*=\s*"UPDATE threads SET rollout_path/);
  assert.match(text, /\$\(\$inserts -join "`n"\)[\s\S]{0,80}\$rolloutUpdate[\s\S]{0,80}COMMIT;/);
  const sqliteStart = text.indexOf('function Invoke-Sqlite');
  const sqliteEnd = text.indexOf('function Get-FileSize', sqliteStart);
  const sqlite = text.slice(sqliteStart, sqliteEnd);
  assert.match(sqlite, /"-cmd", "\.bail on", "-cmd", "\.timeout 5000"/);
});

test('legacy restore and deletion preflight before creating protection snapshots', () => {
  const text = source();
  const restore = text.slice(text.indexOf('function Restore-SessionFromLatestSnapshot'), text.indexOf('function Delete-SelectedSession'));
  const deletion = text.slice(text.indexOf('function Delete-SelectedSession'), text.indexOf('function Extract-ConversationText'));
  assert.ok(restore.indexOf('New-SessionRestorePlan') >= 0);
  assert.ok(restore.indexOf('New-SessionRestorePlan') < restore.indexOf('New-SessionProtectionSnapshot'));
  assert.doesNotMatch(restore, /New-CodexSnapshot/);
  assert.ok(deletion.indexOf('New-SessionDeletionPlan') >= 0);
  assert.ok(deletion.indexOf('New-SessionDeletionPlan') < deletion.indexOf('New-SessionProtectionSnapshot'));
  assert.doesNotMatch(deletion, /New-CodexSnapshot/);
});

test('legacy rollout validation rechecks identity and content across the full read', () => {
  const text = securitySource();
  const start = text.indexOf('function Read-TrustedRolloutFile');
  const end = text.indexOf('function Get-TrustedSessionFileIndex');
  const validation = text.slice(start, end);

  assert.match(validation, /\$before\s*=\s*Get-SessionFileFingerprint/);
  assert.match(validation, /\$after\s*=\s*Get-SessionFileFingerprint/);
  assert.match(validation, /session identity changed during validation/);
  assert.match(validation, /\$before\.Digest\s+-ceq\s+\$after\.Digest/);
});

test('legacy rollout validation rejects a reparse-point trust root', () => {
  const text = securitySource();

  assert.match(text, /function Get-TrustedSessionRootPath/);
  assert.match(text, /FileAttributes\]::ReparsePoint/);
  assert.match(text, /Get-TrustedSessionRootPath -Root \$CodexRoot \| Out-Null/);
});

test('legacy JSONL identity lookup uses exact property names', () => {
  const text = securitySource();

  assert.match(text, /function Get-ExactJsonProperty/);
  assert.match(text, /\$property = Get-ExactJsonProperty -Object \$Object -Name \$expectedKey/);
  assert.match(text, /IsNullOrWhiteSpace\(\$Value\)/);
});

test('legacy restore publishes preflight-missing files without replacement', () => {
  const text = securitySource();

  assert.match(text, /MustRemainMissing/);
  assert.match(text, /\[System\.IO\.File\]::Move\(\$entry\.TemporaryPath, \$entry\.DestinationPath\)/);
  assert.doesNotMatch(
    text,
    /if \(\$entry\.MustRemainMissing\)[\s\S]{0,300}\[System\.IO\.File\]::Replace/,
  );
});

test('legacy deletion revalidates each rollout after moving it to quarantine', () => {
  const text = securitySource();
  const start = text.indexOf('function Invoke-SessionDeletionPlan');
  const deletion = text.slice(start);

  assert.match(deletion, /Test-SessionFileFingerprintAt\s+-Fingerprint\s+\$file\.Fingerprint\s+-Path\s+\$quarantine/);
  assert.match(deletion, /Session file changed before deletion/);
});
