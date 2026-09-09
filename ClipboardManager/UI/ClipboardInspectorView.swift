import SwiftUI

struct ClipboardInspectorRequest: Identifiable {
    let item: ClipboardItem
    let frozenCurrentInspection: ClipboardInspection?

    var id: UUID { item.id }
}

struct ClipboardInspectorView: View {
    @Environment(\.dismiss) private var dismiss
    let request: ClipboardInspectorRequest
    let viewModel: HistoryViewModel

    @State private var inspection: ClipboardInspection?
    @State private var didFinishLoading = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 540, height: 640)
        .background(Color.appBackground)
        .task(id: request.id) {
            if request.item.isCurrent {
                inspection = request.frozenCurrentInspection
                didFinishLoading = true
                return
            }
            let loaded = await viewModel.storedInspection(for: request.item)
            guard !Task.isCancelled else { return }
            inspection = loaded
            didFinishLoading = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text("Clipboard Inspector")
                    .font(.headline)
                Text("Formats and metadata for this clipboard item")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        if let inspection {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview(inspection)
                    representations(inspection)
                    if let metrics = inspection.textMetrics {
                        textMetrics(metrics)
                    }
                    if let metrics = inspection.imageMetrics {
                        imageMetrics(metrics, inspection: inspection)
                    }
                    contentIdentity(inspection)
                    if let typeIdentifiers = inspection.declaredTypeIdentifiers {
                        declaredTypes(typeIdentifiers)
                    }
                }
                .padding(20)
            }
        } else if didFinishLoading {
            ContentUnavailableView(
                "Item Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("The clipboard item may have been removed while the inspector was opening.")
            )
        } else {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Inspecting clipboard item…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            if inspection?.declaredTypeIdentifiers == nil {
                Text("Original pasteboard types were not stored for history items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let inspection else { return }
                viewModel.copyInspectionText(ClipboardInspectionFormatter.report(inspection))
            } label: {
                Label("Copy Report", systemImage: "doc.on.doc")
            }
            .disabled(inspection == nil)
            .accessibilityIdentifier("clipboardInspector.copyReport")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func overview(_ inspection: ClipboardInspection) -> some View {
        InspectorGroup(title: "Overview") {
            InspectorValueRow(label: "Item", value: inspection.isCurrent ? "Current Clipboard" : "History")
            InspectorValueRow(label: "Kind", value: inspection.kind.capitalized)
            InspectorValueRow(
                label: "Captured",
                value: inspection.createdAt.formatted(date: .abbreviated, time: .standard)
            )
            InspectorValueRow(label: "Source", value: inspection.sourceBundleID ?? "Not reported", monospaced: inspection.sourceBundleID != nil)
        }
    }

    private func representations(_ inspection: ClipboardInspection) -> some View {
        InspectorGroup(title: inspection.isCurrent ? "Captured Representations" : "Stored Representations") {
            if inspection.representations.isEmpty {
                Text("No supported representations were found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(inspection.representations.enumerated()), id: \.offset) { _, representation in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(ClipboardInspectionFormatter.title(for: representation.format))
                            Spacer()
                            Text(ClipboardInspectionFormatter.bytes(representation.byteCount))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 5) {
                            if let identifier = representation.typeIdentifier {
                                Text(identifier)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            Text(ClipboardInspectionFormatter.title(for: representation.origin))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                }
            }
            if inspection.isCurrent {
                Text("Sizes are shown only for formats captured by ClipboardManager. See Declared Pasteboard Types for every format advertised by the source application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func textMetrics(_ metrics: ClipboardTextMetrics) -> some View {
        InspectorGroup(title: "Text Metrics") {
            InspectorValueRow(label: "Characters", value: metrics.characterCount.formatted())
            InspectorValueRow(label: "Lines", value: metrics.lineCount.formatted())
            InspectorValueRow(label: "UTF-8", value: ClipboardInspectionFormatter.bytes(metrics.utf8ByteCount))
            InspectorValueRow(label: "UTF-16", value: "\(metrics.utf16CodeUnitCount.formatted()) code units")
        }
    }

    private func imageMetrics(
        _ metrics: ClipboardImageMetrics,
        inspection: ClipboardInspection
    ) -> some View {
        InspectorGroup(title: "Image Metrics") {
            InspectorValueRow(
                label: "Dimensions",
                value: "\(metrics.pixelWidth.formatted()) × \(metrics.pixelHeight.formatted()) px",
                valueIdentifier: "clipboardInspector.dimensions"
            )
            InspectorValueRow(label: "Encoded Type", value: metrics.typeIdentifier ?? "Unknown", monospaced: metrics.typeIdentifier != nil)
            if let status = inspection.ocrStatus {
                InspectorValueRow(label: "OCR Status", value: status.capitalized)
            }
            if let count = inspection.ocrCharacterCount {
                InspectorValueRow(label: "OCR Characters", value: count.formatted())
            }
        }
    }

    private func contentIdentity(_ inspection: ClipboardInspection) -> some View {
        InspectorGroup(title: "Content Identity") {
            if let hash = inspection.contentHash {
                HStack(spacing: 10) {
                    Text(hash)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        viewModel.copyInspectionText(hash)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy full content identity hash")
                    .accessibilityLabel("Copy content identity hash")
                }
                Text("SHA-256 of the normalized content used for duplicate detection, not necessarily every stored representation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No content identity hash is available.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func declaredTypes(_ typeIdentifiers: [String]) -> some View {
        InspectorGroup(title: "Declared Pasteboard Types") {
            if typeIdentifiers.isEmpty {
                Text("No types were reported.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(typeIdentifiers, id: \.self) { identifier in
                    Text(identifier)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Unknown types are listed by identifier only; their payloads are not read.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 9) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
    }
}

private struct InspectorValueRow: View {
    let label: String
    let value: String
    var monospaced = false
    var valueIdentifier: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .leading)
            valueText
        }
        .font(.callout)
    }

    @ViewBuilder
    private var valueText: some View {
        let text = Text(value)
            .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let valueIdentifier {
            text.accessibilityIdentifier(valueIdentifier)
        } else {
            text
        }
    }
}

enum ClipboardInspectionFormatter {
    static func title(for format: ClipboardRepresentationFormat) -> String {
        switch format {
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .richText: "Rich Text (RTF or RTFD)"
        case .rtf: "RTF"
        case .rtfd: "RTFD"
        case .png: "PNG"
        case .tiff: "TIFF"
        }
    }

    static func title(for origin: ClipboardRepresentationOrigin) -> String {
        switch origin {
        case .source: "Source"
        case .derived: "Derived"
        case .normalized: "Normalized"
        case .stored: "Stored"
        }
    }

    static func bytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.includesActualByteCount = true
        return formatter.string(fromByteCount: Int64(count))
    }

    static func report(_ inspection: ClipboardInspection) -> String {
        var lines = [
            "Clipboard Inspector",
            "Item: \(inspection.isCurrent ? "Current Clipboard" : "History")",
            "Kind: \(inspection.kind)",
            "Captured: \(ISO8601DateFormatter().string(from: inspection.createdAt))"
        ]
        if let source = inspection.sourceBundleID { lines.append("Source: \(source)") }
        if let hash = inspection.contentHash { lines.append("Content Identity Hash: \(hash)") }
        lines.append(inspection.isCurrent ? "Captured Representations:" : "Stored Representations:")
        for representation in inspection.representations {
            var description = "- \(title(for: representation.format)): \(representation.byteCount) bytes [\(title(for: representation.origin))]"
            if let identifier = representation.typeIdentifier { description += " (\(identifier))" }
            lines.append(description)
        }
        if let metrics = inspection.textMetrics {
            lines.append("Text: \(metrics.characterCount) characters, \(metrics.lineCount) lines, \(metrics.utf8ByteCount) UTF-8 bytes, \(metrics.utf16CodeUnitCount) UTF-16 code units")
        }
        if let metrics = inspection.imageMetrics {
            var description = "Image: \(metrics.pixelWidth) × \(metrics.pixelHeight) px"
            if let identifier = metrics.typeIdentifier { description += " (\(identifier))" }
            lines.append(description)
        }
        if let status = inspection.ocrStatus { lines.append("OCR Status: \(status)") }
        if let count = inspection.ocrCharacterCount { lines.append("OCR Characters: \(count)") }
        if let typeIdentifiers = inspection.declaredTypeIdentifiers {
            lines.append("Declared Pasteboard Types:")
            lines.append(contentsOf: typeIdentifiers.map { "- \($0)" })
        } else {
            lines.append("Declared Pasteboard Types: Not stored for history items")
        }
        return lines.joined(separator: "\n")
    }
}
