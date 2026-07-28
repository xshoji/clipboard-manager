import AppKit
import SwiftUI

struct PreviewPane: View {
    let item: ClipboardItem?
    let viewModel: HistoryViewModel
    let wrapMode: String

    @State private var isExpanded: Bool = false
    @State private var fullText: String? = nil
    @State private var previewImage: NSImage? = nil
    /// Parsed HTML result paired with the item ID it was loaded for, so a stale
    /// parse from a previous item never bleeds into the current selection.
    @State private var loadedHTML: LoadedHTML? = nil

    private struct LoadedHTML {
        let itemID: UUID
        let attributed: NSAttributedString
    }

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
        }
        .task(id: item?.id) {
            previewImage = nil
            // Note: we do NOT clear loadedHTML here. It is paired with itemID,
            // so a stale value cannot bleed into the current selection. Keeping
            // the previous value acts as a one-item cache: re-selecting the
            // previous HTML item shows content instantly without re-fetching.
            // Most importantly, clearing it here would cause the content(_:)
            // view builder to fall through to the plain-text branch while the
            // async fetch is in flight, then swap in the AppKit view after
            // completion — a two-phase render that causes visible jank.
            guard let item else { return }
            if item.isImage, let data = await viewModel.imageData(id: item.id) {
                previewImage = ThumbnailImageCache.image(
                    forData: data,
                    representation: .full,
                    contentHash: item.contentHash
                )
            } else if item.isHtml, let data = await viewModel.htmlContent(id: item.id) {
                // NSAttributedString(html:) MUST be called on the main thread — Apple's
                // HTML importer synchronizes with the main run loop and times out or
                // returns unstable results when called off-main.
                let result = Self.parseHTML(data)
                guard !Task.isCancelled, let result else { return }
                loadedHTML = LoadedHTML(itemID: item.id, attributed: result)
            }
        }
    }

    @ViewBuilder
    private func content(_ entity: ClipboardItem) -> some View {
        ZStack {
            // Keep the AppKit NSScrollView always mounted so that selecting an
            // HTML item never triggers makeNSView (which causes a layout flash).
            // When the current item is not HTML, the view is hidden via opacity
            // and disabled for hit-testing/accessibility. The attributedString
            // is empty for non-HTML items, so no stale content is visible.
            AttributedTextView(
                documentID: entity.isHtml ? entity.id : nil,
                attributedString: attributedHTML(for: entity),
                wrapsLines: wrapMode != "nowrap"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(entity.isHtml ? 1 : 0)
            .allowsHitTesting(entity.isHtml)
            .accessibilityHidden(!entity.isHtml)

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
            } else if !entity.isHtml {
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
    }

    /// Returns the parsed HTML attributed string for the given entity, or an
    /// empty string if the entity is not HTML or the HTML has not been loaded yet.
    private func attributedHTML(for entity: ClipboardItem) -> NSAttributedString {
        guard entity.isHtml,
              let loadedHTML,
              loadedHTML.itemID == entity.id
        else { return NSAttributedString(string: "") }
        return loadedHTML.attributed
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

    /// Parses HTML into an `NSAttributedString` on the main thread.
    /// Apple's HTML importer requires the main run loop and produces unstable
    /// results (timeouts, partial output) when called from a background queue.
    /// The importer embeds explicit foreground colors (typically black) that are
    /// invisible on the app's dark background. We strip them here so the
    /// NSTextView's `textColor` (set in updateNSView, in the view's appearance
    /// context) is used instead. Bold/italic/size are preserved.
    private static func parseHTML(_ data: Data) -> NSAttributedString? {
        guard let attr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue
            ],
            documentAttributes: nil
        ) else { return nil }
        let mutable = NSMutableAttributedString(attributedString: attr)
        mutable.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: mutable.length))
        return mutable
    }
}

/// `NSTextView` subclass that refuses to become a key view or first responder.
/// Used inside the always-mounted `AttributedTextView` so the AppKit text view
/// never steals keyboard focus from the SwiftUI history list's arrow-key
/// navigation, which would cause the system beep and break cursor movement.
private final class NonKeyTextView: NSTextView {
    override var canBecomeKeyView: Bool { false }
}

/// Renders an `NSAttributedString` (e.g. rich HTML) inside SwiftUI using `NSTextView`.
/// The view is selectable but not editable, so users can copy from the preview.
/// The returned `NSScrollView` owns scrolling — do NOT wrap this in a SwiftUI
/// `ScrollView`; the double-scroll-view causes layout collapse.
///
/// This view should be kept always-mounted (e.g. in a ZStack with opacity toggling)
/// so that switching to an HTML item does not trigger `makeNSView`, which causes a
/// visible layout flash. When always-mounted, only `updateNSView` runs, which
/// efficiently updates the text storage in-place.
struct AttributedTextView: NSViewRepresentable {
    let documentID: UUID?
    let attributedString: NSAttributedString
    let wrapsLines: Bool

    final class Coordinator {
        var didApplyInitialState = false
        var documentID: UUID?
        var wrapsLines: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // Create a scrollable NonKeyTextView instead of the default NSTextView.
        // NonKeyTextView refuses first responder so the always-mounted AppKit
        // view never steals keyboard focus from SwiftUI's arrow-key navigation.
        let textView = NonKeyTextView()
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = wrapsLines ? false : true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = !wrapsLines
        textView.isRichText = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = NSColor.labelColor
        textView.autoresizingMask = [.width]
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.widthTracksTextView = wrapsLines
        textView.textContainer?.containerSize = NSSize(
            width: wrapsLines ? max(scrollView.contentSize.width, 1) : CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        synchronize(scrollView, textView: textView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        synchronize(scrollView, textView: textView, coordinator: context.coordinator)
    }

    private func synchronize(
        _ scrollView: NSScrollView,
        textView: NSTextView,
        coordinator: Coordinator
    ) {
        // Update wrap mode if it changed (also works on first apply).
        if coordinator.wrapsLines != wrapsLines {
            configureWrapping(scrollView, textView: textView, wrapsLines: wrapsLines)
            coordinator.wrapsLines = wrapsLines
        }

        let documentChanged = !coordinator.didApplyInitialState || coordinator.documentID != documentID
        let contentChanged = !textView.attributedString().isEqual(to: attributedString)

        guard documentChanged || contentChanged else { return }

        if contentChanged {
            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributedString(attributedString)
            // Override foreground color in the view's appearance context so the
            // HTML importer's embedded black does not bleed through on dark backgrounds.
            let fullRange = NSRange(location: 0, length: storage?.length ?? 0)
            storage?.addAttribute(.foregroundColor, value: NSColor.labelColor, range: fullRange)
            storage?.endEditing()
        }

        coordinator.didApplyInitialState = true
        coordinator.documentID = documentID

        // Scroll to top on document change.
        if documentChanged {
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        // Flash scrollers after layout so the user sees that the content is
        // scrollable when it overflows (overlay scrollers are hidden at rest).
        if attributedString.length > 0 {
            DispatchQueue.main.async { [weak scrollView] in
                scrollView?.layoutSubtreeIfNeeded()
                scrollView?.flashScrollers()
            }
        }
    }

    private func configureWrapping(
        _ scrollView: NSScrollView,
        textView: NSTextView,
        wrapsLines: Bool
    ) {
        textView.isHorizontallyResizable = !wrapsLines
        textView.autoresizingMask = [.width]

        guard let container = textView.textContainer else { return }
        container.heightTracksTextView = false
        container.widthTracksTextView = wrapsLines
        container.containerSize = NSSize(
            width: wrapsLines
                ? max(scrollView.contentSize.width, 1)
                : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude
        )

        scrollView.hasHorizontalScroller = !wrapsLines
    }
}
