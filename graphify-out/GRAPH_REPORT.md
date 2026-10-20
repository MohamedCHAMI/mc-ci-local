# Graph Report - ci-local  (2026-10-20)

## Corpus Check
- 15 files · ~7,748 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 198 nodes · 436 edges · 11 communities (9 shown, 2 thin omitted)
- Extraction: 97% EXTRACTED · 3% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- RunInfo
- RunsView
- RunnerConfig
- GH
- LocalCheck
- AppModel
- .patch
- RunnerManager
- Foundation
- build.sh
- Package.swift

## God Nodes (most connected - your core abstractions)
1. `RunnerManager` - 36 edges
2. `AppModel` - 17 edges
3. `GH` - 17 edges
4. `RunInfo` - 15 edges
5. `RunsView` - 14 edges
6. `RunnerConfig` - 11 edges
7. `FailureKind` - 11 edges
8. `DetailTab` - 9 edges
9. `Foundation` - 8 edges
10. `LocalCheck` - 8 edges

## Surprising Connections (you probably didn't know these)
- `LocalCheckView` --calls--> `LocalCheck`  [INFERRED]
  ci-local/Sources/CILocal/DashboardView.swift → ci-local/Sources/CILocal/LocalCheck.swift
- `AddRepoView` --references--> `RepoInfo`  [EXTRACTED]
  ci-local/Sources/CILocal/AddRepoView.swift → ci-local/Sources/CILocal/Installer.swift
- `AppModel` --references--> `RunnerManager`  [EXTRACTED]
  ci-local/Sources/CILocal/App.swift → ci-local/Sources/CILocal/RunnerManager.swift
- `DashboardView` --references--> `AppModel`  [EXTRACTED]
  ci-local/Sources/CILocal/DashboardView.swift → ci-local/Sources/CILocal/App.swift
- `RunnerDetail` --references--> `AppModel`  [EXTRACTED]
  ci-local/Sources/CILocal/DashboardView.swift → ci-local/Sources/CILocal/App.swift

## Import Cycles
- None detected.

## Communities (11 total, 2 thin omitted)

### Community 0 - "RunInfo"
Cohesion: 0.14
Nodes (18): Codable, Decodable, Hashable, Identifiable, FailureKind, billing, code, runnerLost (+10 more)

### Community 1 - "RunsView"
Cohesion: 0.12
Nodes (19): AppKit, CaseIterable, Color, DashboardView, DetailTab, local, log, runs (+11 more)

### Community 2 - "RunnerConfig"
Cohesion: 0.13
Nodes (12): LocalizedError, Config, RunnerConfig, String, Installer, InstallError, failed, RepoInfo (+4 more)

### Community 3 - "GH"
Cohesion: 0.21
Nodes (6): GH, Bool, Int, Int32, Set, String

### Community 4 - "LocalCheck"
Cohesion: 0.13
Nodes (11): CILocal, ObservableObject, LocalCheck, Int32, Process, String, CheckCommand, CheckCommandTests (+3 more)

### Community 5 - "AppModel"
Cohesion: 0.14
Nodes (12): Any, App, Scene, ServiceManagement, AddRepoView, String, AppModel, CILocalApp (+4 more)

### Community 6 - ".patch"
Cohesion: 0.24
Nodes (8): Equatable, JobBlock, Result, Bool, Int, String, WorkflowPatcher, WorkflowPatcherTests

### Community 7 - "RunnerManager"
Cohesion: 0.25
Nodes (8): RunnerManager, Bool, Int, Process, Set, String, Timer, URL

### Community 8 - "Foundation"
Cohesion: 0.18
Nodes (7): Foundation, RunnerState, online, orphaned, starting, stopped, SwiftUI

## Knowledge Gaps
- **13 isolated node(s):** `PackageDescription`, `ServiceManagement`, `AppKit`, `log`, `local` (+8 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `RunnerManager` connect `RunnerManager` to `RunInfo`, `RunsView`, `RunnerConfig`, `GH`, `LocalCheck`, `AppModel`, `Foundation`?**
  _High betweenness centrality (0.338) - this node is a cross-community bridge._
- **Why does `RunInfo` connect `RunInfo` to `RunsView`, `GH`?**
  _High betweenness centrality (0.120) - this node is a cross-community bridge._
- **Why does `RunsView` connect `RunsView` to `RunInfo`, `GH`, `RunnerManager`?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **What connects `PackageDescription`, `ServiceManagement`, `AppKit` to the rest of the system?**
  _13 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `RunInfo` be split into smaller, more focused modules?**
  _Cohesion score 0.1354679802955665 - nodes in this community are weakly interconnected._
- **Should `RunsView` be split into smaller, more focused modules?**
  _Cohesion score 0.1225071225071225 - nodes in this community are weakly interconnected._
- **Should `RunnerConfig` be split into smaller, more focused modules?**
  _Cohesion score 0.13230769230769232 - nodes in this community are weakly interconnected._