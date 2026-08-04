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
/// - Preserves interrupted-session files for recovery and refuses to overwrite them.
/// - Determines whether changes were made via SHA256 hash diff, and deletes the working file if unchanged.
@MainActor
final class PreviewImageEditor {
    static let shared = PreviewImageEditor()
    private var repository: ClipboardRepositoryPort?

    func configure(repository: ClipboardRepositoryPort) {
        self.repository = repository
    }

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
        var processingTask: Task<Void, Never>?
        var isProcessing = false
        var finishRequested = false
        /// Retained to release the `box` passed as refcon to the AX callback.
        /// Because it was passed with `passRetained`, it is not released until `release()` is called in `stopSession`.
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
    /// `false` when the session ends — either in `stopSession` (triggered by Preview window
    /// close, Preview termination, or session idle timeout) or on any error path that
    /// aborts the edit before a session is registered.
    ///
    /// `editImage` gates concurrent in-process sessions on this flag. Before creating the
    /// fixed working file, `preparePreviewSession` separately rejects any preserved file
    /// from a failed or interrupted earlier session so recoverable data is not overwritten.
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
    /// Working files are deleted only after an unchanged close or a successful history save.
    /// Files preserved after a save failure or app termination are never overwritten by a
    /// later edit, so the user can recover the edited image manually.
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

    /// Idle timeout for an edit session. When the working file has not been written for this
    /// duration, monitoring stops but the working file is preserved for manual recovery.
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

    /// Stops every active edit session without deleting its working file. App termination
    /// cannot synchronously await an in-flight thumbnail/history save, so preserving the
    /// file is the only safe fallback that keeps edited data recoverable.
    func stopAllSessionsPreservingWorkFiles() {
        let ids = Array(sessions.keys)
        for id in ids {
            stopSession(sessionID: id, deleteWorkFile: false)
        }
        isEditing = false
    }

    // MARK: - Public entry

    func editImage(item: ClipboardItem) {
        guard reserveEditSession() else { return }
        Task {
            guard let data = await repository?.fetchImageData(id: item.id), !data.isEmpty else {
                isEditing = false
                AppNotifier.notify(
                    title: "Image cannot be edited",
                    body: "The selected item has no image data.",
                    deduplicationKey: "preview-edit-no-data"
                )
                return
            }
            preparePreviewSession(data: data, entityID: item.id)
        }
    }

    func editImage(snapshot: CurrentClipboardSnapshot) {
        guard reserveEditSession() else { return }
        guard let data = snapshot.imageData, !data.isEmpty else {
            isEditing = false
            return
        }
        preparePreviewSession(data: data, entityID: snapshot.id)
    }

    private func reserveEditSession() -> Bool {
        // Gate concurrent in-process edits on the internal editing-status flag. Preserved
        // files from an earlier process are checked separately once the image extension is known.
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
            return false
        }

        isEditing = true
        return true
    }

    private func preparePreviewSession(data: Data, entityID: UUID) {
        let ext = fileExtension(for: data)
        // Fixed working file path: ~/Downloads/.ClipboardManagerEdit.<ext>
        // Because concurrent edits are rejected by `isEditing` above, a single fixed path
        // covers all sessions; safe-save's inode churn stays on this constant path,
        // eliminating the "file not found" race that occasionally lost edits.
        // A preserved file from an interrupted session must be recovered explicitly;
        // never overwrite it merely because this process has no active session.
        let workFile = workFilePrefix.appendingPathExtension(ext)
        let existingFiles: [URL]
        do {
            existingFiles = try FileManager.default.contentsOfDirectory(
                at: workFilePrefix.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            )
        } catch {
            isEditing = false
            AppNotifier.notify(
                title: "Image cannot be edited",
                body: "The Downloads folder could not be checked for a preserved edit: \(error.localizedDescription)",
                deduplicationKey: "preview-edit-recovery-check"
            )
            return
        }
        if let preservedFile = existingFiles.first(where: {
            $0.lastPathComponent.hasPrefix(workFilePrefix.lastPathComponent + ".")
        }) {
            isEditing = false
            AppNotifier.notify(
                title: "Previous image edit needs recovery",
                body: "A preserved edited image already exists at \(preservedFile.path). Move or delete that file after recovering it, then try again.",
                deduplicationKey: "preview-edit-recovery-file"
            )
            return
        }
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
                body: "Grant Accessibility permission so edited images are saved as soon as you close the Preview window. Without it, saving happens only after Preview quits. Enable it in Settings → Permissions.",
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
        let exists = !matchingPreviewWindows(for: s).isEmpty
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

    /// Final safety net: stops monitoring after a period of idle time since the last file
    /// write. The working file is preserved because Preview may still hold unsaved edits.
    /// Rescheduled on every file change, so it is not discarded during long edits unless idle.
    ///
    /// Timeout reduced from 10 minutes to 5 minutes per review #7. The user is notified
    /// with the recovery path instead of having the potentially edited file discarded.
    private func rescheduleSessionTimeout(for sessionID: UUID) {
        sessions[sessionID]?.sessionTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, let s = self.sessions[sessionID], !s.didFinish else { return }
                AppNotifier.notify(
                    title: "Image edit session timed out",
                    body: "The Preview edit session has been idle for \(Int(self.sessionIdleTimeoutSec / 60)) minutes, so monitoring stopped. The working file was preserved at \(s.workFile.path).",
                    deduplicationKey: "preview-edit-timeout-\(sessionID.uuidString)"
                )
                self.stopSession(sessionID: sessionID, deleteWorkFile: false)
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
        guard let s = sessions[sessionID], !s.didFinish, !s.isProcessing else { return }
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
        processCandidate(
            sessionID: sessionID,
            workData: workData,
            finishRequested: false
        )
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

        for window in windows {
            guard isTargetWindow(window, workFile: s.workFile) else { continue }

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
        if s.isProcessing {
            sessions[sessionID]?.finishRequested = true
            return
        }

        if let workData = try? Data(contentsOf: s.workFile) {
            processCandidate(
                sessionID: sessionID,
                workData: workData,
                finishRequested: true
            )
        } else {
            stopSession(sessionID: sessionID, deleteWorkFile: false)
        }
    }

    private func processCandidate(
        sessionID: UUID,
        workData: Data,
        finishRequested: Bool
    ) {
        guard let session = sessions[sessionID], !session.didFinish, !session.isProcessing else { return }
        sessions[sessionID]?.sessionTimeoutWork?.cancel()
        sessions[sessionID]?.isProcessing = true
        sessions[sessionID]?.finishRequested = session.finishRequested || finishRequested
        let originalHash = session.originalHash
        let lastSavedHash = session.lastSavedHash
        let maxItemSizeMB = AppSettings.shared.maxItemSizeMB
        let maxBytes = maxItemSizeMB * 1024 * 1024
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.verifyEditedImage(
                    data: workData,
                    originalHash: originalHash,
                    lastSavedHash: lastSavedHash,
                    maxBytes: maxBytes
                )
            }.value
            guard !Task.isCancelled, let self, self.sessions[sessionID] != nil else { return }
            await self.completeCandidateProcessing(
                sessionID: sessionID,
                result: result,
                maxItemSizeMB: maxItemSizeMB
            )
        }
        sessions[sessionID]?.processingTask = task
    }

    private func completeCandidateProcessing(
        sessionID: UUID,
        result: EditVerificationResult,
        maxItemSizeMB: Int
    ) async {
        guard sessions[sessionID] != nil else { return }
        let finishRequested = sessions[sessionID]?.finishRequested == true

        switch result {
        case .duplicate(let processedHash):
            sessions[sessionID]?.processingTask = nil
            sessions[sessionID]?.isProcessing = false
            if finishRequested {
                finishCandidate(
                    sessionID: sessionID,
                    processedHash: processedHash,
                    deleteWorkFileIfCurrent: true
                )
            } else {
                rescheduleSessionTimeout(for: sessionID)
            }
        case .oversize(let processedHash):
            AppNotifier.notify(
                title: "Edited image not saved",
                body: "The edited image exceeds the \(maxItemSizeMB) MB size limit. The working file was preserved.",
                deduplicationKey: "edited-image-size-limit"
            )
            sessions[sessionID]?.processingTask = nil
            sessions[sessionID]?.isProcessing = false
            if finishRequested {
                finishCandidate(
                    sessionID: sessionID,
                    processedHash: processedHash,
                    deleteWorkFileIfCurrent: false
                )
            } else {
                rescheduleSessionTimeout(for: sessionID)
            }
        case .save(let data, let hash):
            let saved = await saveToHistory(data: data, hash: hash)
            guard !Task.isCancelled, sessions[sessionID] != nil else { return }
            let shouldFinish = sessions[sessionID]?.finishRequested == true
            sessions[sessionID]?.processingTask = nil
            sessions[sessionID]?.isProcessing = false
            guard saved else {
                if shouldFinish {
                    finishCandidate(
                        sessionID: sessionID,
                        processedHash: hash,
                        deleteWorkFileIfCurrent: false
                    )
                } else {
                    rescheduleSessionTimeout(for: sessionID)
                }
                return
            }
            sessions[sessionID]?.lastSavedHash = hash
            if shouldFinish {
                finishCandidate(
                    sessionID: sessionID,
                    processedHash: hash,
                    deleteWorkFileIfCurrent: true
                )
            } else {
                rescheduleSessionTimeout(for: sessionID)
                closePreviewWindow(for: sessionID)
            }
        }
    }

    /// Finishes only if the on-disk file still matches the candidate that was processed.
    /// Preview may save a newer version while thumbnail generation or persistence is in
    /// flight. In that case, process the latest bytes instead of deleting them as though
    /// they were the already-handled candidate.
    private func finishCandidate(
        sessionID: UUID,
        processedHash: String,
        deleteWorkFileIfCurrent: Bool
    ) {
        guard let session = sessions[sessionID] else { return }

        guard deleteWorkFileIfCurrent else {
            guard let currentData = try? Data(contentsOf: session.workFile) else {
                stopSession(sessionID: sessionID, deleteWorkFile: false)
                return
            }
            guard HashUtil.sha256Hex(of: currentData) == processedHash else {
                processCandidate(
                    sessionID: sessionID,
                    workData: currentData,
                    finishRequested: true
                )
                return
            }
            stopSession(sessionID: sessionID, deleteWorkFile: false)
            return
        }

        // Atomically capture the exact path entry before deciding whether to delete it.
        // A plain read/hash/remove sequence could read candidate A, then remove a newer
        // candidate B that Preview safe-saved to the same path between those operations.
        let capturedFile = session.workFile
            .deletingLastPathComponent()
            .appendingPathComponent("\(session.workFile.lastPathComponent).completed-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: session.workFile, to: capturedFile)
        } catch {
            stopSession(sessionID: sessionID, deleteWorkFile: false)
            return
        }

        guard let capturedData = try? Data(contentsOf: capturedFile) else {
            stopSession(sessionID: sessionID, deleteWorkFile: false)
            return
        }
        let capturedHash = HashUtil.sha256Hex(of: capturedData)
        if capturedHash == processedHash {
            try? FileManager.default.removeItem(at: capturedFile)
        } else {
            AppNotifier.notify(
                title: "Newer image edit preserved",
                body: "A newer edited image was preserved at \(capturedFile.path).",
                deduplicationKey: "edited-image-newer-file-preserved"
            )
        }

        // Preview may have completed another safe-save after the atomic move. Never
        // remove that replacement; process it if present, otherwise finish cleanly.
        guard let currentData = try? Data(contentsOf: session.workFile) else {
            stopSession(sessionID: sessionID, deleteWorkFile: false)
            return
        }
        processCandidate(
            sessionID: sessionID,
            workData: currentData,
            finishRequested: true
        )
    }

    // MARK: - Edit verification (shared between file-change and session-finalize paths)

    /// Result of verifying a candidate edited image against the session's known hashes
    /// and the configured size limit. Single source of truth so the file-change path
    /// (`performFileChangeCheck`) and the session-finalize path (`performHashCheck`)
    /// agree on what gets saved, what gets skipped as a duplicate, and what gets
    /// rejected as oversize (review #8).
    private enum EditVerificationResult {
        /// New content worth saving: the hash differs from both the original and the
        /// last-saved hash, and the size is within the limit. Carries the data and hash.
        case save(Data, String)
        /// Byte-identical to the original or to the most recent save. Nothing to do.
        case duplicate(String)
        /// Exceeds `AppSettings.maxItemSizeMB`. The caller is expected to notify the user.
        case oversize(String)
    }

    /// Verifies the candidate `data` against the session's `originalHash` / `lastSavedHash`
    /// and the configured size limit. Returns a `EditVerificationResult` the caller uses
    /// to decide the next action (save, skip, or reject + notify).
    ///
    /// Pure: performs only SHA256 hashing and integer comparison. Safe to call from a
    /// `Task.detached` so the hash work stays off the main actor (large edited images
    /// can take tens of ms to hash). Reads `AppSettings.shared.maxItemSizeMB`, which is
    /// a `@MainActor` `UserDefaults` wrapper; reading it off the main actor is safe here
    /// because the underlying `UserDefaults` getter is thread-safe and the value is a
    /// primitive copied into the local `maxMB`.
    private nonisolated static func verifyEditedImage(
        data: Data,
        originalHash: String,
        lastSavedHash: String?,
        maxBytes: Int
    ) -> EditVerificationResult {
        let hash = HashUtil.sha256Hex(of: data)
        if hash == originalHash { return .duplicate(hash) }
        if let lastSavedHash, hash == lastSavedHash { return .duplicate(hash) }
        if data.count > maxBytes { return .oversize(hash) }
        return .save(data, hash)
    }

    private func saveToHistory(data: Data, hash: String) async -> Bool {
        guard let repository else { return false }
        // Thumbnail generation (lockFocus → tiffRepresentation) is heavy for large
        // images; run it on a background task so the main actor is not blocked.
        let thumb = await Task.detached(priority: .userInitiated) {
            ThumbnailGenerator.thumbnailData(from: data, maxEdge: 64)
        }.value
        guard !Task.isCancelled else { return false }
        let saved = repository.insert(
            .init(kind: "image", imageData: data, thumbnail: thumb, contentHash: hash),
            removingDuplicates: false,
            purpose: "PreviewImageEditor.saveToHistory"
        )
        if !saved {
            AppNotifier.notify(
                title: "Edited image not saved",
                body: "The edited image could not be saved to clipboard history. The working file was preserved.",
                deduplicationKey: "edited-image-save-failed"
            )
        }
        return saved
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
            for window in matchingPreviewWindows(for: s) {
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

    private func stopSession(sessionID: UUID, deleteWorkFile: Bool) {
        guard var s = sessions[sessionID] else { return }
        s.didFinish = true
        s.processingTask?.cancel()
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
        if deleteWorkFile {
            try? FileManager.default.removeItem(at: s.workFile)
        }
        sessions[sessionID] = nil
        isEditing = false
    }

    // MARK: - Helpers

    /// Returns `true` when the given AX window belongs to this session's work file.
    ///
    /// Preview's window `title` usually carries the file stem (without extension),
    /// while the `document` attribute carries a path that ends with the file name.
    /// We match on either to be tolerant of Preview version differences. This single
    /// helper is the only place that decides whether an AX window belongs to a
    /// session, so existence checks, AX observer installation, and window-close all
    /// agree on the same criteria (review #8).
    private func isTargetWindow(_ window: AXUIElement, workFile: URL) -> Bool {
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        let title = titleRef as? String
        var docRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXDocumentAttribute as CFString, &docRef)
        let doc = docRef as? String
        let targetStem = workFile.deletingPathExtension().lastPathComponent
        let targetName = workFile.lastPathComponent
        return title == targetStem
            || (doc?.hasSuffix(targetName) ?? false)
            || (doc?.contains(targetName) ?? false)
    }

    /// Enumerates the Preview app's AX windows for the given session and returns
    /// those that match the session's work file. Convenience wrapper around
    /// `isTargetWindow(_:workFile:)` for callers that need the matching window(s).
    private func matchingPreviewWindows(for session: Session) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(session.pid)
        var windowsRef: CFTypeRef?
        AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &windowsRef)
        let windows = (windowsRef as? [AXUIElement]) ?? []
        return windows.filter { isTargetWindow($0, workFile: session.workFile) }
    }

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
