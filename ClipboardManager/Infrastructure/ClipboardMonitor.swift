import AppKit
import CryptoKit
import SwiftData
import os

/// Monitors the system pasteboard and records new entries to history.
///
/// Threading model (review #6):
/// - The poll runs on a background utility queue (`.global(qos: .utility)`) so heavy
///   pasteboard reads (`pb.data(forType: .png)`, etc.), SHA256 hashing, and thumbnail
///   generation do not block the main actor. Large image copies no longer cause UI stalls.
/// - `changeCount` is read on the utility queue at the start of each poll. This is safe:
///   `NSPasteboard.general.changeCount` is documented as thread-safe and is a simple
///   integer read. The previous `lastChangeCount` comparison still happens first, so when
///   nothing changed the heavy path is skipped entirely.
/// - SwiftData `ModelContext` is `@MainActor`, so the final insert+save hops back to the
///   main actor via `Task { @MainActor }`. The expensive work (decode, hash, thumbnail)
///   has already completed by then, so the main actor is only touched for a quick insert.
/// - `DedupCache` is internally locked, so it is safe to touch from the utility queue.
/// - `suppressedChangeCounts` and `lastChangeCount` are only mutated from the single
///   serial timer queue, so they don't need extra locking: the `DispatchSourceTimer`
///   fires its handler on the configured queue serially.
///
/// `@unchecked Sendable`: the instance is shared via `ClipboardMonitor.shared` and reached
/// from both the main actor (callers of `suppressChangeCountRange` /
/// `finalizeSuppressionAfterWrite`) and the utility poll
/// queue. All mutable state is either internally locked (`DedupCache`) or only touched on
/// the serial `pollQueue` (`lastChangeCount`, `suppressedChangeCounts`, `isRunning`,
/// `isObservingSettings`, `timer`). `persistence` and `settings` are `@MainActor` types
/// accessed only inside `Task { @MainActor }` blocks.
final class ClipboardMonitor: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "ClipboardMonitor")

    /// Shared instance set by AppDelegate at launch.
    /// Used by Infrastructure components such as `HookPasteService` to register suppression before a Hook paste.
    /// Same pattern as `PersistenceController.shared`.
    ///
    /// `nonisolated(unsafe)`: the shared instance is assigned once on the main actor at
    /// launch and then only read. It is safe to read from any context after launch.
    static nonisolated(unsafe) var shared: ClipboardMonitor?

    private let persistence: PersistenceController
    private let settings: AppSettings
    private let dedup: DedupCache
    private var timer: DispatchSourceTimer?
    /// Only mutated on the timer queue (serial). Read/written from the single timer
    /// handler, so no lock is required.
    private var lastChangeCount: Int = 0
    private var lastSavedContentHash: String?
    private var isObservingSettings = false
    private var isRunning = false
    /// Only mutated on the timer queue (serial).
    /// Set of changeCounts written by this app (e.g., Hook paste) to exclude from history saving.
    /// `suppressChangeCountRange` pre-registers a range before a write, and
    /// `finalizeSuppressionAfterWrite` cleans up orphaned entries after the write;
    /// the poll consumes a matching entry and skips saving.
    private var suppressedChangeCounts: Set<Int> = []
    /// Serial queue used for polling. Reading the pasteboard (especially large image
    /// data) and generating thumbnails can take tens of ms; running on a utility queue
    /// keeps the main actor responsive (review #6).
    private let pollQueue = DispatchQueue(label: "com.xshoji.ClipboardManager.clipboardPoll", qos: .utility)

    init(persistence: PersistenceController, settings: AppSettings) {
        self.persistence = persistence
        self.settings = settings
        self.dedup = DedupCache(maxSize: settings.dedupCacheSize)
    }

    func start() {
        // Run start on pollQueue so isRunning, isObservingSettings and timer mutations
        // are serialized with poll. `sync` is safe here: poll has not started yet at this
        // point, so the queue is idle and sync returns immediately.
        pollQueue.sync { [weak self] in
            guard let self else { return }
            self.isRunning = true
            // Read the initial changeCount. The poll handler performs a fresh read anyway,
            // so even if the first poll fires before this assignment, the only consequence
            // is treating the launch state as "new" and skipping via `suppressedChangeCounts`.
            self.lastChangeCount = NSPasteboard.general.changeCount
            self.restartTimer()
        }

        guard !isObservingSettings else { return }
        isObservingSettings = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(dedupSizeChanged), name: .dedupCacheSizeChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(pollingIntervalChanged), name: .pollingIntervalChanged, object: nil
        )
    }

    /// Must be called on `pollQueue`. Cancels the existing timer and schedules a new one
    /// on `pollQueue` so all timer-driven polls fire serially on the same queue.
    private func restartTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: pollQueue)
        t.schedule(deadline: .now() + .milliseconds(settings.pollingIntervalMs), repeating: .milliseconds(settings.pollingIntervalMs))
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
    }

    func stop() {
        pollQueue.sync { [weak self] in
            self?.isRunning = false
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    @objc private func dedupSizeChanged() {
        // `dedup` is internally locked; safe to call from either queue.
        dedup.resizeIfNeeded(maxSize: settings.dedupCacheSize)
    }

    @objc private func pollingIntervalChanged() {
        // Rebuild the timer on pollQueue so the new schedule takes effect serially.
        pollQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.restartTimer()
        }
    }

    /// Registers a range of changeCounts for suppression. Used to close the race
    /// between the main-actor pasteboard write and the utility-queue poll (review #6):
    /// the poll could fire mid-write (between `clearContents()` and `setData()`) and
    /// otherwise save the app's own write as a history item.
    ///
    /// Callers MUST pass a range that excludes the pre-write `changeCount` itself
    /// (start at `pre + 1`), and MUST call `finalizeSuppressionAfterWrite(preChangeCount:)`
    /// after the write completes. Otherwise, pre-registered entries whose `changeCount`
    /// was never produced by the write remain as orphans and can suppress a later
    /// user copy (see `finalizeSuppressionAfterWrite` for details).
    ///
    /// Example: `let pre = pb.changeCount; pb.clearContents(); pb.setData(...);
    /// monitor.suppressChangeCountRange((pre + 1)..<(pre + 3));
    /// monitor.finalizeSuppressionAfterWrite(preChangeCount: pre)`.
    func suppressChangeCountRange(_ range: Range<Int>) {
        // `sync` so the range is visible on `pollQueue` before this method returns.
        pollQueue.sync { [weak self] in
            guard let self else { return }
            for c in range {
                self.suppressedChangeCounts.insert(c)
            }
        }
    }

    /// Finalizes suppression after the app writes to `NSPasteboard.general`.
    ///
    /// `suppressChangeCountRange((pre + 1)..<(pre + 3))` pre-registers a conservative
    /// range to cover the race where the utility-queue poll fires mid-write. However,
    /// `clearContents()` + `setData()` typically produces only a single `changeCount`
    /// increment, leaving `pre + 2` as an **orphan** in `suppressedChangeCounts`.
    /// Since `changeCount` is monotonically increasing, that orphan will match the
    /// user's **next** copy and wrongly suppress it — the copied content never enters
    /// history. This is the root cause of the "copied content missing from history"
    /// bug, which is most visible shortly after launch when copy/paste cycles are
    /// frequent.
    ///
    /// This method reads the actual post-write `changeCount`, ensures it is
    /// suppressed, and removes any pre-registered entries above it (orphans that
    /// could suppress future user copies). Must be called on the main actor
    /// **immediately after** the pasteboard write completes.
    func finalizeSuppressionAfterWrite(preChangeCount pre: Int) {
        // `sync` so the cleanup is visible on `pollQueue` before this method returns
        // and before any subsequent poll fires.
        pollQueue.sync { [weak self] in
            guard let self else { return }
            let post = NSPasteboard.general.changeCount
            // Ensure the actual post-write changeCount is suppressed even if the
            // write produced more bumps than the pre-registered range covered.
            self.suppressedChangeCounts.insert(post)
            // Remove pre-registered entries above `post`; they were never produced
            // by this write and would otherwise orphan-suppress a future user copy.
            for c in (pre + 1)..<(pre + 3) {
                if c > post {
                    self.suppressedChangeCounts.remove(c)
                }
            }
        }
    }

    private func poll() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if suppressedChangeCounts.remove(count) != nil {
            return
        }

        // Do not save temporary/concealed copies from password managers.
        // - org.nspasteboard.ConcealedType: set by 1Password, Keychain Access, etc.
        // - org.nspasteboard.AutoGeneratedType: auto-generated passwords, etc.
        // If present, do not persist to clipboard history (review #1).
        if isConcealedPasteboard(pb) {
            return
        }

        // Prefer images. Heaviest path (pb.data(forType: .png) + thumbnail) runs here
        // on the utility queue, off the main actor (review #6).
        if let pngData = pb.data(forType: .png), !pngData.isEmpty {
            prepareImageSave(pb, pngData)
            return
        }
        // RTFD -> text
        if let rtfData = pb.data(forType: .rtfd), !rtfData.isEmpty {
            prepareTextSave(pb, rich: rtfData)
            return
        }
        if let rtfData = pb.data(forType: .rtf), !rtfData.isEmpty {
            prepareTextSave(pb, rich: rtfData)
            return
        }
        if let text = pb.string(forType: .string), !text.isEmpty {
            prepareTextSave(pb, plain: text)
            return
        }
    }

    /// Performs size check, hashing, dedup record, and thumbnail generation on the poll
    /// queue, then hops to the main actor for the SwiftData insert (ModelContext is
    /// `@MainActor`). Splitting the heavy work from the main-actor save means the UI
    /// thread is only briefly touched for the final insert (review #6).
    private func prepareImageSave(_ pb: NSPasteboard, _ data: Data) {
        if data.count > settings.maxItemSizeMB * 1024 * 1024 {
            Self.logger.info("image exceeded maxItemSizeMB (\(self.settings.maxItemSizeMB)MB), skipped")
            DispatchQueue.main.async {
                AppNotifier.notify(
                    title: "Clipboard item not saved",
                    body: "The copied image exceeds the \(self.settings.maxItemSizeMB) MB size limit.",
                    deduplicationKey: "clipboard-item-size-limit"
                )
            }
            return
        }
        let hash = HashUtil.sha256Hex(of: data)
        if dedup.shouldSkip(contentHash: hash) { return }
        dedup.record(hash)
        lastSavedContentHash = hash

        // Thumbnail generation (lockFocus → tiffRepresentation) is heavy: run it here
        // on the utility queue instead of the main actor (review #6).
        let thumb = ThumbnailGenerator.thumbnailData(from: data, maxEdge: 64)
        let sourceBundle = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.sourceApp.bundleID"))
        let kind = "image"
        let text: String? = nil
        let richText: Data? = nil
        let imageData = data

        Task { @MainActor [weak self] in
            guard let self else { return }
            let entity = ClipboardEntity(
                kind: kind,
                text: text,
                richText: richText,
                imageData: imageData,
                thumbnail: thumb,
                sourceBundleID: sourceBundle,
                contentHash: hash
            )
            let ctx = self.persistence.container.mainContext
            ctx.insert(entity)
            self.persistence.saveContext(ctx, purpose: "saveImage")
            self.scheduleEnforce()
        }
    }

    private func prepareTextSave(_ pb: NSPasteboard, plain: String? = nil, rich: Data? = nil) {
        let text = plain ?? pb.string(forType: .string) ?? ""
        if text.isEmpty { return }
        let maxBytes = settings.maxItemSizeMB * 1024 * 1024
        if text.utf8.count > maxBytes || (rich?.count ?? 0) > maxBytes {
            Self.logger.info("text exceeded maxItemSizeMB (\(self.settings.maxItemSizeMB)MB), skipped")
            DispatchQueue.main.async {
                AppNotifier.notify(
                    title: "Clipboard item not saved",
                    body: "The copied text exceeds the \(self.settings.maxItemSizeMB) MB size limit.",
                    deduplicationKey: "clipboard-item-size-limit"
                )
            }
            return
        }
        let hash = HashUtil.sha256Hex(of: Data(text.utf8))
        if dedup.shouldSkip(contentHash: hash) { return }
        dedup.record(hash)
        lastSavedContentHash = hash

        let sourceBundle = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.sourceApp.bundleID"))
        let kind = "text"
        let richText = rich
        let imageData: Data? = nil
        let thumbnail: Data? = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let entity = ClipboardEntity(
                kind: kind,
                text: text,
                richText: richText,
                imageData: imageData,
                thumbnail: thumbnail,
                sourceBundleID: sourceBundle,
                contentHash: hash
            )
            let ctx = self.persistence.container.mainContext
            ctx.insert(entity)
            self.persistence.saveContext(ctx, purpose: "saveText")
            self.scheduleEnforce()
        }
    }

    @MainActor private func scheduleEnforce() {
        persistence.scheduleEnforceWithDebounce()
    }

    /// Determines whether the pasteboard contains a concealed copy from a password manager.
    /// Treats it as concealed when `org.nspasteboard.ConcealedType` or `org.nspasteboard.AutoGeneratedType` is present (review #1).
    /// These markers are set by 1Password, Keychain Access, Bitwarden, etc.
    private func isConcealedPasteboard(_ pb: NSPasteboard) -> Bool {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let autoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        let types = pb.types ?? []
        if types.contains(concealed) { return true }
        if types.contains(autoGenerated) { return true }
        // Some apps set the value to "1", so also check the string representation.
        if let v = pb.string(forType: concealed), v == "1" { return true }
        if let v = pb.string(forType: autoGenerated), v == "1" { return true }
        return false
    }
}

extension DedupCache {
    func resizeIfNeeded(maxSize newMax: Int) {
        if newMax != maxSize { resize(maxSize: newMax) }
    }
}
