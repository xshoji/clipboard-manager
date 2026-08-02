# AGENTS.md

## Purpose

Maintain ClipboardManager: a macOS 14+ SwiftUI clipboard-history app.

## Priorities

1. Preserve user data, clipboard contents, and app responsiveness.
2. Follow current behavior and the design documents.
3. Make the smallest complete, tested change.

## Source of Truth

- Product/UI/technical design: `docs/design-app.md`, `docs/design-ui.md`, `docs/design-implementation.md`.
- Test architecture, execution, and E2E isolation: `docs/testing.md`.
- Deferred or undecided work: `docs/open-questions.md`; do not silently choose it.
- `Package.swift` defines supported platform, target, resources, and frameworks.

### Documentation

```
docs/
├── requirements.md              # original requirements memo
├── design-app.md                # functional requirements
├── design-ui.md                 # UI requirements
├── design-implementation.md     # technical design
├── testing.md                   # test architecture, execution, and isolation
├── open-questions.md            # deferred / undecided items
└── remaining-features.md        # implementation status
```

Before starting implementation, check `docs/open-questions.md` for undecided items.

## Architecture

- `App/`: lifecycle, windows, composition.
- `App/Coordinators/`: window ownership and lifecycle coordination.
- `UI/`: SwiftUI presentation and user interaction.
- `Presentation/`: observable view models (`HistoryViewModel`, `SettingsViewModel`).
- `ApplicationServices/`: persistence boundary (`ClipboardRepository`) and paste orchestration (`PasteCoordinator`). Defines port protocols that Infrastructure adapters conform to, so dependencies point inward.
- `Domain/`: models and pure rules; no platform or persistence details.
- `Infrastructure/`: AppKit, SwiftData, Carbon, pasteboard, processes, filesystem. Conforms to ApplicationServices port protocols.
- Keep dependencies inward. Put side effects in `Infrastructure`.
- ApplicationServices defines port protocols; Infrastructure provides concrete adapters. Infrastructure never imports ApplicationServices concrete types — it only conforms to the protocols.

### Project Layout

```
ClipboardManager/
├── App/
│   ├── ClipboardApp.swift          # @main entry point
│   ├── AppDelegate.swift           # app lifecycle, window management
│   ├── AppContainer.swift          # manual dependency composition
│   ├── Coordinators/               # window coordinators (main/settings)
│   └── Info.plist
│   └── Info.E2E.plist             # XCUITest-host variant (bundle id …E2E)
├── Presentation/
│   ├── HistoryViewModel.swift      # observable history list state
│   └── SettingsViewModel.swift     # observable settings state
├── ApplicationServices/            # persistence boundary + paste orchestration
│   ├── ClipboardRepository.swift   # port-mediated persistence boundary (DI)
│   ├── PasteCoordinator.swift      # standard / Macro / OCR pasteboard writes
│   ├── ClipboardRepositoryPort.swift   # port protocols (ClipboardRepositoryPort, ClipboardHistoryWriting)
│   ├── ClipboardPersistencePort.swift # port protocol abstracting PersistenceController + ClipboardDataActor
│   └── PasteCoordinatorPorts.swift     # port protocols (PasteboardSuppressing, OcrRecognizing, MacroRunning, AppActivating, AppNotifying) + MacroInput/MacroOutput/MacroRunningError
├── UI/
│   ├── MainView.swift              # main UI
│   ├── HeaderBar.swift             # header controls
│   ├── HistoryListPane.swift       # search bar + history list
│   ├── HistoryRowView.swift        # single history row
│   ├── PreviewPane.swift           # detail preview for selected item
│   ├── FooterBar.swift             # action buttons (Paste / Plain Text / Copy / Edit / More)
│   ├── TextEditView.swift          # text edit sheet
│   ├── SettingsView.swift          # settings window
│   ├── MacroManagementView.swift   # dedicated macro CRUD and execution settings
│   ├── MacroScriptRowView.swift     # macro script settings row (with register/change confirmation dialog)
│   ├── HotkeyRecorderView.swift    # hotkey registration UI
│   └── Colors.swift                # color definitions
├── Domain/
│   ├── ClipboardEntity.swift       # SwiftData @Model
│   ├── ClipboardItem.swift         # UI DTO (no full image payload)
│   ├── ClipboardPersistenceDTO.swift # cross-boundary DTOs (ClipboardTextContent, NewClipboardItem)
│   ├── MacroScript.swift            # transform script setting
│   ├── MacroScriptPathValidator.swift # macro script path validation rule
│   ├── AppSettings.swift           # UserDefaults wrapper
│   └── DedupCache.swift            # [deprecated] dedup cache (unused; see docs/design-implementation.md §4.1)
├── Infrastructure/
│   ├── ClipboardMonitor.swift      # clipboard monitoring (pasteboard polling)
│   ├── HotkeyManager.swift         # Carbon API hotkey management
│   ├── MacroRunner.swift            # script execution
│   ├── MacroRunnerAdapter.swift     # MacroRunning port adapter
│   ├── PreviewImageEditor.swift    # Preview.app image editing integration
│   ├── PersistenceController.swift # SwiftData container management
│   ├── ClipboardPersistenceAdapter.swift # ClipboardPersistencePort adapter (owns PersistenceController + ClipboardDataActor)
│   ├── ClipboardDataActor.swift        # @ModelActor performing off-main reads
│   ├── PersistenceSchema.swift    # SwiftData VersionedSchema + MigrationPlan
│   ├── AppIconResolver.swift       # source app icon lookup
│   ├── AppActivator.swift          # bring previous app to front (AppActivating)
│   ├── AppNotifier.swift           # user notifications
│   ├── AppNotifierAdapter.swift    # AppNotifying port adapter
│   ├── OcrRecognizer.swift         # Vision OCR
│   ├── OcrRecognizerAdapter.swift  # OcrRecognizing port adapter
│   ├── ThumbnailGenerator.swift    # image thumbnail generation
│   ├── ThumbnailImageCache.swift   # in-memory thumbnail cache
│   ├── KeyLabelRenderer.swift      # key label rendering for UI
│   ├── SyntheticPasteSender.swift  # synthetic Cmd+V event sender (opt-in)
│   ├── InputPermission.swift       # accessibility permission check & guidance
│   └── MenuBarController.swift     # menu bar residency
└── Resources/
    ├── Assets.xcassets             # app icon, color definitions
    └── DefaultMacros                # bundled default macro scripts
```

### Layer Responsibilities

| Layer | Responsibility |
|---|---|
| `App` | Entry point, AppDelegate, AppContainer composition root, window coordinators |
| `Presentation` | Observable view models (`HistoryViewModel`, `SettingsViewModel`) |
| `UI` | SwiftUI views. References Presentation and Domain |
| `ApplicationServices` | Persistence boundary (`ClipboardRepository`) and paste orchestration (`PasteCoordinator`). Defines port protocols |
| `Domain` | Data models and pure rules. Knows nothing about persistence details |
| `Infrastructure` | Integration with external APIs: SwiftData, NSPasteboard, Carbon API, Process, etc. Conforms to ApplicationServices port protocols |

## Settings Synchronization

- Whenever adding, removing, renaming, or changing a Settings item, also update the canonical `config.json` synchronization contract in the same change.
- Ensure the setting is represented in `SettingsConfigurationDocument` / `AppSettingsSnapshot`, encoded on app-side changes, decoded and validated on external reload, and applied back to `AppSettings`.
- Add or update focused round-trip and validation tests. A Settings UI or UserDefaults change is incomplete until its `config.json` behavior is covered.
- Keep machine-local bootstrap metadata, permissions, and other explicitly excluded values outside `config.json`; document any new exclusion rather than omitting it silently.

## Execution Loop

1. Inspect related code and authoritative docs.
2. State assumptions when requirements remain undecided.
3. Implement a focused change in the owning layer.
4. Run `swift build` after Swift/package/resource changes.
5. Report changed files, validation, and remaining limits.

## Tool Usage

- Use `rg` for discovery.
- Prefer `swift build`; run focused tests when added.
- Preserve existing formatting and Swift concurrency isolation.
- Check `git diff` before finishing.

## Build / Test Pipeline (two-track)

- **Source of truth**: `docs/testing.md`. Read it before changing or running
  tests, E2E launch configuration, persistence paths, pasteboard wiring,
  test-host packaging, or test process management.
- Production uses the Swift package track; E2E uses `project.yml` and
  `Scripts/run-e2e-tests.sh`. Do not introduce Xcode-only production behavior.
- Never weaken the E2E isolation contract or terminate a production process.
- Keep XCUITest accessibility identifiers stable and semantic.

### Smoke UI Test Rules

- Follow `docs/testing.md#ui-smoke-test-rules`.
- During iteration, run the smallest relevant case and redirect verbose build
  output to `/tmp`; inspect only failures or the final summary.

## Safety Rules

- Never discard or rewrite unrelated user changes.
- Do not delete clipboard history or alter migrations without explicit approval.
- Treat macro scripts as untrusted: validate paths and preserve timeout/failure handling.
- Keep synthetic paste opt-in; do not request accessibility access by default.
- Avoid blocking the main actor with polling, image work, persistence cleanup, or processes.

## Image Editing (Preview.app Integration)

- Image editing is handled by `Infrastructure/PreviewImageEditor.swift`, which launches Preview.app as an external process with a pre-prepared working file under `~/Downloads/ClipboardManagerEdit/`.
- The working file uses a fixed name so safe-save's inode churn stays on a constant path, eliminating the "file not found" race that occasionally lost edits. Because the path is fixed, only one edit session may be active at a time; triggering Edit while another session is active shows an alert and rejects the new edit.
- Session completion is detected by AX window destruction, AX window-existence polling, `NSWorkspace.didTerminateApplicationNotification`, or a 10-minute idle timeout reset on file change.
- Accessibility permission is recommended for instant window-close detection but is not required; without it the app falls back to Preview app termination or the idle timeout.
- Only one edit session may be active at a time. Triggering Edit while another session is active shows an alert and rejects the new edit (this prevents clashing on the fixed working file path).
- `cleanupOrphanedEditFiles()` runs at startup to delete stale `edit.*` files from previous crashed sessions.
- Do not reintroduce the removed `MarkupIntegrator` / `NSSharingService` approach.

## Efficiency Rules

- Avoid unrelated refactors and dependency additions.
- Use existing models, services, colors, and settings before adding equivalents.
- Keep large image/data work off the UI path.

## Code Comment Language

- All code comments (inline, doc comments, and error messages) must be written in English.
- This ensures consistency across the codebase and accessibility to all contributors.

## Output Format

Report: summary; files changed; validation; unresolved decisions.

## Forbidden Actions

- Do not edit generated build output.
- Do not change the macOS deployment target without approval.
- Do not implement an item marked deferred/undecided as settled behavior.
