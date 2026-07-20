import Foundation
import SwiftData
import os

@MainActor
final class PersistenceController {
    /// Shared instance set by AppDelegate at launch.
    /// Used to centralize limit enforcement triggered by UI edits (TextEditView, PreviewImageEditor).
    static var shared: PersistenceController?

    let container: ModelContainer
    private let settings: AppSettings
    private var enforceDebouncer: DispatchWorkItem?
    /// Logger for store lifecycle events (initialization, backup, recovery).
    private static let logger = Logger(
        subsystem: "com.xshoji.ClipboardManager",
        category: "Persistence"
    )

    /// Sibling files SwiftData's SQLite backing store may keep alongside the main store URL.
    /// All of them must be backed up / removed together when the store is recreated.
    private static let storeFileSuffixes = ["", "-wal", "-shm"]

    init(settings: AppSettings = .shared) {
        self.settings = settings
        // Use a versioned schema so SwiftData records the schema version and can run
        // `PersistenceMigrationPlan` when future model changes are introduced.
        let schema = Schema(versionedSchema: SchemaV1.self)
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("ClipboardManager/Clipboard.store", isDirectory: false)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(nil, schema: schema, url: url)
        do {
            container = try ModelContainer(
                for: schema,
                migrationPlan: PersistenceMigrationPlan.self,
                configurations: config
            )
        } catch {
            // The on-disk store is corrupted or incompatible with the current schema.
            // NEVER delete the user's clipboard history without first preserving it:
            // 1. Copy the existing store (+ -wal / -shm) into a timestamped Backups/ folder.
            // 2. Only if the backup succeeded, remove the original and recreate.
            // 3. If the backup failed, leave the original store untouched and fall back
            //    to an in-memory container so the app still launches without crashing.
            // 4. Log every step (Logger) and notify the user (AppNotifier).
            Self.logger.error("ModelContainer creation failed: \(String(describing: error), privacy: .public).")

            let backupDir = url.deletingLastPathComponent()
                .appendingPathComponent("Backups", isDirectory: true)
            let backedUp = Self.backupStoreFiles(at: url, into: backupDir)

            if backedUp {
                Self.logger.notice("Backed up existing store files into \(backupDir.path, privacy: .public) before recreating.")
                AppNotifier.notify(
                    title: "Clipboard store recreated",
                    body: "The clipboard history store could not be opened (corrupted or incompatible). A timestamped backup was saved under Application Support/ClipboardManager/Backups before a new empty store was created. Please contact support if you need to restore previous history."
                )
                Self.removeStoreFiles(at: url)
                do {
                    container = try ModelContainer(
                        for: schema,
                        migrationPlan: PersistenceMigrationPlan.self,
                        configurations: config
                    )
                    return
                } catch {
                    Self.logger.fault("ModelContainer recreation failed after backup: \(String(describing: error), privacy: .public). Falling back to in-memory store.")
                    AppNotifier.notify(
                        title: "Clipboard store unavailable",
                        body: "Recreating the clipboard history store failed. New history will be kept in memory only and will not persist after the app quits."
                    )
                }
            } else {
                Self.logger.fault("Backup of existing store files failed. Refusing to delete the original store; falling back to in-memory store to avoid data loss.")
                AppNotifier.notify(
                    title: "Clipboard store unavailable",
                    body: "The clipboard history store could not be opened and could not be backed up. The original store file was left untouched in Application Support/ClipboardManager. New history will be kept in memory only until the app is restarted. Please contact support before removing any files in that folder."
                )
            }

            // Safe fallback: in-memory container. The app keeps running but nothing
            // persists this session. The on-disk store is preserved for manual recovery.
            let memoryConfig = ModelConfiguration(nil, schema: schema, isStoredInMemoryOnly: true)
            do {
                container = try ModelContainer(
                    for: schema,
                    migrationPlan: PersistenceMigrationPlan.self,
                    configurations: memoryConfig
                )
            } catch {
                Self.logger.fault("In-memory ModelContainer creation failed: \(String(describing: error), privacy: .public).")
                fatalError("Persistent store initialization failed: \(error)")
            }
        }
    }

    /// Copies the main store file and its SQLite sidecar files (`-wal`, `-shm`) into
    /// `backupDir` with a timestamped suffix. Returns `true` if at least one file was
    /// copied successfully. Returns `false` when no source file exists or every copy
    /// attempt failed, in which case the caller must NOT delete the original store.
    private static func backupStoreFiles(at url: URL, into backupDir: URL) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: Date())

        let baseName = url.lastPathComponent
        var copiedAny = false
        for suffix in storeFileSuffixes {
            let srcPath = url.path + suffix
            guard fm.fileExists(atPath: srcPath) else { continue }
            let dest = backupDir.appendingPathComponent("\(baseName).\(stamp)\(suffix).backup")
            do {
                try fm.copyItem(at: URL(fileURLWithPath: srcPath), to: dest)
                copiedAny = true
                logger.notice("Backed up \(srcPath, privacy: .public) -> \(dest.path, privacy: .public).")
            } catch {
                logger.error("Backup copy failed for \(srcPath, privacy: .public): \(String(describing: error), privacy: .public).")
            }
        }
        return copiedAny
    }

    /// Removes the main store file and its SQLite sidecar files (`-wal`, `-shm`).
    /// Used only after a successful backup.
    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in storeFileSuffixes {
            let path = url.path + suffix
            if fm.fileExists(atPath: path) {
                do {
                    try fm.removeItem(atPath: path)
                } catch {
                    logger.error("Failed to remove \(path, privacy: .public) after backup: \(String(describing: error), privacy: .public).")
                }
            }
        }
    }

    /// Starts observing settings-change notifications. Called by AppDelegate at launch.
    /// Also runs `enforceLimits` once immediately after launch.
    func startObservingSettings() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .retentionChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged), name: .maxCountChanged, object: nil
        )
        // Run once at launch.
        scheduleEnforceWithDebounce()
    }

    @objc private func settingsChanged() {
        scheduleEnforceWithDebounce()
    }

    /// Called after new history is saved or settings change. Runs `enforceLimits` with a 1-second debounce.
    /// Even if called repeatedly, only the last invocation executes (design-implementation.md §4.4).
    func scheduleEnforceWithDebounce() {
        enforceDebouncer?.cancel()
        let r = settings.retentionDays
        let m = settings.maxHistoryCount
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.enforceLimits(retentionDays: r, maxCount: m) }
        }
        enforceDebouncer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func enforceLimits(retentionDays: Int, maxCount: Int) {
        let ctx = container.mainContext
        let now = Date()
        if retentionDays > 0 {
            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) ?? now
            let fd = FetchDescriptor<ClipboardEntity>(
                predicate: #Predicate<ClipboardEntity> { $0.createdAt < cutoff }
            )
            if let stale = fetchEntities(fd, context: ctx, purpose: "enforceLimits.retention") {
                for e in stale {
                    ctx.delete(e)
                }
            }
        }
        let allFd = FetchDescriptor<ClipboardEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        if let all = fetchEntities(allFd, context: ctx, purpose: "enforceLimits.maxCount"), all.count > maxCount {
            let surplus = all.count - maxCount
            for e in all.prefix(surplus) {
                ctx.delete(e)
            }
        }
        saveContext(ctx, purpose: "enforceLimits")
    }

    func clearAll() {
        let ctx = container.mainContext
        let fd = FetchDescriptor<ClipboardEntity>()
        if let all = fetchEntities(fd, context: ctx, purpose: "clearAll") {
            for e in all {
                ctx.delete(e)
            }
            saveContext(ctx, purpose: "clearAll")
        }
    }

    // MARK: - Save / fetch helpers (surface SwiftData errors instead of swallowing them)

    /// Saves the given ModelContext. On failure, logs via `Logger` and notifies the user via `AppNotifier`
    /// so save failures (disk full, external storage load failure, quota exceeded) are not silently dropped.
    /// Use this instead of bare `try? ctx.save()` everywhere a history change is persisted.
    func saveContext(_ ctx: ModelContext, purpose: String) {
        do {
            try ctx.save()
        } catch {
            Self.logger.error("ModelContext save failed (\(purpose, privacy: .public)): \(String(describing: error), privacy: .public).")
            AppNotifier.notify(
                title: "Clipboard save failed",
                body: "A clipboard history change could not be saved (disk full or storage error). Recent copies may not persist. (\(purpose))",
                deduplicationKey: "persistence-save-failed"
            )
        }
    }

    /// Fetches entities with the given descriptor. On failure, logs via `Logger` and returns `nil`
    /// so callers can fall back gracefully. Fetch failures are not user-notified because they do not
    /// cause data loss by themselves (the data remains on disk; only the in-memory result is missing).
    func fetchEntities<T: PersistentModel>(
        _ descriptor: FetchDescriptor<T>,
        context: ModelContext,
        purpose: String
    ) -> [T]? {
        do {
            return try context.fetch(descriptor)
        } catch {
            Self.logger.error("ModelContext fetch failed (\(purpose, privacy: .public)): \(String(describing: error), privacy: .public).")
            return nil
        }
    }

    /// Flushes pending changes to disk at termination. Errors are logged but not user-notified
    /// (the app is quitting and a modal notification would be disruptive).
    func flushOnTerminate() {
        let ctx = container.mainContext
        do {
            try ctx.save()
        } catch {
            Self.logger.error("ModelContext save on terminate failed: \(String(describing: error), privacy: .public).")
        }
    }
}
