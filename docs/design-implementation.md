# Clipboard Manager — Technical Design

> This document defines the technical design for implementing the functional requirements in `docs/design-app.md` according to the UI requirements in `docs/design-ui.md`.

## 1. Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| Language | Swift 5.9+ (Xcode 15+) | Native to macOS, can access Carbon APIs |
| Minimum OS | **macOS 14 (Sonoma) or later** | `@Observable` / SwiftData require macOS 14+ APIs. macOS 13 (Ventura) is dropped |
| UI | SwiftUI | Declarative, maintainable, standard for macOS |
| State management | `@Observable` + `@Environment` | Lightweight approach without Combine (macOS 14+ macro API) |
| Persistence | **SwiftData** (`@Model`, `ModelContainer`, `ModelContext`) | Declarative with strong SwiftUI integration. `@Query` for virtual scrolling + paging. Roughly half the code of Core Data |
| Settings storage | `UserDefaults` | KVS is enough, lightweight |
| Global hotkey | Carbon `RegisterEventHotKey` | Bridged from Swift. Works even when app is not running |
| Clipboard monitoring | `NSPasteboard.changeCount` polling | Reliable, 0.25s interval |
| External process | `Process` | Macro script execution |
| Image editing | `NSWorkspace.open` + Preview.app + Accessibility API | Launch Preview as an external process, detect edit completion via file watcher + AX window destruction + NSWorkspace termination |
| Background execution | `LSUIElement = YES` | No Dock icon, menu bar resident |

> **Background on technology choices**:
> - Initially considered macOS 13 compatibility + Core Data, but `@Observable` and SwiftData are both macOS 14+ APIs, so they could not be combined.
> - The development environment is macOS 26 (Tahoe)-based, so requiring macOS 14+ does not hinder real-machine verification, so we raised the floor to macOS 14+.
> - SwiftData requires paging via `@Query` + `FetchDescriptor.fetchLimit` for use cases with 100,000+ history items (see §4.1).

## 2. Module Structure

```
ClipboardManager/
├── App/
│   ├── ClipboardApp.swift            # @main, AppDelegate
│   └── Info.plist                     # LSUIElement=YES
├── UI/                                # SwiftUI views
│   ├── MainView.swift                # 2-pane layout
│   ├── HeaderBar.swift                # Header controls
│   ├── HistoryListPane.swift         # Search bar + history list (virtual scroll)
│   ├── HistoryRowView.swift          # Single row (icon/thumbnail, title, subtitle)
│   ├── PreviewPane.swift             # Selected item preview (monospace/image)
│   ├── FooterBar.swift               # Action buttons
│   ├── TextEditView.swift            # Plain text edit (modal sheet)
│   ├── SettingsView.swift            # Retention/count, hotkey, Macro registration
│   ├── MacroScriptRowView.swift       # Macro script row editor
│   ├── HotkeyRecorderView.swift      # Hotkey recorder UI
│   └── MenuBarView.swift              # Menu bar resident UI (NSStatusItem)
├── Domain/                            # Models
│   ├── ClipboardEntity.swift         # SwiftData @Model
│   ├── MacroScript.swift             # Macro script settings model
│   ├── AppSettings.swift            # UserDefaults wrapper
│   └── DedupCache.swift              # Recent hash cache for dedup
├── Infrastructure/                    # External API integration
│   ├── ClipboardMonitor.swift        # changeCount monitor, save
│   ├── HotkeyManager.swift          # Carbon API wrapper
│   ├── PreviewImageEditor.swift      # Preview.app integration for image editing
│   ├── MacroRunner.swift              # Launch scripts via Process
│   ├── PersistenceController.swift  # SwiftData ModelContainer + cleanup
│   ├── AppIconResolver.swift         # Resolve app icon from bundleID
│   ├── ThumbnailGenerator.swift     # Image thumbnail generation
│   ├── InputPermission.swift         # Accessibility permission check/prompt
│   └── MenuBarController.swift      # NSStatusItem management
└── Resources/
    ├── Assets.xcassets               # App icon, ColorSet (Any/Dark)
    └── DefaultMacros/                 # Sample scripts (later)
```

### Layer Responsibilities

- **App**: Entry point, `AppDelegate`, `Info.plist`.
- **UI**: SwiftUI views. Reference Domain and cause side effects via Infrastructure interfaces. Layout follows `docs/design-ui.md`.
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
| Clipboard monitoring | `ClipboardMonitor` | Polls `NSPasteboard.changeCount` at 0.25s, saves on change |
| Global hotkey | `HotkeyManager` | Registers hotkeys via Carbon `RegisterEventHotKey` |
| Macro script execution | `MacroRunner` | Launches scripts via `Process`, passes IO file paths via env vars (§4.2) |
| Preview.app image editing | `PreviewImageEditor` | Launches Preview.app as an external process, detects edit completion, saves edited image (§4.3) |
| SwiftData persistence | `PersistenceController` | Builds `ModelContainer`, save + cleanup |
| App icon resolution | `AppIconResolver` | Gets `NSImage` via `NSWorkspace.shared.icon(forFile:)` from `sourceBundleID`, supplies to `HistoryRowView` |
| Image thumbnail | `ThumbnailGenerator` | Generates list-display thumbnails from image Entity |
| Accessibility permission | `InputPermission` | Prompts for permission when enabling synthetic `Cmd+V` or when Preview editing needs faster detection (see §5.2) |
| Menu bar resident | `MenuBarController` | `NSStatusItem` management, menu construction (per `design-ui.md §11`) |
| Dedup | `DedupCache` | Holds recent `dedupCacheSize` `contentHash` entries in memory for pre-save dedup |

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
    var imageData: Data?       // PNG (image history)
    var thumbnail: Data?       // For fast list display
    var sourceBundleID: String?
    var contentHash: String?   // SHA256 (for dedup)

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
| imageData | Data? | PNG (image history) |
| thumbnail | Data? | For fast list display |
| sourceBundleID | String? | Source app identifier |
| contentHash | String? | SHA256 for dedup (text or imageData) |

> **Edit handling**: Results edited in `TextEditView` are **saved as a new Entity with `kind = "text"` and `richText = nil`** (per `design-app.md §2.1.4`). The original rich text history remains as a separate Entity.
> **Search scale**: For 100,000+ items with full-text search, `LIKE` queries on `text` become heavy, so v2 should consider prefiltering using `contentHash` suffix or introducing SQLite FTS5 (see §9).

### 3.2 AppSettings (UserDefaults)

- `hotkeyKeyCode: Int`
- `hotkeyModifiers: Int`
- `retentionDays: Int` (0=unlimited)
- `maxHistoryCount: Int`
- `maxItemSizeMB: Int`
- `pollingIntervalMs: Int` (default 250)
- `dedupCacheSize: Int` (default 100) — recent hash cache size
- `macroScripts: [MacroScript]` (JSON encoded)
- `macroSameDirectoryFingerprint: Bool` (default true) — verify script fingerprint before run
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
  → Dedup check (recent hash comparison in DedupCache)
  → Insert new Entity into SwiftData ModelContext
      ※ If consecutive copies occur within the same changeCount,
        only the last observed content is saved (spec).
  → PersistenceController.enforceLimits() asynchronously
      (does not block the save flow)
```

> **`enforceLimits` execution policy**:
> - On save flow: runs asynchronously via `Task.detached` so it does not affect save latency.
> - On settings change (§4.4): debounced by 1 second (avoids full sweep on every slider tick).

### 4.2 Paste Flow

```
[UI item selection + paste command]
  → Branch:
      Rich   → write RTFD + text to NSPasteboard
      Plain  → write text only
      Macro   → write temp file → MacroRunner.run(script, inputFile)
             → read output file → write to pasteboard
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
- exit != 0 or timeout 5s is treated as "Macro failure" (see §5 response table).
- Scripts may freely output to stdout/stderr (this app does not consume them).

### 4.3 Image Editing Flow via Preview.app

The image editing feature uses macOS standard Preview.app as an external process, not the previous Markup sharing service. The previous Markup-based `MarkupIntegrator` has been removed and replaced with `PreviewImageEditor`.

Rationale: The Markup sharing service had issues with service identifier instability across macOS versions and unreliable result retrieval. Launching Preview.app directly with a pre-prepared working file provides a more stable editing experience and avoids the save dialog (file name specification) that appears when opening an in-memory image directly.

```
[Image history selected + Edit button pressed]
  → PreviewImageEditor.editImage(entity):
      1. Create working file:
         - Copy the original image to `<workDir>/<entity.id>_edit.<ext>`
         - Work directory: ~/Downloads/ClipboardManagerEdit/ (Preview is sandboxed
           and cannot write to other apps' Application Support; Downloads is
           user-writable. Hidden attribute is set to keep it out of Finder.)
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
          e. Idle timeout (final safety net): 5 minutes (was 10 minutes; reduced per
             review #7) after the last file write, the session is force-finalized and a
             user notification is posted. Each file change resets the timer, so long
             editing sessions are not interrupted as long as saves continue.
      4. On any detector firing:
         - performHashCheck: read the working file, compute SHA256, compare to
           the original hash AND the last saved hash (dedup guard for Preview
           auto-save). If different, save as a new ClipboardEntity.
         - teardown: cancel all watchers (file source, AX observer run loop source,
           window polling work item, timeout work item, NSWorkspace observer),
           release the AX refcon box, delete the working file, remove the session.
```

Key behaviors:
- **No save dialog**: Because the working file is a real on-disk file at a user-writable path, Cmd+S in Preview overwrites it directly. No file name modal appears.
- **Multiple saves per session**: Each Cmd+S within a session saves a new history entry (deduped by `lastSavedHash`). The session continues until window close / app exit / idle timeout.
- **Concurrent edits**: Each session uses a unique working file path derived from the entity UUID, so editing multiple images simultaneously does not conflict. Re-editing the same entity while a session is active brings the existing Preview window to the front instead of starting a new session (avoids deleting and recreating the working file under the live Preview window).
- **Accessibility permission**: Required for instant detection on window close (detectors b and c). Without it, only detector d (Preview quit) and e (5-min idle) terminate the session, so monitoring may linger after the window is closed. The app notifies the user to enable Accessibility in Settings → Paste Behavior when AX is not trusted.
- **Cleanup on launch**: `AppDelegate` calls `PreviewImageEditor.shared.cleanupOrphanedEditFiles()` at startup to delete any `*_edit.*` files left from a previous crashed session. Additionally, `AppDelegate` starts `PreviewImageEditor.shared.startOrphanCleanupTimer()` which sweeps orphaned files every 5 minutes (review #7), so crashed-session files do not sit in Downloads between launches.
- **Working file location & naming (review #7)**: Files live under `~/Downloads/.ClipboardManagerEdit/` (dot-prefixed so Finder hides it). Each file is named `<random16hex>_<UUID>_edit.<ext>` using a cryptographically-random prefix (`SecRandomCopyBytes`) so the filename is not guessable. This is hardening, not a full Application Support migration — Preview.app is sandboxed and cannot write to another app's Application Support directory without presenting a save dialog, so Downloads is kept as the working location to preserve the in-place `Cmd+S` UX.
- **AX refcon lifetime**: The `SessionBox` passed as the AX observer refcon is `Unmanaged.passRetained` so it survives until `teardown` explicitly `release()`s it, even if the session is removed from the dictionary before a late AX callback fires.

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

## 5. Technical Concerns and Mitigations

| Concern | Mitigation |
|---|---|
| Paste method | Simple approach: write to pasteboard then activate previous app. Synthetic Cmd+V requires accessibility, so not prioritized (`AppSettings.needsAccessibilityForSyntheticPaste` for future) |
| Plain text paste | Set only `NSStringPboardType` on `NSPasteboard` (do not co-write RTF) |
| Macro file format | Assume `.txt` for text and `.png` for image. Detect output with same extension |
| Macro failure | 5s timeout, exit != 0 → user notification + paste original content (default, configurable) |
| Large image rejection | `maxItemSizeMB` in UserDefaults, skip save + notify on exceed. Default 10MB |
| Dedup | Recent SHA256 hash cache (`dedupCacheSize` default 100) |
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
| Accessibility | (1) Synthetic `Cmd+V` send via `AXUIElement`. (2) `PreviewImageEditor` window-close detection via `AXObserver`/`AXUIElementCopyAttributeValue` for instant edit completion. | Not requested by default. Prompted when `needsAccessibilityForSyntheticPaste` is turned on, or when `PreviewImageEditor` launches and `AXIsProcessTrusted()` is false (notification directs user to Settings → Paste Behavior). Without the permission, Preview editing still works but completion is detected only on Preview quit or 5-min idle timeout. |
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
4. Test policy: XCTest unit tests (`ClipboardMonitor`, `PersistenceController`, `MacroRunner`, `PreviewImageEditor` prioritized) + XCUITest automation later
5. Localization: Japanese-first, use `String(localized:)` from the start to keep i18n-ready (English resources later)
6. Unimplemented UI items (`design-ui.md §10`) priority
7. Search optimization for 100,000+ items: SQLite FTS5 / N-gram index (v2+)

## 10. UI Requirements Handling

UI details (layout, pane structure, header/footer, color theme, etc.) are managed in `docs/design-ui.md`. This document focuses on technical implementation and refers to that document for UI details.
