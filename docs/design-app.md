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
- An optional second global hotkey can open the UI and immediately show the Macro Picker overlay (equivalent to pressing the main hotkey followed by the Macro Picker action hotkey).

#### 2.1.2 History Search

- The first row is a virtual **Current Clipboard** item backed directly by the
  current eligible `NSPasteboard` payload; it does not wait for persistence.
- Rows below Current Clipboard are persisted history in reverse chronological
  order. The persisted row matching Current Clipboard is merged out of the list,
  so the second visible row represents the previous captured content.
- Concealed, auto-generated, empty, unsupported, and oversized pasteboard payloads
  are never exposed as Current Clipboard; the newest eligible history row remains
  first in those cases.
- Incremental search (real-time filtering).
- Search target is the full text of history entries.
- Image history is searchable via metadata such as the source app name and, when
  automatic image OCR is enabled, recognized text.
- An image-only filter can be toggled independently and combined with the search query.

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
- An opt-in setting runs on-device OCR for newly saved images in the background
  and stores recognized text for keyword search. Existing images are not backfilled.
- An image history entry can be edited in macOS standard Preview.app (annotations, cropping, etc.).
- Editing is performed by launching Preview.app as an external process with a pre-prepared working file. When the user saves (Cmd+S) and closes the Preview window, the edited result is saved as **a new history entry** and becomes the Current Clipboard (the original image is preserved). If there are no changes, no new entry is created.
- Image editing is also invoked via the **Edit button in the footer**. Text/image is auto-dispatched by the selected item's kind.
- Accessibility permission is recommended for instant detection on window close. Without it, completion detection falls back to Preview app termination. After 5 idle minutes, monitoring stops and the working file is preserved for recovery rather than treated as a completed edit. See `docs/design-implementation.md §4.3` for details.

### 2.1.6 Retention and Count Settings

- Retention period: configurable in days. Unlimited is also selectable.
- Max count: excess entries are auto-deleted oldest first.
- Setting changes are **reflected immediately**, and cleanup runs on change.

### 2.2 Additional Features

#### 2.2.1 Rich / Plain Paste Toggle

- History is saved as **rich text** by default. When a clipboard entry provides HTML (but not RTF/RTFD), the HTML source is preserved and used for rich paste.
- At paste time, an **option allows pasting as plain text**.
- Raw HTML is never passed to the system HTML importer or directly rendered by
  TextKit in the main app process. The source-provided plain-text
  representation is used when available. Otherwise, a bounded single-pass
  scanner derives a plain-text representation without DOM/CSS processing.
  Successful extraction enables search, Plain Text, Edit, and Macro actions.
  Formatted preview conversion is optional presentation work isolated in a
  disposable helper process with a one-second timeout. The app accepts only a
  bounded result and falls back to the safe plain preview on timeout or failure.
  If text extraction produces no text, the item remains visible and persisted;
  rich Paste and Copy stay available while text-dependent actions are unavailable.
- **Paste method**: The UI writes the appropriate type (`RTFD` / `public.html` + `NSStringPboardType` / `NSStringPboardType`) to `NSPasteboard`, then **the user presses `Cmd+V` to paste** (synthetic `Cmd+V` events are not sent by default).
  - Rationale: Synthetic `Cmd+V` goes through `AXUIElement` API and requires accessibility permission, which adds friction to first-run setup.
  - Extension candidate: A "send synthetic `Cmd+V`" option can be added via settings (future). In that case, an accessibility permission grant flow is provided separately (see `docs/design-implementation.md §6`).
- After paste, **the previous app is automatically brought to front** so the user can immediately press `Cmd+V`.
- Pasting or copying from history records the exact output payload as the newest history item. Rich paste retains its rich payload, Plain Text stores only text, and OCR stores recognized text. Macro execution and its failure fallback are excluded from this history update because Macro output follows a separate transformation workflow. Existing entries with the same content hash are replaced through normal deduplication.

#### 2.2.2 Paste Macro (Clipboard Transform Script)

Macros have three source types: Inline shell, JavaScript (JXA), and Script file.
JavaScript (JXA) runs only text input through `/usr/bin/osascript`; users implement
`main(clipboardContentString)` and it must return a string. JXA entries remain visible
but are unavailable for image input. An empty output file, including an empty JXA return,
keeps the existing fallback of pasting the original input.

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
| Paste | 2.2.1 Rich paste |
| Plain Text | 2.2.1 Plain paste |
| Run Macro ▾ | 2.2.2 Transform script invocation |
| Copy | Re-copy (no paste) |
| Edit | 2.1.4 / 2.1.5 Edit invocation |
| ⋯ (More menu) | 2.1.3 Individual delete / bulk delete / item info |

## 6. UI Requirements Handling

UI details (layout, pane structure, search bar, footer action bar, color theme, etc.) are managed separately in `docs/design-ui.md`. This document focuses on functional requirements and refers to that document for UI details.
