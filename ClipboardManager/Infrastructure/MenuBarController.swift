import AppKit

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    let settings: AppSettings
    var onShow: () -> Void = {}
    var onSearch: () -> Void = {}
    var onSettings: () -> Void = {}
    var onClearHistory: () -> Void = {}
    var onQuit: () -> Void = {}

    private var statusItem: NSStatusItem?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func install() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let item = statusItem, let button = item.button else { return }
        let image = makeMenuBarIcon()
        image.accessibilityDescription = "ClipboardManager"
        button.image = image
        button.toolTip = "ClipboardManager"
        button.action = #selector(handleClick(_:))
        button.target = self
        // Include `.otherMouseUp` so middle-click / trackpad two-finger click on some
        // configurations are received, and Control-click (which reports as leftMouseUp
        // with .control modifier) is handled in `handleClick`.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
    }

    /// メニューバー用のテンプレートアイコンを生成する。
    /// アプリアイコン（Assets.xcassets/AppIcon）と同じモチーフ
    /// （クリップボード＋クリップ＋3本の水平線）を単色シルエットで表現し、
    /// メニューバーのライト/ダーク両モードで自動的に色が切り替わるようにする。
    private func makeMenuBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setFill()

        let boardRect = NSRect(x: 3.5, y: 2.5, width: 11, height: 13)
        let boardPath = NSBezierPath(roundedRect: boardRect, xRadius: 1.5, yRadius: 1.5)
        boardPath.lineWidth = 1.2
        boardPath.stroke()

        let clipRect = NSRect(x: 7, y: 14, width: 4, height: 2.5)
        let clipPath = NSBezierPath(roundedRect: clipRect, xRadius: 1, yRadius: 1)
        clipPath.lineWidth = 1.0
        clipPath.stroke()

        for index in 0..<3 {
            let lineRect = NSRect(x: 5.5, y: 10 - CGFloat(index) * 2.5, width: 7, height: 1.0)
            lineRect.fill()
        }

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Treat right-click, option-click, control-click (Ctrl+Click on trackpad), and
        // other-mouse-up (middle-click on some devices) as the context-menu path.
        // Relying on `.rightMouseUp` alone is fragile because trackpad two-finger clicks
        // and Control-clicks may arrive as `.leftMouseUp` with modifier flags instead.
        let isRightClick = (event?.type == .rightMouseUp)
            || (event?.type == .otherMouseUp)
            || (event?.modifierFlags.contains(.option) ?? false)
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            // Right-click / option-click → context menu (standard pattern for clipboard managers).
            let menu = buildMenu()
            statusItem?.menu = menu
            menu.delegate = self
            statusItem?.button?.performClick(nil)
            return
        }
        // Left-click → show history panel immediately (most frequent action; matches Maccy/Paste/Raycast).
        onShow()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(buildItem("Show Clipboard History", action: #selector(show), key: "\r", mods: [.command]))
        menu.addItem(buildItem("Search…", action: #selector(search), key: "f", mods: [.command]))
        menu.addItem(buildItem("Settings…", action: #selector(openSettings), key: ",", mods: [.command]))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildItem("Clear History…", action: #selector(clear), key: "\u{7F}", mods: [.command]))
        menu.addItem(NSMenuItem.separator())
        // About menu item (design-ui.md §8).
        let aboutItem = NSMenuItem(title: "About ClipboardManager", action: #selector(about), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(buildItem("Quit ClipboardManager", action: #selector(quit), key: "q", mods: [.command]))
        return menu
    }

    private func buildItem(_ title: String, action: Selector, key: String, mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = mods
        return item
    }

    @objc private func show() { onShow() }
    @objc private func search() { onSearch() }
    @objc private func openSettings() { onSettings() }
    @objc private func clear() { onClearHistory() }
    @objc private func quit() { onQuit() }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
}
