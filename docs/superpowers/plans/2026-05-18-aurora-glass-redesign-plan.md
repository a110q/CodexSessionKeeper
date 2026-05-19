# Aurora Glass Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-theme the macOS desktop app into a brighter Aurora Glass / Spark product UI with a clearly different color system and stronger modern product feel.

**Architecture:** Keep the existing SwiftUI screen structure and workflows, but replace the current “light modern” surface system with a more opinionated Aurora Glass design language. Update shell background, navigation styling, toolbar styling, list rows, cards, and action hierarchy in-place so the redesign ships as a cohesive visual system rather than isolated tweaks.

**Tech Stack:** Swift 6, SwiftUI, macOS 14

---

### Task 1: Re-theme the app shell

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Replace the neutral app chrome with an Aurora Glass shell background and refined top bar styling.
- [ ] Restyle the top settings cluster so it fits the new Spark direction without dominating the page.
- [ ] Re-theme the sidebar into a product-grade aurora navigation panel.

### Task 2: Rebuild the surface system

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Update reusable cards (`CurrentStateCard`, `PrimaryActionCard`, `DetailCard`, `MetricCard`, `DangerZoneCard`, `CountBadge`, `StatusBar`) to a unified glass + electric blue visual language.
- [ ] Ensure the new palette distinguishes primary, secondary, and danger actions clearly.

### Task 3: Re-theme list areas and selections

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Rework session rows, snapshot rows, and snapshot session pick rows into brighter glass cards with stronger selected states.
- [ ] Preserve readability and avoid reintroducing truncated action buttons.

### Task 4: Polish split views and key interactions

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Update split dividers and section spacing to better match the redesigned shell.
- [ ] Keep drag affordance easy to discover while making it visually lighter and more premium.

### Task 5: Verify and package

**Files:**
- Modify: `/Users/awk/awk/codex_project/codex_huihuaguanli/Sources/CodexSessionVault/main.swift`

- [ ] Run `swift build` and fix any compile issues.
- [ ] Rebuild the macOS app with `./scripts/build_app.sh`.
- [ ] Verify the package with `codesign --verify --deep --strict dist/codex_会话管理.app`.
