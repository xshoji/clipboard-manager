import AppKit
import os
import os.lock

/// Monitors the injected pasteboard and records new entries to history.
///
/// Threading model (review #6):
/// - The poll runs on a background utility queue (`.global(qos: .utility)`) so heavy
///   pasteboard reads (`pb.data(forType: .png)`, etc.), SHA256 hashing, and thumbnail
///   generation do not block the main actor. Large image copies no longer cause UI stalls.
/// - `changeCount` is read on the utility queue at the start of each poll. This is safe:
///   `NSPasteboard.changeCount` is documented as thread-safe and is a simple
///   integer read. The previous `lastChangeCount` comparison still happens first, so when
///   nothing changed the heavy path is skipped entirely.
/// - SwiftData `ModelContext` is `@MainActor`, so the final insert+save hops back to the
///   main actor via `Task { @MainActor }`. The expensive work (decode, hash, thumbnail)
///   has already completed by then, so the main actor is only touched for a quick insert.
/// - `suppressedChangeCounts` and `lastChangeCount` are only mutated from the single
///   serial timer queue, so they don't need extra locking: the `DispatchSourceTimer`
///   fires its handler on the configured queue serially. `lastSavedContentHash` is
///   likewise only mutated from the poll handler, so it is safe without a lock.
/// `persistence` and `settings` are `@MainActor` types accessed only inside
/// `Task { @MainActor }` blocks.
///
/// `@unchecked Sendable`: the shared instance is shared via `ClipboardMonitor.shared`
/// and reached from both the main actor (callers of `suppressChangeCountRange` /
/// `finalizeSuppressionAfterWrite`) and the utility poll
/// queue. All mutable state is only touched on the serial `pollQueue`
/// (`lastChangeCount`, `lastSavedContentHash`, `suppressedChangeCounts`, `isRunning`,
/// `isObservingSettings`, `timer`, `cachedCurrentObservation`).
final class ClipboardMonitor: @unchecked Sendable, PasteboardSuppressing, CurrentClipboardReading {
    private static let logger = Logger(subsystem: "com.xshoji.ClipboardManager", category: "ClipboardMonitor")

    /// Shared instance set by AppDelegate at launch.
    /// Used by the paste coordinator to register suppression before an app-owned write.
    ///
    /// `nonisolated(unsafe)`: the shared instance is assigned once on the main actor at
    /// launch and then only read. It is safe to read from any context after launch.
    static nonisolated(unsafe) var shared: ClipboardMonitor?

    private let repository: ClipboardHistoryWriting
    private let settings: AppSettings
    private let automaticOcr: AutomaticOcrProcessor
    private let pasteboard: NSPasteboard
    private var timer: DispatchSourceTimer?
    /// Only mutated on the timer queue (serial). Read/written from the single timer
    /// handler, so no lock is required.
    private var lastChangeCount: Int = 0
    /// Only mutated on the timer queue (serial). Holds the SHA256 hash of the most
    /// recently saved entry. Used to skip the immediately-following identical copy so
    /// Pasteboard repeats (e.g. from app-internal pasteboard writes or
    /// re-copying the same selection) do not pile up as duplicate history entries.
    ///
    /// Dedup strategy (two layers, see also `removeDuplicates`):
    ///   1. Skip-on-identical-immediate (this property): when the incoming hash equals
    ///      `lastSavedContentHash`, save is skipped entirely. Cheap, in-memory, and
    ///      avoids a needless SwiftData write + SQLite round-trip.
    ///   2. Remove-by-hash (`removeDuplicates`): runs on the main actor before each
    ///      insert. Deletes any older entities with the same `contentHash` so the newly
    ///      copied item bubbles up to the top without stacking duplicates.
    /// Layer 1 is a pure performance/UX guard; layer 2 is the correctness guard that
    /// guarantees at most one entry per hash. The previous ring-buffer (`DedupCache`)
    /// skipped any duplicate within the last N entries and prevented the same content
    /// from ever re-entering history until the ring evicted it; that behavior was
    /// replaced by the two-layer approach because users expect the same content to
    /// re-enter history once anything else has been copied in between.
    private var lastSavedContentHash: String?
    private var isObservingSettings = false
    private var isRunning = false
    /// Suppression set guarded by an `OSAllocatedUnfairLock`.
    ///
    /// Previously this was a plain `Set<Int>` accessed via `pollQueue.sync` from the
    /// main actor. When the poll queue was busy with heavy work (SHA256 hashing,
    /// thumbnail generation on large images), the `sync` call blocked the main actor.
    /// The unfair lock is extremely cheap (spinning, microseconds) and independent of
    /// the poll queue, so main-actor suppression operations never wait on poll work.
    private let suppressedChangeCountsLock = OSAllocatedUnfairLock(initialState: Set<Int>())
    /// Serial queue used for polling. Reading the pasteboard (especially large image
    /// data) and generating thumbnails can take tens of ms; running on a utility queue
    /// keeps the main actor responsive (review #6).
    private let pollQueue = DispatchQueue(label: "com.xshoji.ClipboardManager.clipboardPoll", qos: .utility)
    /// Stable normalized result for the current pasteboard generation. Explicit
    /// refreshes and action resolution reuse this value instead of re-reading and
    /// re-normalizing the same `changeCount`.
    private var cachedCurrentObservation: CurrentClipboardObservation?
    private typealias CurrentClipboardHandler = @Sendable (CurrentClipboardObservation) -> Void
    private let currentClipboardHandlerLock = OSAllocatedUnfairLock<CurrentClipboardHandler?>(initialState: nil)

    init(
        repository: ClipboardHistoryWriting,
        settings: AppSettings,
        automaticOcr: AutomaticOcrProcessor,
        pasteboard: NSPasteboard
    ) {
        self.repository = repository
        self.settings = settings
        self.automaticOcr = automaticOcr
        self.pasteboard = pasteboard
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
            self.lastChangeCount = self.pasteboard.changeCount
            self.restartTimer()
        }
        pollQueue.async { [weak self] in
            guard let self else { return }
            if let observation = self.captureCurrentClipboard() {
                self.publishCurrent(observation)
            }
        }

        guard !isObservingSettings else { return }
        isObservingSettings = true
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
        // Uses an unfair lock instead of `pollQueue.sync` so the main actor is never
        // blocked by heavy poll-queue work (image hashing, thumbnail generation).
        suppressedChangeCountsLock.withLock { set in
            for c in range {
                set.insert(c)
            }
        }
    }

    /// Finalizes suppression after the app writes to the injected pasteboard.
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
    @discardableResult
    func finalizeSuppressionAfterWrite(preChangeCount pre: Int) -> Int {
        let post = pasteboard.changeCount
        // Uses an unfair lock instead of `pollQueue.sync` so the main actor is never
        // blocked by heavy poll-queue work (image hashing, thumbnail generation).
        suppressedChangeCountsLock.withLock { set in
            // Ensure the actual post-write changeCount is suppressed even if the
            // write produced more bumps than the pre-registered range covered.
            set.insert(post)
            // Remove any pre-registered entries in `(pre...post]` other than `post`
            // itself. The write only ever produces `changeCount == post`, so any other
            // entry in this range was never produced by the write and would otherwise
            // sit as an orphan and suppress a future user copy. Previously the cleanup
            // was limited to `(pre+1)..<(pre+3)`, which could leave `pre+1` (when the
            // write produced two bumps, `post == pre+2`) and similar stragglers that
            // matched the next user copy.
            for c in (pre + 1)...post where c != post {
                set.remove(c)
            }
            // Also drop orphans strictly above `post` that were pre-registered for this
            // write (the conservative `(pre+1)..<(pre+3)` range). They were never
            // produced and would suppress a future copy otherwise.
            for c in (post + 1)..<(pre + 3) {
                set.remove(c)
            }
        }
        return post
    }

    /// Performs a pasteboard write that is excluded from history recording.
    ///
    /// This wraps the suppression transaction that closes the race between the
    /// main-actor pasteboard write and the utility-queue poll (review #6):
    /// without it, the poll could fire mid-write (between `clearContents()` and
    /// `setData()`) and save the app's own write as a history item.
    ///
    /// Callers MUST do only pasteboard writes inside `write`. Everything else
    /// (previous-app activation, notifications, etc.) belongs outside this call
    /// so the suppression bookkeeping stays tightly scoped to the write itself.
    ///
    /// Must be called on the main actor: pasteboard writes are AppKit APIs and
    /// `finalizeSuppressionAfterWrite` reads the post-write `changeCount`
    /// immediately after the closure returns.
    ///
    /// Example:
    /// ```
    /// ClipboardMonitor.shared?.performSuppressedPasteboardWrite { pb in
    ///     entity.writeToPasteboard(pb, rich: rich)
    /// }
    /// ```
    @discardableResult
    @MainActor
    func performSuppressedPasteboardWrite(_ write: (NSPasteboard) -> Void) -> Int {
        let pre = pasteboard.changeCount
        suppressChangeCountRange((pre + 1)..<(pre + 3))
        write(pasteboard)
        let post = finalizeSuppressionAfterWrite(preChangeCount: pre)
        pollQueue.async { [weak self] in
            guard let self else { return }
            if self.pasteboard.changeCount > post {
                self.suppressedChangeCountsLock.withLock { $0.remove(post) }
            }
            self.poll()
        }
        return pre
    }

    @MainActor
    func setCurrentClipboardHandler(_ handler: @escaping @Sendable (CurrentClipboardObservation) -> Void) {
        currentClipboardHandlerLock.withLock { $0 = handler }
    }

    func currentClipboardObservation() async -> CurrentClipboardObservation? {
        await withCheckedContinuation { continuation in
            pollQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                continuation.resume(returning: self.captureCurrentClipboard())
            }
        }
    }

    /// Writes without exposing a partially-written pasteboard, then records the exact
    /// output payload through the same deduplicating insertion path as a monitored copy.
    @MainActor
    func performHistoryPasteboardWrite(
        recording item: NewClipboardItem,
        _ write: (NSPasteboard) -> Void
    ) -> Int {
        let pre = performSuppressedPasteboardWrite(write)
        pollQueue.async { [weak self] in
            self?.insertPreparedItem(item, purpose: "historyPaste")
        }
        return pre
    }

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount,
              let observation = captureCurrentClipboard(notifyWhenOversized: true),
              observation.changeCount != lastChangeCount else { return }
        lastChangeCount = observation.changeCount

        let suppressed = suppressedChangeCountsLock.withLock { $0.remove(observation.changeCount) != nil }
        publishCurrent(observation)
        let snapshot = observation.snapshot
        guard !suppressed, let snapshot, lastSavedContentHash != snapshot.contentHash else { return }
        insertPreparedItem(snapshot.newClipboardItem(), purpose: snapshot.isImage ? "saveImage" : "saveText")
    }

    private func publishCurrent(_ observation: CurrentClipboardObservation) {
        guard let handler = currentClipboardHandlerLock.withLock({ $0 }) else { return }
        DispatchQueue.main.async { handler(observation) }
    }

    /// Copies a pasteboard owner generation only when its change count stays stable
    /// across all representation reads. A bounded retry handles an owner change that
    /// races the first attempt without ever mixing concealed and ordinary payloads.
    private func captureCurrentClipboard(
        notifyWhenOversized: Bool = false
    ) -> CurrentClipboardObservation? {
        let currentChangeCount = pasteboard.changeCount
        if let cachedCurrentObservation,
           cachedCurrentObservation.changeCount == currentChangeCount {
            return cachedCurrentObservation
        }
        for _ in 0..<3 {
            let before = pasteboard.changeCount
            let snapshot = makeSnapshot(
                from: pasteboard,
                changeCount: before,
                notifyWhenOversized: notifyWhenOversized
            )
            let after = pasteboard.changeCount
            if before == after {
                let observation = CurrentClipboardObservation(changeCount: after, snapshot: snapshot)
                cachedCurrentObservation = observation
                return observation
            }
        }
        return nil
    }

    /// Reads each pasteboard representation once and derives the complete snapshot
    /// from that immutable payload, preserving the monitor's format priority.
    func makeSnapshot(
        from pb: NSPasteboard,
        changeCount: Int,
        notifyWhenOversized: Bool = false
    ) -> CurrentClipboardSnapshot? {
        guard !isConcealedPasteboard(pb) else { return nil }
        let maxBytes = settings.maxItemSizeMB * 1024 * 1024
        let source = pb.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.sourceApp.bundleID"))
        let image: Data? = {
            if let png = pb.data(forType: .png), !png.isEmpty { return png }
            if let tiff = pb.data(forType: .tiff), !tiff.isEmpty { return Self.pngData(fromTiff: tiff) }
            return nil
        }()
        if let image {
            guard image.count <= maxBytes else {
                if notifyWhenOversized { notifySizeLimit() }
                return nil
            }
            return .init(changeCount: changeCount, kind: "image", imageData: image,
                thumbnail: ThumbnailGenerator.thumbnailData(from: image, maxEdge: 64),
                sourceBundleID: source, contentHash: HashUtil.sha256Hex(of: image))
        }
        let rich: Data?
        if let data = pb.data(forType: .rtfd), !data.isEmpty { rich = data }
        else if let data = pb.data(forType: .rtf), !data.isEmpty { rich = data }
        else { rich = nil }
        let htmlType = NSPasteboard.PasteboardType("public.html")
        let html: Data? = {
            guard rich == nil, let data = pb.data(forType: htmlType), !data.isEmpty else { return nil }
            return data
        }()
        let sourceText = pb.string(forType: .string)
        let text = sourceText?.isEmpty == false ? sourceText : nil
        guard text != nil || html != nil,
              (text?.utf8.count ?? 0) <= maxBytes,
              (rich?.count ?? 0) <= maxBytes,
              (html?.count ?? 0) <= maxBytes else {
            if notifyWhenOversized { notifySizeLimit() }
            return nil
        }
        let contentHash: String
        if let text {
            contentHash = HashUtil.sha256Hex(of: Data(text.utf8))
        } else if let html {
            contentHash = HashUtil.sha256HTMLOnly(html)
        } else {
            return nil
        }
        return .init(changeCount: changeCount, kind: "text", text: text, richText: rich,
            html: html, sourceBundleID: source,
            contentHash: contentHash)
    }

    private func notifySizeLimit() {
        Self.logger.info("clipboard item exceeded maxItemSizeMB (\(self.settings.maxItemSizeMB)MB), skipped")
        DispatchQueue.main.async {
            AppNotifier.notify(
                title: "Clipboard item not saved",
                body: "The copied item exceeds the \(self.settings.maxItemSizeMB) MB size limit.",
                deduplicationKey: "clipboard-item-size-limit"
            )
        }
    }

    /// Must be called on `pollQueue`; image thumbnail generation and hashing have
    /// already happened for monitored copies, while history-generated image outputs
    /// receive their thumbnail here before the main-actor insert.
    private func insertPreparedItem(_ input: NewClipboardItem, purpose: String) {
        guard let contentHash = input.contentHash else { return }
        var item = input
        if item.kind == "image", item.thumbnail == nil, let imageData = item.imageData {
            item.thumbnail = ThumbnailGenerator.thumbnailData(from: imageData, maxEdge: 64)
        }
        let shouldRunAutomaticOcr = item.kind == "image" && settings.automaticImageOcrEnabled
        if shouldRunAutomaticOcr {
            item.ocrStatus = "pending"
        }
        let ocrLanguages = settings.ocrLanguages
        Task { @MainActor [weak self] in
            guard let self else { return }
            let saved = self.repository.insert(
                item,
                removingDuplicates: true,
                purpose: purpose
            )
            if saved {
                self.pollQueue.async { [weak self] in
                    self?.lastSavedContentHash = contentHash
                }
                if shouldRunAutomaticOcr, let imageData = item.imageData {
                    self.automaticOcr.enqueue(
                        id: item.id,
                        imageData: imageData,
                        languages: ocrLanguages
                    )
                }
            }
        }
    }

    /// Converts a TIFF pasteboard payload to PNG so it can be stored as a standard
    /// image history item and written back as `.png` on paste.
    private static func pngData(fromTiff data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return png
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
