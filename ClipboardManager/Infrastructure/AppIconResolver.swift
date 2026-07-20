import AppKit

@MainActor
enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]

    static func icon(forBundleID bundleID: String?) -> NSImage {
        let fallback = NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
        guard let bundleID, !bundleID.isEmpty else { return fallback }
        if let cached = cache[bundleID] { return cached }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let img = NSWorkspace.shared.icon(forFile: url.path)
            img.size = NSSize(width: 24, height: 24)
            cache[bundleID] = img
            return img
        }
        return fallback
    }
}
