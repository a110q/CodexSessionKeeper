# macOS Update Retry and Toolbar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a NAS-gated macOS update attempt release Sparkle cleanly, allow a later retry, and expose a visible “检查更新” toolbar button.

**Architecture:** Add a main-actor `UpdateAttemptGate<Choice>` in the Core target to own the in-flight request flag and the one-shot Sparkle ready reply. `MacUpdateCoordinator` uses this gate for duplicate suppression and every success/failure resolution path. `ContentView` calls the existing coordinator through one additional toolbar button, so menu, toolbar, and scheduled checks share one implementation.

**Tech Stack:** Swift 6, SwiftUI, AppKit `NSAlert`, Sparkle 2.9.4, Swift Testing, existing shell/Node packaging tests.

## Global Constraints

- Keep both native confirmations: one before download and one before restart/install.
- Do not change NAS backup, readback verification, or the 5-second pre-install drain.
- Do not enable automatic downloads or unattended installation.
- Do not change Windows behavior, `stable`, or the employee download page during candidate validation.
- Every failure path must leave the updater retryable without deleting conversations, backup data, or published artifacts.

---

### Task 1: One-shot update attempt gate

**Files:**
- Create: `Sources/CodexSessionVaultCore/Update/UpdateAttemptGate.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdateAttemptGateTests.swift`

**Interfaces:**
- Produces: `@MainActor public final class UpdateAttemptGate<Choice>`
- Produces: `isBusy: Bool`, `hasRequestInFlight: Bool`, `hasPendingReply: Bool`
- Produces: `beginRequest() -> Bool`, `endRequest()`, `holdReadyReply(_:resolvingPreviousWith:)`, `resolveReadyReply(_:) -> Bool`, and `discardReadyReply()`

- [ ] **Step 1: Write the failing gate tests**

```swift
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
@MainActor
struct UpdateAttemptGateTests {
    @Test
    func pendingReplyResolvesExactlyOnceAndAllowsTheNextAttempt() {
        let gate = UpdateAttemptGate<String>()
        var replies: [String] = []

        #expect(gate.beginRequest())
        #expect(!gate.beginRequest())
        gate.holdReadyReply({ replies.append($0) }, resolvingPreviousWith: "dismiss-old")
        #expect(gate.hasPendingReply)
        #expect(!gate.beginRequest())

        #expect(gate.resolveReadyReply("dismiss"))
        #expect(!gate.resolveReadyReply("install"))
        #expect(replies == ["dismiss"])
        #expect(gate.beginRequest())
    }

    @Test
    func replacingAReadyReplyDismissesThePreviousReply() {
        let gate = UpdateAttemptGate<String>()
        var replies: [String] = []
        gate.holdReadyReply({ replies.append("first:\($0)") }, resolvingPreviousWith: "unused")

        gate.holdReadyReply({ replies.append("second:\($0)") }, resolvingPreviousWith: "replaced")

        #expect(replies == ["first:replaced"])
        #expect(gate.resolveReadyReply("install"))
        #expect(replies == ["first:replaced", "second:install"])
    }

    @Test
    func discardingAReplyClearsBusyStateWithoutInvokingIt() {
        let gate = UpdateAttemptGate<String>()
        var replyCount = 0
        gate.holdReadyReply({ _ in replyCount += 1 }, resolvingPreviousWith: "unused")

        gate.discardReadyReply()

        #expect(replyCount == 0)
        #expect(!gate.isBusy)
    }
}
```

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --filter UpdateAttemptGateTests
```

Expected: compilation fails because `UpdateAttemptGate` does not exist.

- [ ] **Step 3: Implement the minimal main-actor gate**

```swift
@MainActor
public final class UpdateAttemptGate<Choice> {
    private var requestInFlight = false
    private var readyReply: ((Choice) -> Void)?

    public init() {}

    public var hasRequestInFlight: Bool { requestInFlight }
    public var hasPendingReply: Bool { readyReply != nil }
    public var isBusy: Bool { requestInFlight || readyReply != nil }

    @discardableResult
    public func beginRequest() -> Bool {
        guard !isBusy else { return false }
        requestInFlight = true
        return true
    }

    public func endRequest() {
        requestInFlight = false
    }

    public func holdReadyReply(
        _ reply: @escaping (Choice) -> Void,
        resolvingPreviousWith replacementChoice: Choice
    ) {
        endRequest()
        _ = resolveReadyReply(replacementChoice)
        readyReply = reply
    }

    @discardableResult
    public func resolveReadyReply(_ choice: Choice) -> Bool {
        guard let reply = readyReply else { return false }
        readyReply = nil
        reply(choice)
        return true
    }

    public func discardReadyReply() {
        readyReply = nil
    }
}
```

- [ ] **Step 4: Run the focused tests and verify GREEN**

Run:

```bash
swift test --filter UpdateAttemptGateTests
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit the gate**

```bash
git add Sources/CodexSessionVaultCore/Update/UpdateAttemptGate.swift \
  Tests/CodexSessionVaultCoreTests/UpdateAttemptGateTests.swift
git commit -m "test: add one-shot update attempt gate"
```

---

### Task 2: Release Sparkle after failed installation preparation

**Files:**
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
- Test: `Tests/CodexSessionVaultCoreTests/UpdateAttemptGateTests.swift`

**Interfaces:**
- Consumes: `UpdateAttemptGate<SPUUserUpdateChoice>` from Task 1
- Produces: `cancelPendingSession(with:) -> Bool` on the gate
- Produces: retryable coordinator behavior after `.dismiss`, Sparkle failure, or NAS drain failure

- [ ] **Step 1: Add a failing retry lifecycle test**

Append a test for the atomic cleanup operation required by every failed-preparation path:

```swift
@Test
func failedPreparationDismissesReadyReplyAndPermitsRetry() {
    let gate = UpdateAttemptGate<String>()
    var replies: [String] = []
    #expect(gate.beginRequest())
    gate.holdReadyReply({ replies.append($0) }, resolvingPreviousWith: "unused")

    #expect(gate.cancelPendingSession(with: "dismiss"))

    #expect(replies == ["dismiss"])
    #expect(!gate.isBusy)
    #expect(gate.beginRequest())
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter UpdateAttemptGateTests.failedPreparationDismissesReadyReplyAndPermitsRetry
```

Expected: compilation fails because `cancelPendingSession(with:)` does not exist.

- [ ] **Step 3: Implement the minimal atomic cleanup operation**

Add to `UpdateAttemptGate`:

```swift
@discardableResult
public func cancelPendingSession(with choice: Choice) -> Bool {
    endRequest()
    return resolveReadyReply(choice)
}
```

Run the focused test again. Expected: it passes.

- [ ] **Step 4: Replace raw coordinator flags/reply with the gate**

In `MacUpdateCoordinator`, replace both the raw `installRequested` flag and
`readyReply` closure with:

```swift
private let attemptGate = UpdateAttemptGate<SPUUserUpdateChoice>()
```

Use:

```swift
guard !attemptGate.isBusy else { return }
```

before showing the download confirmation. Inside the confirmed operation:

```swift
guard self.attemptGate.beginRequest() else { return }
self.recordAudit(.downloadRequested, version: version)
self.installWhenReady = false
self.deferredReady = false
self.updater.checkForUpdates()
```

Use `attemptGate.hasRequestInFlight` in `acceptSparkleItem`, then call
`endRequest()` before processing the item. Dismiss a mismatched item and leave
the gate idle. In `holdReadyReply`, call:

```swift
attemptGate.holdReadyReply(reply, resolvingPreviousWith: .dismiss)
```

When `performRestartAndInstall` needs Sparkle to reopen an already downloaded
item because no ready reply is pending, require `attemptGate.beginRequest()`
before calling `updater.checkForUpdates()`. If it cannot begin, resume backup
and present a retryable failure instead of starting an overlapping request.

- [ ] **Step 5: Add one cleanup method and route all failure paths through it**

Add:

```swift
private func cancelPendingUpdateSession(resumeBackup: Bool) {
    _ = attemptGate.cancelPendingSession(with: .dismiss)
    installWhenReady = false
    deferredReady = false
    if resumeBackup {
        resumeBackupIfNeeded()
    }
}
```

Call it when:

- `prepareForUpdate(timeout:)` returns `false`;
- `stateStore.setPendingVersion` throws;
- Sparkle reports failure.

Call `attemptGate.endRequest()` when Sparkle reports “update not found”. Use
`resolveReadyReply(.dismiss)` for “稍后重启”,
`resolveReadyReply(.install)` for installation, and
`discardReadyReply()` plus `endRequest()` only when Sparkle has already emitted
its dismissal callback.

- [ ] **Step 6: Run Core and macOS update tests**

Run:

```bash
swift test --filter UpdateAttemptGateTests
swift test --filter MacUpdateConsentPolicyTests
swift test --filter UpdatePresentationStateTests
```

Expected: all focused tests pass.

- [ ] **Step 7: Commit coordinator cleanup**

```bash
git add Sources/CodexSessionVaultCore/Update/UpdateAttemptGate.swift \
  Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift \
  Tests/CodexSessionVaultCoreTests/UpdateAttemptGateTests.swift
git commit -m "fix: release failed macOS update sessions"
```

---

### Task 3: Visible toolbar check action

**Files:**
- Modify: `Sources/CodexSessionVault/main.swift`

**Interfaces:**
- Consumes: `MacUpdateCoordinator.checkNow()`
- Produces: a visible toolbar button named `检查更新`

- [ ] **Step 1: Add the coordinator environment object to `ContentView`**

```swift
@EnvironmentObject private var updateCoordinator: MacUpdateCoordinator
```

- [ ] **Step 2: Add the visible toolbar action**

Place it before help and refresh:

```swift
Button {
    updateCoordinator.checkNow()
} label: {
    Text("检查更新")
}
.help("检查公司局域网更新")
```

Keep the existing menu command unchanged.

- [ ] **Step 3: Build the app target**

Run:

```bash
swift build -c release
```

Expected: build succeeds without actor-isolation errors.

- [ ] **Step 4: Commit the toolbar**

```bash
git add Sources/CodexSessionVault/main.swift
git commit -m "feat: show macOS check update button"
```

---

### Task 4: Full regression and package validation

**Files:**
- Verify: `Package.swift`
- Verify: `scripts/build_app.sh`
- Verify: `scripts/update/macos-package.test.mjs`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: tested 1.0.99 testing and 1.1.0 stable-feed artifacts

- [ ] **Step 1: Run all Swift tests**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH"
swift test
```

Expected: the complete Swift test suite, including every new gate test, passes.

- [ ] **Step 2: Run release/deployment tests**

```bash
node --test scripts/update/*.test.mjs
```

Expected: all tests pass, including macOS `LC_RPATH` validation.

- [ ] **Step 3: Build both macOS candidates**

```bash
APP_VERSION=1.0.99 APP_BUILD=10099 UPDATE_SCOPE=testing ./scripts/build_app.sh
APP_VERSION=1.1.0 APP_BUILD=10100 UPDATE_SCOPE=stable ./scripts/build_app.sh
```

Expected: both ZIP and DMG files are generated, `codesign --verify --deep --strict` passes, and both DMGs verify.

- [ ] **Step 4: Verify both ZIP payloads**

Extract each ZIP into its own directory and verify the resulting application bundle:

```bash
VERIFY_ROOT="$(mktemp -d /tmp/codex-update-verify.XXXXXX)"
for ZIP in \
  "$PWD/dist/macos/CodexSessionKeeper-1.0.99-macos-arm64.zip" \
  "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip"
do
  VERSION_DIR="$VERIFY_ROOT/$(basename "$ZIP" .zip)"
  mkdir "$VERSION_DIR"
  ditto -x -k "$ZIP" "$VERSION_DIR"
  APP_PATH="$VERSION_DIR/codex_会话管理.app"
  test -d "$APP_PATH"
  ./scripts/verify_macos_runtime_layout.sh "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH"
done
```

Expected: version/build/feed are `1.0.99/10099/testing` and `1.1.0/10100/stable`; each executable is arm64 and contains `@executable_path/../Frameworks`.

- [ ] **Step 5: Commit any test-only adjustments**

If no tracked files changed during verification, do not create an empty commit.

---

### Task 4A: Allow the confirmed updater to terminate exactly once

**Files:**
- Create: `Sources/CodexSessionVaultCore/Update/UpdateTerminationApprovalGate.swift`
- Create: `Tests/CodexSessionVaultCoreTests/UpdateTerminationApprovalGateTests.swift`
- Modify: `Sources/CodexSessionVault/main.swift`
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`

**Interfaces:**
- Produces: one-shot `approve()`, `consume() -> Bool`, and `revoke()` behavior
- Produces: a single automatic use of Sparkle's documented
  `retryTerminatingApplication` callback if the first quit event is refused

- [x] **Step 1: Write failing tests for one-shot approval and revocation**

Verify that an unapproved termination is rejected, approval is consumed once,
and revocation removes an unused approval.

- [x] **Step 2: Implement the minimal approval gate**

Keep the gate main-actor isolated. Do not make the NAS termination warning
globally bypassable.

- [x] **Step 3: Wire approval to successful NAS drain**

Approve only after `prepareForUpdate` succeeds. Revoke on cancelled update,
Sparkle failure, or dismissal. In `applicationShouldTerminate`, consume the
one-shot approval before evaluating the ordinary NAS warning.

- [x] **Step 4: Retry termination at most once**

When Sparkle reports `applicationTerminated == false`, approve one retry and
invoke `retryTerminatingApplication` once. Reset the retry flag on a new
install attempt and every terminal path.

- [x] **Step 5: Run focused and complete tests**

Run the approval tests, `MacNASWiringContractTests`, complete Swift tests, and
all release/deployment Node tests before rebuilding either package.

---

### Task 4B: Dismiss modal update UI before Sparkle termination

**Files:**
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
- Modify: `scripts/update/latest-product-integration.test.mjs`

**Interfaces:**
- Produces: bounded dismissal of SwiftUI/AppKit sheets before handing control
  to Sparkle
- Produces: one deferred retry only after modal UI has left the window hierarchy

- [x] **Step 1: Reproduce the modal termination stall**

The rebuilt `1.0.99` downloaded and verified `1.1.0`, recorded both
confirmations, and reached `install_started`, but remained alive while its
update sheet was attached. A normal Command-Q was also deferred.

- [x] **Step 2: Add a failing packaging contract**

Require the coordinator to wait for both `NSApplication.modalWindow` and
attached sheets to clear before asking Sparkle to terminate.

- [x] **Step 3: Dismiss and settle update UI before termination**

Close the SwiftUI update sheet, poll the AppKit window hierarchy for at most
one second, and add a short main-run-loop settling delay.

- [x] **Step 4: Defer the one-shot Sparkle retry**

Run the retry from a cancellable main-actor task after the same modal UI
barrier. Cancel the task on update failure, dismissal, completion, or a new
install attempt.

- [x] **Step 5: Re-run focused and complete verification**

Run the product integration contract, approval gate tests, NAS wiring
contract, complete Swift and Node suites, and a release build.

---

### Task 4C: Make install audit survive process replacement

**Files:**
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
- Modify: `scripts/update/latest-product-integration.test.mjs`

- [x] **Step 1: Reproduce the audit gap**

The app successfully replaced `1.0.99` with `1.1.0`, preserved all 638
sessions, and resumed NAS verification, but the old process exited before its
Sparkle callback could append `install_started`, and the relaunched process
did not append `install_completed`.

- [x] **Step 2: Persist start before handing control to Sparkle**

Append `install_started` immediately before resolving the ready reply with
`.install`, including the deferred re-download path.

- [x] **Step 3: Persist completion on matching relaunch**

When the stored pending version equals the running version, append
`install_completed` before presenting the completed state.

- [x] **Step 4: Add contracts and rerun complete tests**

Require both durable audit locations in the product integration contract, then
rerun all Swift and Node suites.

---

### Task 4D: End every abandoned Sparkle session without latent installation

**Files:**
- Modify: `Sources/CodexSessionVault/Update/MacUpdateCoordinator.swift`
- Modify: `Sources/CodexSessionVault/Update/UpdatePromptView.swift`
- Modify: `Tests/CodexSessionVaultCoreTests/UpdateAttemptGateTests.swift`
- Modify: `scripts/update/latest-product-integration.test.mjs`

- [x] **Step 1: Reproduce the deferred-install escape**

Sparkle helpers remained alive after a ready reply was resolved with
`.dismiss`. A later manual check caused that deferred update to request
application termination even though no new install confirmation had been
accepted.

- [x] **Step 2: Confirm documented Sparkle semantics**

Sparkle documents `.dismiss` as deferring the ready update and permitting
installation when the application terminates independently. This does not
satisfy the product rule that every installation requires a fresh second
confirmation.

- [x] **Step 3: Make non-install paths explicit skips**

Use `.skip` for “稍后提醒”, a blocked NAS drain, pending-state persistence
failure, and a mismatched Sparkle item. Every such path clears the attempt gate
and requires a new manual update attempt before download or installation.

- [x] **Step 4: Add regression contracts and rerun all tests**

The focused gate tests, complete Swift suite, Windows suite, and release
contracts all pass. The final counts are 373/373 Swift, 456/456 Windows, and
60/60 release/deployment tests.

---

### Task 5: Isolated publication and pure manual update acceptance

**Files:**
- Publish only: Mac mini `/Users/Shared/codex-update-site/codex-session-keeper/testing`
- Preserve: Mac mini `/Users/Shared/codex-update-site/codex-session-keeper/stable`
- Preserve: `~/.codex`, NAS session files, and prior testing archives

**Interfaces:**
- Consumes: verified artifacts from Task 4
- Produces: a tested 1.0.99 → 1.1.0 manual macOS update

- [x] **Step 1: Exit the old app normally**

Cancel any open confirmation alert. Use the application’s normal Quit command. If the NAS warning appears, choose the normal product option; do not use Force Quit. Wait until `CodexSessionVault`, Sparkle `Updater`, and `Autoupdate` have exited.

- [x] **Step 2: Archive stale Sparkle cache recoverably**

Move, do not delete:

```bash
mv "$HOME/Library/Caches/local.codex.session-manager/org.sparkle-project.Sparkle" \
  "$HOME/Library/Caches/local.codex.session-manager/org.sparkle-project.Sparkle.pre-retry-fix-20260725"
```

Only run when the destination does not exist and all related processes are stopped.

- [x] **Step 3: Publish the rebuilt testing candidate atomically**

Build and verify a signed testing release directory:

```bash
CANDIDATE_PARENT="$(mktemp -d /tmp/codex-retry-release.XXXXXX)"
CANDIDATE_OUTPUT="$CANDIDATE_PARENT/output"
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip" \
  --windows-exe "$PWD/dist/windows/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "$PWD/dist/windows/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --output "$CANDIDATE_OUTPUT" \
  --server-scope testing

CANDIDATE="$CANDIDATE_OUTPUT/codex-session-keeper/testing"
node scripts/update/verify-release-directory.mjs --root "$CANDIDATE"
```

Transfer it through the configured long-lived SSH key, retain the previously published testing ZIP, and publish from a fresh remote staging directory:

```bash
REMOTE_STAGE="/Users/Shared/.codex-update-stage-retry.$(date +%Y%m%d%H%M%S)"
REMOTE_ARCHIVE="/Users/Shared/codex-update-site/.testing-artifact-archive-1.1.0-$(date +%Y%m%d%H%M%S)"
ssh codex-update-macmini \
  "mkdir -m 0775 -p '$REMOTE_STAGE/testing' '$REMOTE_STAGE/tooling/scripts/update' \
  '$REMOTE_STAGE/tooling/Config' '$REMOTE_ARCHIVE'"
rsync -a "$CANDIDATE/" "codex-update-macmini:$REMOTE_STAGE/testing/"
rsync -a \
  scripts/update/publish-release.sh \
  scripts/update/verify-release-directory.mjs \
  scripts/update/release-manifest.mjs \
  scripts/update/update-server.mjs \
  "codex-update-macmini:$REMOTE_STAGE/tooling/scripts/update/"
rsync -a \
  Config/UpdateKeys.json \
  Config/UpdateServer.json \
  Config/UpdateServer.testing.json \
  "codex-update-macmini:$REMOTE_STAGE/tooling/Config/"
ssh codex-update-macmini \
  "export PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'; \
  OLD_ZIP='/Users/Shared/codex-update-site/codex-session-keeper/testing/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip'; \
  ARCHIVED_ZIP='$REMOTE_ARCHIVE/CodexSessionKeeper-1.1.0-macos-arm64.zip'; \
  node '$REMOTE_STAGE/tooling/scripts/update/verify-release-directory.mjs' --root '$REMOTE_STAGE/testing'; \
  mv \"\$OLD_ZIP\" \"\$ARCHIVED_ZIP\"; \
  restore_old_zip() { test -e \"\$OLD_ZIP\" || mv \"\$ARCHIVED_ZIP\" \"\$OLD_ZIP\"; }; \
  trap restore_old_zip ERR; \
  '$REMOTE_STAGE/tooling/scripts/update/publish-release.sh' --candidate '$REMOTE_STAGE/testing' \
    '/Users/Shared/codex-update-site/codex-session-keeper/testing'; \
  trap - ERR"
```

Verify HTTP 200 for manifest/appcast/ZIP, POST 405, exact SHA-256, and unchanged `stable` and `index.html`.

- [x] **Step 4: Install and launch the new 1.0.99**

Archive the current application bundle, copy the verified 1.0.99 bundle into `/Applications`, verify signature/version/feed, then launch through Computer Use. Keep a one-second RSS monitor and allow the explicitly authorized NAS connection.

- [x] **Step 5: Verify the visible button and manual download**

Confirm the toolbar shows “检查更新”. Click it once, choose “立即更新”, then accept the native “确认下载” dialog once. Verify:

- one `download_confirmation_requested`;
- one `download_confirmed`;
- one `download_requested`;
- one `download_started`;
- no repeated confirmation loop.

- [x] **Step 6: Verify NAS-gated retry**

If NAS remains busy, accept the install confirmation and verify the app reports a safe cancellation. Confirm Sparkle `Updater` and `Autoupdate` exit, then use “检查更新” again and verify a new download can start.

- [x] **Step 7: Complete the manual installation**

When NAS is safely idle, repeat the two confirmations. Verify 1.1.0 launches, the toolbar remains visible, session counts remain unchanged, NAS backup resumes, the audit log contains download/install completion, and memory stays bounded.

- [x] **Step 8: Final repository and environment checks**

Run:

```bash
git status --short
git rev-parse HEAD
```

Record artifact hashes, testing HTTP hashes, memory summary, app version, session count, NAS state, retained archive paths, and any remaining temporary directories.

Final acceptance used the rebuilt `1eed207` artifacts. The testing channel
served the new macOS ZIP while the stable manifest and download page hashes
remained unchanged. The manual 1.0.99 → 1.1.0 flow recorded exactly one
ordered download/install audit chain, relaunched as 1.1.0 build 10100,
preserved 648/648 sessions, resumed a verified NAS backup, and stayed near
157–175 MB RSS during the post-update observation instead of reproducing OOM.
