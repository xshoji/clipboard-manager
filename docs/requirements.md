# Clipboard Manager — Requirements Memo

> This is the original project requirement memo. It is **subordinate** to the design documents (`docs/design-app.md`, `docs/design-ui.md`, `docs/design-implementation.md`). When content here conflicts with the design docs, the design docs take precedence.

## 1. Background

A clipboard history manager running on macOS. At any time, from any application, the user can invoke the UI via a global hotkey to search/edit/paste history entries, edit image history via macOS standard Preview.app, and transform paste content via scripts.

The app is **menu bar resident** and does not appear in the Dock (`LSUIElement = YES`).

## 2. Core Requirements

1. **Clipboard history**: Capture text and image copies and store them in a persistent history.
2. **Global invocation**: Show the UI from any application via a user-configurable global hotkey.
3. **Search & paste**: Incremental search across history; paste the selected entry via `NSPasteboard` + `Cmd+V`.
4. **History edit**:
   - Text: inline edit, save as new entry (original preserved).
   - Image: edit in Preview.app as an external process; save (Cmd+S) and close window to add edited image as new entry (original preserved).
5. **Paste hook scripts**: User-registered scripts transform clipboard content at paste time; invoked via a shortcut.
6. **Retention settings**: Retention period (days, or unlimited) and max count; changes apply immediately.
7. **Plain paste toggle**: Paste as plain text (strip rich text formatting) via a dedicated action.
8. **Menu bar residency**: No Dock icon; the app lives in the menu bar.

## 3. Non-Goals (v1)

- Cloud sync of history across devices.
- History encryption at rest beyond SwiftData defaults.
- Rich text editing (text edit is plain text only).
- Built-in image editor (image editing relies on macOS standard Preview.app).
- Mobile/companion apps.

## 4. Out of Scope for This Memo

- Detailed UI layout, color theme, and interaction specs → see `docs/design-ui.md`.
- Technical architecture, persistence, hotkey handling, Preview integration, hook script execution, and distribution notes → see `docs/design-implementation.md`.
- Deferred or undecided items → see `docs/open-questions.md`.
- Implementation status → see `docs/remaining-features.md`.
