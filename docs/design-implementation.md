# Clipboard Manager — Technical Design

> This document defines the technical design for implementing the functional requirements in `docs/design-app.md` according to the UI requirements in `docs/design-ui.md`.

## 1. Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| Language | Swift 5.9+ (Xcode 15+) | Native to macOS, can access Carbon APIs |
| Minimum OS | **macOS 14 (Sonoma) or later** | `@Observable` / SwiftData require macOS 14+ APIs. macOS 13 (Ventura) is dropped |
| UI | SwiftUI | Declarative, maintainable, standard for macOS |
| State management | `@Observable` + `@Environment` | Lightweight approach without Combine (macOS 14+ macro API) |
| Persistence | **SwiftData** (`@Model`, `ModelContainer`, `ModelContext`) | Declarative persistence hidden behind `ClipboardRepository` |
| Settings storage | `UserDefaults` | KVS is enough, lightweight |
| Global hotkey | Carbon `RegisterEventHotKey` | Bridged from Swift. Works even when app is not running |
| Clipboard monitoring | `NSPasteboard.changeCount` polling | Reliable, 0.25s interval |
| External process | `Process` | Macro script execution |
| Image editing | `NSWorkspace.open` + Preview.app + Accessibility API | Launch Preview as an external process, detect edit completion via file watcher + AX window destruction + NSWorkspace termination |
| Background execution | `LSUIElement = YES` | No Dock icon, menu bar resident |

> **Background on technology choices**:
> - Initially considered macOS 13 compatibility + Core Data, but `@Observable` and SwiftData are both macOS 14+ APIs, so they could not be combined.
> - The development environment is macOS 26 (Tahoe)-based, so requiring macOS 14+ does not hinder real-machine verification, so we raised the floor to macOS 14+.
> - Large history collections are mapped to lightweight DTOs without loading full text, rich text, or image payloads. Paging remains a future optimization for the 100,000-item upper range (see §4.1).

## 2. Module Structure

The implementation uses six dependency layers (top to bottom): composition root
(`ClipboardApp`, `AppDelegate`, `AppContainer`), window coordinators, Presentation
view models, Application Services, Domain values, and Infrastructure adapters.
`ClipboardRepository` is the only boundary that exposes SwiftData history to the
rest of the app, mapping records to image-payload-free `ClipboardItem` values.
`PasteCoordinator` owns standard, Macro, and OCR pasteboard writes. Views observe
`HistoryViewModel` repository refreshes rather than SwiftData `@Query`.

### 2.1 Persistence Boundary & Dependency Direction

`ClipboardRepository` (ApplicationServices) depends on `ClipboardPersistencePort`
(an ApplicationServices port protocol) and is injected with a concrete adapter
at composition time (`AppContainer`). The concrete adapter
`ClipboardPersistenceAdapter` lives in Infrastructure and bundles
`PersistenceController` (main-context IO, limits enforcement,
backup-on-corruption) with `ClipboardDataActor` (off-main reads via
`@ModelActor`). This keeps the dependency direction strictly inward:

- ApplicationServices -> ApplicationServices port (`ClipboardPersistencePort`)
- Infrastructure -> ApplicationServices port (the adapter conforms to it)
- No ApplicationServices -> Infrastructure dependency exists.
- No Infrastructure -> ApplicationServices concrete-type dependency exists.

DTOs that cross this boundary (`ClipboardItem`, `ClipboardTextContent`,
`NewClipboardItem`) all live in Domain so neither layer needs to reference the
other to return/accept them.

```
ClipboardManager/
├── App/
│   ├── ClipboardApp.swift            # @main, AppDelegate
│   ├── AppContainer.swift            # Manual dependency composition
│   ├── Coordinators/                  # App/main/settings window coordination
│   └── Info.plist                     # LSUIElement=YES
├── Presentation/                      # HistoryViewModel, SettingsViewModel
├── ApplicationServices/               # ClipboardRepository, PasteCoordinator
│   ├── ClipboardRepositoryPort.swift     # ClipboardRepositoryPort + ClipboardHistoryWriting (Presentation/Infrastructure-facing)
│   ├── ClipboardRepository.swift         # Port-mediated persistence boundary (DI)
│   ├── ClipboardPersistencePort.swift    # Port protocol abstracting PersistenceController + ClipboardDataActor
│   ├── PasteCoordinatorPorts.swift       # Paste-side port protocols
│   └── SettingsConfigurationPort.swift   # Canonical JSON configuration schema + port
├── UI/                                # SwiftUI views
│   ├── MainView.swift                # 2-pane layout
│   ├── HeaderBar.swift                # Header controls
│   ├── HistoryListPane.swift         # Search bar + history list (virtual scroll)
│   ├── HistoryRowView.swift          # Single row (icon/thumbnail, title, subtitle)
│   ├── PreviewPane.swift             # Selected item preview (monospace/image)
│   ├── FooterBar.swift               # Action buttons
│   ├── TextEditView.swift            # Plain text edit (modal sheet)
│   ├── SettingsView.swift            # Settings navigation + application preferences
│   ├── MacroManagementView.swift     # Dedicated Macro CRUD and execution settings
│   ├── MacroScriptRowView.swift       # Macro script row editor
│   ├── HotkeyRecorderView.swift      # Hotkey recorder UI
│   └── MenuBarView.swift              # Menu bar resident UI (NSStatusItem)
├── Domain/                            # Models
│   ├── ClipboardEntity.swift         # SwiftData @Model
│   ├── ClipboardItem.swift           # UI DTO (no full image payload)
│   ├── ClipboardPersistenceDTO.swift # Cross-boundary DTOs (ClipboardTextContent, NewClipboardItem)
│   ├── MacroScript.swift             # Macro script settings model
│   ├── AppSettings.swift            # UserDefaults wrapper
│   └── DedupCache.swift              # [deprecated] Recent hash cache for dedup (unused; see §4.1)
├── Infrastructure/                    # External API integration
│   ├── ClipboardMonitor.swift        # changeCount monitor, save
│   ├── HotkeyManager.swift          # Carbon API wrapper
│   ├── PreviewImageEditor.swift      # Preview.app integration for image editing
│   ├── MacroRunner.swift              # Launch scripts via Process
│   ├── SettingsConfigurationAdapter.swift # Atomic JSON persistence + external-change monitoring
│   ├── PersistenceController.swift  # SwiftData ModelContainer + cleanup
│   ├── ClipboardPersistenceAdapter.swift  # ClipboardPersistencePort adapter (owns PersistenceController + ClipboardDataActor)
│   ├── ClipboardDataActor.swift        # @ModelActor performing off-main reads
│   ├── AppIconResolver.swift         # Resolve app icon from bundleID
│   ├── ThumbnailGenerator.swift     # Image thumbnail generation
│   ├── InputPermission.swift         # Accessibility permission check/prompt
│   └── MenuBarController.swift      # NSStatusItem management
└── Resources/
    ├── Assets.xcassets               # App icon, ColorSet (Any/Dark)
    └── DefaultMacros/                 # Sample scripts (later)
```

### Layer Responsibilities

- **App / Coordinators**: Composition, lifecycle, and window ownership.
- **Presentation / UI**: Observable screen state and SwiftUI rendering. UI actions use application services.
- **Application Services**: Persistence boundary and all paste workflows.
- **Domain**: Data models and pure rules. Does not know persistence details.
- **Infrastructure**: Integration with external APIs such as SwiftData, `NSPasteboard`, Carbon, `Process`, `NSWorkspace`, ApplicationServices (Accessibility API).

### UI Layer Component Mapping

| UI element (design-ui.md) | Implementation |
|---|---|
| 2-pane split | `MainView` |
| Header controls | `HeaderBar` |
| Search bar + history list | `HistoryListPane` + `HistoryRowView` |
| Preview area | `PreviewPane` |
| Footer action bar | `FooterBar` |
| Edit screen | `TextEditView` (text), `PreviewImageEditor` (image) |
| Settings screen | `SettingsView` |
| Menu bar resident UI (`design-ui.md §11`) | `MenuBarController` + `MenuBarView` |

### Infrastructure Component Mapping

| Function | Implementation | Overview |
|---|---|---|
| Clipboard monitoring | `ClipboardMonitor` | Polls `NSPasteboard.changeCount` at 0.25s, publishes a non-persisted Current Clipboard snapshot immediately, and saves eligible external changes |
| Global hotkey | `HotkeyManager` | Registers hotkeys via Carbon `RegisterEventHotKey` |
| Macro script execution | `MacroRunner` | Launches scripts via `Process`, passes IO file paths via env vars (§4.2) |
| Preview.app image editing | `PreviewImageEditor` | Launches Preview.app as an external process, detects edit completion, saves edited image (§4.3) |
| SwiftData persistence | `PersistenceController` | Builds `ModelContainer`, save + cleanup |
| SwiftData persistence adapter | `ClipboardPersistenceAdapter` | Concretions of `ClipboardPersistencePort`; owns `PersistenceController` + `ClipboardDataActor`, performs entity<->DTO conversion. Injected into `ClipboardRepository` by `AppContainer` so ApplicationServices never references Infrastructure persistence types directly. |
| SwiftData off-main reads | `ClipboardDataActor` | `@ModelActor` performing fetches (list, text payload, image bytes, full text, HTML) off the main actor. Referenced only by `ClipboardPersistenceAdapter`. |
| App icon resolution | `AppIconResolver` | Gets `NSImage` via `NSWorkspace.shared.icon(forFile:)` from `sourceBundleID`, supplies to `HistoryRowView` |
| Image thumbnail | `ThumbnailGenerator` | Generates list-display thumbnails from image Entity |
| Accessibility permission | `InputPermission` | Prompts for permission when enabling synthetic `Cmd+V` or when Preview editing needs faster detection (see §5.2) |
| Menu bar resident | `MenuBarController` | `NSStatusItem` management, menu construction (per `design-ui.md §11`) |
| Dedup | `ClipboardMonitor.removeDuplicates` | Two-layer dedup. Layer 1 (in-memory `lastSavedContentHash`) skips a save entirely when the copy is byte-identical to the immediately-preceding save, avoiding a needless SwiftData write. Layer 2 (`removeDuplicates`, main actor) deletes any older entities with the same `contentHash` before inserting the new one, so the newly copied item bubbles up to the top without stacking duplicates. The previous `DedupCache` ring-buffer approach (which skipped any duplicate within the last `dedupCacheSize` entries) was removed because it prevented the same content from re-entering history even after different content was copied in between; the current approach guarantees at most one entry per hash while still allowing the same content to re-enter history once anything else has been copied. |

## 3. Data Model

### 3.1 ClipboardEntity (SwiftData `@Model`)

```swift
@Model
final class ClipboardEntity {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var kind: String            // "text" / "image"
    var text: String?          // Plain text (search target)
    var richText: Data?        // RTFD (for rich restoration on paste)
    var html: Data?            // HTML source (for rich paste + styled preview)
    var imageData: Data?       // PNG (image history)
    var thumbnail: Data?       // For fast list display
    var sourceBundleID: String?
    var contentHash: String?   // SHA256 (for dedup)
    var ocrText: String?       // Persisted automatic OCR result
    var ocrStatus: String?     // "pending" / "completed"

    init(...) { ... }
}
```

| Attribute | Type | Purpose |
|---|---|---|
| id | UUID | Primary key (`@Attribute(.unique)`) |
| createdAt | Date | Retention period check |
| kind | String | "text" / "image" |
| text | String? | Plain text (search target) |
| richText | Data? | RTFD (for rich restoration on paste) |
| html | Data? | HTML source (for rich paste + styled preview). Stored with `@Attribute(.externalStorage)` |
| imageData | Data? | PNG (image history) |
| thumbnail | Data? | For fast list display |
| sourceBundleID | String? | Source app identifier |
| contentHash | String? | SHA256 for dedup (text or imageData) |
| ocrText | String? | On-device OCR text used for image keyword search. Stored with `@Attribute(.externalStorage)` |
| ocrStatus | String? | Automatic OCR state (`pending` or `completed`); nil for entries not scheduled for automatic OCR |

> **Edit handling**: Results edited in `TextEditView` are **saved as a new Entity with `kind = "text"` and `richText = nil`** (per `design-app.md §2.1.4`). The original rich text history remains as a separate Entity.
> **HTML format handling**: When a clipboard entry provides HTML (via `public.html` pasteboard type) without RTF/RTFD, the raw HTML `Data` is stored in the `html` attribute. The source-provided plain-text pasteboard representation is stored in `text`; HTML extraction is used only when that representation is absent. This preserves source-specific plain text such as Markdown instead of regenerating a differently laid-out string from HTML. At paste time, if `html` is present it is written to the pasteboard as `public.html` alongside the plain text, so the target app can pick up the styled content. The preview pane renders styled HTML only when its textual representation matches the source-provided plain text; otherwise it shows the source plain text so Markdown and other source-specific layouts are not replaced by HTML extraction.
> **Dedup and HTML**: `contentHash` is derived from the **plain-text** representation (`Data(text.utf8)`), not from the HTML markup. This means two copies with identical plain text but different HTML markup (e.g. copied from different apps with different styling) are treated as duplicates — only the first copy is kept. This is an accepted tradeoff: the vast majority of use-cases care about the text content, not the markup. If "same text, different formatting" preservation is needed in the future, the hash would need to incorporate the `html`/`richText` payload (review #2).
> **Search scale**: For 100,000+ items with full-text search, `LIKE` queries on `text` become heavy, so v2 should consider prefiltering using `contentHash` suffix or introducing SQLite FTS5 (see §9).

### 3.2 AppSettings (UserDefaults)

- `hotkeyKeyCode: Int`
- `hotkeyModifiers: Int`
- `globalMacroPickerHotkeyKeyCode: Int` (optional second global hotkey; 0 = unset)
- `globalMacroPickerHotkeyModifiers: Int`
- `retentionDays: Int` (0=unlimited)
- `maxHistoryCount: Int`
- `maxItemSizeMB: Int`
- `pollingIntervalMs: Int` (default 250)
- `dedupCacheSize: Int` (default 100) — [deprecated] recent hash cache size. The `DedupCache` ring buffer is no longer used; the setting is retained only for backward compatibility of the UserDefaults schema and is ignored at runtime. Dedup is now a two-layer approach (see §4.1 and `ClipboardMonitor.removeDuplicates`).
- `macroScripts: [MacroScript]` (JSON encoded)
- `macroSameDirectoryFingerprint: Bool` (default true) — verify script fingerprint before run
- `macroTimeoutSeconds: Int` (default 5, range 1–300) — maximum Macro execution time
- `needsAccessibilityForSyntheticPaste: Bool` (default false) — enable synthetic `Cmd+V`

#### UI State Persistence (corresponds to UI toggles in design-ui.md)

- `isAlwaysOnTop: Bool` (always-on-top ON/OFF; toggled via the header pin button, persisted across launches. When ON the panel is not auto-dismissed on blur.)
- `isSidebarVisible: Bool` (sidebar collapse)
- `isSplitView: Bool` (2-pane/1-pane toggle)
- `previewWrapMode: String` (wrap mode, "wrap" / "nowrap")

### 3.3 MacroScript

| Attribute | Type | Purpose |
|---|---|---|
| id | UUID | Primary key |
| name | String | Registered name |
| scriptPath | String | Script file path |
| inlineScript | String? | Inline script code; `nil` for file-backed Macros |
| testInput | String? | Reusable text fixture saved with the Macro for Test Run |
| interpreter | String | `/bin/sh`, `python3`, etc. |
| hotkeyCode | Int | For shortcut binding |
| hotkeyModifiers | Int | Ditto |
| lastFingerprint | String? | SHA256 of script file (for pre-run verification) |
| lastModified | Date? | Last modified date of script file at previous run |

## 4. Main Sequences

### 4.1 Clipboard Save Flow

```
[NSPasteboard.changeCount changes]
  → ClipboardMonitor.poll (0.25s)
  → Type detection (text/image)
  → Dedup check (two layers; see below)
  → Insert new Entity into SwiftData ModelContext
      ※ If consecutive copies occur within the same changeCount,
        only the last observed content is saved (spec).
  → If automatic image OCR is enabled and the insert succeeds:
      AutomaticOcrProcessor serial utility queue
      → Vision OCR → update ocrText/ocrStatus → refresh search DTOs
  → PersistenceController.enforceLimits() asynchronously
      (does not block the save flow)
```

#### Dedup (two layers)

1. **Skip-on-identical-immediate** (`ClipboardMonitor.lastSavedContentHash`, in-memory, poll-queue):
   When the incoming content hash equals `lastSavedContentHash`, the save is skipped entirely (no SwiftData write, no thumbnail generation). This short-circuits re-copies of the same content and app-internal pasteboard re-writes that bump `changeCount` without changing content. `lastSavedContentHash` is updated on every successful save.
2. **Remove-by-hash** (`ClipboardMonitor.removeDuplicates`, main actor, pre-insert):
   Before each insert, deletes any existing entities with the same `contentHash` so the newly copied item bubbles up to the top without stacking duplicates. Guarantees at most one entry per `contentHash` in the database.

> **Note**: The previous ring-buffer approach (`DedupCache`, `dedupCacheSize` default 100) skipped any duplicate within the last `dedupCacheSize` entries and prevented the same content from re-entering history until the ring evicted it. It was removed because users expect the same content to re-enter history once anything else has been copied in between; the two-layer approach above preserves "don't save the same copy twice in a row" (Layer 1) while allowing re-entry after intervening copies (Layer 2 only dedupes within the database, not across an in-memory window).

#### Current Clipboard snapshot

- `ClipboardMonitor` normalizes each eligible pasteboard value into a complete
  `CurrentClipboardSnapshot` on its utility queue. The snapshot and persistence
  insert share the same normalized payload and content hash.
- `HistoryViewModel` prepends the snapshot as a virtual Current Clipboard row and
  hides one persisted row with the same hash. Persisted rows remain unchanged in
  SwiftData.
- Current actions use the snapshot payload directly; persisted-history actions
  continue to lazy-load full payloads by UUID through `ClipboardRepository`.
  OCR may reuse status and recognized text from the same-hash persisted row that
  was merged into Current Clipboard, avoiding duplicate Vision work while the
  snapshot remains the source image for any uncached recognition.
- Macro Picker refreshes and fixes its target before opening, so a pasteboard or
  repository update while the picker is visible cannot change the Macro input.
- App-owned suppressed writes update Current Clipboard but remain excluded from
  persisted history. Concealed and auto-generated payloads are excluded from both.

#### Automatic image OCR

- Disabled by default and applies only to images saved after the setting is enabled.
- Uses the configured OCR language set and runs entirely on-device.
- `AutomaticOcrProcessor` uses one serial utility-QoS queue, preventing concurrent
  Vision requests during bursts and keeping the main actor responsive.
- The image row is inserted with `ocrStatus = "pending"`. After recognition,
  `ocrText` is stored (or left nil when no text is found), status becomes
  `"completed"`, and the repository change notification refreshes keyword search.
- Paste Plain / its action hotkey reuses a completed persisted result without
  running Vision again. It reports pending background work instead of starting a
  duplicate request; an unanalysed image is recognized on demand and cached.
- Existing history is not automatically backfilled.


> **`enforceLimits` execution policy**:
> - On save flow: runs asynchronously via `Task.detached` so it does not affect save latency.
> - On settings change (§4.4): debounced by 1 second (avoids full sweep on every slider tick).

### 4.2 Paste Flow

```
[UI item selection + paste command]
  → Branch:
      Rich (RTFD) → write RTFD + text to NSPasteboard
      Rich (HTML) → write public.html + text to NSPasteboard
      Plain       → write text only
      Macro       → write temp file → MacroRunner.run(script, inputFile)
             → read output file → write to pasteboard
  → Record the exact pasteboard output through ClipboardMonitor's deduplicating insert:
      Rich retains RTFD / HTML, Plain and OCR store text only
      Macro output and Macro failure fallback remain monitor-suppressed and do not update history
  → NSApp.activate(ignoringOtherApps: true) to restore previous app
  → User presses Cmd+V to complete paste
```

> **Paste method policy** (per `design-app.md §2.2.1`):
> - Synthetic `Cmd+V` events are not sent (to avoid requiring accessibility permission).
> - An optional "allow synthetic Cmd+V" toggle can be added to `AppSettings` (`needsAccessibilityForSyntheticPaste: Bool`, default `false`). When enabled, sends `Cmd+V` via `AXUIElement` API.

#### 4.2.1 MacroRunner Interface

`MacroRunner.run()` launches external scripts with the following environment:

| Env var | Value | Required |
|---|---|---|
| `CB_INPUT_FILE` | Absolute path to input temp file (`.txt` or `.png`) | Macro must read |
| `CB_OUTPUT_FILE` | Absolute path to output temp file (same extension as input) | Macro must write |
| `CB_ITEM_KIND` | `text` or `image` | For type detection |
| `CB_ITEM_SOURCE` | Source bundle ID (if available) | Optional |

- If the output file is not created, treat as **no transformation** and paste input content as-is.
- exit != 0 or the configured timeout (5s by default) is treated as "Macro failure" (see §5 response table).
- Normal Macro runs send stdout/stderr to the null device so verbose scripts cannot block on full process pipes and no unused logs are retained.
- The Settings Macro row stores a reusable text test case with each Macro for
  **Test Run**. It is saved automatically and does not read from or require a selected history item.
  New or edited Macros first pass through the normal registration/change
  confirmation and fingerprint-save flow. Test Run writes the configured text
  to a `.txt` input file and uses the same input-file,
  environment-variable, interpreter, fingerprint, and timeout setup as a normal
  Macro run, but it does not write to the pasteboard, activate another app, or
  apply the configured failure fallback. A debug console shows the command,
  environment, duration, exit status, stdout, stderr, and transformed output.
  Captured stdout/stderr is limited to 256 KiB per stream while excess bytes are
  drained and discarded. Macro output is represented by a metadata-rich preview
  limited to 256 KiB; the full output file is never loaded by the debug console.
  Copy Report writes through the injected, monitor-suppressed pasteboard boundary.

### 4.3 Image Editing Flow via Preview.app

The image editing feature uses macOS standard Preview.app as an external process, not the previous Markup sharing service. The previous Markup-based `MarkupIntegrator` has been removed and replaced with `PreviewImageEditor`.

Rationale: The Markup sharing service had issues with service identifier instability across macOS versions and unreliable result retrieval. Launching Preview.app directly with a pre-prepared working file provides a more stable editing experience and avoids the save dialog (file name specification) that appears when opening an in-memory image directly.

```
[Image history selected + Edit button pressed]
  → PreviewImageEditor.editImage(entity):
      1. Create working file:
         - Copy the original image to `~/Downloads/.ClipboardManagerEdit.<ext>`
         - Preview is sandboxed and cannot write to other apps' Application Support;
           Downloads is user-writable. The dot-prefixed file is also marked hidden.
         - If that fixed path already exists after a failed/interrupted session, reject
           the new edit and report the recovery path instead of overwriting it.
         - Extension/UTI matches the original (PNG stays PNG, JPEG stays JPEG)
           so Preview offers the correct edit menus and Cmd+S overwrites the file
           without showing a save dialog.
      2. Launch Preview.app:
         - NSWorkspace.shared.open([workFile], withApplicationAt: previewURL, configuration:)
         - Explicitly target com.apple.Preview so the file opens in Preview.
         - On launch completion, capture the PID and create a session (UUID-keyed).
      3. Start monitoring (multiple detectors, any one triggers completion):
         a. File change watcher (primary): DispatchSource.makeFileSystemObjectSource
            on the working file with [.write, .rename, .delete]. On Cmd+S, the file
            is overwritten and the event fires. Safe-save (temp file → atomic rename)
            is handled by re-opening the descriptor on .rename/.delete.
            A 0.5s debounce collapses multiple FS events from safe-save into one check.
         b. AX window destruction (main, requires Accessibility permission):
            AXObserverAddNotification for kAXUIElementDestroyedNotification on the
            Preview window whose AXDocument/kAXTitle matches the working file.
            Window is located by polling AX windows for up to 3s after launch.
         c. AX window existence polling (main, requires Accessibility permission):
            Every 5s, check that the target Preview window still exists in the AX
            windows list. If it disappears, trigger completion. This is a backup
            for cases where the destruction notification does not fire.
         d. NSWorkspace didTerminateApplicationNotification (fallback, no AX):
            Monitors the Preview PID. Fires when Preview quits. This is the
            safety net when Accessibility permission is not granted (only detects
            on app exit, not window close).
          e. Idle timeout (final safety net): 5 minutes after the last file write,
             monitoring stops and a user notification reports the preserved working-file
             path. The file is not deleted because Preview may still hold unsaved edits.
      4. On any detector firing:
         - performHashCheck: read the working file, compute SHA256, compare to
           the original hash AND the last saved hash (dedup guard for Preview
           auto-save). If different, await insertion as a new ClipboardEntity.
         - Only after insertion succeeds: update `lastSavedHash`, close the target
           Preview window, stop watchers, and delete the working file.
         - On save failure, oversize output, idle timeout, or app termination: stop
           watchers as needed but preserve the working file for manual recovery.
```

Key behaviors:
- **No save dialog**: Because the working file is a real on-disk file at a user-writable path, Cmd+S in Preview overwrites it directly. No file name modal appears.
- **Save completion boundary**: A Cmd+S result is considered saved only after repository insertion succeeds. The target Preview window then closes automatically. Insert failures keep the window open when possible and always preserve the working file.
- **Concurrent edits**: Rejected. Because the working file uses a fixed path (`edit.<ext>`), only one edit session may be active at a time. Triggering Edit while another session is active shows an alert and rejects the new edit. This keeps safe-save's inode churn on a constant path and eliminates the "file not found" race that occasionally lost edits.
- **Accessibility permission**: Required for instant detection on window close (detectors b and c). Without it, Preview termination finalizes the session; the 5-minute idle timeout safely stops monitoring and preserves the file rather than assuming the edit is complete.
- **No automatic orphan deletion**: Startup and periodic prefix-based cleanup are intentionally disabled because a file left by a failed save or interrupted shutdown is potentially the only recoverable copy of the edit. A preserved fixed-path file blocks a new edit until the user moves or removes it.
- **Working file location & naming**: The active file is `~/Downloads/.ClipboardManagerEdit.<ext>` (dot-prefixed and marked hidden). A single fixed path keeps safe-save's inode churn on a constant path. Downloads is used because Preview.app cannot overwrite another app's Application Support file without presenting a save dialog.
- **AX refcon lifetime**: The `SessionBox` passed as the AX observer refcon is `Unmanaged.passRetained` so it survives until `stopSession` explicitly `release()`s it, even if the session is removed from the dictionary before a late AX callback fires.

### 4.4 Settings Immediate Reflection

```
[Value changed in SettingsView]
  → AppSettings writes to UserDefaults (via propertyWrapper)
  → PersistenceController.enforceLimits(retention:max:) runs
      after a 1-second debounce
      (avoids full sweep on every slider tick)
```

#### 4.4.1 debounce / throttle policy

- `retentionDays`, `maxHistoryCount` slider: 1 second debounce.
- `macroScripts` add/edit: immediate (user action each time).
- `pollingIntervalMs` change: immediate (ClipboardMonitor rebuilds timer on next poll).

### 4.5 Canonical Settings and Macro Configuration

- The canonical configuration path is resolved once at launch. E2E isolation takes precedence, followed by the exact absolute file path in `CLIPBOARD_MANAGER_CONFIG_PATH`, the GUI-selected path persisted as local UserDefaults bootstrap metadata, `${XDG_CONFIG_HOME}/clipboard-manager/config.json` when XDG specifies an absolute root, and finally `~/.config/clipboard-manager/config.json`.
- An explicit `CLIPBOARD_MANAGER_CONFIG_PATH` must end in `config.json`, have an existing parent directory, and point directly to a regular file rather than a symbolic link. Invalid explicit paths fail closed: configuration reads, writes, and monitoring are disabled without falling back to another file. XDG and default directories continue to be created automatically.
- The GUI-selected path is intentionally excluded from `config.json` to avoid a bootstrap cycle and to keep machine-local placement out of shared dotfiles. A new destination receives the current normalized configuration before its path is persisted, then offers Restart Now or Later. An existing destination is fully validated and requires explicit confirmation that accepting it will restart the app; it is never overwritten. Reset also confirms and restarts automatically. Relaunch asks Launch Services for a new app instance, passes it the old PID, and makes the new instance wait before initialization until the old process has completed normal shutdown. The previous configuration file is never deleted automatically.
- The resolved file is the versioned, size-bounded source of truth for explicit application settings and Macro snapshots. If it does not exist, the app migrates the current UserDefaults values into it once.
- Inline Macros include their code; file-backed Macros include only the external path because one script file does not represent its dependencies or runtime environment. Test Input is included for both source types.
- Each Macro has a unique non-negative integer `order`. Gaps are valid, reads sort by `order`, and a newly registered Macro uses the current maximum plus 10 to keep ordering stable in Git diffs.
- App changes are written after a short debounce using pretty-printed, sorted JSON and atomic replacement. A directory watcher handles editor saves and Git checkout inode replacement; self-writes are ignored by content hash.
- Reads reject files larger than 10 MB, unknown format versions, duplicate Macro IDs or order values, conflicting truncated Carbon IDs, invalid source discriminators, and unsupported setting values before changing `AppSettings`.
- Invalid external content is never applied or overwritten. External reload waits while Macro rows have unsaved edits, and runtime hotkey failures roll settings back.
- Clipboard history, macOS permissions, and Macro trust fingerprints remain local and outside this contract. Existing trust is retained only when a Macro ID and source are unchanged.

## 5. Technical Concerns and Mitigations

| Concern | Mitigation |
|---|---|
| Paste method | Simple approach: write to pasteboard then activate previous app. Synthetic Cmd+V requires accessibility, so not prioritized (`AppSettings.needsAccessibilityForSyntheticPaste` for future) |
| Plain text paste | Set only `NSStringPboardType` on `NSPasteboard` (do not co-write RTF) |
| Macro file format | Assume `.txt` for text and `.png` for image. Detect output with same extension |
| Macro failure | Configurable timeout (5s default), exit != 0 → user notification + paste original content (default, configurable) |
| Large image rejection | `maxItemSizeMB` in UserDefaults, skip save + notify on exceed. Default 10MB |
| Dedup | Two layers: (1) in-memory `lastSavedContentHash` skips a save entirely when the copy matches the immediately-preceding save; (2) `ClipboardMonitor.removeDuplicates` deletes older entities with the same `contentHash` before insert, so each hash has at most one entry and the new copy bubbles to the top. The previous `DedupCache` ring buffer (`dedupCacheSize` default 100) is deprecated. |
| Sanitize | Invalid RTF load via try/catch + Data validation, corrupt Entity deleted |

### 5.1 Macro Script Safeguards

Since arbitrary scripts run with Sandbox off, implement three layers of defense:

1. **Confirmation on registration/change**
   - When registering a new script or changing `scriptPath` in `SettingsView`, require a confirmation dialog.
   - Message: "This script can access your clipboard contents. Do not specify untrusted scripts."
   - After confirmation, save fingerprint and last-modified date to `MacroScript.lastFingerprint / lastModified`.

2. **Pre-run fingerprint verification**
   - Compute SHA256 of the script file before `MacroRunner.run()`.
   - If it does not match `lastFingerprint`, abort and notify user ("The script has been modified. Please reconfirm in Settings.").
   - `AppSettings.macroSameDirectoryFingerprint` toggles verification (default ON).

3. **Path whitelist**
   - `scriptPath` must be **under the user's home directory (`~/`)**.
   - `/System`, `/usr`, `/bin`, `/sbin`, `/etc` are rejected immediately.
   - Verified via `URL.hasDirectoryPath(NSHomeDirectory())`.

### 5.2 Permission Flow

| Permission | Purpose | Grant flow |
|---|---|---|
| Accessibility | (1) Synthetic `Cmd+V` send via `AXUIElement`. (2) `PreviewImageEditor` window-close detection via `AXObserver`/`AXUIElementCopyAttributeValue` for instant edit completion. | Not requested by default. Prompted when `needsAccessibilityForSyntheticPaste` is turned on, or when `PreviewImageEditor` launches and `AXIsProcessTrusted()` is false (notification directs user to Settings → Permissions). Without the permission, Preview editing still works but completion is detected only on Preview quit or 5-min idle timeout. |
| Full Disk Access | — | Not requested unless required |

Carbon `RegisterEventHotKey` does not require Input Monitoring permission. Therefore normal launch does not request privacy permissions. Only if future features introduce full key logging via `CGEventTap` etc. would Input Monitoring be required, and it should be tied to the enabling action of that feature.

### 5.3 Threat Model with Sandbox Off

- **Premise**: App Sandbox is off. Macro scripts can freely access files/network with user privileges.
- **Threats**:
  1. Tampering with `UserDefaults` plist → malicious `scriptPath` swap → mitigated by path restriction in 5.1-3
  2. `macroScripts` rewrite without UI → detected by `lastFingerprint` verification
  3. Exfiltration of sensitive clipboard contents by script → user responsibility (explicit via confirmation dialog)
  4. Memory exhaustion from large images passed to Macro → pre-rejected by `maxItemSizeMB`
- **Responsibility**: Script behavior is the user's responsibility. This app only provides registration confirmation and fingerprint verification.

## 6. Permissions and External Dependencies

| Permission | Purpose | Required/Optional |
|---|---|---|
| Accessibility | (1) Synthetic `Cmd+V` send. (2) Instant Preview window-close detection. | Optional (only when `needsAccessibilityForSyntheticPaste` is ON, or for faster Preview edit detection; without it Preview editing still works via app-quit/idle-timeout fallback) |
| Full Disk Access | — | Not required |
| App Sandbox | Off (to allow Macro execution freedom) | Off assumed. Distribution requires Developer ID + Notarization |

## 7. Color Design (corresponds to design-ui.md §9)

- Define `ColorSet` in `Assets.xcassets` with both **Any / Dark** appearances.
- Use SwiftUI `Color.primary` / `Color.secondary` as base, with these supplemental ColorSets:

| ColorSet | Purpose |
|---|---|
| `AppBackground` | Whole window background |
| `SelectionHighlight` | Selection highlight (vivid blue) |
| `SelectionBar` | Selection leading bar |
| `SeparatorLine` | Separator line |
| `FooterButtonBg` | Footer button background |
| `FooterButtonHover` | Footer button hover state |

## 8. Build Requirements

- Xcode 15+
- **macOS 14 (Sonoma) or later** (for `@Observable` / SwiftData APIs)
- Target: `ClipboardManager.app`
- Distribution: local build (unsigned or Developer ID, decided later)
- Note: If the app is sandboxed in the future, writing to `~/Downloads/ClipboardManagerEdit/` for Preview editing requires the `com.apple.security.files.downloads.read-write` entitlement. Currently non-sandboxed, so no entitlement needed.

## 9. Remaining Design Decisions (may be finalized later)

> See `docs/open-questions.md` for a prioritized list. Key items:

1. ~~Paste method: UI only or also synthetic Cmd+V~~ → **UI-only by default, synthetic Cmd+V as optional `AppSettings` toggle** (decided)
2. Macro extensions: fixed `.txt` / `.png` or user-configurable
3. Distribution: developer signing / notarization necessity
4. Test policy: SwiftPM unit/contract coverage and XCUITest smoke coverage exist. Infrastructure integration tests remain future work. See `docs/testing.md` for layer-selection criteria, test architecture, and the E2E isolation contract.
5. Localization: Japanese-first, use `String(localized:)` from the start to keep i18n-ready (English resources later)
6. Unimplemented UI items (`design-ui.md §10`) priority
7. Search optimization for 100,000+ items: SQLite FTS5 / N-gram index (v2+)

## 10. UI Requirements Handling

UI details (layout, pane structure, header/footer, color theme, etc.) are managed in `docs/design-ui.md`. This document focuses on technical implementation and refers to that document for UI details.
