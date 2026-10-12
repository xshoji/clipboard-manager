# ClipboardManager

Copy something, then do everything else without leaving this app — run a
script on it, edit the image in Preview, or extract text from a
screenshot. Invoke the UI with a global hotkey, select an entry with the
arrow keys, and press `Enter` to paste it straight into the app you were
using.

<img width="1046" height="686" alt="app-image" src="https://github.com/user-attachments/assets/52b802eb-8938-4cd2-9d39-0b02171f3b99" />


## Demo

[demo.mp4](https://github.com/user-attachments/assets/fd4e1a87-4631-4ba8-8cc3-3faf79ce807c)




---

## Why this exists

ClipboardManager is free and open-source, with a native macOS UI and
dedicated Macro setup: register a script, get a hotkey, and run it against
the selected clipboard entry. Its image-editing feature was inspired by
BetterTouchTool's clipboard manager and independently implemented using
Preview.app and public macOS APIs.

### Why not BTT / Maccy / CopyQ / Maus?

|                            | ClipboardManager | BTT's Clipboard Manager | Maccy | CopyQ | Maus |
|----------------------------|:----------------:|:---:|:-----:|:------:|:----:|
| Open source                | ✅ | ❌ | ✅ | ✅ | ❌ |
| Native macOS UI (SwiftUI)  | ✅ | ✅ | ✅ | ❌<br>(Qt) | ✅ |
| Script/macro execution     | ✅<br>(any shell script) | ✅<br>(JS / shell / AppleScript / etc.) | ❌ | ✅<br>(JS / external commands) | ❌ |
| Dedicated Macro setup      | ✅<br>register a script, get a hotkey + picker | ⚠️<br>Configured as one of BTT's many general-purpose actions/triggers — more flexible, but a steeper setup for "just run a script on paste" | — | ✅<br>Dedicated command UI | — |
| Image editing              | ✅<br>(opens in Preview.app) | ✅<br>(built-in annotation editor) | ❌ | ❌ | ❌ |
| On-device OCR paste        | ✅<br>built into "Paste Plain" | ⚠️<br>(separate predefined action you chain yourself) | ❌ | ❌ | ✅ |

(Feature comparisons are based on public docs/websites as of 2026 and may
be out of date — please file an issue if something's changed.)

---

## Features

### Clipboard monitoring & search
Automatically saves text and image copies (rich text supported), with
real-time incremental search across history. Optional background OCR indexes
text in newly saved images entirely on-device, so screenshots can be found by
the words they contain as well as their source app.

### Macro scripts
Most clipboard managers that support scripting (CopyQ, for example) use
their own scripting language or AppleScript. If you already think in
bash, that's one more language to learn for no reason. Macro scripts run
**any** scripting language via a plain shell script instead — write it
once, register it, and invoke it with its own hotkey or through the
keyboard-driven picker (`Cmd+M`) without touching the mouse.

### Git-friendly configuration
Application settings and Macros are stored in one canonical JSON file at
`~/.config/clipboard-manager/config.json`. The app updates it automatically and
validates external edits before applying them, so the file can be managed in a
dotfiles or other Git repository. Inline code, reusable Test Inputs, and stable
Macro ordering are included. File-backed Macros store only their external script
path; the script file and its dependencies remain externally managed.

Use **Settings → App Settings → Configuration → Change and Reload Config…** to
choose an existing `config.json` or a folder for a new one. New files are
initialized from current settings; existing files require validation and
confirmation before their contents replace current settings. Location changes take effect after restart;
accepting an existing file or using **Reset Location** restarts automatically.
The previous file is never deleted automatically.

For environment overrides (`XDG_CONFIG_HOME`, `CLIPBOARD_MANAGER_CONFIG_PATH`),
path precedence, and validation rules, see
[Configuration design](docs/design-implementation.md#45-canonical-settings-and-macro-configuration).

### Image editing via Preview.app
Hit Edit on an image entry and it opens in Preview — the same editor
you already know, launched as a real external process. `Cmd+S` saves
back in place with no filename dialog, and the edited result is added
to history as a new entry (original preserved). A working copy is kept
at `~/Downloads/.ClipboardManagerEdit.<ext>` while editing. See
[Image editing and recovery](#image-editing-and-recovery) for precautions.

### OCR text paste
Select an image entry, run "Paste Plain", and the text in it is
recognized on-device with the Vision framework and pasted directly —
no cloud, no separate OCR app. Recognition language is configurable
(English / Japanese / Japanese + English / Chinese / Korean; default
English). Settings can also enable background OCR for newly saved images,
making recognized text searchable; this is off by default and does not process
existing history. "Paste Plain" reuses a saved OCR result when available instead
of analyzing the same image again.

### Rich / plain paste
Choose whether to paste with formatting intact or stripped, per entry.

### Clipboard Inspector
Open **More → Clipboard Inspector…** to inspect the selected item's captured or stored
representations, exact byte sizes, content identity hash, and text or image
metrics. Images include encoded type and pixel dimensions. Current Clipboard
also lists every pasteboard type declared by the source application without
reading unknown payloads. A metadata-only report can be copied without adding
the report itself to clipboard history.

### Global hotkey & menu bar resident
Invoke the UI from any application with a configurable shortcut. No
Dock icon — it lives in the menu bar.

### Retention & count limits
Automatic cleanup by age and/or maximum item count, so history doesn't
grow forever. Pin frequently reused entries to keep them at the top and exempt
them from automatic cleanup and Clear All History.

### Fully local, no cloud sync
Clipboard history, images, and OCR recognition all stay on-device.
Nothing is uploaded anywhere, and there's no account or cloud sync —
your history never leaves the machine it was copied on.

---

## Install / Build

### Install from a release (recommended)

Download a pre-built binary from the [Releases page](https://github.com/xshoji/clipboard-manager/releases)
and install it with the bundled install script. The script automatically
detects your Mac's architecture (Apple Silicon or Intel), downloads the
matching archive, extracts the `.app` bundle into `/Applications`, and
strips the macOS quarantine attribute.

```bash
# One-liner — installs the latest release
curl -fsSL https://raw.githubusercontent.com/xshoji/clipboard-manager/main/Scripts/install.sh | bash
```

Options:

```bash
# Install a specific version
curl -fsSL https://raw.githubusercontent.com/xshoji/clipboard-manager/main/Scripts/install.sh | bash -s 1.2.0

# Install to a custom location
curl -fsSL https://raw.githubusercontent.com/xshoji/clipboard-manager/main/Scripts/install.sh | bash -s -- --app ~/Applications/ClipboardManager.app
```

After installation, launch from `/Applications` or run `open /Applications/ClipboardManager.app`.

> **Note**: The one-liner pipes a remote script into `bash`. Review
> [`Scripts/install.sh`](Scripts/install.sh) first if you prefer to
> inspect what it does.

#### About code signing & Gatekeeper

This project is **not** enrolled in the Apple Developer Program, so the
packages distributed via GitHub Releases are **unsigned**. On recent
macOS versions, the Gatekeeper feature (File Quarantine) will prevent
the app from launching — this is expected behavior, not a bug.

To run the app manually, remove the quarantine attribute:

```bash
xattr -d com.apple.quarantine /Applications/ClipboardManager.app
```

If you used `install.sh`, this step is **performed automatically** —
the script runs `xattr -dr com.apple.quarantine` on the installed
`.app` bundle as its final step, so no manual action is required.

---

### Build from source

### 1. Clone the repository

```bash
git clone https://github.com/xshoji/clipboard-manager.git
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
Finder. To run the SwiftPM executable directly, build all products first so the
HTML preview helper exists beside the app executable:

```bash
swift build && swift run --skip-build ClipboardManager
```

#### Build and Run in one step

```bash
export CODE_SIGN_IDENTITY="Apple Development: xxxx"; ./Scripts/build-app.sh; killall "ClipboardManager"; rm -rf /Applications/ClipboardManager.app; mv .build/debug/ClipboardManager.app /Applications/; open /Applications/ClipboardManager.app
```

---

## Runtime Permissions

Normal use and the Carbon global hotkey do not require any additional
privacy permissions.

<details>
<summary>Accessibility (strongly recommended)</summary>

Accessibility permission is **strongly recommended**. Without it, two
core workflows degrade significantly:

- **Enter to paste (synthetic `Cmd+V`)**: when you select an entry and
  press `Enter`, the app writes to the pasteboard and brings the
  previous app to the front. With Accessibility permission (and the
  synthetic paste setting enabled), it also sends a synthetic `Cmd+V`
  so the entry is pasted automatically. Without it, the app stops at
  activating the previous app — you must press `Cmd+V` yourself every
  time.
- **Image editing completion detection**: Accessibility enables instant
  detection of Preview window close, so the edited image is saved to
  history as soon as you finish. Without it, closing the window is not
  detected until Preview quits. After five idle minutes, monitoring stops
  and the working file is preserved for recovery.

In short: without Accessibility, every paste requires a manual
`Cmd+V` and image edits are detected much later.

- **How to grant**: open System Settings → Privacy & Security →
  Accessibility, and enable ClipboardManager. The app also provides a
  button in Settings to open System Settings directly.

</details>

---

## Image editing and recovery

The Edit button in the footer dispatches by the selected item's kind:

- **Text**: opens an inline edit sheet; saving creates a new plain text
  history entry and makes it the current clipboard (original preserved).
- **Image**: launches macOS standard Preview.app as an external process
  with a pre-prepared working file.

The hidden working copy is `~/Downloads/.ClipboardManagerEdit.<ext>`.
Downloads lets Preview save in place with `Cmd+S` without a filename dialog.
After the edited image is added to history, the Preview window closes and
the working file is deleted. Only one image edit can be active at a time.

Failed or interrupted edits preserve the working file. After five idle
minutes, monitoring stops without deleting it. A preserved file blocks a
new edit: recover it by moving it to another location before editing again,
or remove it only if you no longer need it.

For save detection, cleanup rules, and implementation details, see
[Image editing design](docs/design-implementation.md#43-image-editing-flow-via-previewapp).

---

## Test

The Swift package provides production build and deterministic unit/contract
test tracks:

```bash
swift build
swift test
```

UI smoke tests use XCUITest through the separate E2E host:

```bash
Scripts/run-e2e-tests.sh
Scripts/run-e2e-tests.sh SmokeUITests/testSettingsAndHotkeyWorkflows
```

See [`docs/testing.md`](docs/testing.md) for prerequisites, focused runs, E2E
resource isolation, signing, internal launch configuration, and test-writing
rules.

---

<details>
<summary>Development Environment & Tech Stack</summary>

| Item | Requirement |
|---|---|
| OS | macOS 14 (Sonoma) or later |
| Xcode | 15 or later (Swift 6.0+) |

See [Technology stack](docs/design-implementation.md#1-technology-stack)
for frameworks and platform integrations.

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
