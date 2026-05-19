# Desktop UI Modernization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh the macOS desktop UI into a lighter, more modern product experience while fixing cramped bulk-action controls, weak split dragging, and the auto-restore default state.

**Architecture:** Keep the existing SwiftUI screen structure and business logic, but introduce a small set of reusable visual containers plus a reusable resizable split view. Rework top-level layout and per-page toolbars in place instead of rewriting the app structure.

**Tech Stack:** Swift 6, SwiftUI, macOS 14

---

### Task 1: Refresh top-level shell and sidebar styling

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Restyle `ContentView` top bar into a lighter control strip with compact segmented navigation and a subdued auto-restore setting card.
- [ ] Keep `autoRestoreOnLaunch` default off and ensure the setting remains visually secondary.
- [ ] Restyle `AppSidebar` and `CurrentStateCard` to feel lighter and more product-like without changing navigation behavior.

### Task 2: Rework list toolbars to avoid compression

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Split session-page controls into separate search/filter and bulk-action rows.
- [ ] Split snapshot-page controls into separate creation/filter and bulk-action rows.
- [ ] Ensure destructive bulk buttons have a fixed readable width and only appear when relevant.

### Task 3: Replace hard-to-drag split boundaries

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Introduce a reusable SwiftUI split container with a wider drag hit area and subtle visual affordance.
- [ ] Migrate `SessionsPane` and `SnapshotPane` from `HSplitView` to the reusable split container.
- [ ] Clamp pane widths so resizing remains stable across common window sizes.

### Task 4: Lighten cards and detail surfaces

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Update primary cards, detail cards, metric cards, status bar, and row selection surfaces to the lighter “young tech” style.
- [ ] Preserve hierarchy: recommended actions first, risky actions clearly separated.

### Task 5: Verify and package

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Run `swift build` and fix any compile issues.
- [ ] Rebuild the macOS app with `./scripts/build_app.sh`.
- [ ] Verify the packaged app with `codesign --verify --deep --strict dist/codex_会话管理.app`.
