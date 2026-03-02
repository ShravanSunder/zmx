# Persistent WatchedPath Folder Watching — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** "Add Folder" persists the folder path. FilesystemActor watches it with FSEvents and rescans for new repos automatically — so cloning a repo under a watched folder appears in the sidebar within seconds.

**Architecture:** A `WatchedPath` model is persisted in `workspace.state.json` via `WorkspaceStore`. When watched paths change (Add Folder or boot), `FilesystemActor` registers each parent folder with `DarwinFSEventStreamClient` for FSEvents monitoring. When FSEvents fires (new `.git` directory appears), FilesystemActor rescans using `RepoScanner` and emits `.repoDiscovered` on the `EventBus`. The existing idempotent `WorkspaceCacheCoordinator` handles dedup. A lazy fallback timer (5 minutes) rescans for robustness. No UI changes — the only entry point is the existing "Add Folder" menu item.

**Tech Stack:** Swift 6, @Observable stores, DarwinFSEventStreamClient (FSEvents), AsyncStream (RuntimeEventBus), Swift Testing framework

---

## Context for the Implementing Agent

### Key Files to Read First

1. **CLAUDE.md** — State management patterns (especially patterns 2 and 4). Store boundaries are architectural decisions — ask the user before changing them.
2. **[Event System Design](docs/architecture/workspace_data_architecture.md#event-system-design-what-it-is-and-isnt)** — This is NOT CQRS. Pattern: mutate store directly → emit fact on bus → coordinator updates other store.
3. **`Sources/AgentStudio/Core/PaneRuntime/Sources/DarwinFSEventStreamClient.swift`** — Production FSEvents client. Registers paths, creates `FSEventStream` with `kFSEventStreamCreateFlagFileEvents`, pumps `FSEventBatch` through `AsyncStream`. You will reuse this for parent folder watching.
4. **`Sources/AgentStudio/Core/PaneRuntime/Sources/FilesystemActor.swift`** — Currently registers worktree roots with `DarwinFSEventStreamClient`. You will extend it to also register parent folders. Key: `register(worktreeId:, repoId:, rootPath:)` creates one FSEvent stream per path.
5. **`Sources/AgentStudio/Infrastructure/RepoScanner.swift`** — Centralized scanner: `scanForGitRepos(in:maxDepth:)`. Walks filesystem, stops at `.git` boundary, skips submodules. All scanning MUST go through this — no ad-hoc `.git` detection.
6. **`Sources/AgentStudio/App/AppDelegate.swift`** — `handleAddFolderRequested()` (line ~823) uses `RepoScanner`. `addRepoIfNeeded()` (line ~860) emits `.repoDiscovered`. `replayBootTopology()` (line ~244) replays events on boot.
7. **`Sources/AgentStudio/App/WorkspaceCacheCoordinator.swift`** — Uses `scopeSyncHandler` closure (not direct actor references) to communicate with `FilesystemGitPipeline`. Init: `bus`, `workspaceStore`, `repoCache`, `scopeSyncHandler`.
8. **`Sources/AgentStudio/App/FilesystemGitPipeline.swift`** — Composition root. `applyScopeChange()` forwards `ScopeChange` to actors.

### Dependency Wiring Pattern

The coordinator does NOT hold direct actor references. It uses a `scopeSyncHandler` closure:

```swift
// AppDelegate wires:
scopeSyncHandler: { [weak pipeline] change in
    guard let pipeline else { return }
    await pipeline.applyScopeChange(change)
}
```

Extend `ScopeChange` enum → extend `applyScopeChange()` → call `FilesystemActor`. Never add direct actor references to the coordinator.

### Build & Test

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run build    # timeout 60s
AGENT_RUN_ID=watch-$(date +%s) mise run test     # timeout 120s
AGENT_RUN_ID=watch-$(date +%s) mise run lint
```

**Never run two swift commands in parallel.** SwiftPM holds an exclusive lock. Always sequential.

---

### Task 1: WatchedPath Model + RepoScanner Constant

**Files:**
- Create: `Sources/AgentStudio/Core/Models/WatchedPath.swift`
- Modify: `Sources/AgentStudio/Infrastructure/RepoScanner.swift`
- Test: `Tests/AgentStudioTests/Core/Models/WatchedPathTests.swift`

**Step 1: Add maxDepth constant to RepoScanner**

Currently `maxDepth: 3` is scattered across call sites. Centralize it:

```swift
// RepoScanner.swift — add at top of struct
struct RepoScanner {
    /// Default scan depth for parent folder discovery.
    /// Depth 4 supports layouts like ~/projects/org/suborg/repo/.git
    /// Scanning stops at the first .git boundary (no deeper).
    static let defaultMaxDepth = 4

    func scanForGitRepos(in rootURL: URL, maxDepth: Int = Self.defaultMaxDepth) -> [URL] {
        // ... existing implementation unchanged
    }
}
```

Change default from 3 to 4. The scanner already stops at `.git` — increasing depth just allows deeper folder nesting before the first repo.

**Step 2: Create WatchedPath model**

```swift
// Sources/AgentStudio/Core/Models/WatchedPath.swift
import Foundation

/// A user-added folder path persisted in workspace.state.json.
/// FilesystemActor watches this path with FSEvents and rescans for new repos.
struct WatchedPath: Codable, Identifiable, Hashable {
    let id: UUID
    var path: URL
    var addedAt: Date

    var stableKey: String { StableKey.fromPath(path) }

    init(id: UUID = UUID(), path: URL, addedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.addedAt = addedAt
    }
}
```

No `kind` enum — all watched paths are parent folders. Direct repo adds use the existing `addRepoIfNeeded()` flow and don't need a WatchedPath.

**Step 3: Write tests**

```swift
// Tests/AgentStudioTests/Core/Models/WatchedPathTests.swift
import Testing
@testable import AgentStudio

@Suite struct WatchedPathTests {
    @Test func stableKey_isDeterministic() {
        let a = WatchedPath(path: URL(fileURLWithPath: "/projects"))
        let b = WatchedPath(path: URL(fileURLWithPath: "/projects"))
        #expect(a.stableKey == b.stableKey)
    }

    @Test func stableKey_differentPaths_differ() {
        let a = WatchedPath(path: URL(fileURLWithPath: "/projects"))
        let b = WatchedPath(path: URL(fileURLWithPath: "/other"))
        #expect(a.stableKey != b.stableKey)
    }

    @Test func codable_roundTrips() throws {
        let original = WatchedPath(path: URL(fileURLWithPath: "/projects"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WatchedPath.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.path == original.path)
    }
}
```

**Step 4: Update all existing `maxDepth: 3` call sites to use `RepoScanner.defaultMaxDepth`**

Search for `maxDepth: 3` across the codebase. Replace with `RepoScanner.defaultMaxDepth` or remove the parameter (since 4 is now the default).

**Step 5: Verify**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run build
```

**Step 6: Commit**

```bash
git add -A
git commit -m "feat: add WatchedPath model, centralize RepoScanner.defaultMaxDepth to 4"
```

---

### Task 2: WatchedPath in WorkspaceStore + Persistence

**Files:**
- Modify: `Sources/AgentStudio/Core/Stores/WorkspaceStore.swift`
- Modify: `Sources/AgentStudio/Core/Stores/WorkspacePersistor.swift`
- Test: `Tests/AgentStudioTests/Core/Stores/WorkspaceStoreTests.swift`

**Step 1: Add watchedPaths to WorkspaceStore**

```swift
private(set) var watchedPaths: [WatchedPath] = []

/// Add a watched path. Deduplicates by stableKey.
@discardableResult
func addWatchedPath(_ path: URL) -> WatchedPath? {
    let normalizedPath = path.standardizedFileURL
    let key = StableKey.fromPath(normalizedPath)
    guard !watchedPaths.contains(where: { $0.stableKey == key }) else {
        return watchedPaths.first { $0.stableKey == key }
    }
    let wp = WatchedPath(path: normalizedPath)
    watchedPaths.append(wp)
    markDirty()
    return wp
}

func removeWatchedPath(_ id: UUID) {
    watchedPaths.removeAll { $0.id == id }
    markDirty()
}
```

**Step 2: Add to PersistableState**

In `WorkspacePersistor.swift`:
- Add `var watchedPaths: [WatchedPath]` to `PersistableState`
- Add to init with default `[]`
- Add to CodingKeys
- In `init(from decoder:)`: `watchedPaths = try container.decodeIfPresent([WatchedPath].self, forKey: .watchedPaths) ?? []`

This `decodeIfPresent ?? []` is schema evolution — old files lack the field. Not backward compat ceremony.

In `WorkspaceStore`:
- Add `watchedPaths: watchedPaths` to `buildPersistableState()`
- Add `self.watchedPaths = state.watchedPaths` to `restore()`

**Step 3: Write tests**

```swift
@Test func addWatchedPath_deduplicatesByStableKey() {
    let store = WorkspaceStore()
    store.addWatchedPath(URL(fileURLWithPath: "/projects"))
    store.addWatchedPath(URL(fileURLWithPath: "/projects"))
    #expect(store.watchedPaths.count == 1)
}

@Test func removeWatchedPath_removesById() {
    let store = WorkspaceStore()
    let wp = store.addWatchedPath(URL(fileURLWithPath: "/projects"))!
    store.removeWatchedPath(wp.id)
    #expect(store.watchedPaths.isEmpty)
}
```

**Step 4: Verify**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run build
AGENT_RUN_ID=watch-$(date +%s) mise run test
```

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: persist watchedPaths in WorkspaceStore and workspace.state.json"
```

---

### Task 3: Extend ScopeChange + FilesystemActor FSEvents Registration

This is the core task. FilesystemActor gains FSEvents-based parent folder watching.

**Files:**
- Modify: `Sources/AgentStudio/App/WorkspaceCacheCoordinator.swift` — extend `ScopeChange`
- Modify: `Sources/AgentStudio/App/FilesystemGitPipeline.swift` — forward new scope change
- Modify: `Sources/AgentStudio/Core/PaneRuntime/Sources/FilesystemActor.swift` — add parent folder FSEvents + rescan

**Step 1: Read FilesystemActor fully**

Understand how `register()` creates FSEvent streams via `fseventStreamClient.register()`. How the ingress task processes `FSEventBatch`. How `ingestRawPaths()` filters and batches changes. You're adding a parallel path for parent folders.

**Step 2: Add ScopeChange case**

```swift
enum ScopeChange: Sendable {
    case registerForgeRepo(repoId: UUID, remote: String)
    case unregisterForgeRepo(repoId: UUID)
    case refreshForgeRepo(repoId: UUID, correlationId: UUID?)
    case updateWatchedFolders(paths: [URL])  // NEW
}
```

Update the `CustomStringConvertible` extension.

**Step 3: Add parent folder tracking to FilesystemActor**

Key design: parent folder FSEvent registrations are keyed by a synthetic UUID (derived from folder stableKey, NOT a real worktreeId). When FSEvents fires under a parent folder, the actor runs `RepoScanner` on that folder and emits `.repoDiscovered` for each repo found. The existing idempotent coordinator handles dedup.

```swift
// New state in FilesystemActor
private var watchedFolderIds: [URL: UUID] = [:]  // folder path → synthetic registration UUID
private var fallbackRescanTask: Task<Void, Never>?

func updateWatchedFolders(_ paths: [URL]) async {
    let newPaths = Set(paths.map { $0.standardizedFileURL })
    let oldPaths = Set(watchedFolderIds.keys)

    // Unregister removed folders
    for removed in oldPaths.subtracting(newPaths) {
        if let syntheticId = watchedFolderIds.removeValue(forKey: removed) {
            fseventStreamClient.unregister(worktreeId: syntheticId)
        }
    }

    // Register new folders
    for added in newPaths.subtracting(oldPaths) {
        let syntheticId = UUID()
        watchedFolderIds[added] = syntheticId
        fseventStreamClient.register(worktreeId: syntheticId, repoId: syntheticId, rootPath: added)
    }

    // Immediate scan of all watched folders
    await rescanAllWatchedFolders()

    // Fallback periodic rescan (5 minutes) for robustness
    startFallbackRescan()
}
```

**Step 4: Handle FSEvents from parent folders**

The existing ingress task receives `FSEventBatch` with a `worktreeId`. For parent folder batches, the worktreeId will be the synthetic UUID. Detect this and trigger a rescan instead of the normal worktree-level processing:

```swift
// In the ingress processing loop, check if the batch is from a parent folder
private func isWatchedFolderBatch(_ worktreeId: UUID) -> Bool {
    watchedFolderIds.values.contains(worktreeId)
}
```

When a batch arrives from a watched folder, filter for `.git` path changes (e.g., path contains `/.git`). If found, rescan that specific watched folder using `RepoScanner`.

**Step 5: Implement rescan + event emission**

```swift
private func rescanAllWatchedFolders() async {
    let scanner = RepoScanner()
    for (folderPath, _) in watchedFolderIds {
        let repoPaths = scanner.scanForGitRepos(in: folderPath)
        for repoPath in repoPaths {
            await emitRepoDiscovered(repoPath: repoPath, parentPath: folderPath)
        }
    }
}

private func emitRepoDiscovered(repoPath: URL, parentPath: URL) async {
    let envelope = RuntimeEnvelope.system(
        SystemEnvelope(
            source: .builtin(.filesystemWatcher),
            seq: nextSystemSeq(),
            timestamp: envelopeClock.now,
            event: .topology(.repoDiscovered(repoPath: repoPath, parentPath: parentPath))
        )
    )
    await runtimeBus.post(envelope)
}
```

Use the actor's existing monotonic sequence counter pattern (`nextSystemSeq()` or equivalent). Do NOT hardcode `seq: 0`. Read how the actor generates seq numbers for its other events and follow the same pattern.

`RepoScanner.scanForGitRepos()` is blocking I/O. Since `FilesystemActor` is an `actor`, this runs on its serial executor. If performance is a concern, wrap in `@concurrent nonisolated` per project conventions. But for an initial implementation, the actor's executor is fine.

**Step 6: Fallback timer**

```swift
private func startFallbackRescan() {
    fallbackRescanTask?.cancel()
    guard !watchedFolderIds.isEmpty else { return }
    fallbackRescanTask = Task { [weak self] in
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(300))  // 5 minutes
            guard !Task.isCancelled else { break }
            await self?.rescanAllWatchedFolders()
        }
    }
}
```

Cancel `fallbackRescanTask` in `shutdown()`.

**Step 7: Wire FilesystemGitPipeline**

In `FilesystemGitPipeline.applyScopeChange()`:

```swift
case .updateWatchedFolders(let paths):
    await filesystemActor.updateWatchedFolders(paths)
```

**Step 8: Verify**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run build
```

**Step 9: Commit**

```bash
git add -A
git commit -m "feat: FSEvents-based parent folder watching in FilesystemActor"
```

---

### Task 4: Wire AppDelegate — Add Folder Persists + Triggers Watch

**Files:**
- Modify: `Sources/AgentStudio/App/AppDelegate.swift`

**Step 1: Modify handleAddFolderRequested**

Add `store.addWatchedPath(rootURL)` before the existing scan. Then trigger scope sync so FilesystemActor starts watching:

```swift
private func handleAddFolderRequested(startingAt initialURL: URL? = nil) async {
    // ... existing NSOpenPanel code unchanged ...

    // 1. Persist the watched path (direct store mutation)
    store.addWatchedPath(rootURL)

    // 2. Tell FilesystemActor to start watching (via scopeSyncHandler)
    await workspaceCacheCoordinator.syncScope(
        .updateWatchedFolders(paths: store.watchedPaths.map(\.path))
    )

    // 3. Existing one-shot scan for immediate feedback (kept for responsiveness)
    let repoPaths = await Task(priority: .userInitiated) {
        RepoScanner().scanForGitRepos(in: rootURL)
    }.value

    guard !repoPaths.isEmpty else {
        let alert = NSAlert()
        alert.messageText = "No Git Repositories Found"
        alert.informativeText = "No folders with a Git repository were found under \(rootURL.lastPathComponent). The folder will still be watched for future repos."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return
    }

    for repoPath in repoPaths {
        postAppEvent(.addRepoAtPathRequested(path: repoPath.standardizedFileURL))
    }
}
```

Note: Step 3 is the existing scan — kept because it provides immediate results. The FSEvents watch (step 2) handles future discoveries.

**Step 2: Sync watched folders on boot**

At the end of `replayBootTopology()`:

```swift
if !store.watchedPaths.isEmpty {
    await coordinator.syncScope(
        .updateWatchedFolders(paths: store.watchedPaths.map(\.path))
    )
}
```

**Step 3: Remove hardcoded maxDepth: 3 from handleAddFolderRequested**

The call `RepoScanner().scanForGitRepos(in: rootURL, maxDepth: 3)` should become `RepoScanner().scanForGitRepos(in: rootURL)` — using the new default of 4.

**Step 4: Verify**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run build
```

**Step 5: Commit**

```bash
git add Sources/AgentStudio/App/AppDelegate.swift
git commit -m "feat: Add Folder persists WatchedPath and triggers FSEvents watch on boot"
```

---

### Task 5: Tests

**Files:**
- Modify: `Tests/AgentStudioTests/App/WorkspaceCacheCoordinatorTests.swift`

**Step 1: Test scope change forwarding**

```swift
@Test func updateWatchedFolders_scopeChangeForwarded() async {
    let workspaceStore = WorkspaceStore()
    let repoCache = WorkspaceRepoCache()
    var recorded: [ScopeChange] = []
    let coordinator = WorkspaceCacheCoordinator(
        workspaceStore: workspaceStore,
        repoCache: repoCache,
        scopeSyncHandler: { change in recorded.append(change) }
    )

    await coordinator.syncScope(
        .updateWatchedFolders(paths: [URL(fileURLWithPath: "/projects")])
    )

    #expect(recorded.count == 1)
    if case .updateWatchedFolders(let paths) = recorded[0] {
        #expect(paths.count == 1)
    } else {
        Issue.record("Expected updateWatchedFolders")
    }
}
```

**Step 2: Test rescan dedup via coordinator**

```swift
@Test func rescan_repoDiscovered_idempotent() async {
    let workspaceStore = WorkspaceStore()
    let repoCache = WorkspaceRepoCache()
    let coordinator = WorkspaceCacheCoordinator(
        workspaceStore: workspaceStore,
        repoCache: repoCache,
        scopeSyncHandler: { _ in }
    )
    let repoPath = URL(fileURLWithPath: "/projects/my-repo")
    workspaceStore.addRepo(at: repoPath)

    // Simulate two rescans finding the same repo
    let envelope = RuntimeEnvelope.system(
        SystemEnvelope(
            source: .builtin(.filesystemWatcher),
            seq: 1,
            timestamp: .now,
            event: .topology(.repoDiscovered(
                repoPath: repoPath,
                parentPath: URL(fileURLWithPath: "/projects")
            ))
        )
    )
    coordinator.consume(envelope)
    coordinator.consume(envelope)

    #expect(workspaceStore.repos.count == 1)
}
```

**Step 3: Verify**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run test
```

**Step 4: Commit**

```bash
git add -A
git commit -m "test: watched folder scope change forwarding and rescan dedup"
```

---

### Task 6: Verification Pass

**Step 1: Format and lint**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run format
AGENT_RUN_ID=watch-$(date +%s) mise run lint
```

**Step 2: Full test suite**

```bash
AGENT_RUN_ID=watch-$(date +%s) mise run test
```

**Step 3: Grep for consistency**

```bash
# No scattered maxDepth: 3 (should all use defaultMaxDepth or no param)
grep -rn "maxDepth: 3" Sources/ --include="*.swift"

# WatchedPath in persistence
grep -rn "watchedPaths" Sources/AgentStudio/Core/Stores/WorkspacePersistor.swift

# ScopeChange has the new case
grep -rn "updateWatchedFolders" Sources/AgentStudio/App/WorkspaceCacheCoordinator.swift

# FilesystemActor handles parent folders
grep -rn "watchedFolderIds\|updateWatchedFolders\|rescanAllWatchedFolders" Sources/AgentStudio/Core/PaneRuntime/Sources/FilesystemActor.swift

# Pipeline forwards it
grep -rn "updateWatchedFolders" Sources/AgentStudio/App/FilesystemGitPipeline.swift
```

Expected: zero `maxDepth: 3` matches. All other greps return results.

**Step 4: Commit**

```bash
git add -A
git commit -m "chore: verification pass for persistent WatchedPath feature"
```

---

## Summary

| Task | What | Files |
|------|------|-------|
| 1 | WatchedPath model + centralize maxDepth=4 | `WatchedPath.swift`, `RepoScanner.swift` |
| 2 | Store + persistence | `WorkspaceStore.swift`, `WorkspacePersistor.swift` |
| 3 | ScopeChange + FSEvents parent folder watching | `WorkspaceCacheCoordinator.swift`, `FilesystemActor.swift`, `FilesystemGitPipeline.swift` |
| 4 | Wire AppDelegate (Add Folder + boot) | `AppDelegate.swift` |
| 5 | Tests | `WorkspaceCacheCoordinatorTests.swift` |
| 6 | Verification | All |

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| FSEvents, not polling | Near-instant detection. No wasted I/O. Uses existing `DarwinFSEventStreamClient`. |
| 5-min fallback timer | Robustness for edge cases where FSEvents misses something. Not the primary mechanism. |
| maxDepth: 4 (centralized) | Supports `~/projects/org/suborg/repo/.git`. Scanner stops at `.git` — deeper nesting is safe. |
| No `WatchedPathKind` enum | All watched paths are parent folders. Direct repos use `addRepoIfNeeded()`. YAGNI. |
| No UI changes | Entry point is existing "Add Folder" menu item. No new UI surfaces. |
| `ScopeChange`, not bus event | `ConfigChangeEvent.watchedPathsUpdated` exists but has no consumers. YAGNI. Don't delete it — emit when a consumer exists. |
| Synthetic UUIDs for FSEvent registration | Parent folders aren't worktrees. Use a synthetic UUID keyed by folder path so `DarwinFSEventStreamClient` can manage the stream lifecycle. |
