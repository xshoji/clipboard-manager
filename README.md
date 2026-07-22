# ClipboardManager

Copy something, then do everything else without leaving this app — run a
script on it, edit the image in Preview, or extract text from a
screenshot. Then just switch back and paste with `Cmd+V`.

<img width="1046" height="686" alt="app-image" src="https://github.com/user-attachments/assets/52b802eb-8938-4cd2-9d39-0b02171f3b99" />

---

## Why this exists

Most Mac clipboard managers make you pick two out of three: open-source
and free (Maccy), scriptable but not Mac-native (CopyQ, built with Qt),
or Mac-native with real automation but closed-source and paid (Paste,
Maus, BetterTouchTool). BetterTouchTool's clipboard manager can already annotate/edit images with its own built-in editor and run scripts on clipboard content, but it's paid, closed-source, and script execution is configured as one of BTT's many general-purpose actions rather than a dedicated, single-purpose feature.

This one is an attempt to be all three at once — open-source, free, and
built specifically for engineers who'd rather write a 5-line bash script
than learn a new automation language, with a Macro feature that's just:
register a script, get a hotkey.

The image-editing idea itself is inspired by BetterTouchTool's clipboard
manager (BTT's source isn't public, so the implementation here is
original). This app deliberately launches Preview.app as a real
external process rather than hosting an embedded editor window, so
image editing stays on documented, public macOS APIs.

### Why not BTT / Maccy / CopyQ / Maus?

|                            | ClipboardManager | BTT's Clipboard Manager | Maccy | CopyQ | Maus |
|----------------------------|:----------------:|:---:|:-----:|:------:|:----:|
| Open source                | ✅ | ❌ | ✅ | ✅ | ❌ |
| Native macOS UI (SwiftUI)  | ✅ | ✅ | ✅ | ❌<br>(Qt) | ✅ |
| Script/macro execution     | ✅<br>(any shell script) | ✅<br>(JS / shell / AppleScript / etc.) | ❌ | ✅<br>(JS / external commands) | ❌ |
| Dedicated Macro setup      | ✅<br>register a script, get a hotkey + picker | ⚠️<br>Configured as one of BTT's many general-purpose actions/triggers — more flexible, but a steeper setup for "just run a script on paste" | — | ✅<br>Dedicated command UI | — |
| Image editing              | ✅<br>(opens in Preview.app) | ✅<br>(Preview-based editor) | ❌ | ❌ | ❌ |
| On-device OCR paste        | ✅<br>built into "Paste Plain" | ⚠️<br>(separate predefined action you chain yourself) | ❌ | ❌ | ✅ |
| Fully local (no cloud sync)| ✅ | ✅ | Optional (iCloud) | ✅ | ✅ |

(Feature comparisons are based on public docs/websites as of 2026 and may
be out of date — please file an issue if something's changed.)

---

## Features

### Clipboard monitoring & search
Automatically saves text and image copies (rich text supported), with
real-time incremental search across history.

### Macro scripts
Most clipboard managers that support scripting (CopyQ, for example) use
their own scripting language or AppleScript. If you already think in
bash, that's one more language to learn for no reason. Macro scripts run
**any** scripting language via a plain shell script instead — write it
once, register it, and invoke it with its own hotkey or through the
keyboard-driven picker (`Cmd+M`) without touching the mouse.

### Image editing via Preview.app
Hit Edit on an image entry and it opens in Preview — the same editor
you already know, launched as a real external process. `Cmd+S` saves
back in place with no filename dialog, and the edited result is added
to history as a new entry (original preserved). A working copy is kept
under `~/Downloads/ClipboardManagerEdit/` while editing — see
[Image Editing via Preview.app](#image-editing-via-previewapp) below
for exactly how that's detected and made safe.

### OCR text paste
Select an image entry, run "Paste Plain", and the text in it is
recognized on-device with the Vision framework and pasted directly —
no cloud, no separate OCR app. Recognition language is configurable
(English / Japanese / Japanese + English / Chinese / Korean; default
English).

### Rich / plain paste
Choose whether to paste with formatting intact or stripped, per entry.

### Global hotkey & menu bar resident
Invoke the UI from any application with a configurable shortcut. No
Dock icon — it lives in the menu bar.

### Retention & count limits
Automatic cleanup by age and/or maximum item count, so history doesn't
grow forever.

### Fully local, no cloud sync
Clipboard history, images, and OCR recognition all stay on-device.
Nothing is uploaded anywhere, and there's no account or cloud sync —
your history never leaves the machine it was copied on.

---

## Install / Build

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

You can also open `.build/debug/ClipboardManager.app` directly from
Finder. `swift run` is still available if you want to run via the
SwiftPM executable.

#### Build and Run in one step

```bash
/Scripts/build-app.sh debug "" xxxx; rm -rf /Applications/ClipboardManager.app; mv .build/debug/ClipboardManager.app /Applications/; open /Applications/ClipboardManager.app
```

---

## Runtime Permissions

Normal use and the Carbon global hotkey do not require any additional
privacy permissions.

<details>
<summary>Accessibility (optional, recommended for image editing)</summary>

Accessibility permission is **recommended** for the best image-editing
experience.

- **Used for**: detecting when the Preview window is closed during
  image editing, so the edited image can be saved to history
  immediately.
- **Without it**: the app falls back to detecting Preview app
  termination or a 10-minute idle timeout. The app still works, but
  detection is delayed.
- **How to grant**: open System Settings → Privacy & Security →
  Accessibility, and enable ClipboardManager. The app also provides a
  button in Settings to open System Settings directly.

Synthetic `Cmd+V` event sending (if enabled in the future) would also
require Accessibility permission. It is disabled by default.

</details>

---

## Image Editing via Preview.app

The Edit button in the footer dispatches by the selected item's kind:

- **Text**: opens an inline edit sheet; saving creates a new plain text
  history entry (original preserved).
- **Image**: launches macOS standard Preview.app as an external process
  with a pre-prepared working file.

**A note on `~/Downloads`**: while an image is being edited, a working
copy is kept at `~/Downloads/ClipboardManagerEdit/<entityUUID>_edit.<ext>`
(hidden). This app writes to your Downloads folder for this reason —
Preview can't overwrite a file in another app's Application Support
directory without popping a save dialog, and `~/Downloads` is a
location Preview can save into directly, so `Cmd+S` works without a
dialog. The working file is deleted once editing is done.

<details>
<summary>Full image edit flow (click to expand)</summary>

1. The selected image is copied to a working file at:
   ```
   ~/Downloads/ClipboardManagerEdit/<entityUUID>_edit.<original extension>
   ```
   The directory and file are marked hidden. The original format/UTI
   and extension are preserved so Preview offers the correct edit
   menus.
2. Preview.app is launched explicitly via `NSWorkspace` and opens the
   working file.
3. Because the working file has real on-disk content, `Cmd+S` saves in
   place **without showing a filename dialog**.
4. File writes are watched with `DispatchSourceFileSystemObject`.
   Preview's safe-save (atomic rename) is handled by reinstalling the
   watcher after rename/delete events. File events are debounced by
   ~500 ms.
5. A SHA-256 hash check skips unchanged saves and deduplicates
   identical results. When a change is detected, the edited image is
   added as a new history entry. The session stays alive after a save
   so later saves in the same edit session are also captured.
6. Session completion is detected by any of:
   - AX `kAXUIElementDestroyedNotification` on the Preview window
     (requires Accessibility permission)
   - AX window-existence polling fallback
   - `NSWorkspace.didTerminateApplicationNotification` for the Preview
     process
   - 10-minute **idle** timeout, reset whenever the working file changes
7. On completion: final hash check, watcher cancellation, AX/run-loop
   cleanup, workspace observer removal, timer/work-item cancellation,
   retained AX refcon release, work-file deletion, and session removal.
8. Re-editing the same entity while its session is active activates
   the existing Preview app/session instead of creating a new one.
   Different entities can be edited concurrently.
9. On app startup, `cleanupOrphanedEditFiles()` deletes stale
   `*_edit.*` work files left behind by previous sessions.

### Sandboxing note

If the app is sandboxed for App Store distribution, a
`com.apple.security.files.downloads.read-write` entitlement may be
required (see `docs/design-implementation.md §8`).

</details>

---

## Test

A lightweight launch smoke test is available. It builds the app via
`swift build`, launches the executable, and verifies the process stays
alive for several seconds without crashing. It does not interact with
UI elements or clipboard history data.

```bash
swift test
```

Notes:
- Run while no other `ClipboardManager` instance is running (Carbon
  hotkey registration conflicts otherwise, though it should not crash).
- The app opens its real SwiftData store under
  `~/Library/Application Support`; the test only checks for crashes,
  not history contents. Clipboard monitoring will be active during the
  brief run.
- Intended for local execution on macOS; headless CI environments may
  not be able to launch the GUI app.

---

<details>
<summary>Development Environment & Tech Stack</summary>

| Item | Requirement |
|---|---|
| OS | macOS 14 (Sonoma) or later |
| Xcode | 15 or later (Swift 6.0+) |
| Language | Swift |
| UI framework | SwiftUI |
| Persistence | SwiftData |

| Purpose | Technology |
|---|---|
| UI | SwiftUI (`@Observable` + `@Environment`) |
| Persistence | SwiftData (`@Model`, `ModelContainer`) |
| Settings | `UserDefaults` |
| Global hotkey | Carbon `RegisterEventHotKey` |
| Clipboard monitoring | `NSPasteboard.changeCount` polling (0.5s) |
| Macro script execution | `Process` |
| Image editing | `NSWorkspace.open` + Preview.app + `DispatchSourceFileSystemObject` + AX API |

</details>

<details>
<summary>Release process</summary>

The release flow for this repository is automated with GitHub Actions.
Pushing Git tags triggers the release job.

```bash
# Release
git tag 0.0.1 && git push --tags

# Delete tag
v="0.0.1"; git tag -d "${v}" && git push origin :"${v}"

# Delete tag and recreate new tag and push
v="0.0.1"; git tag -d "${v}" && git push origin :"${v}"; git tag "${v}"; git push --tags
```

</details>

---

## License

MIT
