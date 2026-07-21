import SwiftUI

struct PreviewPane: View {
    @Environment(\.modelContext) private var ctx
    let entity: ClipboardEntity?
    let wrapMode: String

    @State private var isExpanded: Bool = false
    @State private var fullText: String? = nil

    private static let previewCharLimit = 2_000

    /// Scroll axes for the text preview. In `nowrap` mode the text overflows
    /// horizontally, so enable horizontal scrolling to reveal the full content.
    /// In `wrap` mode the text wraps to the pane width, so vertical-only is enough.
    private var scrollAxes: Axis.Set {
        wrapMode == "nowrap" ? [.vertical, .horizontal] : .vertical
    }

    var body: some View {
        Group {
            if let entity {
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
        .onChange(of: entity?.id) { _, _ in
            isExpanded = false
            fullText = nil
        }
    }

    @ViewBuilder
    private func content(_ entity: ClipboardEntity) -> some View {
        if entity.isImage, let data = entity.imageData, let img = ThumbnailImageCache.image(forData: data, representation: .full, contentHash: entity.contentHash) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func displayedText(_ entity: ClipboardEntity) -> String {
        if isExpanded, let full = fullText { return full }
        return Self.clampPreview(entity.displayTextPreview)
    }

    private static func clampPreview(_ s: String) -> String {
        if s.count <= previewCharLimit { return s }
        return String(s.prefix(previewCharLimit)) + "…"
    }

    private func expandFullText(_ entity: ClipboardEntity) {
        guard !isExpanded else { return }
        fullText = entity.text
        isExpanded = true
    }

    private func collapse() {
        isExpanded = false
        fullText = nil
    }

    private func footer(_ entity: ClipboardEntity) -> some View {
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
