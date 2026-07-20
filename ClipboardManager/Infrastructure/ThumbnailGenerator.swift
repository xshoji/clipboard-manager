import AppKit
import CoreImage

enum ThumbnailGenerator {
    static func thumbnailData(from pngData: Data, maxEdge: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(data: pngData) else { return nil }
        let origW = CGFloat(rep.pixelsWide)
        let origH = CGFloat(rep.pixelsHigh)
        let scale = maxEdge / max(origW, origH)
        guard scale < 1.0 else { return pngData }
        let newW = Int(origW * scale)
        let newH = Int(origH * scale)

        let size = NSSize(width: newW, height: newH)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let tiffRep = NSBitmapImageRep(data: tiff),
              let png = tiffRep.representation(using: .png, properties: [:]) else { return nil }
        return png
    }
}
