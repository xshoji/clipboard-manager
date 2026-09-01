import AppKit
import Foundation

private let maximumInputBytes = 100 * 1024 * 1024
private let maximumOutputBytes = 512 * 1024
private let maximumUTF16Length = 2_000
private let maximumStyledRuns = 255
private let maximumPhysicalFootprintBytes: UInt64 = 512 * 1024 * 1024
private let watchdogDeadline = ContinuousClock.now + .seconds(2)

DispatchQueue.global(qos: .userInteractive).async {
    while ContinuousClock.now < watchdogDeadline {
        var info = rusage_info_v0()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V0, $0)
            }
        }
        guard result == 0,
              info.ri_phys_footprint <= maximumPhysicalFootprintBytes else {
            kill(getpid(), SIGKILL)
            return
        }
        usleep(10_000)
    }
    kill(getpid(), SIGKILL)
}

guard CommandLine.arguments.count == 3 else { exit(64) }
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

do {
    let attributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
    guard let size = attributes[.size] as? NSNumber,
          size.intValue > 0,
          size.intValue <= maximumInputBytes else { exit(65) }
    let html = try Data(contentsOf: inputURL, options: .mappedIfSafe)
    let imported = try NSAttributedString(
        data: html,
        options: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ],
        documentAttributes: nil
    )

    var length = min(imported.length, maximumUTF16Length)
    let importedString = imported.string as NSString
    if length < imported.length, length > 0,
       (0xD800...0xDBFF).contains(importedString.character(at: length - 1)) {
        length -= 1
    }
    guard length > 0 else { exit(66) }
    let source = imported.attributedSubstring(from: NSRange(location: 0, length: length))
    let output = NSMutableAttributedString(
        string: source.string,
        attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
    )
    var styledRunCount = 0
    source.enumerateAttributes(
        in: NSRange(location: 0, length: source.length),
        options: []
    ) { values, range, stop in
        guard styledRunCount < maximumStyledRuns else {
            stop.pointee = true
            return
        }
        output.setAttributes(sanitizedAttributes(values), range: range)
        styledRunCount += 1
    }

    var rtf = try output.data(
        from: NSRange(location: 0, length: output.length),
        documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    if rtf.count > maximumOutputBytes {
        let plain = NSAttributedString(
            string: output.string,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        rtf = try plain.data(
            from: NSRange(location: 0, length: plain.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
    guard rtf.count <= maximumOutputBytes else { exit(67) }
    try rtf.write(to: outputURL, options: .atomic)
} catch {
    exit(1)
}

private func sanitizedAttributes(
    _ attributes: [NSAttributedString.Key: Any]
) -> [NSAttributedString.Key: Any] {
    var sanitized: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
    ]
    if let font = attributes[.font] as? NSFont {
        let size = min(max(font.pointSize, 8), 48)
        let traits = NSFontManager.shared.traits(of: font)
            .intersection([.boldFontMask, .italicFontMask])
        let base = NSFont.systemFont(ofSize: size)
        sanitized[.font] = NSFontManager.shared.convert(base, toHaveTrait: traits)
    }
    if let underline = attributes[.underlineStyle] as? NSNumber {
        sanitized[.underlineStyle] = underline
    }
    if let strikethrough = attributes[.strikethroughStyle] as? NSNumber {
        sanitized[.strikethroughStyle] = strikethrough
    }
    return sanitized
}
