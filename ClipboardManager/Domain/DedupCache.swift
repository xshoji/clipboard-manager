import Foundation
import CryptoKit

/// Thread-safe dedup cache used by `ClipboardMonitor`, which polls the pasteboard
/// on a background utility queue (review #6). All mutating access is guarded by an
/// internal lock so callers do not need actor isolation.
final class DedupCache {
    private(set) var maxSize: Int
    private var ring: [String] = []
    private var set: Set<String> = []
    private let lock = NSLock()

    init(maxSize: Int) {
        self.maxSize = max(0, maxSize)
    }

    func resize(maxSize newMax: Int) {
        lock.lock(); defer { lock.unlock() }
        maxSize = max(0, newMax)
        while ring.count > maxSize {
            let oldest = ring.removeFirst()
            set.remove(oldest)
        }
    }

    func shouldSkip(contentHash: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard maxSize > 0 else { return false }
        return set.contains(contentHash)
    }

    func record(_ contentHash: String) {
        lock.lock(); defer { lock.unlock() }
        guard maxSize > 0 else { return }
        if set.contains(contentHash) {
            moveToFront(contentHash)
            return
        }
        while ring.count >= maxSize {
            let oldest = ring.removeFirst()
            set.remove(oldest)
        }
        ring.append(contentHash)
        set.insert(contentHash)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        ring.removeAll()
        set.removeAll()
    }

    private func moveToFront(_ contentHash: String) {
        if let idx = ring.firstIndex(of: contentHash) {
            ring.remove(at: idx)
            ring.append(contentHash)
        }
    }
}

enum HashUtil {
    static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256File(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return sha256Hex(of: data)
    }
}
