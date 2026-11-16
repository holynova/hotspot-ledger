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
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier?.hasSuffix(".preview") != true && !CommandLine.arguments.contains("--preview") {
            let directory = LedgerStore().directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            instanceLock = Darwin.open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            if instanceLock < 0 || flock(instanceLock, LOCK_EX | LOCK_NB) != 0 { NSApp.terminate(nil); return }
        }
        model = AppModel()
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "关于热点账本", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出热点账本", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let editItem = NSMenuItem(); editItem.title = "编辑"; let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c"); editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"); editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"); editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = model.preview ? "热点账本 界面预览" : "热点账本"; window.minSize = NSSize(width: 374, height: 562); window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        dashboard = WebDashboard(model: model)
        window.contentView = dashboard.view
        window.setFrame(NSRect(x: 0, y: 0, width: 374, height: 562), display: true)
        let drag = DragStrip(frame: NSRect(x: 65, y: 533, width: 265, height: 29))
        drag.autoresizingMask = [.width, .minYMargin]; dashboard.view.addSubview(drag)
        window.center()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "wifi", accessibilityDescription: "热点账本")
        status.button?.imagePosition = .imageLeading
        let tray = NSMenu()
        let open = NSMenuItem(title: "打开热点账本", action: #selector(showWindow), keyEquivalent: ""); open.target = self; tray.addItem(open)
        let toggle = NSMenuItem(title: "暂停 / 恢复记录", action: #selector(toggleRecording), keyEquivalent: ""); toggle.target = self; tray.addItem(toggle)
        tray.addItem(.separator()); tray.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = tray
        cancellable = model.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.status.button?.title = " " + (self.model.active.map { formatBytes($0.usage.total) } ?? "待机")
            self.status.button?.toolTip = "热点账本 · " + (self.model.network ?? "未连接 Wi-Fi")
        }
        showWindow()
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
