import SwiftUI
import AppKit

/// Macro picker overlay shown by the Cmd+M action hotkey (default) while the history
/// window is visible. Lists all registered Macros with keyboard-driven selection:
/// - Up/Down: move cursor
/// - Enter: run the selected Macro against the currently selected history entity
/// - Esc: dismiss without running
/// - Cmd+M (toggle): same as Esc
///
/// Design intent (user request): ClipboardManager open -> pick history -> Cmd+M ->
/// cursor-select a Macro -> Enter runs the Macro with the selected history as input.
struct MacroPickerView: View {
    let macros: [MacroScript]
    let onSelect: (MacroScript) -> Void
    let onCancel: () -> Void

    @State private var selectedIndex: Int = 0
    @State private var searchText: String = ""
    @FocusState private var searchFieldFocused: Bool

    private var filteredMacros: [MacroScript] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return macros }
        return macros.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Run Macro").font(.headline)
                Spacer()
                Text("\(filteredMacros.count) / \(macros.count) macros")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            TextField("Search macros…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .focused($searchFieldFocused)
                .onChange(of: searchText) { _, _ in
                    if selectedIndex >= filteredMacros.count { selectedIndex = 0 }
                }
                .onKeyPress(.upArrow) {
                    guard !filteredMacros.isEmpty else { return .ignored }
                    if selectedIndex <= 0 {
                        selectedIndex = filteredMacros.count - 1
                    } else {
                        selectedIndex -= 1
                    }
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !filteredMacros.isEmpty else { return .ignored }
                    if selectedIndex >= filteredMacros.count - 1 {
                        selectedIndex = 0
                    } else {
                        selectedIndex += 1
                    }
                    return .handled
                }
                .onKeyPress(.return) {
                    guard !filteredMacros.isEmpty,
                          filteredMacros.indices.contains(selectedIndex) else { return .ignored }
                    onSelect(filteredMacros[selectedIndex])
                    return .handled
                }
                .onKeyPress(.escape) {
                    onCancel()
                    return .handled
                }

            Divider().opacity(0.2).padding(.top, 8)

            if filteredMacros.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No macros registered").foregroundStyle(.secondary)
                    Text("Add macros in Settings > Macro Scripts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredMacros.enumerated()), id: \.element.id) { idx, macro in
                            row(for: macro, idx: idx)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            HStack(spacing: 16) {
                Label("Type to search", systemImage: "magnifyingglass")
                Label("Up/Down navigate", systemImage: "arrow.up.arrow.down")
                Label("Return run", systemImage: "return")
                Label("Esc close", systemImage: "escape")
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .overlay(alignment: .top) { Divider().opacity(0.2) }
        }
        .frame(width: 360, height: 320)
        .background(Color.appBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.tertiary.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
        .onAppear {
            searchFieldFocused = true
            if selectedIndex >= filteredMacros.count { selectedIndex = 0 }
        }
    }

    @ViewBuilder
    private func row(for macro: MacroScript, idx: Int) -> some View {
        let isSelected = idx == selectedIndex
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(macro.name).lineLimit(1)
                Text(macro.inlineScript != nil ? "inline" : macro.scriptPath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedIndex = idx
            onSelect(macro)
        }
        .id(macro.id)
    }
}

/// Full-window dimming overlay that hosts `MacroPickerView`. Clicking the dimmed
/// background cancels the picker (same as Esc). Used by `MainView` when the
/// `Cmd+M` action hotkey fires.
struct MacroPickerOverlay: View {
    let macros: [MacroScript]
    let onSelect: (MacroScript) -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
            MacroPickerView(
                macros: macros,
                onSelect: onSelect,
                onCancel: onCancel
            )
        }
    }
}
