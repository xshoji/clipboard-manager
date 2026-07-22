import Foundation

/// Design reference: design-implementation.md §5.1 (registration/change confirmation flow, pre-execution fingerprint check, path whitelist).
struct MacroScriptValidation {
    enum Failure: String {
        case pathEmpty
        case fileNotFound
        case outsideHome
        case fingerprintUnavailable
    }

    let resolvedPath: String
    let isInsideHome: Bool
    let fileExists: Bool
    let fingerprint: String?
    let lastModified: Date?
    let failure: Failure?

    var isValid: Bool { failure == nil }
}

/// Expands `~`, resolves `..` and symlinks, then checks location using standardized URLs.
/// Design reference: design-implementation.md §5.1-3 / remaining-features #5, #14
enum MacroScriptPathValidator {
    /// Expands `~` and returns the URL with symlinks resolved. If resolution fails, returns the URL with expansion only.
    static func resolve(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let expanded: String
        if trimmed.hasPrefix("~/") {
            expanded = home + String(trimmed.dropFirst(2))
        } else if trimmed == "~" {
            expanded = home
        } else {
            expanded = trimmed
        }
        let url = URL(fileURLWithPath: expanded)
        return url.resolvingSymlinksInPath()
    }

    static func validate(path: String) -> MacroScriptValidation {
        guard let url = resolve(path: path) else {
            return MacroScriptValidation(
                resolvedPath: path, isInsideHome: false, fileExists: false,
                fingerprint: nil, lastModified: nil, failure: .pathEmpty
            )
        }
        let resolvedPath = url.path
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let normalizedHome = homeURL.resolvingSymlinksInPath()
        let isInsideHome = isPath(url: url, inside: normalizedHome)

        let fm = FileManager.default
        let fileExists = fm.fileExists(atPath: resolvedPath)

        var fingerprint: String? = nil
        var lastModified: Date? = nil
        if fileExists, isInsideHome {
            fingerprint = HashUtil.sha256File(at: resolvedPath)
            if let attrs = try? fm.attributesOfItem(atPath: resolvedPath) {
                lastModified = attrs[.modificationDate] as? Date
            }
        }

        let failure: MacroScriptValidation.Failure?
        if !fileExists {
            failure = .fileNotFound
        } else if !isInsideHome {
            failure = .outsideHome
        } else if fingerprint == nil {
            failure = .fingerprintUnavailable
        } else {
            failure = nil
        }

        return MacroScriptValidation(
            resolvedPath: resolvedPath,
            isInsideHome: isInsideHome,
            fileExists: fileExists,
            fingerprint: fingerprint,
            lastModified: lastModified,
            failure: failure
        )
    }

    /// For remaining-features #14, enforces a directory boundary instead of a plain `hasPrefix(home)`.
    static func isPath(url: URL, inside base: URL) -> Bool {
        let a = url.standardizedFileURL.path
        let b = base.standardizedFileURL.path
        if a == b { return true }
        return a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}
