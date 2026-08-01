# Clipboard Manager — UI Requirements

> This document defines the UI requirements for a macOS clipboard history manager.
> Functional requirements are in `docs/design-app.md`; this document covers only UI requirements.

## 1. UI Overview

- **Menu bar resident** window (no Dock icon, `LSUIElement = YES`).
- Invoked at any time by a **global hotkey**.
- Window appears at a configurable location and disappears on blur or Esc. The placement is selected in Settings:
  - **Screen center** (default): center of the screen containing the cursor.
  - **Near cursor**: position the window near the current mouse location.
- Window is utility-style: non-fullscreen, non-zoomable, always-on-top while visible. "Always-on-top" is togglable via the pin button in the header (not in Settings); when enabled the panel stays above other apps while visible and is not dismissed on blur, so users can refer to it while working in other apps.

## 2. Window Layout

Single window with three regions stacked vertically:

1. **Search bar** (top)
2. **History list** (middle, scrollable)
3. **Footer action bar** (bottom)

```
┌─────────────────────────────────────┐
│ 🔍 Search...                        │  ← Search bar
├─────────────────────────────────────┤
│ ▸ <thumbnail> <body text>           │
│ ▸ <body text>                       │  ← History list
│ ▸ <image thumbnail>                 │
│ ...                                 │
├─────────────────────────────────────┤
│ Paste | Plain Text | Edit | ⋯ │  ← Footer action bar
└─────────────────────────────────────┘
```

The window is resizable; the list pane grows/shrinks while the search bar and footer keep fixed heights.

## 3. Search Bar

- Single-line text field with a magnifying-glass icon.
- **Incremental search**: filters the list in real time as the user types.
- An image filter button shows only image history entries when active. It can be combined with incremental search.
- Search targets text content, image source app metadata, and persisted OCR text
  for images analyzed by the opt-in automatic OCR setting.
- `Esc` clears the search and closes the window.

## 4. History List

- Vertical list, one row per history entry, newest at top.
- Each row displays:
  - For text: body text (truncated with ellipsis if long), source app name, and timestamp.
  - For images: image thumbnail, source app name, and timestamp.
- The currently focused row is highlighted.
- Keyboard navigation: ↑/↓ to move focus, Enter to execute the default action (Paste).
- Hover behavior is optional; selection follows focus.

## 5. Footer Action Bar

The footer is a single horizontal bar with the following actions. Actions operate on the currently focused list row.

### 5.1 Paste

- Default action. Pastes the selected entry as rich text (or plain text if the entry is plain text).
- After paste, brings the previous app to front so the user can press `Cmd+V`.
- Enter on the list is equivalent to pressing Paste.

### 5.2 Plain Text

- Pastes the selected entry as plain text (rich text formatting is stripped).
- After paste, brings the previous app to front so the user can press `Cmd+V`.

### 5.3 Edit

- Invokes editing of the selected entry.
- Auto-dispatches by kind:
  - **Text**: Opens an inline text editor sheet. On save, a new plain text history entry is created (original preserved).
  - **Image**: Launches macOS standard Preview.app as an external process with a pre-prepared working file. When the user saves (Cmd+S) and closes the Preview window, a new image history entry is created with the edited result (original preserved). If there are no changes, no new entry is created.
- Accessibility permission is recommended for instant detection on Preview window close. Without it, detection falls back to Preview app termination or a 5-minute idle timeout.

### 5.4 More (⋯) Menu

- **Delete**: Deletes the focused entry. Asks for confirmation.
- **Clear All**: Deletes all history entries. Asks for confirmation.
- **Item Info**: Shows a popover/sheet with metadata for the focused entry (source app, timestamp, kind, size).

### 5.5 Run Macro ▾ (Optional / Future)

- If paste-macro transform scripts are registered, a dropdown shows the list of scripts.
- Selecting a script runs it against the focused entry's content and pastes the result (still requires `Cmd+V`).
- See `docs/design-app.md §2.2.2` for the macro feature contract.

## 6. Color Theme

- Support at least two themes: **Default (light)** and **Dark**.
- Themes follow the system appearance by default; a manual override is allowed via settings.
- Colors and typography follow macOS standard semantics (label, secondaryLabel, system background, accentColor) rather than hard-coded RGB.

## 7. Settings Window

A separate standard-style window (not the menu bar popup) launched from the menu bar icon menu. A sidebar separates application preferences from Macro management so transform scripts do not share the same form hierarchy as app behavior.

### 7.1 App Settings

Settings are ordered by task and use grouped form sections. Explanatory copy is
shown in section footers rather than as standalone form rows. System-provided
row separators are used; sections do not add manual dividers.

1. **General**
   - Launch at login
   - History window position (screen center / near cursor)
   - Preview text wrapping (wrap / no wrap)
2. **History**
   - Retention period (days, or Unlimited)
   - Max count
   - Max item size
3. **Keyboard Shortcuts**
   - Show ClipboardManager global hotkey
   - Optional global hotkey that opens the Macro Picker directly
   - Window-scoped Edit, Paste as Plain Text, and Macro Picker shortcuts
4. **Paste**
   - Automatic paste after selection via synthetic Cmd+V (off by default;
     requires Accessibility permission)
5. **Text Recognition**
   - Automatic OCR indexing for newly saved images (off by default)
   - Recognition language set shared by image search indexing and Paste as Plain Text
   - Explanation that recognition is on-device and does not process existing images
6. **Permissions**
   - Accessibility permission status and a button that opens System Settings
   - Explanation that the permission is used for automatic paste and Preview
     window-close detection during image editing

### 7.2 Macro Management

- A dedicated view supports Macro registration, editing, test runs, and confirmed removal.
- New Macros start as editable inline-shell examples; file-backed scripts can be selected in the editor.
- Registration and script changes require the existing trust confirmation and fingerprint capture flow.
- A saved Macro can be test-run against the currently selected history item with the same execution environment used by the main window. Test Run opens a debug console with exit status, stdout, stderr, environment variables, and a size-bounded transformed-output preview; it does not update the pasteboard or switch applications. Copy Report uses the app's monitored pasteboard boundary so the report is not re-added to history.
- Macro failure behavior and fingerprint verification are configured in this view because they apply to script execution rather than general app behavior.

## 8. Menu Bar Icon Menu

- Clicking the menu bar icon shows a small menu:
  - Show Clipboard History (same as hotkey)
  - Settings…
  - About
  - Quit
- Left-click on the menu bar icon invokes "Show Clipboard History" directly (most frequent action). Right-click or Option-click shows the menu above.

## 9. Keyboard Shortcuts

| Shortcut | Action |
|---|---|
| Global hotkey | Show/hide history window |
| `Esc` | Clear search / close window |
| `↑` / `↓` | Move focus in list |
| `Enter` | Paste |
| `Cmd+V` (in target app) | Paste from pasteboard |
| `Cmd+S` (in Preview) | Save image edit (no filename dialog) |

## 10. First-Run Experience

- On first launch, request Accessibility permission via a dialog with an "Open System Settings" button.
- Explain that the permission is recommended for instant detection when closing the Preview window during image editing; without it, the app falls back to Preview app termination or a 5-minute idle timeout.
- The app remains usable without the permission, but image edit detection is delayed.

## 11. UI Requirements Not Covered Here

Detailed visual specs (exact colors, font sizes, padding, etc.) are implementation details and belong in `docs/design-implementation.md`. This document defines only the user-facing structure and behavior.
