import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import test from 'node:test';

test('latest bounded backup and signed updater coexist', () => {
  assert.equal(
    existsSync('Sources/CodexSessionVaultCore/Backup/SessionBackupStreamer.swift'),
    true,
    'latest bounded Swift backup streamer is missing',
  );
  assert.equal(
    existsSync('Tests/CodexSessionVaultCoreTests/LargeJSONLEndToEndAcceptanceTests.swift'),
    true,
    'large JSONL acceptance suite is missing',
  );
  assert.equal(
    existsSync('Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift'),
    true,
    'macOS updater is missing',
  );
  assert.equal(existsSync('Config/UpdateServer.testing.json'), true);
  assert.equal(
    existsSync('windows/codex_session_manager_electron/src/update/update-service.js'),
    true,
    'Windows updater is missing',
  );

  const packageManifest = readFileSync('Package.swift', 'utf8');
  assert.match(
    packageManifest,
    /\.product\(name: "Sparkle", package: "Sparkle"\)/,
    'macOS application target is not linked to Sparkle',
  );

  const macMain = readFileSync('Sources/CodexSessionVault/main.swift', 'utf8');
  assert.match(macMain, /@StateObject private var updateCoordinator: MacUpdateCoordinator/);
  assert.match(macMain, /\.sheet\([\s\S]*UpdatePromptView\(\)/);
  assert.match(macMain, /\.task \{ updateCoordinator\.start\(\) \}/);
  assert.match(
    macMain,
    /struct ContentView: View \{[\s\S]*@EnvironmentObject private var updateCoordinator: MacUpdateCoordinator/,
    'ContentView does not receive the shared update coordinator',
  );
  assert.match(
    macMain,
    /\.toolbar \{[\s\S]*updateCoordinator\.checkNow\(\)[\s\S]*Text\("检查更新"\)/,
    'macOS toolbar does not expose a visible check-update action',
  );
  assert.match(macMain, /func prepareForUpdate\(timeout:/);
  assert.match(macMain, /func resumeBackupAfterCancelledUpdate\(\)/);
  assert.doesNotMatch(macMain, /private let appVersion = "1\.0\.14"/);
  assert.match(macMain, /CFBundleShortVersionString/);

  const macUpdateCoordinator = readFileSync(
    'Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift',
    'utf8',
  );
  assert.match(macUpdateCoordinator, /showDownloadConfirmation\(version:/);
  assert.match(macUpdateCoordinator, /showInstallConfirmation\(version:/);
  assert.match(macUpdateCoordinator, /NSAlert\(\)/);
  assert.match(macUpdateCoordinator, /MacUpdateConsentPolicy\.perform\(/);
  assert.match(macUpdateCoordinator, /MacUpdateConsentPolicy\.performAsync\(/);
  assert.match(macUpdateCoordinator, /update-audit\.jsonl/);
  assert.match(macUpdateCoordinator, /retryTerminatingApplication\(\)/);
  assert.match(macUpdateCoordinator, /terminationRetryAttempted/);
  assert.match(macUpdateCoordinator, /private func waitForUpdateUIToDismiss\(\) async/);
  assert.match(macUpdateCoordinator, /application\.modalWindow/);
  assert.match(macUpdateCoordinator, /attachedSheet/);
  assert.match(macUpdateCoordinator, /await waitForUpdateUIToDismiss\(\)/);
  assert.match(
    macUpdateCoordinator,
    /pendingVersion == currentVersion[\s\S]*recordAudit\(\.installCompleted/
  );
  assert.match(
    macUpdateCoordinator,
    /recordAudit\(\.installStarted[\s\S]*resolveReadyReply\(\.install\)/
  );
  assert.match(
    macUpdateCoordinator,
    /guard await model\.prepareForUpdate[\s\S]{0,800}cancelPendingUpdateSession\(resumeBackup: false\)[\s\S]{0,800}\.failed/,
    'a blocked NAS drain must end the current install session without installing',
  );
  const deferRestartBody = macUpdateCoordinator.match(
    /func deferRestart\(\) \{([\s\S]*?)\n    \}\n\n    func restartAndInstall/,
  )?.[1] ?? '';
  assert.match(
    deferRestartBody,
    /cancelPendingSession\(with: \.skip\)/,
    'deferring installation must end the current Sparkle session',
  );
  assert.match(
    macUpdateCoordinator,
    /try stateStore\.setPendingVersion\(version\)[\s\S]{0,800}catch \{[\s\S]{0,800}cancelPendingUpdateSession\(resumeBackup: true\)[\s\S]{0,800}\.failed/,
    'a pending-marker failure must not authorize Sparkle to install without durable audit state',
  );
  assert.match(
    macUpdateCoordinator,
    /cancelPendingSession\(with: \.skip\)/,
    'all abandoned ready sessions must explicitly skip instead of deferring installation to app quit',
  );
  const macUpdatePrompt = readFileSync(
    'Sources/CodexSessionVault/Update/UpdatePromptView.swift',
    'utf8',
  );
  assert.match(macUpdatePrompt, /Button\("稍后提醒", action: coordinator\.deferRestart\)/);

  const windowsMain = readFileSync(
    'windows/codex_session_manager_electron/src/main.js',
    'utf8',
  );
  assert.match(windowsMain, /require\('electron-updater'\)/);
  assert.match(windowsMain, /require\('\.\/update\/update-service'\)/);
  assert.match(windowsMain, /let updateService;/);
  assert.match(windowsMain, /updateService = createUpdateService\(\)/);
  assert.match(windowsMain, /updateService\?\.start\(\)/);
  assert.match(windowsMain, /updateService\?\.dispose\(\)/);
  assert.match(windowsMain, /const appVersion = packageMetadata\.version;/);
  assert.match(windowsMain, /runConfirmedUpdateAction/);
  assert.match(windowsMain, /dialog\.showMessageBox/);
  assert.match(windowsMain, /update-audit\.jsonl/);

  const windowsPackage = JSON.parse(readFileSync(
    'windows/codex_session_manager_electron/package.json',
    'utf8',
  ));
  assert.equal(windowsPackage.version, '1.1.0');
  assert.equal(windowsPackage.updateBuild, 10100);
  assert.equal(windowsPackage.dependencies['electron-updater'], '6.8.9');
  assert.equal(windowsPackage.devDependencies.electron, '43.1.0');
  assert.equal(windowsPackage.devDependencies['electron-builder'], '26.15.3');
  assert.equal(windowsPackage.build.appId, 'local.codex.session-manager');
  assert.equal(windowsPackage.build.extraResources.length, 2);
  assert.equal(
    windowsPackage.build.publish[0].url,
    'http://192.168.10.54:18080/codex-session-keeper/stable/windows/',
  );
});

test('macOS package explains and allows company-LAN update access', () => {
  const script = readFileSync('scripts/build_app.sh', 'utf8');
  assert.match(script, /APP_VERSION="\$\{APP_VERSION:-1\.1\.0\}"/);
  assert.match(script, /APP_BUILD="\$\{APP_BUILD:-10100\}"/);
  assert.match(script, /UPDATE_SCOPE="\$\{UPDATE_SCOPE:-stable\}"/);
  assert.match(script, /Config\/UpdateServer\.testing\.json/);
  assert.match(script, /<key>NSLocalNetworkUsageDescription<\/key>/);
  assert.match(script, /用于连接公司局域网更新服务器/);
  assert.match(script, /<key>NSAllowsLocalNetworking<\/key>\s*<true\/>/);
});
