import Foundation
import ImageIO

enum ClipboardImageMetadataReader {
    static func metrics(from data: Data) -> ClipboardImageMetrics? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        return ClipboardImageMetrics(
            pixelWidth: width.intValue,
            pixelHeight: height.intValue,
            typeIdentifier: CGImageSourceGetType(source) as String?
        )
    }
}
