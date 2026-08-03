import SwiftUI
import AppKit

struct TextEditView: View {
    let original: ClipboardItem
    let viewModel: HistoryViewModel
    let initialText: String?
    @State private var draft: String
    @Environment(\.dismiss) private var dismiss

    init(original: ClipboardItem, viewModel: HistoryViewModel, initialText: String? = nil) {
        self.original = original
        self.viewModel = viewModel
        self.initialText = initialText
        _draft = State(initialValue: initialText ?? "")
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
                    if viewModel.saveText(draft) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 360)
        .task {
            if initialText == nil {
                draft = await viewModel.fullText(id: original.id) ?? ""
            }
        }
    }
}
