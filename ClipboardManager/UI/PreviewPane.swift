import AppKit
import SwiftUI

struct PreviewPane: View {
    let item: ClipboardItem?
    let viewModel: HistoryViewModel
    let wrapMode: String

    @State private var isExpanded: Bool = false
    @State private var fullText: String? = nil
    @State private var previewImage: NSImage? = nil
    @State private var htmlAttributed: NSAttributedString? = nil

    private static let previewCharLimit = 2_000

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
        .onChange(of: item?.id) { _, _ in
            isExpanded = false
            fullText = nil
            htmlAttributed = nil
        }
        .task(id: item?.id) {
            previewImage = nil
            htmlAttributed = nil
            guard let item else { return }
            if item.isImage, let data = await viewModel.imageData(id: item.id) {
                previewImage = ThumbnailImageCache.image(
                    forData: data,
                    representation: .full,
                    contentHash: item.contentHash
                )
            } else if item.isHtml, let data = await viewModel.htmlContent(id: item.id) {
                // NSAttributedString(html:) is synchronous and heavy; parse off the
                // main actor to avoid blocking the UI thread during preview (review #5).
                htmlAttributed = await Self.parsedAttributedString(fromHTML: data)
            }
        }
    }

    @ViewBuilder
    private func content(_ entity: ClipboardItem) -> some View {
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
        } else if entity.isHtml, let htmlAttributed {
            ScrollView(scrollAxes) {
                AttributedTextView(attributedString: htmlAttributed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.topLeading)
        } else {
            ScrollView(scrollAxes) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(displayedText(entity))
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 200)
                        .fixedSize(horizontal: wrapMode == "nowrap", vertical: false)
                    if entity.isTextPreviewTruncated == true, !isExpanded {
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

    /// `NSAttributedString` is not `Sendable`, so we wrap it for safe transfer across
    /// actor boundaries. `NSAttributedString` is effectively immutable for our read-only
    /// preview use-case, so `@unchecked Sendable` is safe here (review #5).
    private struct HTMLParseResult: @unchecked Sendable {
        let attributed: NSAttributedString?
    }

    /// Parses HTML into an `NSAttributedString` on a background priority to keep the
    /// main actor free (review #5). `NSAttributedString(html:)` is synchronous and
    /// can take tens of milliseconds for non-trivial HTML.
    private static nonisolated func parseHTML(_ data: Data) -> HTMLParseResult {
        HTMLParseResult(attributed: try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ))
    }

    private static func parsedAttributedString(fromHTML data: Data) async -> NSAttributedString? {
        await Task.detached(priority: .userInitiated) {
            parseHTML(data)
        }.value.attributed
    }
}

/// Renders an `NSAttributedString` (e.g. rich HTML) inside SwiftUI using `NSTextView`.
/// The view is selectable but not editable, so users can copy from the preview.
struct AttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainer?.widthTracksTextView = true
        // With widthTracksTextView = true, the text container automatically tracks the
        // textView width, so an explicit containerSize is unnecessary. Setting width to
        // 0 can cause the first layout pass to clip text (review #6).
        textView.autoresizingMask = [.width]
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        textView.textStorage?.setAttributedString(attributedString)
    }
}
