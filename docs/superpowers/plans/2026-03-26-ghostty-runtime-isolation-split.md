# Ghostty Runtime Isolation Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the Ghostty runtime wrapper by isolation contract so C callback trampolines, app handle ownership, action routing, and focus synchronization no longer live in one mixed-responsibility type.

**Architecture:** Extract the current `Ghostty.App` responsibilities into four focused types: `GhosttyAppHandle`, `GhosttyCallbackRouter`, `GhosttyActionRouter`, and `GhosttyFocusSynchronizer`. Callback trampolines remain nonisolated and capture only stable identity before hopping to `@MainActor`; lifecycle and action routing remain `@MainActor`. This is a post-host-cutover cleanup and should not change pane host or mount semantics.

**Tech Stack:** Swift 6.2, AppKit, Ghostty/libghostty, Swift Testing, mise, swift-format, swiftlint

---

## Preconditions

This follow-up starts only after the universal `PaneHostView` / `TerminalPaneMountView` / `GhosttyMountView` cutover has landed and passed full verification. Do not interleave the two plans.

## Hard-Cutover Rules

1. No compatibility wrapper that keeps the old mixed `Ghostty.App` shape alive.
2. No plain `nonisolated async` methods used as fake background boundaries.
3. No `Task.detached` unless intentionally escaping structured concurrency is required and documented inline.
4. Tests should verify observable routing behavior and compile-safe structure, not runtime "is main actor" helper flags.

## File Structure Map

### New files

- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyAppHandle.swift`
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyCallbackRouter.swift`
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionRouter.swift`
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyFocusSynchronizer.swift`

### Existing files to modify

- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift`
- Modify: `docs/architecture/ghostty_surface_architecture.md`
- Modify: `docs/architecture/appkit_swiftui_architecture.md`
- Modify: `AGENTS.md`

### Test files

- Create: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyAppHandleTests.swift`
- Create: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyCallbackRouterTests.swift`
- Create: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyActionRouterTests.swift`
- Create: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyFocusSynchronizerTests.swift`
- Modify: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyAdapterTests.swift`

---

### Task 1: Extract App Handle Ownership

**Files:**
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyAppHandle.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift`
- Test: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyAppHandleTests.swift`

- [ ] **Step 1: Write failing tests for app handle ownership**

```swift
@Test
func appHandle_initializesGhosttyAppAndExposesTick() {
    let handle = try #require(GhosttyAppHandle.forTesting())
    #expect(handle.hasLiveAppForTesting == true)
}

@Test
func appHandle_exposesStableUserdataPointer() {
    let handle = try #require(GhosttyAppHandle.forTesting())
    #expect(handle.userdataPointerForTesting != nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `SWIFT_BUILD_DIR=".build-agent-$(uuidgen | tr -dc 'a-z0-9' | head -c 8)" swift test --build-path "$SWIFT_BUILD_DIR" --filter "GhosttyAppHandleTests"`
Expected: FAIL with missing type errors.

- [ ] **Step 3: Implement `GhosttyAppHandle`**

Required behavior:

- own `ghostty_app_t`
- own config lifetime
- expose `tick()`
- expose stable userdata for callback router composition
- keep lifetime ownership separate from action routing and lifecycle observation

- [ ] **Step 4: Rewire `Ghostty.swift` to compose `GhosttyAppHandle`**

Required behavior:

- `Ghostty.swift` no longer stores raw app/config ownership directly in the mixed type
- app creation / freeing route through `GhosttyAppHandle`

- [ ] **Step 5: Run focused tests**

Run: `SWIFT_BUILD_DIR=".build-agent-$(uuidgen | tr -dc 'a-z0-9' | head -c 8)" swift test --build-path "$SWIFT_BUILD_DIR" --filter "GhosttyAppHandleTests"`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyAppHandle.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift \
  Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyAppHandleTests.swift
git commit -m "refactor: extract ghostty app handle ownership"
```

---

### Task 2: Extract Callback And Main-Actor Routers

**Files:**
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyCallbackRouter.swift`
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionRouter.swift`
- Create: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyFocusSynchronizer.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift`
- Modify: `Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift`
- Test: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyCallbackRouterTests.swift`
- Test: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyActionRouterTests.swift`
- Test: `Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyFocusSynchronizerTests.swift`

- [ ] **Step 1: Write failing routing tests**

```swift
@Test
@MainActor
func actionRouter_routesKnownActionToTerminalRuntime() {
    let harness = makeGhosttyActionRoutingHarness()
    harness.deliverTitleChangedAction()
    #expect(harness.routedEvent == .setTitle("demo"))
}

@Test
@MainActor
func focusSynchronizer_pushesLifecycleFocusChangesToGhostty() {
    let harness = makeGhosttyFocusHarness()
    harness.setApplicationActive(false)
    #expect(harness.lastFocusedValue == false)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `SWIFT_BUILD_DIR=".build-agent-$(uuidgen | tr -dc 'a-z0-9' | head -c 8)" swift test --build-path "$SWIFT_BUILD_DIR" --filter "GhosttyCallbackRouterTests|GhosttyActionRouterTests|GhosttyFocusSynchronizerTests"`
Expected: FAIL with missing type errors.

- [ ] **Step 3: Implement `GhosttyCallbackRouter`**

Required behavior:

- own C callback statics
- reconstruct Swift objects from userdata
- capture only stable identity before hopping to `@MainActor`
- remain nonisolated

- [ ] **Step 4: Implement `GhosttyActionRouter`**

Required behavior:

- own main-actor action routing currently mixed into `Ghostty.swift`
- keep exhaustive action-tag handling
- route into `SurfaceManager`, `RuntimeRegistry`, and terminal runtime code

- [ ] **Step 5: Implement `GhosttyFocusSynchronizer`**

Required behavior:

- observe app lifecycle state
- call `ghostty_app_set_focus`
- keep focus synchronization isolated from callback/router code

- [ ] **Step 6: Recompose `Ghostty.swift` around the new types**

Required behavior:

- `Ghostty.swift` becomes the thin composition root for the handle/router/synchronizer pieces
- no mixed type remains that owns callbacks and lifecycle sync in one place

- [ ] **Step 7: Run focused tests**

Run: `SWIFT_BUILD_DIR=".build-agent-$(uuidgen | tr -dc 'a-z0-9' | head -c 8)" swift test --build-path "$SWIFT_BUILD_DIR" --filter "GhosttyCallbackRouterTests|GhosttyActionRouterTests|GhosttyFocusSynchronizerTests|GhosttyAdapterTests"`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyCallbackRouter.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyActionRouter.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/GhosttyFocusSynchronizer.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/Ghostty.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/GhosttySurfaceView.swift \
  Sources/AgentStudio/Features/Terminal/Ghostty/SurfaceManager.swift \
  Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyCallbackRouterTests.swift \
  Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyActionRouterTests.swift \
  Tests/AgentStudioTests/Features/Terminal/Ghostty/GhosttyFocusSynchronizerTests.swift
git commit -m "refactor: split ghostty callbacks and lifecycle routing"
```

---

### Task 3: Docs And Verification

**Files:**
- Modify: `docs/architecture/ghostty_surface_architecture.md`
- Modify: `docs/architecture/appkit_swiftui_architecture.md`
- Modify: `AGENTS.md`
- All files modified in Tasks 1-2

- [ ] **Step 1: Update docs for the new Ghostty runtime structure**

Required doc outcomes:

- document `GhosttyAppHandle`, `GhosttyCallbackRouter`, `GhosttyActionRouter`, and `GhosttyFocusSynchronizer`
- describe nonisolated callback trampolines vs `@MainActor` routing
- keep Swift 6.2 concurrency guidance aligned with the code

- [ ] **Step 2: Run focused tests**

Run: `SWIFT_BUILD_DIR=".build-agent-$(uuidgen | tr -dc 'a-z0-9' | head -c 8)" swift test --build-path "$SWIFT_BUILD_DIR" --filter "GhosttyAppHandleTests|GhosttyCallbackRouterTests|GhosttyActionRouterTests|GhosttyFocusSynchronizerTests|GhosttyAdapterTests"`
Expected: PASS

- [ ] **Step 3: Run full test suite and lint**

Run:

```bash
AGENT_RUN_ID=ghostty-runtime-split mise run test
AGENT_RUN_ID=ghostty-runtime-split mise run lint
```

Expected: PASS, zero failures, zero lint errors.

- [ ] **Step 4: Commit**

```bash
git add docs/architecture/ghostty_surface_architecture.md \
  docs/architecture/appkit_swiftui_architecture.md \
  AGENTS.md
git commit -m "docs: update ghostty runtime isolation architecture"
```

---

## Notes For The Implementer

- This follow-up should happen immediately after the host/mount cutover, not in the same changeset.
- Prefer compile-time-safe structure and observable behavior over runtime actor-isolation helper tests.
- Keep callback trampolines tiny and deterministic.
- Do not let this plan reopen any host/mount or placeholder design decisions from the previous plan.
