# ClipboardManager

A clipboard history manager for macOS.

Invoke the UI via a global hotkey to search, edit, and paste text/image clipboard history. The app is menu bar resident and emphasizes a workflow where you return to the previous app and paste with `Cmd+V`.


<img width="1046" height="686" alt="app-image" src="https://github.com/user-attachments/assets/85d20772-618c-4d64-aea2-45679bc8d9d4" />



---

## Features

- **Clipboard monitoring** — automatically saves text and image copies (rich text supported)
- **Incremental search** — real-time history filtering
- **Global hotkey** — invoke the UI from any application (shortcut is configurable)
- **Image history** — thumbnails for copied images, plus editing via macOS standard Preview.app
- **Rich / plain paste** — choose whether to paste with or without formatting
- **Macro scripts** — transform clipboard content at paste time with any scripting language (multiple registrations, shortcut-based invocation)
- **Macro shortcuts & picker** — run any registered Macro instantly from a per-Macro shortcut, or open a keyboard-driven picker (Cmd+M) to select and run a Macro without leaving the keyboard
- **OCR text paste** — running "Paste Plain" on an image history entry recognizes text with the on-device Vision framework and pastes the extracted text. Recognition language is configurable (English / Japanese / Japanese + English / Chinese / Korean; default English)
- **Menu bar resident** — no Dock icon; operate from the menu bar icon
- **Retention & count limits** — automatic cleanup by days and/or max count

---

## Development Environment

| Item | Requirement |
|---|---|
| OS | **macOS 14 (Sonoma) or later** |
| Xcode | **15 or later** (Swift 6.0+) |
| Language | Swift |
| UI framework | SwiftUI |
| Persistence | SwiftData |

---

## Build

### 1. Clone the repository

```bash
git clone <repository-url>
cd clipboard-manager
```

### 2. Build as a macOS app

```bash
./Scripts/build-app.sh
```

Output:

```bash
.build/debug/ClipboardManager.app
```

For a release build:

```bash
./Scripts/build-app.sh release
```

### 3. Run

```bash
open .build/debug/ClipboardManager.app
```

You can also open `.build/debug/ClipboardManager.app` directly from Finder.

`swift run` is still available if you want to run via the SwiftPM executable.

#### Build and Run

```bash
./Scripts/build-app.sh; rm -rf /Applications/ClipboardManager.app; mv .build/debug/ClipboardManager.app /Applications/; open /Applications/ClipboardManager.app
```

---

## Test

A lightweight launch smoke test is available. It builds the app via `swift build`, launches the executable, and verifies the process stays alive for several seconds without crashing. It does not interact with UI elements or clipboard history data.

```bash
swift test
```

Notes:
- Run while no other `ClipboardManager` instance is running (Carbon hotkey registration conflicts otherwise, though it should not crash).
- The app opens its real SwiftData store under `~/Library/Application Support`; the test only checks for crashes, not history contents. Clipboard monitoring will be active during the brief run.
- Intended for local execution on macOS; headless CI environments may not be able to launch the GUI app.

---

## Runtime Permissions

Normal use and the Carbon global hotkey do not require any additional privacy permissions.

### Accessibility (optional but recommended)

Accessibility permission is **recommended** for the best image-editing experience.

- **Used for**: detecting when the Preview window is closed during image editing, so the edited image can be saved to history immediately.
- **Without it**: the app falls back to detecting Preview app termination or a 10-minute idle timeout. The app still works, but detection is delayed.
- **How to grant**: open System Settings → Privacy & Security → Accessibility, and enable ClipboardManager. The app also provides a button in Settings to open System Settings directly.

Synthetic `Cmd+V` event sending (if enabled in the future) would also require Accessibility permission. It is disabled by default.

---

## Image Editing via Preview.app

The Edit button in the footer dispatches by the selected item's kind:

- **Text**: opens an inline edit sheet; saving creates a new plain text history entry (original preserved).
- **Image**: launches macOS standard Preview.app as an external process with a pre-prepared working file.

### Image edit flow

1. The selected image is copied to a working file at:
   ```
   ~/Downloads/ClipboardManagerEdit/<entityUUID>_edit.<original extension>
   ```
   The directory and file are marked hidden. The original format/UTI and extension are preserved so Preview offers the correct edit menus.
2. Preview.app is launched explicitly via `NSWorkspace` and opens the working file.
3. Because the working file has real on-disk content, `Cmd+S` saves in place **without showing a filename dialog**.
4. File writes are watched with `DispatchSourceFileSystemObject`. Preview's safe-save (atomic rename) is handled by reinstalling the watcher after rename/delete events. File events are debounced by ~500 ms.
5. A SHA-256 hash check skips unchanged saves and deduplicates identical results. When a change is detected, the edited image is added as a new history entry. The session stays alive after a save so later saves in the same edit session are also captured.
6. Session completion is detected by any of:
   - AX `kAXUIElementDestroyedNotification` on the Preview window (requires Accessibility permission)
   - AX window-existence polling fallback
   - `NSWorkspace.didTerminateApplicationNotification` for the Preview process
   - 10-minute **idle** timeout, reset whenever the working file changes
7. On completion: final hash check, watcher cancellation, AX/run-loop cleanup, workspace observer removal, timer/work-item cancellation, retained AX refcon release, work-file deletion, and session removal.
8. Re-editing the same entity while its session is active activates the existing Preview app/session instead of creating a new one. Different entities can be edited concurrently.
9. On app startup, `cleanupOrphanedEditFiles()` deletes stale `*_edit.*` work files left behind by previous sessions.

### Why Downloads?

Preview could not overwrite files in another app's Application Support directory without presenting a save dialog. Placing the working file under `~/Downloads` avoids the dialog and lets `Cmd+S` save in place. If the app is sandboxed for App Store distribution, a `com.apple.security.files.downloads.read-write` entitlement may be required (see `docs/design-implementation.md §8`).

---

## Tech Stack

| Purpose | Technology |
|---|---|
| UI | SwiftUI (`@Observable` + `@Environment`) |
| Persistence | SwiftData (`@Model`, `ModelContainer`) |
| Settings | `UserDefaults` |
| Global hotkey | Carbon `RegisterEventHotKey` |
| Clipboard monitoring | `NSPasteboard.changeCount` polling (0.5s) |
| Macro script execution | `Process` |
| Image editing | `NSWorkspace.open` + Preview.app + `DispatchSourceFileSystemObject` + AX API |

---


## Release

The release flow for this repository is automated with GitHub Actions.
Pushing Git tags triggers the release job.

```
# Release
git tag 0.0.1 && git push --tags

# Delete tag
v="0.0.1"; git tag -d "${v}" && git push origin :"${v}"

# Delete tag and recreate new tag and push
v="0.0.1"; git tag -d "${v}" && git push origin :"${v}"; git tag "${v}"; git push --tags
```


## License

MIT
