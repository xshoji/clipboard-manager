import SwiftUI

struct HistoryRowView: View {
    let entity: ClipboardEntity
    let selected: Bool
    private let title: String
    private let subtitle: String

    private static let titleCharLimit = 200
    private static let subtitleCharLimit = 200

    init(entity: ClipboardEntity, selected: Bool) {
        self.entity = entity
        self.selected = selected
        if entity.isImage {
            title = "Image\(entity.sourceBundleID.map { "  via \($0)" } ?? "")"
            subtitle = Self.formatBytes(entity.imageData?.count ?? 0)
        } else {
            let preview = entity.displayTextPreview
            let lines = preview.split(separator: "\n", omittingEmptySubsequences: false)
            let firstLineRaw = String(lines.first ?? Substring(preview))
                .trimmingCharacters(in: .whitespaces)
            let firstLine = Self.clamp(firstLineRaw, limit: Self.titleCharLimit)
            let restRaw = lines.dropFirst().joined(separator: "")
                .trimmingCharacters(in: .whitespaces)
            let rest = Self.clamp(restRaw, limit: Self.subtitleCharLimit)
            title = firstLine.isEmpty ? Self.clamp(preview.trimmingCharacters(in: .whitespaces), limit: Self.titleCharLimit) : firstLine
            subtitle = rest.isEmpty ? Self.formattedDate(entity.createdAt) : rest
        }
    }

    private static func clamp(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        return String(s.prefix(limit)) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))
            } else {
                Color.clear
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var icon: some View {
        if entity.isImage, let thumb = entity.thumbnail, let img = ThumbnailImageCache.image(forData: thumb, representation: .thumbnail, contentHash: entity.contentHash) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        } else {
            Image(nsImage: AppIconResolver.icon(forBundleID: entity.sourceBundleID))
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt
    }()

    private static func formattedDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func formatBytes(_ b: Int) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.1f KB", Double(b) / 1024) }
        return String(format: "%.1f MB", Double(b) / 1024 / 1024)
    }
}
