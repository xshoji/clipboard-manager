import SwiftUI
import SwiftData
import AppKit

struct TextEditView: View {
    let original: ClipboardEntity
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var ctx

    init(original: ClipboardEntity) {
        self.original = original
        _draft = State(initialValue: original.text ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Edit (plain text)").font(.headline)
                Spacer()
            }.padding()
            Divider()
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save as new") {
                    let newEntity = ClipboardEntity(
                        kind: "text",
                        text: draft,
                        richText: nil,
                        contentHash: HashUtil.sha256Hex(of: Data(draft.utf8))
                    )
                    ctx.insert(newEntity)
                    PersistenceController.shared?.saveContext(ctx, purpose: "TextEditView.saveAsNew")
                    PersistenceController.shared?.scheduleEnforceWithDebounce()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
