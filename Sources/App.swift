import AppKit
import SwiftUI
import Combine
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var status: NSStatusItem!
    var model: AppModel!
    var cancellable: AnyCancellable?
    var instanceLock: Int32 = -1
    var dashboard: WebDashboard!
    var languageObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier?.hasSuffix(".preview") != true && !CommandLine.arguments.contains("--preview") {
            let directory = LedgerStore().directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLock = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { NSApp.terminate(nil); return }
        }
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        model = AppModel()
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "关于热点账本", action: #selector(showAbout), keyEquivalent: "")
        appMenu.items.first?.target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出热点账本", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(); editItem.title = "编辑"; let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = model.preview ? "热点账本 界面预览" : "热点账本"; window.minSize = NSSize(width: 384, height: 614); window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        dashboard = WebDashboard(model: model)
        let menuBackground = NSVisualEffectView()
        menuBackground.material = .menu
        menuBackground.blendingMode = .behindWindow
        menuBackground.state = .followsWindowActiveState
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = menuBackground
        dashboard.view.frame = menuBackground.bounds
        dashboard.view.autoresizingMask = [.width, .height]
        menuBackground.addSubview(dashboard.view)
        window.setFrame(NSRect(x: 0, y: 0, width: 384, height: 614), display: true)
        // WKWebView uses flipped coordinates; anchor the drag strip to the visual top.
        // A numeric y offset can otherwise intercept the footer's mouse events.
        let drag = DragStrip(frame: .zero)
        drag.translatesAutoresizingMaskIntoConstraints = false
        dashboard.view.addSubview(drag)
        NSLayoutConstraint.activate([
            drag.topAnchor.constraint(equalTo: dashboard.view.topAnchor),
            drag.leadingAnchor.constraint(equalTo: dashboard.view.leadingAnchor, constant: 65),
            drag.trailingAnchor.constraint(equalTo: dashboard.view.trailingAnchor, constant: -54),
            drag.heightAnchor.constraint(equalToConstant: 24)
        ])
        window.center()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = makeStatusIcon()
        status.button?.imagePosition = .imageLeading
        let tray = NSMenu()
        let open = NSMenuItem(title: "打开热点账本", action: #selector(showWindow), keyEquivalent: ""); open.target = self; tray.addItem(open)
        let toggle = NSMenuItem(title: "暂停 / 恢复记录", action: #selector(toggleRecording), keyEquivalent: ""); toggle.target = self; tray.addItem(toggle)
        tray.addItem(.separator()); tray.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = tray
        cancellable = model.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.status.button?.title = " " + (self.model.active.map { formatBytes($0.usage.total) } ?? L10n.text("待机"))
            self.status.button?.toolTip = L10n.text("热点账本") + " — " + (self.model.network ?? "未连接 Wi-Fi")
        }
        refreshLanguage()
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.refreshLanguage() }
        showWindow()
    }
    private func refreshLanguage() {
        window.title = L10n.text("热点账本")
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        appMenu?.items.first?.title = L10n.text("关于热点账本")
        appMenu?.items.last?.title = L10n.text("退出热点账本")
        if let edit = NSApp.mainMenu?.items.dropFirst().first {
            edit.title = L10n.text("编辑")
            for (item, title) in zip(edit.submenu?.items ?? [], ["复制", "粘贴", "全选"]) { item.title = L10n.text(title) }
        }
        if let items = status.menu?.items, items.count >= 4 {
            items[0].title = L10n.text("打开热点账本")
            items[1].title = L10n.text("暂停 / 恢复记录")
            items[3].title = L10n.text("退出")
        }
        status.button?.image?.accessibilityDescription = L10n.text("热点账本")
    }
    // Original histogram mark, deliberately unlike the system Wi-Fi glyph.
    // Template rendering supplies the correct menu-bar tint in either appearance.
    private func makeStatusIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (x, height): (CGFloat, CGFloat) in [(2, 10), (7.5, 5), (13, 12)] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 4, width: 3, height: height),
                             xRadius: 1, yRadius: 1).fill()
            }
            NSBezierPath(roundedRect: NSRect(x: 2, y: 1, width: 14, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "热点账本流量统计"
        return image
    }
    @objc func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let icon = NSImage(contentsOfFile: Bundle.main.bundlePath + "/Contents/Resources/AppIcon.icns") { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggleRecording() { model.toggle() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
@main enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate(); app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
