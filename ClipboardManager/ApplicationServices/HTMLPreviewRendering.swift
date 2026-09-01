import Foundation

enum HTMLPreviewLimits {
    static let maximumInputBytes = 100 * 1024 * 1024
    static let maximumOutputBytes = 512 * 1024
    static let maximumUTF16Length = 2_000
    static let maximumStyleRuns = 256
    static let maximumPhysicalFootprintBytes: UInt64 = 512 * 1024 * 1024
}

/// Isolates formatted HTML conversion behind an asynchronous boundary.
/// Implementations must never invoke the system HTML importer in the app process.
protocol HTMLPreviewRendering: Sendable {
    func render(html: Data) async -> Data?
}
