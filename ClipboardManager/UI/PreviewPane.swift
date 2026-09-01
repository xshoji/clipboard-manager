import AppKit
import SwiftUI

struct PreviewPane: View {
    let item: ClipboardItem?
    let viewModel: HistoryViewModel
    let wrapMode: String

    @State private var isExpanded: Bool = false
    @State private var fullText: String? = nil
    @State private var previewImage: NSImage? = nil
    @State private var formattedHTML: FormattedHTML? = nil

    private struct PreviewRevision: Hashable {
        let id: UUID
        let createdAt: Date
        let contentHash: String?
    }

    private struct FormattedHTML {
        let revision: PreviewRevision
        let attributedString: NSAttributedString
    }

    private static let previewCharLimit = 2_000

    private var revision: PreviewRevision? {
        item.map { PreviewRevision(id: $0.id, createdAt: $0.createdAt, contentHash: $0.contentHash) }
    }

    /// Scroll axes for the text preview. In `nowrap` mode the text overflows
    /// horizontally, so enable horizontal scrolling to reveal the full content.
    /// In `wrap` mode the text wraps to the pane width, so vertical-only is enough.
    private var scrollAxes: Axis.Set {
        wrapMode == "nowrap" ? [.vertical, .horizontal] : .vertical
    }

    var body: some View {
        Group {
            if let entity = item {
                VStack(alignment: .leading, spacing: 4) {
                    content(entity)
                    Divider().opacity(0.2)
                    footer(entity)
                }
                .padding()
            } else {
                VStack {
                    Spacer()
                    Text("Select an item on the left.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.appBackground)
        .onChange(of: revision) { _, _ in
            isExpanded = false
            fullText = nil
            previewImage = nil
            formattedHTML = nil
        }
        .task(id: revision) {
            previewImage = nil
            formattedHTML = nil
            guard let item, revision != nil else { return }
            if item.isImage, let data = await viewModel.imageData(id: item.id) {
                previewImage = ThumbnailImageCache.image(
                    forData: data,
                    representation: .full,
                    contentHash: item.contentHash
                )
            } else if item.isHtml,
                      let rtf = await viewModel.formattedHTMLPreview(id: item.id),
                      !Task.isCancelled,
                      let attributedString = Self.decodeBoundedRTF(rtf),
                      let revision {
                formattedHTML = FormattedHTML(
                    revision: revision,
                    attributedString: attributedString
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ entity: ClipboardItem) -> some View {
        let displaysFormattedHTML = formattedHTML?.revision == revision
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                BoundedAttributedTextView(
                    attributedString: displaysFormattedHTML
                        ? formattedHTML?.attributedString ?? NSAttributedString()
                        : NSAttributedString(),
                    wrapsLines: wrapMode != "nowrap"
                )
                .opacity(displaysFormattedHTML ? 1 : 0)
                .allowsHitTesting(displaysFormattedHTML)
                .accessibilityHidden(!displaysFormattedHTML)

                if entity.isImage {
                    if let previewImage {
                        Image(nsImage: previewImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        Text("Image preview unavailable.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if !displaysFormattedHTML {
                    ScrollView(scrollAxes) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text(displayedText(entity))
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .lineLimit(isExpanded ? nil : 200)
                                .fixedSize(horizontal: wrapMode == "nowrap", vertical: false)
                            if entity.isHtml, !entity.canUsePlainText {
                                unavailableTextNotice
                                    .padding(.top, 8)
                            } else if entity.isTextPreviewTruncated == true, !isExpanded {
                                Button {
                                    expandFullText(entity)
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("Show all\(entity.textCharacterCount.map { " (\($0) chars)" } ?? "")")
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                    .padding(.top, 8)
                                }
                                .buttonStyle(.borderless)
                            } else if isExpanded {
                                Button {
                                    collapse()
                                } label: {
                                    Text("Show less")
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.top, 8)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .defaultScrollAnchor(.topLeading)
                }
            }
            if displaysFormattedHTML, !entity.canUsePlainText {
                unavailableTextNotice
            }
        }
    }

    private var unavailableTextNotice: some View {
        Text("The original HTML is preserved for rich paste. Plain Text, Edit, and Macro actions are unavailable because no usable text could be extracted.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    static func decodeBoundedRTF(_ data: Data) -> NSAttributedString? {
        guard data.count <= HTMLPreviewLimits.maximumOutputBytes,
              let attributedString = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
              ),
              attributedString.length <= HTMLPreviewLimits.maximumUTF16Length else { return nil }
        var runCount = 0
        attributedString.enumerateAttributes(
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { _, _, stop in
            runCount += 1
            if runCount > HTMLPreviewLimits.maximumStyleRuns { stop.pointee = true }
        }
        return runCount <= HTMLPreviewLimits.maximumStyleRuns ? attributedString : nil
    }

    private func displayedText(_ entity: ClipboardItem) -> String {
        if isExpanded, let full = fullText { return full }
        return Self.clampPreview(entity.displayTextPreview)
    }

    private static func clampPreview(_ s: String) -> String {
        if s.count <= previewCharLimit { return s }
        return String(s.prefix(previewCharLimit)) + "…"
    }

    private func expandFullText(_ entity: ClipboardItem) {
        guard !isExpanded else { return }
        Task {
            fullText = await viewModel.fullText(id: entity.id)
            isExpanded = true
        }
    }

    private func collapse() {
        isExpanded = false
        fullText = nil
    }

    private func footer(_ entity: ClipboardItem) -> some View {
        HStack {
            Text(entity.kind.uppercased())
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
            if let b = entity.sourceBundleID {
                Text(b)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formatted(entity.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private func formatted(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f.string(from: d)
    }

}

private final class NonKeyHTMLPreviewTextView: NSTextView {
    override var canBecomeKeyView: Bool { false }
}

/// Displays only the helper's bounded RTF output. HTML is never passed into this
/// view, and TextKit receives at most 2,000 UTF-16 code units and 256 style runs.
private struct BoundedAttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString
    let wrapsLines: Bool

    final class Coordinator {
        var lastInput: NSAttributedString?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NonKeyHTMLPreviewTextView()
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = .zero
        textView.isVerticallyResizable = true
        textView.isRichText = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        configureWrapping(scrollView, textView: textView)
        applyText(to: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        configureWrapping(scrollView, textView: textView)
        applyText(to: textView, coordinator: context.coordinator)
    }

    private func applyText(to textView: NSTextView, coordinator: Coordinator) {
        guard coordinator.lastInput?.isEqual(to: attributedString) != true else { return }
        coordinator.lastInput = NSAttributedString(attributedString: attributedString)
        let display = NSMutableAttributedString(attributedString: attributedString)
        display.addAttribute(
            .foregroundColor,
            value: NSColor.labelColor,
            range: NSRange(location: 0, length: display.length)
        )
        textView.textStorage?.setAttributedString(display)
    }

    private func configureWrapping(_ scrollView: NSScrollView, textView: NSTextView) {
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = [.width]
        scrollView.hasHorizontalScroller = !wrapsLines
        guard let container = textView.textContainer else { return }
        container.heightTracksTextView = false
        container.widthTracksTextView = wrapsLines
        container.containerSize = NSSize(
            width: wrapsLines
                ? max(scrollView.contentSize.width, 1)
                : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
    }
}
