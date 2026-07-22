import AppKit

@MainActor
enum ThumbnailImageCache {
    /// Which representation the cached image corresponds to. Used to namespace the
    /// cache key so a 24x24 thumbnail and a full-resolution image with the same
    /// `contentHash` do not collide (which would return the small thumbnail for a
    /// full-image request and produce a blurry preview).
    enum Representation: String {
        case thumbnail = "thumb"
        case full = "full"
    }

    /// Bounded cache of decoded `NSImage` instances.
    ///
    /// Review #21: the previous `[Data: NSImage]` dictionary was unbounded and keyed by
    /// raw image `Data`, so opening a few dozen multi-MB images could hold hundreds of
    /// MB in memory. `NSCache` evicts under memory pressure and respects `countLimit` /
    /// `totalCostLimit`. The key is `"<representation>:<contentHash>"`, namespaced by
    /// `Representation` so thumbnails and full images do not collide. When no hash is
    /// supplied the image is decoded on demand and not cached.
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 128
        // 256 MB upper bound; `NSImage` cost is approximated from pixel dimensions.
        c.totalCostLimit = 256 * 1024 * 1024
        return c
    }()

    /// Returns a cached `NSImage` for the given image data, decoding and caching it on miss.
    /// - Parameters:
    ///   - data: Raw image data (PNG thumbnail or full image).
    ///   - representation: Which representation this data corresponds to (thumbnail or
    ///     full image). Namespaces the cache key to avoid collisions.
    ///   - contentHash: Stable hash (e.g. SHA-256 hex) used as the cache key. When nil,
    ///     the image is decoded but NOT cached (avoiding unbounded growth from uncached
    ///     callers); pass `entity.contentHash` for normal lookups.
    static func image(forData data: Data, representation: Representation, contentHash: String?) -> NSImage? {
        let key: NSString? = contentHash.map { "\(representation.rawValue):\($0)" as NSString }
        if let key {
            if let cached = cache.object(forKey: key) { return cached }
        }
        guard let img = NSImage(data: data) else { return nil }
        if let key {
            // Approximate cost: bytes per pixel * width * height (RGBA = 4 bytes).
            let cost = Int(img.size.width * img.size.height * 4)
            cache.setObject(img, forKey: key, cost: cost)
        }
        return img
    }

    static func clear() {
        cache.removeAllObjects()
    }
}
