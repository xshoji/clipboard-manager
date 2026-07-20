# Clipboard Manager — Open Questions

> This document lists deferred or undecided items. Do **not** silently implement any of these as settled behavior. Items here require an explicit product decision before being moved to the design docs and implemented.

## 1. Paste Behavior

### 1.1 Synthetic `Cmd+V` option

- **Question**: Should the app offer an option to send a synthetic `Cmd+V` event after writing to the pasteboard, so the user does not have to press `Cmd+V` themselves?
- **Default (current)**: No. The app writes to `NSPasteboard`, brings the previous app to front, and the user presses `Cmd+V`.
- **If enabled**: Requires Accessibility permission. Must add a separate grant flow and clear UX copy. Risk of input-event permission revocation.
- **Status**: Deferred. Not blocking v1.

### 1.2 Hook script failure behavior

- **Question**: When a paste-hook transform script exits non-zero or times out, should the app paste the original content, show an error notification, or both?
- **Default (current)**: Paste the original content.
- **Status**: Deferred. Current behavior is acceptable for v1 but should be confirmed.

## 2. History Limits

### 2.1 Max item size

- **Question**: Should very large clipboard items (e.g., multi-MB images) be rejected or truncated?
- **Default (current)**: No explicit limit beyond SwiftData/persistence practical limits.
- **Status**: Deferred. Needs a concrete threshold (e.g., 10 MB) before implementing.

### 2.2 Retention period upper bound

- **Question**: What is the maximum retention period offered in the UI?
- **Default (current)**: 1 day to unlimited.
- **Status**: Effectively decided. Confirm UI copy.

### 2.3 Max count upper bound

- **Question**: What is the maximum count offered in the UI?
- **Default (current)**: 100 to 100000.
- **Status**: Effectively decided. Confirm UI copy.

## 3. Image Editing

### 3.1 Working directory location

- **Question**: Is `~/Downloads/ClipboardManagerEdit` acceptable as the working directory, or should it move to Application Support / a container path?
- **Default (current)**: `~/Downloads/.ClipboardManagerEdit` (dot-prefixed, hidden). Chosen because Preview.app is sandboxed (`com.apple.security.files.downloads.read-write` + `com.apple.security.files.user-selected.read-write` only — verified via `codesign --entitlements`) and cannot write under another app's Application Support directory without presenting a save dialog.
- **Hardening (review #7)**:
  - Directory name is dot-prefixed (`.ClipboardManagerEdit`) so Finder and Open/Save panels do not list it.
  - Each working file is prefixed with a cryptographically-random 16-char hex string (`<random>_<UUID>_edit.<ext>`) so the filename is not guessable from the entity ID alone.
  - Working files are also marked `isHidden` on disk as a secondary defense.
- **Implication**: If the app is sandboxed for App Store distribution, a `com.apple.security.files.downloads.read-write` entitlement may be required.
- **Status**: Open for distribution review. Not blocking v1 non-sandboxed. A full Application Support-based scheme ("make file, copy edits back") was evaluated and rejected because it forces Preview to present a Save dialog on Cmd+S, breaking the in-place save UX.

### 3.2 Re-edit behavior when Preview is already open

- **Question**: When the user presses Edit on an entity whose Preview session is already active, should the app (a) activate the existing Preview window, or (b) warn and ask whether to start a new session?
- **Default (current)**: (a) Activate the existing Preview session via `NSWorkspace.activate`.
- **Status**: Effectively decided. Revisit if users report confusion.

### 3.3 Idle timeout duration

- **Question**: What is the right idle timeout for an edit session that resets on file change?
- **Default (current)**: 5 minutes (was 10 minutes; reduced per review #7). Reset whenever the working file is written. Fires a user notification when the session times out so the user knows the working file was discarded.
- **Status**: Reduced. Still tunable via settings as a future option; a confirmation dialog before discarding is a candidate but deferred.

## 4. Distribution

### 4.1 Distribution channel

- **Question**: Distribute via Developer ID + notarization (outside sandbox) or via App Store (sandboxed)?
- **Default (current)**: Undecided. Build works both ways; distribution not configured.
- **Impact**: App Store sandbox affects working directory entitlements and Accessibility API usage. See `docs/design-implementation.md §8`.
- **Status**: Open. Must decide before public release.

### 4.2 Code signing & notarization

- **Question**: Should the repo include signing/notarization automation (e.g., GitHub Actions)?
- **Default (current)**: Not configured.
- **Status**: Open. Depends on 4.1.

## 5. UX

### 5.1 First-run permission copy

- **Question**: What exact wording should the first-run Accessibility permission dialog use?
- **Default (current)**: Explains that the permission is recommended for instant detection on Preview window close during image editing; without it, detection falls back to Preview app termination or a 5-minute idle timeout.
- **Status**: Deferred. Needs localization review.

### 5.2 Theme support

- **Question**: Beyond System/Light/Dark, are additional themes needed?
- **Default (current)**: System / Light / Dark.
- **Status**: Effectively decided.

## 6. Security

### 6.1 Hook script trust model

- **Question**: Is the current model (home-directory-only + SHA-256 fingerprint + registration confirmation) sufficient, or should scripts be sandboxed (e.g., restricted to read stdin/write stdout only)?
- **Default (current)**: File-path registration with fingerprint + path restriction + registration confirmation dialog.
- **Status**: Deferred. Current model is "user's own risk" by design.
