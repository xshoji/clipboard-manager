# Clipboard Manager — Functional Requirements

> This document defines the functional requirements for a macOS clipboard history manager.
> UI requirements are in `docs/design-ui.md`; this document covers only functional requirements.

## 1. Overview

A clipboard history manager running on macOS. The user can invoke the UI at any time via a global hotkey to search, edit, and paste history items, edit image history via macOS standard Preview.app, and transform paste content via scripts.

The app is **menu bar resident** and does not appear in the Dock (`LSUIElement = YES`).

## 2. Functional Requirements

### 2.1 Basic Features

#### 2.1.1 Global Shortcut Invocation

- Any hotkey can invoke the UI from any application.
- The hotkey is user-configurable.

#### 2.1.2 History Search

- Incremental search (real-time filtering).
- Search target is the full text of history entries.
- Image history is searchable via metadata such as the source app name.

#### 2.1.3 History Deletion

- Individual deletion (specify one item).
- Bulk deletion (clear all).

#### 2.1.4 History Edit (Text)

- Select an existing history entry and edit its text.
- Editing targets **plain text only** (rich text formatting is not preserved).
- The edit result is **saved as a new history entry**; the original is preserved.
- **When editing a rich text history, formatting is lost and it is saved as a new `kind = "text"` plain text entry** (spec). The `richText` attribute is set to nil.
- Editing is invoked via the **Edit button in the footer** (see `docs/design-ui.md`).

#### 2.1.5 Image History

- Image copies can be saved to history.
- An image history entry can be edited in macOS standard Preview.app (annotations, cropping, etc.).
- Editing is performed by launching Preview.app as an external process with a pre-prepared working file. When the user saves (Cmd+S) and closes the Preview window, the edited result is saved as **a new history entry** (the original image is preserved). If there are no changes, no new entry is created.
- Image editing is also invoked via the **Edit button in the footer**. Text/image is auto-dispatched by the selected item's kind.
- Accessibility permission is recommended for instant detection on window close. Without it, detection falls back to Preview app termination or a 5-minute idle timeout. See `docs/design-implementation.md §4.3` for details.

### 2.1.6 Retention and Count Settings

- Retention period: configurable in days. Unlimited is also selectable.
- Max count: excess entries are auto-deleted oldest first.
- Setting changes are **reflected immediately**, and cleanup runs on change.

### 2.2 Additional Features

#### 2.2.1 Rich / Plain Paste Toggle

- History is saved as **rich text** by default.
- At paste time, an **option allows pasting as plain text**.
- **Paste method**: The UI writes the appropriate type (`RTFD` / `NSStringPboardType`) to `NSPasteboard`, then **the user presses `Cmd+V` to paste** (synthetic `Cmd+V` events are not sent by default).
  - Rationale: Synthetic `Cmd+V` goes through `AXUIElement` API and requires accessibility permission, which adds friction to first-run setup.
  - Extension candidate: A "send synthetic `Cmd+V`" option can be added via settings (future). In that case, an accessibility permission grant flow is provided separately (see `docs/design-implementation.md §6`).
- After paste, **the previous app is automatically brought to front** so the user can immediately press `Cmd+V`.

#### 2.2.2 Paste Macro (Clipboard Transform Script)

- At paste time, **a script in any language** can transform the clipboard content.
- Multiple transformations can be **registered**.
- Each transformation can be **invoked via a shortcut** (select and run a transform script at paste time).
- Script IO is **file-based** (temp files for input/output).
- Script specification is **by file path only** (no code body in the settings UI).
- **Scripts are specified at the user's own risk** (registration is only via the settings UI).
- **Safeguards**:
  - A **confirmation dialog** is shown when **registering or changing** a script in the settings UI (warning: "This script can access your clipboard contents").
  - Before running, the **SHA256 fingerprint of the file is computed** and compared to the registered fingerprint; if mismatched, execution is aborted and the user is notified (tamper detection).
  - Scripts are **allowed only under the user's home directory** (`/System`, `/usr`, `/bin`, etc. are rejected).

## 3. App Operation Mode

- **Menu bar resident** + hotkey to show UI.
- No Dock icon (`LSUIElement = YES`).

## 4. Open Items for Implementation

Open items are centralized in `docs/open-questions.md`. Below are the key items to prioritize for v1 (see that doc for details and priorities).

| Item | Note |
|---|---|
| Retention period upper bound | Decided in UI within 1 day to unlimited |
| Max count upper bound | Assume 100 to 100000 |
| File format passed to Macro scripts | Assume `.txt` for text, `.png` for image (finalize at impl) |
| Macro script failure behavior | Paste original or error notification (can be decided later) |
| Max item size limit | Reject huge images etc. (discuss at impl) |
| Distribution form (signing/notarization) | See `design-implementation.md §8` |

## 5. Action List

| Action | Maps to requirement |
|---|---|
| Standard | 2.2.1 Rich paste |
| Paste Plain | 2.2.1 Plain paste |
| Run Macro ▾ | 2.2.2 Transform script invocation |
| Just Copy | Re-copy (no paste) |
| Edit | 2.1.4 / 2.1.5 Edit invocation |
| ⋯ (More menu) | 2.1.3 Individual delete / bulk delete / item info |

## 6. UI Requirements Handling

UI details (layout, pane structure, search bar, footer action bar, color theme, etc.) are managed separately in `docs/design-ui.md`. This document focuses on functional requirements and refers to that document for UI details.
