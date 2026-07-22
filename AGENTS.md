# AGENTS.md

## Purpose

Maintain ClipboardManager: a macOS 14+ SwiftUI clipboard-history app.

## Priorities

1. Preserve user data, clipboard contents, and app responsiveness.
2. Follow current behavior and the design documents.
3. Make the smallest complete, tested change.

## Source of Truth

- Product/UI/technical design: `docs/design-app.md`, `docs/design-ui.md`, `docs/design-implementation.md`.
- Deferred or undecided work: `docs/open-questions.md`; do not silently choose it.
- `Package.swift` defines supported platform, target, resources, and frameworks.

### Documentation

```
docs/
├── requirements.md              # original requirements memo
├── design-app.md                # functional requirements
├── design-ui.md                 # UI requirements
├── design-implementation.md     # technical design
├── open-questions.md            # deferred / undecided items
└── remaining-features.md        # implementation status
```

Before starting implementation, check `docs/open-questions.md` for undecided items.

## Architecture

- `App/`: lifecycle, windows, composition.
- `UI/`: SwiftUI presentation and user interaction.
- `Domain/`: models and pure rules; no platform or persistence details.
- `Infrastructure/`: AppKit, SwiftData, Carbon, pasteboard, processes, filesystem.
- Keep dependencies inward. Put side effects in `Infrastructure`.

### Project Layout

```
ClipboardManager/
├── App/
│   ├── ClipboardApp.swift          # @main entry point
│   ├── AppDelegate.swift           # app lifecycle, window management
│   └── Info.plist
├── UI/
│   ├── MainView.swift              # main UI
│   ├── HeaderBar.swift             # header controls
│   ├── HistoryListPane.swift       # search bar + history list
│   ├── HistoryRowView.swift        # single history row
│   ├── PreviewPane.swift           # detail preview for selected item
│   ├── FooterBar.swift             # action buttons (Paste / Plain Text / Copy / Edit / More)
│   ├── TextEditView.swift          # text edit sheet
│   ├── SettingsView.swift          # settings window
│   ├── MacroScriptRowView.swift     # macro script settings row (with register/change confirmation dialog)
│   ├── HotkeyRecorderView.swift    # hotkey registration UI
│   └── Colors.swift                # color definitions
├── Domain/
│   ├── ClipboardEntity.swift       # SwiftData @Model
│   ├── MacroScript.swift            # transform script setting
│   ├── MacroScriptPathValidator.swift # macro script path validation rule
│   ├── AppSettings.swift           # UserDefaults wrapper
│   ├── AppState.swift              # runtime state
│   └── DedupCache.swift            # dedup cache
├── Infrastructure/
│   ├── ClipboardMonitor.swift      # clipboard monitoring (pasteboard polling)
│   ├── HotkeyManager.swift         # Carbon API hotkey management
│   ├── MacroRunner.swift            # script execution
│   ├── MacroPasteService.swift      # macro + paste flow
│   ├── PreviewImageEditor.swift    # Preview.app image editing integration
│   ├── PersistenceController.swift # SwiftData container management
│   ├── PersistenceSchema.swift    # SwiftData VersionedSchema + MigrationPlan
│   ├── AppIconResolver.swift       # source app icon lookup
│   ├── AppActivator.swift          # bring previous app to front
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
| `App` | Entry point, AppDelegate, window control |
| `UI` | SwiftUI views. References Domain and triggers side effects via Infrastructure interfaces |
| `Domain` | Data models and pure rules. Knows nothing about persistence details |
| `Infrastructure` | Integration with external APIs: SwiftData, NSPasteboard, Carbon API, Process, etc. |

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

## Safety Rules

- Never discard or rewrite unrelated user changes.
- Do not delete clipboard history or alter migrations without explicit approval.
- Treat macro scripts as untrusted: validate paths and preserve timeout/failure handling.
- Keep synthetic paste opt-in; do not request accessibility access by default.
- Avoid blocking the main actor with polling, image work, persistence cleanup, or processes.

## Image Editing (Preview.app Integration)

- Image editing is handled by `Infrastructure/PreviewImageEditor.swift`, which launches Preview.app as an external process with a pre-prepared working file under `~/Downloads/ClipboardManagerEdit/`.
- The working file preserves the original UTI/extension so Cmd+S saves in place without a filename dialog.
- Session completion is detected by AX window destruction, AX window-existence polling, `NSWorkspace.didTerminateApplicationNotification`, or a 10-minute idle timeout reset on file change.
- Accessibility permission is recommended for instant window-close detection but is not required; without it the app falls back to Preview app termination or the idle timeout.
- Each edit session is independent (UUID-keyed) with its own working file path; concurrent edits of different entities are supported.
- Re-editing an entity whose session is already active activates the existing Preview session rather than starting a new one.
- `cleanupOrphanedEditFiles()` runs at startup to delete stale `*_edit.*` files from previous crashed sessions.
- Do not reintroduce the removed `MarkupIntegrator` / `NSSharingService` approach.

## Efficiency Rules

- Avoid unrelated refactors and dependency additions.
- Use existing models, services, colors, and settings before adding equivalents.
- Keep large image/data work off the UI path.

## Output Format

Report: summary; files changed; validation; unresolved decisions.

## Forbidden Actions

- Do not edit generated build output.
- Do not change the macOS deployment target without approval.
- Do not implement an item marked deferred/undecided as settled behavior.
