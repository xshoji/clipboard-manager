import SwiftUI

struct HeaderBar: View {
    @Bindable private var settings = AppSettings.shared
    @Binding var sidebarVisible: Bool
    let onShowSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 4) {
                sidebarButton
                Spacer().frame(width: 12)
                pinButton
                Spacer()
                settingsButton
                Spacer().frame(width: 12)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(height: 44)
            .background(Color.appBackground.opacity(0.95))
        }
        .frame(height: 44)
    }

    private var sidebarButton: some View {
        HeaderBarButton(
            isActive: false,
            action: {
                sidebarVisible.toggle()
                settings.isSidebarVisible = sidebarVisible
            },
            label: { Image(systemName: "sidebar.left") },
            helpText: "Toggle sidebar"
        )
    }

    private var settingsButton: some View {
        HeaderBarButton(
            isActive: false,
            action: onShowSettings,
            label: { Image(systemName: "gear") },
            helpText: "Settings"
        )
    }

    private var pinButton: some View {
        HeaderBarButton(
            isActive: settings.isAlwaysOnTop,
            action: {
                settings.isAlwaysOnTop.toggle()
                NotificationCenter.default.post(name: .alwaysOnTopChanged, object: nil)
            },
            label: {
                Image(systemName: settings.isAlwaysOnTop ? "pin.fill" : "pin")
            },
            helpText: settings.isAlwaysOnTop ? "Always on top (pinned)" : "Always on top"
        )
    }
}

// MARK: - Reusable Button Style

/// ヘッダーバー用の軽快なボタン。
/// - active 時は accentColor に即座に切り替わる。
/// - タップ時に素早い scale / opacity フィードバックを返す。
private struct HeaderBarButton<Label: View>: View {
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    let helpText: String

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(isActive ? Color.accentColor : .primary)
                .opacity(isPressed ? 0.55 : 1.0)
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.easeOut(duration: 0.08), value: isPressed)
                .animation(.easeInOut(duration: 0.10), value: isActive)
        }
        .help(helpText)
        .buttonStyle(.borderless)
        .pressDetector { pressed in
            isPressed = pressed
        }
    }
}

// MARK: - Press Gesture Helper

private struct PressDetectorModifier: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onChange(true) }
                    .onEnded { _ in onChange(false) }
            )
    }
}

private extension View {
    func pressDetector(onChange: @escaping (Bool) -> Void) -> some View {
        modifier(PressDetectorModifier(onChange: onChange))
    }
}
