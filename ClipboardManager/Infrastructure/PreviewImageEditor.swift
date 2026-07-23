import AppKit
import ApplicationServices
import CryptoKit
import UniformTypeIdentifiers

/// Edits an image from history using macOS Preview.app, then saves the edited image as a new history entry.
///
/// Design intent (spec-compliant):
/// - Launch Preview as an external process instead of embedding it in the app.
/// - Prepare a real file (`.ClipboardManagerEdit.<ext>`) beforehand so that Cmd+S does not show a save dialog.
///   Open it in Preview. The extension and UTI match the original image.
///   The working file uses a fixed path (directly in Downloads) so safe-save's inode churn
///   stays on a constant path, eliminating the "file not found" race that occasionally lost edits.
/// - Because the path is fixed, only one edit session may be active at a time. If the user
///   triggers Edit while another session is active, an alert is shown and the new edit is rejected.
/// - Edit completion detection uses a two-stage approach:
///   1. Main: Accessibility API monitors the target document window's
///      `kAXUIElementDestroyedNotification`, triggering immediately when the window closes.
///   2. Fallback: `NSWorkspace.didTerminateApplicationNotification` catches the target PID's
///      Preview process termination (safety net when AX permission is missing or a window close is missed).
/// - Cleans up leftovers (`.ClipboardManagerEdit.*`) from previous sessions at app launch.
/// - Determines whether changes were made via SHA256 hash diff, and deletes the working file if unchanged.
@MainActor
final class PreviewImageEditor {
    static let shared = PreviewImageEditor()

    /// Carrier for the session identifier passed as AX refcon.
    /// `@unchecked Sendable`: holds only an immutable UUID, safe to read from a C callback.
    final class SessionBox: @unchecked Sendable {
        let sessionID: UUID
        init(sessionID: UUID) { self.sessionID = sessionID }
    }

    /// Editing session state. Each session is monitored independently.
    private struct Session {
        let id: UUID
        let entityID: UUID
        let workFile: URL
        let originalHash: String
        let pid: pid_t
        let box: SessionBox
        var runningApp: NSRunningApplication?
        var axObserver: AXObserver?
        var axObserversInstalled: Bool
        var debounceWork: DispatchWorkItem?
        var didFinish: Bool
        var terminateObserver: NSObjectProtocol?
       var fileWatchSource: DispatchSourceFileSystemObject?
       var lastSavedHash: String?
       var windowPollWork: DispatchWorkItem?
       var sessionTimeoutWork: DispatchWorkItem?
       /// Retained to release the `box` passed as refcon to the AX callback.
       /// Because it was passed with `passRetained`, it is not released until `release()` is called in teardown.
       var boxRefcon: UnsafeMutableRawPointer?
      /// Watches the parent directory while the work file is temporarily absent during
      /// Preview's safe-save (temp file → delete original → rename). Once the work file
      /// reappears, the per-file watcher is reinstalled.
      var dirWatchSource: DispatchSourceFileSystemObject?
    }

    private var sessions: [UUID: Session] = [:]

    /// Internal editing-status flag. This is the single source of truth for whether an
    /// image edit session is currently active.
    ///
    /// Set to `true` at the start of `editImage` (before launching Preview), and reset to
    /// `false` when the session ends — either in `teardown` (triggered by Preview window
    /// close, Preview termination, or session idle timeout) or on any error path that
    /// aborts the edit before a session is registered.
    ///
    /// `editImage` gates on this flag instead of checking for the existence of the fixed
    /// working file (`.ClipboardManagerEdit.<ext>`). This means that even if a stale file
    /// remains on disk (e.g., the previous Preview window was closed without saving and
    /// the file was not cleaned up), a new edit can start by overwriting the file.
    private var isEditing = false

    /// Working file path prefix: ~/Downloads/.ClipboardManagerEdit
    /// Preview.app is a sandboxed app and cannot write under other apps' Application Support directories.
    /// Place it under Downloads, where the user can write, so Cmd+S does not show a save dialog.
    ///
    /// The file is placed directly in Downloads (no subdirectory) with a dot-prefixed name
    /// (`.ClipboardManagerEdit.<ext>`) so Finder and Open/Save panels do not list it by default.
    /// Because concurrent edits are rejected by `editImage`, a single fixed file is sufficient
    /// and the filename race that lost edits under unique-per-session names is eliminated.
    ///
    /// Working files are deleted after the edit session ends, and a periodic orphan cleanup
    /// (`startOrphanCleanupTimer`) runs every 5 minutes so files left behind by a crash do
    /// not sit in Downloads until the next app launch.
    ///
    /// Note: If this app is sandboxed, writing to Downloads requires
    /// the `com.apple.security.files.downloads.read-write` entitlement.
    /// Currently unsandboxed, so no issue, but verify when distributing (notarization/App Store).
    private let workFilePrefix: URL = {
        let downloads = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first!
        return downloads.appendingPathComponent(".ClipboardManagerEdit")
    }()

    /// Timer that periodically sweeps orphaned `.ClipboardManagerEdit.*` files left behind by crashed sessions.
    /// Without this, files from a crashed session would sit in Downloads until the next app
    /// launch. Runs every 5 minutes so the exposure window is bounded (review #7).
    private var orphanCleanupTimer: DispatchSourceTimer?
    private let orphanCleanupIntervalSec: Int = 5 * 60

    /// Idle timeout for an edit session. When the working file has not been written for this
    /// duration, the session is force-completed (working file deleted, watchers torn down).
    /// Reduced from 10 minutes to 5 minutes per review #7 to bound the exposure of the
    /// working file sitting in Downloads.
    private let sessionIdleTimeoutSec: Int = 5 * 60

   /// When a file-change debounce fires but the work file cannot be read (Preview's safe-save
   /// has deleted the original and not yet renamed the temp file into place), retry reading
   /// at this interval until the file reappears.
   private let fileReadRetryInterval: TimeInterval = 0.3

   /// Maximum number of read retries before giving up on a single file-change event.
   /// 10 × 0.3s = 3s covers Preview's safe-save window for typical images.
   private let maxFileReadRetries: Int = 10

    private static let previewBundleID = "com.apple.Preview"

    private init() {}

    /// True when at least one editing session has not finished.
    /// Used by AppDelegate to suppress the blur-auto-close of the history window
    /// while the user is editing an image in Preview.app, so they can verify
    /// that the saved image was appended to the history.
    var hasActiveSession: Bool {
        isEditing
    }

    /// Tears down every active edit session. Called by AppDelegate on termination so
    /// AX observers, file watchers, terminate observers, and DispatchWorkItems are
    /// released deterministically instead of leaking until process exit.
    func teardownAllSessions() {
        let ids = Array(sessions.keys)
        for id in ids {
            teardown(sessionID: id)
        }
        isEditing = false
        stopOrphanCleanupTimer()
    }

    /// Starts a periodic orphan cleanup. Called by AppDelegate at launch (alongside
    /// `cleanupOrphanedEditFiles()`) so crashed-session files do not accumulate in
    /// Downloads between launches (review #7).
    func startOrphanCleanupTimer() {
        guard orphanCleanupTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(orphanCleanupIntervalSec), repeating: .seconds(orphanCleanupIntervalSec))
        t.setEventHandler { [weak self] in
            self?.cleanupOrphanedEditFiles()
        }
        t.resume()
        orphanCleanupTimer = t
    }

    func stopOrphanCleanupTimer() {
        orphanCleanupTimer?.cancel()
        orphanCleanupTimer = nil
    }

    // MARK: - Public entry

    func editImage(entity: ClipboardEntity) {
        // Gate on the internal editing-status flag. Unlike file-existence checks,
        // this flag is reliably reset by the window-close monitoring teardown, so a
        // stale `.ClipboardManagerEdit.<ext>` file left behind by a previous session
        // does not block the next edit — the file is simply overwritten below.
        if isEditing {
            let alert = NSAlert()
            alert.messageText = "Image edit already in progress"
            alert.informativeText = "Another image is being edited in Preview. Please close that edit first, then start a new one."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window) { _ in }
            } else {
                alert.runModal()
            }
            return
        }

        isEditing = true

        guard let data = entity.imageData, !data.isEmpty else {
            isEditing = false
            AppNotifier.notify(
                title: "Image cannot be edited",
                body: "The selected item has no image data.",
                deduplicationKey: "preview-edit-no-data"
            )
            return
        }

        let ext = fileExtension(for: data)
        // Fixed working file path: ~/Downloads/.ClipboardManagerEdit.<ext>
        // Because concurrent edits are rejected by `isEditing` above, a single fixed path
        // covers all sessions; safe-save's inode churn stays on this constant path,
        // eliminating the "file not found" race that occasionally lost edits.
        // If a stale file from a previous session remains, it is overwritten by the
        // atomic write below.
        let workFile = workFilePrefix.appendingPathExtension(ext)
        do {
            try data.write(to: workFile, options: .atomic)
            try? (workFile as NSURL).setResourceValue(true, forKey: .isHiddenKey)
        } catch {
            isEditing = false
            AppNotifier.notify(
                title: "Image cannot be edited",
                body: "Failed to prepare a working file: \(error.localizedDescription)",
                deduplicationKey: "preview-edit-workfile"
            )
            return
        }

        guard let previewURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.previewBundleID
        ) else {
            isEditing = false
            AppNotifier.notify(
                title: "Preview unavailable",
                body: "Preview.app could not be located on this system.",
                deduplicationKey: "preview-app-missing"
            )
            try? FileManager.default.removeItem(at: workFile)
            return
        }

        let originalHash = HashUtil.sha256Hex(of: data)
        let entityID = entity.id
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(
            [workFile],
            withApplicationAt: previewURL,
            configuration: config
        ) { [weak self] runningApp, error in
            Task { @MainActor in
                self?.onPreviewLaunched(
                    runningApp: runningApp,
                    error: error,
                    entityID: entityID,
                    workFile: workFile,
                    originalHash: originalHash
                )
            }
        }
    }

    // MARK: - Launch completion

    private func onPreviewLaunched(
        runningApp: NSRunningApplication?,
        error: Error?,
        entityID: UUID,
        workFile: URL,
        originalHash: String
    ) {
        if let error {
            isEditing = false
            AppNotifier.notify(
                title: "Preview launch failed",
                body: error.localizedDescription,
                deduplicationKey: "preview-launch-failed"
            )
            try? FileManager.default.removeItem(at: workFile)
            return
        }
        guard let runningApp else {
            isEditing = false
            AppNotifier.notify(
                title: "Preview launch failed",
                body: "Preview.app did not start.",
                deduplicationKey: "preview-launch-failed"
            )
            try? FileManager.default.removeItem(at: workFile)
            return
        }

        let sessionID = UUID()
        let box = SessionBox(sessionID: sessionID)
        let session = Session(
            id: sessionID,
            entityID: entityID,
            workFile: workFile,
            originalHash: originalHash,
            pid: runningApp.processIdentifier,
            box: box,
            runningApp: runningApp,
            axObserver: nil,
            axObserversInstalled: false,
            debounceWork: nil,
            didFinish: false,
            terminateObserver: nil
        )
        sessions[sessionID] = session

        installTerminateObserver(for: sessionID, pid: runningApp.processIdentifier)
       installFileWatcher(for: sessionID)
       startWindowPolling(for: sessionID)
       rescheduleSessionTimeout(for: sessionID)
        startAXPolling(for: sessionID)

        if !AXIsProcessTrusted() {
            AppNotifier.notify(
                title: "Enable Accessibility for faster edit detection",
                body: "Grant Accessibility permission so edited images are saved as soon as you close the Preview window. Without it, saving happens only after Preview quits. Enable it in Settings → Paste Behavior.",
                deduplicationKey: "preview-edit-ax-hint"
            )
        }
    }

    // MARK: - File change watcher (primary detection)

   /// Periodically checks Preview's window list and ends the session when the target window closes.
    /// AX notifications alone can miss closures due to permission or window-matching issues, so polling ensures reliable detection.
    /// Skipped when AX permission is absent since it would be wasted effort.
   private func startWindowPolling(for sessionID: UUID) {
       guard AXIsProcessTrusted() else { return }
       let work = DispatchWorkItem { [weak self] in
           Task { @MainActor in
               self?.pollWindowExistence(sessionID: sessionID)
           }
       }
       sessions[sessionID]?.windowPollWork = work
       DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
   }

   private func pollWindowExistence(sessionID: UUID) {
       guard let s = sessions[sessionID], !s.didFinish else { return }
       let appEl = AXUIElementCreateApplication(s.pid)
       var windowsRef: CFTypeRef?
       AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
       let windows = (windowsRef as? [AXUIElement]) ?? []
       let targetStem = s.workFile.deletingPathExtension().lastPathComponent
       let targetName = s.workFile.lastPathComponent
       let exists = windows.contains { window in
           var titleRef: CFTypeRef?
           AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
           let title = titleRef as? String
           var docRef: CFTypeRef?
           AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
           let doc = docRef as? String
           return (title == targetStem)
               || (doc?.hasSuffix(targetName) ?? false)
               || (doc?.contains(targetName) ?? false)
       }
       if !exists {
           scheduleHashCheck(for: sessionID, delay: 0.3)
           return
       }
       let next = DispatchWorkItem { [weak self] in
           Task { @MainActor in
               self?.pollWindowExistence(sessionID: sessionID)
           }
       }
       sessions[sessionID]?.windowPollWork = next
       DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: next)
   }

    /// Final safety net: times out after a period of idle time since the last file write,
    /// forcing the session to end. Prevents monitoring from persisting when AX permission is missing and Preview is not quit.
    /// Rescheduled on every file change, so it is not discarded during long edits unless idle.
    ///
    /// Timeout reduced from 10 minutes to 5 minutes per review #7 to bound the exposure of
    /// the working file sitting in Downloads. The user is notified when the timeout fires
    /// so they know the edit was discarded and can restart it if needed.
    private func rescheduleSessionTimeout(for sessionID: UUID) {
        sessions[sessionID]?.sessionTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let s = self.sessions[sessionID], !s.didFinish else { return }
                AppNotifier.notify(
                    title: "Image edit session timed out",
                    body: "The Preview edit session has been idle for \(Int(self.sessionIdleTimeoutSec / 60)) minutes and was closed. The working file was discarded. Start the edit again to continue.",
                    deduplicationKey: "preview-edit-timeout-\(sessionID.uuidString)"
                )
                self.performHashCheck(sessionID: sessionID)
            }
        }
        sessions[sessionID]?.sessionTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sessionIdleTimeoutSec), execute: work)
    }

    /// Watches the working file for changes and runs a hash diff check the moment an overwrite save (Cmd+S) occurs.
    /// Preview may use safe-save (temp file → atomic rename), which can change the inode,
    /// so reinstall the watcher from the path on `.rename` / `.delete` events.
    private func installFileWatcher(for sessionID: UUID) {
        guard let s = sessions[sessionID] else { return }
        reinstallFileWatcher(for: sessionID, path: s.workFile.path)
    }

    private func reinstallFileWatcher(for sessionID: UUID, path: String) {
        sessions[sessionID]?.fileWatchSource?.cancel()
        sessions[sessionID]?.fileWatchSource = nil
        if !FileManager.default.fileExists(atPath: path) {
           // Preview's safe-save deletes the original file before renaming the temp file into
           // place, so the work file may briefly not exist. Watch the parent directory so we
           // can reinstall the per-file watcher the moment the file reappears. Without this,
           // a save that lands in this window is missed until the window closes.
           installParentDirWatcher(for: sessionID, path: path)
           return
       }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.handleFileWatchEvent(sessionID: sessionID)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        sessions[sessionID]?.fileWatchSource = source
    }

   /// Installs a watcher on the work file's parent directory while the work file is temporarily
   /// missing during Preview's safe-save. When the work file reappears (rename complete),
   /// the per-file watcher is reinstalled and a hash check is scheduled so the saved image
   /// is picked up immediately instead of waiting for window close.
   private func installParentDirWatcher(for sessionID: UUID, path: String) {
       sessions[sessionID]?.dirWatchSource?.cancel()
       sessions[sessionID]?.dirWatchSource = nil
       let parentDir = (path as NSString).deletingLastPathComponent
       guard FileManager.default.fileExists(atPath: parentDir) else { return }
       let fd = open(parentDir, O_EVTONLY)
       guard fd >= 0 else { return }
       let source = DispatchSource.makeFileSystemObjectSource(
           fileDescriptor: fd,
           eventMask: [.write],
           queue: .main
       )
       source.setEventHandler { [weak self] in
           Task { @MainActor in
               guard let self, let s = self.sessions[sessionID], !s.didFinish else { return }
               guard FileManager.default.fileExists(atPath: path) else { return }
               self.sessions[sessionID]?.dirWatchSource?.cancel()
               self.sessions[sessionID]?.dirWatchSource = nil
               self.reinstallFileWatcher(for: sessionID, path: path)
               self.scheduleFileChangeDebounce(for: sessionID)
           }
       }
       source.setCancelHandler { close(fd) }
       source.resume()
       sessions[sessionID]?.dirWatchSource = source
   }

    private func handleFileWatchEvent(sessionID: UUID) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        let event = s.fileWatchSource?.data ?? []
        // The inode may have changed due to safe-save, so reopen the watcher from the path.
        if event.contains(.rename) || event.contains(.delete) {
            reinstallFileWatcher(for: sessionID, path: s.workFile.path)
        } else if !FileManager.default.fileExists(atPath: s.workFile.path) {
            // A `.write` event arrived but the work file is gone — Preview's safe-save
            // deleted the original and has not yet renamed the temp file into place.
            // Without this, no `.rename`/`.delete` event triggers `reinstallFileWatcher`,
            // so the parent-dir watcher is never installed and the file reappearance
            // is missed entirely (root cause of "edited image not saved to history"
            // when saving a large multi-annotation edit).
            installParentDirWatcher(for: sessionID, path: s.workFile.path)
        }
        scheduleFileChangeDebounce(for: sessionID)
    }

    /// Checks file changes with debounced hash checks.
    /// Consolidates multiple consecutive FS events from safe-save into a single check.
    private func scheduleFileChangeDebounce(for sessionID: UUID) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        s.debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performFileChangeCheck(sessionID: sessionID)
            }
        }
        sessions[sessionID]?.debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Hash check when a file change is detected. The session continues (final teardown on window close / termination).
    /// Skips if the hash matches the original image or the last saved hash (duplicate guard for auto-save).
    /// File read and hash computation run on a background task so the main actor is not
    /// blocked while processing large edited images (prevents spinning-rainbow cursor).
    private func performFileChangeCheck(sessionID: UUID, retryCount: Int = 0) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        guard let workData = try? Data(contentsOf: s.workFile) else {
           // Preview's safe-save deletes the original file and renames a temp file into place.
           // The read may land in that brief window; retry until the file reappears so the
           // saved image is captured immediately rather than only on window close.
           if retryCount < maxFileReadRetries {
               let work = DispatchWorkItem { [weak self] in
                   Task { @MainActor in
                       self?.performFileChangeCheck(sessionID: sessionID, retryCount: retryCount + 1)
                   }
               }
               sessions[sessionID]?.debounceWork = work
               DispatchQueue.main.asyncAfter(deadline: .now() + fileReadRetryInterval, execute: work)
           } else {
               // Retries exhausted — the file is still absent (large-image safe-save
               // can take longer than 3 s). Install a parent-dir watcher so the moment
               // the file reappears we pick it up. Without this, the session silently
               // loses the save event and the edited image never enters history.
               installParentDirWatcher(for: sessionID, path: s.workFile.path)
           }
           return
       }
        let originalHash = s.originalHash
        let lastSavedHash = s.lastSavedHash
        Task.detached(priority: .userInitiated) { [weak self] in
            let hash = HashUtil.sha256Hex(of: workData)
            guard hash != originalHash else { return }
            guard hash != lastSavedHash else { return }
            let maxBytes = AppSettings.shared.maxItemSizeMB * 1024 * 1024
            guard workData.count <= maxBytes else {
                await MainActor.run {
                    AppNotifier.notify(
                        title: "Edited image not saved",
                        body: "The edited image exceeds the \(AppSettings.shared.maxItemSizeMB) MB size limit.",
                        deduplicationKey: "edited-image-size-limit"
                    )
                }
                return
            }
            await MainActor.run {
                self?.saveToHistory(data: workData, hash: hash)
                self?.sessions[sessionID]?.lastSavedHash = hash
                self?.rescheduleSessionTimeout(for: sessionID)
                // After a successful save, close the Preview window automatically
                // (the edit's purpose is fulfilled). Only the session's window is
                // closed; other Preview windows are left untouched.
                self?.closePreviewWindow(for: sessionID)
            }
        }
    }

    // MARK: - AX window detection (main)

    /// Waits briefly for Preview to open the window, then installs `kAXUIElementDestroyedNotification` on the target file's window.
    /// Polls for up to 3 seconds.
    private func startAXPolling(for sessionID: UUID) {
        let start = Date()
        pollAXOnce(sessionID: sessionID, start: start)
    }

    private func pollAXOnce(sessionID: UUID, start: Date) {
        guard sessions[sessionID] != nil,
              sessions[sessionID]?.axObserversInstalled == false,
              sessions[sessionID]?.didFinish == false else { return }
        if Date().timeIntervalSince(start) > 3.0 { return }
        installAXObserver(for: sessionID)
        if sessions[sessionID]?.axObserversInstalled == true { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollAXOnce(sessionID: sessionID, start: start)
        }
    }

    private func installAXObserver(for sessionID: UUID) {
        guard var s = sessions[sessionID], !s.axObserversInstalled, !s.didFinish else { return }
        let appEl = AXUIElementCreateApplication(s.pid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (windowsRef as? [AXUIElement]) ?? []
        let targetStem = s.workFile.deletingPathExtension().lastPathComponent
        let targetName = s.workFile.lastPathComponent

        for window in windows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String
            var docRef: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
            let doc = docRef as? String
            let matched = (title == targetStem)
                || (doc?.hasSuffix(targetName) ?? false)
                || (doc?.contains(targetName) ?? false)
            guard matched else { continue }

            var observer: AXObserver?
            let callback: AXObserverCallback = previewAXWindowDestroyedCallback
            guard AXObserverCreate(s.pid, callback, &observer) == .success,
                  let observer else { return }
            let refcon = Unmanaged.passRetained(s.box).toOpaque()
            let r = AXObserverAddNotification(
                observer,
                window,
                kAXUIElementDestroyedNotification as CFString,
                refcon
            )
            if r == .success {
                CFRunLoopAddSource(
                    CFRunLoopGetMain(),
                    AXObserverGetRunLoopSource(observer),
                    .defaultMode
                )
                s.axObserver = observer
                s.axObserversInstalled = true
               s.boxRefcon = refcon
                sessions[sessionID] = s
           } else {
               // If adding the notification fails, the observer is automatically released by Swift ARC when leaving this scope (CFRelease is unavailable from Swift).
               // Explicitly release only the retain count of the passRetained box.
               Unmanaged<PreviewImageEditor.SessionBox>.fromOpaque(refcon).release()
            }
            return
        }
    }

    func onWindowDestroyed(sessionID: UUID) {
        // Give Preview time to finish writing when the window closes.
        scheduleHashCheck(for: sessionID, delay: 0.5)
    }

    // MARK: - NSWorkspace terminate fallback

    private func installTerminateObserver(for sessionID: UUID, pid: pid_t) {
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier == pid else { return }
            Task { @MainActor in
                self?.onPreviewTerminated(sessionID: sessionID)
            }
        }
        sessions[sessionID]?.terminateObserver = observer
    }

    private func onPreviewTerminated(sessionID: UUID) {
        // Check immediately on termination. Double-fire is prevented by didFinish / debounce.
        scheduleHashCheck(for: sessionID, delay: 0.0)
    }

    // MARK: - Hash diff + history save

    private func scheduleHashCheck(for sessionID: UUID, delay: TimeInterval) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        s.debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.performHashCheck(sessionID: sessionID)
            }
        }
        sessions[sessionID]?.debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performHashCheck(sessionID: UUID) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        sessions[sessionID]?.didFinish = true

       if let workData = try? Data(contentsOf: s.workFile) {
            let originalHash = s.originalHash
            let lastSavedHash = s.lastSavedHash
            Task.detached(priority: .userInitiated) { [weak self] in
                let hash = HashUtil.sha256Hex(of: workData)
                guard hash != originalHash, hash != lastSavedHash else {
                    await MainActor.run {
                        self?.teardown(sessionID: sessionID)
                    }
                    return
                }
                let maxBytes = AppSettings.shared.maxItemSizeMB * 1024 * 1024
                guard workData.count <= maxBytes else {
                    await MainActor.run {
                        self?.teardown(sessionID: sessionID)
                    }
                    return
                }
                await MainActor.run {
                    self?.saveToHistory(data: workData, hash: hash)
                    self?.sessions[sessionID]?.lastSavedHash = hash
                    self?.teardown(sessionID: sessionID)
                }
            }
       } else {
            teardown(sessionID: sessionID)
       }
    }

    private func saveToHistory(data: Data, hash: String) {
        guard let persistence = PersistenceController.shared else { return }
        // Thumbnail generation (lockFocus → tiffRepresentation) is heavy for large
        // images; run it on a background task so the main actor is not blocked.
        Task.detached(priority: .userInitiated) {
            let thumb = ThumbnailGenerator.thumbnailData(from: data, maxEdge: 64)
            await MainActor.run {
                let entity = ClipboardEntity(
                    kind: "image",
                    imageData: data,
                    thumbnail: thumb,
                    contentHash: hash
                )
                let ctx = persistence.container.mainContext
                ctx.insert(entity)
                do {
                    try ctx.save()
                    persistence.scheduleEnforceWithDebounce()
                } catch {
                    ctx.delete(entity)
                    AppNotifier.notify(
                        title: "Edited image not saved",
                        body: "The edited image could not be added to clipboard history.",
                        deduplicationKey: "edited-image-save-failed"
                    )
                }
            }
        }
    }

    // MARK: - Close Preview window

    /// Closes the Preview window for the given session after a successful save.
    ///
    /// Uses the AX API to press the target window's close button when Accessibility
    /// permission is granted (consistent with the existing AX-based detection). Falls
    /// back to AppleScript when AX is not available, targeting the window by file name.
    /// Only the window matching this session's work file is closed; other Preview
    /// windows are left untouched.
    ///
    /// After issuing the close, focus is restored to the ClipboardManager history
    /// window on a delay so the close action is not interrupted by activating this app.
    private func closePreviewWindow(for sessionID: UUID) {
        guard let s = sessions[sessionID], !s.didFinish else { return }
        var didCloseViaAX = false

        if AXIsProcessTrusted() {
            // AX path: press the close button on the matching window.
            let appEl = AXUIElementCreateApplication(s.pid)
            var windowsRef: CFTypeRef?
            AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
            let windows = (windowsRef as? [AXUIElement]) ?? []
            let targetStem = s.workFile.deletingPathExtension().lastPathComponent
            let targetName = s.workFile.lastPathComponent
            for window in windows {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                let title = titleRef as? String
                var docRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
                let doc = docRef as? String
                let matched = (title == targetStem)
                    || (doc?.hasSuffix(targetName) ?? false)
                    || (doc?.contains(targetName) ?? false)
                guard matched else { continue }
                // Press the close button.
                var closeButtonRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButtonRef)
                if let closeButton = closeButtonRef {
                    AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
                    didCloseViaAX = true
                }
                break
            }
        }

        if !didCloseViaAX {
            // Fallback: AppleScript. Close the window whose name matches the work file.
            // This may trigger a one-time automation permission dialog on first use.
            let windowName = s.workFile.deletingPathExtension().lastPathComponent
            let script = """
            tell application "Preview"
                repeat with w in windows
                    if name of w is "\(windowName)" then
                        close w
                        exit repeat
                    end if
                end repeat
            end tell
            """
            if let appleScript = NSAppleScript(source: script) {
                var errorInfo: NSDictionary?
                appleScript.executeAndReturnError(&errorInfo)
            }
        }

        // After closing the Preview window, restore key focus to the ClipboardManager
        // history window so window-scoped hotkeys (Cmd+E, etc.) work immediately.
        // Delayed so the close action (AX press or AppleScript `close`) completes first;
        // activating this app immediately can interrupt Preview's asynchronous close.
        restoreHistoryWindowFocus()
    }

    /// Brings the ClipboardManager history window back to the foreground after
    /// Preview's window is closed, so the user can immediately use action hotkeys
    /// (Cmd+E, etc.) without manually clicking the history window.
    /// Delayed by 0.5s to avoid interrupting Preview's window-close animation.
    private func restoreHistoryWindowFocus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            Task { @MainActor in
                guard self != nil else { return }
                // Find the history window (NSPanel) owned by this app and make it key.
                for window in NSApp.windows where window.isVisible && window.canBecomeKey {
                    if window is NSPanel {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                        return
                    }
                }
            }
        }
    }

    // MARK: - Teardown

    private func teardown(sessionID: UUID) {
        guard let s = sessions[sessionID] else { return }
        s.debounceWork?.cancel()
       s.fileWatchSource?.cancel()
       s.windowPollWork?.cancel()
       s.sessionTimeoutWork?.cancel()
      s.dirWatchSource?.cancel()
        if let observer = s.axObserver {
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        if let to = s.terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(to)
        }
       // Release the retain count of the box passed as refcon to the AX callback.
       // The RunLoop source has already been removed above, so no further AX callbacks should arrive,
       // but explicitly release to stay safe if code ordering changes in the future.
       if let refcon = s.boxRefcon {
           Unmanaged<PreviewImageEditor.SessionBox>.fromOpaque(refcon).release()
       }
        try? FileManager.default.removeItem(at: s.workFile)
        sessions[sessionID] = nil
        isEditing = false
    }

    // MARK: - Cleanup on launch

    /// Called at app launch. Deletes leftover `.ClipboardManagerEdit.*` files from
    /// previous sessions. No active sessions exist at launch, so all editing files
    /// in Downloads matching the prefix can be safely deleted.
    /// Also called periodically by `startOrphanCleanupTimer()` so crashed-session files
    /// do not accumulate between launches (review #7).
    func cleanupOrphanedEditFiles() {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        guard let entries = try? fm.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) else { return }
        let prefix = workFilePrefix.lastPathComponent + "."
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    /// Determines the actual UTI from image data and returns the corresponding file extension.
    /// Falls back to PNG (the app's save format) if it cannot be determined.
    private func fileExtension(for data: Data) -> String {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let uti = CGImageSourceGetType(source) {
            let type = UTType(uti as String)
            if let ext = type?.preferredFilenameExtension { return ext }
        }
        return "png"
    }
}

/// Top-level C callback passed as AXObserverCallback.
/// `refcon` carries `PreviewImageEditor.SessionBox`, which is used to notify the main actor.
/// Does not touch any other state.
private func previewAXWindowDestroyedCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let box = Unmanaged<PreviewImageEditor.SessionBox>.fromOpaque(refcon).takeUnretainedValue()
    let sessionID = box.sessionID
    Task { @MainActor in
        PreviewImageEditor.shared.onWindowDestroyed(sessionID: sessionID)
    }
}
