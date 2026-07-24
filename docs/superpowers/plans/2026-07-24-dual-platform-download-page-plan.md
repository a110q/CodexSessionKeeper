# Dual-Platform Employee Download Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the already validated Windows installer and the candidate-validated macOS DMG through one read-only employee download page, then promote the matching macOS Sparkle release to stable.

**Architecture:** Keep `release.json` schema 1 unchanged so installed Windows and macOS clients remain compatible. Add a separately signed `downloads.json` for manual-install artifacts, teach the release verifier and atomic publisher to handle the macOS DMG, and render a script-free two-platform HTML page from the verified metadata. Stable publication happens only after the macOS candidate acceptance plan passes.

**Tech Stack:** Node.js built-in modules and test runner, Bash atomic publisher, static HTML/CSS, Homebrew Nginx, Ed25519 release-manifest key.

## Global Constraints

- This plan may start only after `docs/superpowers/plans/2026-07-24-macos-sparkle-validation-plan.md` passes in full.
- Keep signed `release.json` schema 1 byte-compatible with installed clients.
- Windows `1.1.0` Setup must retain SHA-256 `6A9C27A10EE9EDC3EBF59C83D4E5283F197DBAFAC7187B7832B147B55264A9A9`.
- macOS DMG must be the exact bytes accepted in the macOS candidate validation.
- Do not rebuild either version during stable promotion.
- Do not expose the Sparkle ZIP as the employee’s manual Mac download.
- Page output contains no JavaScript, form, upload, login, analytics, or external resource.
- Page and metadata are served only from the existing private IP and Nginx ACL.
- Do not operate the NAS.
- Never output or upload the release-manifest private key.
- Do not delete previous versioned installers.
- Versioned artifact filenames are immutable.

---

## File Map

Files created:

- `scripts/update/manual-downloads.mjs` — strict schema, canonical bytes, signing, and verification for manual download metadata.
- `scripts/update/manual-downloads.test.mjs` — schema, signature, path, and tamper tests.

Files modified:

- `scripts/update/build-release-manifest.mjs` — stage the verified macOS DMG and emit signed `downloads.json`.
- `scripts/update/release-manifest.test.mjs` — assembly regression tests for the new server-only metadata.
- `scripts/update/verify-release-directory.mjs` — verify `downloads.json`, its signature, the DMG hash, and release-version equality.
- `scripts/update/build-download-page.mjs` — render Windows and macOS cards from verified metadata.
- `scripts/update/build-download-page.test.mjs` — accessibility, escaping, paths, hashes, and Gatekeeper copy tests.
- `scripts/update/publish-release.sh` — atomically publish the DMG and signed manual-download metadata before the page.

---

### Task 1: Add a signed manual-download metadata format

**Files:**
- Create: `scripts/update/manual-downloads.mjs`
- Create: `scripts/update/manual-downloads.test.mjs`

**Interfaces:**
- `validateManualDownloads(value) -> frozen object`
- `manualDownloadBytes(value) -> Buffer`
- `signManualDownloads(bytes, privateKeyPem) -> base64 String`
- `verifyManualDownloads(bytes, signature, publicKeyBase64) -> object`

- [ ] **Step 1: Write failing schema and signature tests**

Create tests covering this exact valid object:

```javascript
const valid = {
  schemaVersion: 1,
  version: '1.1.0',
  platforms: {
    'macos-arm64': {
      url: 'macos/CodexSessionKeeper-1.1.0-macos-arm64.dmg',
      size: 2538054,
      sha256: 'a'.repeat(64),
    },
  },
};
```

Tests must assert:

```javascript
assert.deepEqual(validateManualDownloads(valid), valid);
assert.throws(
  () => validateManualDownloads({ ...valid, extra: true }),
  /unknown top level field extra/,
);
assert.throws(
  () => validateManualDownloads({
    ...valid,
    platforms: {
      'macos-arm64': {
        ...valid.platforms['macos-arm64'],
        url: 'https://outside.invalid/app.dmg',
      },
    },
  }),
  /safe relative URL/,
);
```

Generate an ephemeral Ed25519 key in the test. Sign canonical bytes, verify them,
then flip one byte and assert verification fails.

- [ ] **Step 2: Run the test and verify failure**

Run:

```bash
node --test scripts/update/manual-downloads.test.mjs
```

Expected: FAIL because `manual-downloads.mjs` does not exist.

- [ ] **Step 3: Implement strict validation and canonical signing**

The module must:

- accept only `schemaVersion`, `version`, and `platforms` at the top level;
- require `schemaVersion === 1`;
- require numeric `X.Y.Z` without leading zeroes;
- require exactly one platform key, `macos-arm64`;
- require exact artifact keys `url`, `size`, and `sha256`;
- require the exact relative pattern
  `macos/CodexSessionKeeper-<same-version>-macos-arm64.dmg`;
- require positive safe-integer size;
- require lowercase 64-character SHA-256;
- serialize as `JSON.stringify(validated) + "\n"`;
- use Node `crypto.sign(null, bytes, privateKey)` and
  `crypto.verify(null, bytes, publicKey, signature)`.

Return newly constructed frozen objects; do not return the caller’s mutable
object.

- [ ] **Step 4: Run focused tests**

Run:

```bash
node --test scripts/update/manual-downloads.test.mjs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add \
  scripts/update/manual-downloads.mjs \
  scripts/update/manual-downloads.test.mjs
git commit -m "feat: sign manual download metadata"
```

---

### Task 2: Include the macOS DMG in assembled and verified releases

**Files:**
- Modify: `scripts/update/build-release-manifest.mjs`
- Modify: `scripts/update/release-manifest.test.mjs`
- Modify: `scripts/update/verify-release-directory.mjs`

**Interfaces:**
- New assembly input and CLI flag: `macDmg` / `--mac-dmg`
- New release files:
  - `downloads.json`
  - `downloads.json.sig`
  - `macos/CodexSessionKeeper-<version>-macos-arm64.dmg`

- [ ] **Step 1: Extend the assembly test first**

In the existing assembly fixture, create:

```javascript
const macDmg = path.join(
  inputs,
  'CodexSessionKeeper-1.1.0-macos-arm64.dmg',
);
await writeFile(macDmg, 'mac disk image');
```

Pass `macDmg` to `assembleRelease()`, then assert:

```javascript
const downloadsBytes = await readFile(
  path.join(result.releaseRoot, 'downloads.json'),
);
const downloads = verifyManualDownloads(
  downloadsBytes,
  await readFile(path.join(result.releaseRoot, 'downloads.json.sig'), 'utf8'),
  manifestKey.publicKeyBase64,
);
assert.equal(downloads.version, '1.1.0');
assert.equal(
  downloads.platforms['macos-arm64'].url,
  'macos/CodexSessionKeeper-1.1.0-macos-arm64.dmg',
);
```

Add a verifier test that appends one byte to the staged DMG and expects
`verifyReleaseDirectory()` to reject with `manual download sha256 mismatch`.

- [ ] **Step 2: Run and verify failure**

Run:

```bash
node --test scripts/update/release-manifest.test.mjs
```

Expected: FAIL because `assembleRelease()` does not accept or stage a DMG.

- [ ] **Step 3: Stage and sign the DMG metadata**

Require an absolute regular `macDmg` input named:

```text
CodexSessionKeeper-<version>-macos-arm64.dmg
```

Copy it to `releaseRoot/macos`, compute its size and SHA-256, create canonical
manual-download bytes, sign them with the existing manifest Ed25519 private key,
and write both metadata files with exclusive creation:

```javascript
await writeFile(
  path.join(releaseRoot, 'downloads.json'),
  downloadsBytes,
  { flag: 'wx', mode: 0o644 },
);
await writeFile(
  path.join(releaseRoot, 'downloads.json.sig'),
  `${downloadsSignature}\n`,
  { flag: 'wx', mode: 0o644 },
);
```

- [ ] **Step 4: Verify manual metadata and DMG in the release verifier**

`verifyReleaseDirectory()` must:

1. verify `release.json` as before;
2. verify `downloads.json.sig` with the same manifest public key;
3. require `downloads.version === release.version`;
4. resolve the exact relative DMG path below the release root;
5. reject symlinks and non-regular files;
6. compare actual size and SHA-256.

Do not weaken or reorder existing Appcast, ZIP, Windows Setup, or `latest.yml`
checks.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
node --test \
  scripts/update/manual-downloads.test.mjs \
  scripts/update/release-manifest.test.mjs
node --test scripts/update/*.test.mjs
```

Expected: both commands exit `0`.

- [ ] **Step 6: Commit**

```bash
git add \
  scripts/update/build-release-manifest.mjs \
  scripts/update/release-manifest.test.mjs \
  scripts/update/verify-release-directory.mjs
git commit -m "feat: verify macOS manual release artifact"
```

---

### Task 3: Render an accessible dual-platform employee page

**Files:**
- Modify: `scripts/update/build-download-page.mjs`
- Modify: `scripts/update/build-download-page.test.mjs`

**Interfaces:**
- `renderDownloadPage(releaseManifest, manualDownloads) -> HTML String`
- `writeDownloadPage(stableRoot, output)` reads both signed-and-preverified JSON files

- [ ] **Step 1: Write the failing dual-platform page test**

Use a release manifest with the validated Windows artifact and a manual-download
object with the macOS DMG. Assert the rendered page contains:

```javascript
assert.match(html, /Windows 版/);
assert.match(html, /macOS 版/);
assert.match(
  html,
  /stable\/windows\/CodexSessionKeeper-1\.1\.0-windows-x64-Setup\.exe/,
);
assert.match(
  html,
  /stable\/macos\/CodexSessionKeeper-1\.1\.0-macos-arm64\.dmg/,
);
assert.match(html, /适用于 Apple 芯片（M 系列）/);
assert.match(html, /右键.*打开/);
assert.match(html, new RegExp('6a9c27a1', 'i'));
assert.doesNotMatch(html, /<script/i);
```

Also assert that HTML metacharacters in release notes are escaped and that
missing/mismatched macOS metadata throws.

- [ ] **Step 2: Run and verify failure**

Run:

```bash
node --test scripts/update/build-download-page.test.mjs
```

Expected: FAIL because the renderer currently accepts only the release manifest
and renders only Windows.

- [ ] **Step 3: Implement the two download cards**

The page must contain:

- title `codex_会话管理`;
- current version and publication date;
- release-note list;
- Windows card with Setup link, byte size, and SHA-256;
- macOS card with M-series label, DMG link, byte size, and SHA-256;
- first-open Gatekeeper instructions;
- internal-network-only notice.

Use semantic `<main>`, `<section>`, `<h1>`, `<h2>`, `<a>`, and `<code>`
elements. Keep all styling in the existing inline `<style>`. Use no script,
remote font, image, analytics, or network request.

- [ ] **Step 4: Read both metadata files**

`writeDownloadPage()` reads:

```text
<stableRoot>/release.json
<stableRoot>/downloads.json
```

It passes both parsed objects to the renderer. The release directory has already
been cryptographically verified by the publisher before this function runs.

- [ ] **Step 5: Run focused tests**

Run:

```bash
node --test scripts/update/build-download-page.test.mjs
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add \
  scripts/update/build-download-page.mjs \
  scripts/update/build-download-page.test.mjs
git commit -m "feat: add macOS to employee download page"
```

---

### Task 4: Atomically publish the DMG and metadata

**Files:**
- Modify: `scripts/update/publish-release.sh`
- Modify: `scripts/update/build-download-page.test.mjs`

**Interfaces:**
- Consumes a release root already accepted by `verify-release-directory.mjs`
- Publishes DMG and manual metadata before replacing the page

- [ ] **Step 1: Add publisher ordering tests**

Assert source-order relationships:

```javascript
const dmgIndex = source.indexOf(
  'publish_versioned_artifact "$INCOMING_ROOT/macos/CodexSessionKeeper-$VERSION-macos-arm64.dmg"',
);
const downloadsIndex = source.indexOf(
  'publish_metadata "$INCOMING_ROOT/downloads.json" "$DESTINATION_ROOT/downloads.json"',
);
const pageIndex = source.indexOf(
  'publish_metadata "$DOWNLOAD_PAGE" "$SITE_ROOT/index.html"',
);
assert.ok(dmgIndex >= 0);
assert.ok(downloadsIndex > dmgIndex);
assert.ok(pageIndex > downloadsIndex);
```

- [ ] **Step 2: Run and verify failure**

Run:

```bash
node --test scripts/update/build-download-page.test.mjs
```

Expected: FAIL because the publisher does not yet copy the DMG or downloads
metadata.

- [ ] **Step 3: Extend incoming staging**

Create incoming copies for:

```text
macos/CodexSessionKeeper-$VERSION-macos-arm64.dmg
downloads.json
downloads.json.sig
```

Run `fsync_file` on all three. Publish the DMG through
`publish_versioned_artifact`, preserving the existing rule that identical bytes
may be reused and different bytes under the same filename are rejected.

- [ ] **Step 4: Publish metadata and page in safe order**

Order:

1. ZIP, DMG, and Windows Setup versioned files;
2. Appcast and `latest.yml`;
3. `downloads.json.sig`;
4. `downloads.json`;
5. `release.json.sig`;
6. `release.json`;
7. generated `index.html`.

Candidate mode continues to skip step 7.

- [ ] **Step 5: Run all update tests**

Run:

```bash
node --test scripts/update/*.test.mjs
```

Expected: exit `0`.

- [ ] **Step 6: Commit**

```bash
git add \
  scripts/update/publish-release.sh \
  scripts/update/build-download-page.test.mjs
git commit -m "feat: atomically publish macOS downloads"
```

---

### Task 5: Assemble the immutable stable release

**Files:**
- Consume: candidate-accepted macOS `1.1.0` ZIP and DMG
- Consume: validated Windows `1.1.0` Setup and `latest.yml`
- Produce: a new local stable release tree

**Interfaces:**
- Stable assembly CLI includes `--mac-dmg` and `--server-scope stable`

- [ ] **Step 1: Re-run the complete source tests**

Run:

```bash
swift test
node --test scripts/update/*.test.mjs
git status --short
```

Expected: all tests pass and status is clean.

- [ ] **Step 2: Compare candidate-accepted Mac hashes**

Run `shasum -a 256` on the ZIP and DMG selected for stable assembly.

Expected: both exactly match the acceptance record. Stop on any mismatch; do
not rebuild.

- [ ] **Step 3: Confirm Windows identity**

Expected Setup:

```text
104653535 bytes
6A9C27A10EE9EDC3EBF59C83D4E5283F197DBAFAC7187B7832B147B55264A9A9
```

Confirm `latest.yml` version, URL, size, and SHA-512 still describe that Setup.

- [ ] **Step 4: Assemble into a fresh temporary directory**

Run:

```bash
STABLE_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/codex-stable-release.XXXXXX")"
STABLE_OUTPUT="$STABLE_PARENT/release"
MAC_ZIP="$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.zip"
MAC_DMG="$PWD/dist/macos/CodexSessionKeeper-1.1.0-macos-arm64.dmg"
test ! -e "$STABLE_OUTPUT"
test -f "$MAC_ZIP"
test -f "$MAC_DMG"
node scripts/update/build-release-manifest.mjs \
  --version 1.1.0 \
  --build 10100 \
  --mac-zip "$MAC_ZIP" \
  --mac-dmg "$MAC_DMG" \
  --windows-exe "/Users/mqzj/Downloads/CodexSessionKeeper-Windows-builds-01c27be-20260723-105726/CodexSessionKeeper-1.1.0-windows-x64-Setup.exe" \
  --windows-yml "/Users/mqzj/Downloads/CodexSessionKeeper-Windows-builds-01c27be-20260723-105726/latest.yml" \
  --notes-file "$PWD/release-notes/1.1.0.json" \
  --server-scope stable \
  --output "$STABLE_OUTPUT"
```

Expected: verifier reports version `1.1.0`, build `10100`, and success.

- [ ] **Step 5: Render and inspect the page locally**

Run:

```bash
node scripts/update/build-download-page.mjs \
  --stable-root "$STABLE_OUTPUT/codex-session-keeper/stable" \
  --output "$STABLE_OUTPUT/index.html"
```

Expected: output contains both exact download links and both hashes, contains no
`<script>`, and has no external URLs.

---

### Task 6: Promote stable and perform final regression

**Files:**
- Remote stable root: `/Users/Shared/codex-update-site/codex-session-keeper/stable`
- Remote employee page: `/Users/Shared/codex-update-site/codex-session-keeper/index.html`

**Interfaces:**
- Consumes the verified stable tree from Task 5
- Produces the employee URL:
  `http://192.168.10.54:18080/codex-session-keeper/`

- [ ] **Step 1: Snapshot current remote stable hashes**

Read and record hashes for:

- `release.json` and signature;
- Windows `latest.yml` and Setup;
- existing Appcast and Mac ZIP, if present;
- existing employee `index.html`.

Do not modify files during this step.

- [ ] **Step 2: Transfer to a remote temporary directory**

Use the bounded SSH control socket. Compare all transferred hashes with the
local verified tree before publication.

Expected: exact match.

- [ ] **Step 3: Run the atomic stable publisher**

Run on the Mac mini:

```bash
./publish-release.sh \
  /absolute/remote/verified/codex-session-keeper/stable \
  /Users/Shared/codex-update-site/codex-session-keeper/stable
```

Expected: `published 1.1.0`; no versioned filename collision with different
bytes.

- [ ] **Step 4: Validate the employee page from another LAN computer**

Open:

```text
http://192.168.10.54:18080/codex-session-keeper/
```

Expected:

- Windows and macOS cards are visible;
- Windows download returns the validated Setup;
- macOS download returns the accepted DMG;
- displayed version, sizes, and hashes match;
- page works without Internet access.

- [ ] **Step 5: Regress application update endpoints**

Expected:

```text
stable/release.json → 200
stable/release.json.sig → 200
stable/windows/latest.yml → 200
stable Windows Setup HEAD → 200
stable/macos/appcast.xml → 200
stable macOS ZIP HEAD → 200
stable macOS DMG HEAD → 200
POST to each metadata endpoint → 405
```

- [ ] **Step 6: Re-run both application checks**

- Windows `1.1.0` reports up to date.
- macOS `1.1.0` reports up to date.
- Neither check downloads an installer.
- Nginx logs show only expected GET/HEAD traffic.

- [ ] **Step 7: Final source and safety verification**

Run:

```bash
swift test
node --test scripts/update/*.test.mjs
git status --short
```

Expected: tests pass, source tree is clean, NAS was not accessed, and no old
versioned artifact was deleted.
