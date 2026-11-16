import AppKit
import WebKit
import Combine

final class DragStrip: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class WebDashboard: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let model: AppModel
    let view: WKWebView
    var subscription: AnyCancellable?
    var ready = false
    var iconCache: [String: String] = [:]
    var previous: [String: Usage] = [:]
    var rates: [String: Double] = [:]
    var previousDate: Date?
    var previousSession: String?
    init(model: AppModel) {
        self.model = model
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(self, name: "ledger")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        let file = Bundle.main.url(forResource: "dashboard", withExtension: "html")!
        view.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        subscription = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.publish() }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true; publish() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
    func icon(_ row: ProcessUsage) -> String {
        var path = row.executable
        if let r = path.range(of: ".app/") { path = String(path[..<r.lowerBound])+".app" }
        if row.proxy { path = "/Applications/Clash Verge.app" }
        if row.name == "其他进程" { path = "/System/Applications/Utilities/Activity Monitor.app" }
        if !path.hasSuffix(".app") { path = "/System/Applications/Utilities/Terminal.app" }
        if let cached = iconCache[path] { return cached }
        var image = NSWorkspace.shared.icon(forFile: path)
        if let bundle = Bundle(path: path), let name = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String {
            let resource = name.hasSuffix(".icns") ? String(name.dropLast(5)) : name
            if let file = bundle.path(forResource: resource, ofType: "icns"), let original = NSImage(contentsOfFile: file) { image = original }
        }
        let small = NSImage(size: NSSize(width: 96, height: 96))
        small.lockFocus(); image.draw(in: NSRect(x: 0, y: 0, width: 96, height: 96)); small.unlockFocus()
        let png = small.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) } ?? Data()
        let result = "data:image/png;base64,"+png.base64EncodedString(); iconCache[path] = result; return result
    }
    func rows(_ values: [String: ProcessUsage], kind: String) -> [[String: Any]] {
        groupedProcesses(Array(values.values)).map { row in
            let count = values.values.filter { processGroupKey($0) == row.id }.count
            return ["id": row.id, "name": row.name, "pid": Int(row.pid), "path": row.executable,
                    "down": row.usage.down, "up": row.usage.up, "icon": icon(row), "proxy": row.proxy,
                    "sub": model.preview && row.name == "node" ? "wrangler deploy" : row.proxy ? "代理转发" : count > 1 ? "\(count) 个进程" : "进程 \(row.pid)",
                    "rate": rates[kind+row.id] ?? 0]
        }
    }
    func publish() {
        guard ready else { return }
        let selected = model.selected
        let date = model.lastSample
        if date != previousDate || selected?.id != previousSession {
            var next: [String: Usage] = [:]
            for (kind, data) in [("apps", selected?.activityApps ?? [:]), ("outlet", selected?.wifiApps ?? [:])] {
                for row in groupedProcesses(Array(data.values)) { next[kind+row.id] = row.usage }
            }
            let dt = date?.timeIntervalSince(previousDate ?? date ?? Date()) ?? 0
            rates = [:]
            if selected?.id == model.active?.id && selected?.id == previousSession && dt > 0 && dt < 15 {
                for (key, value) in next { if let old = previous[key] { rates[key] = Double(value.delta(from: old).total)/dt } }
            }
            previous = next; previousDate = date; previousSession = selected?.id
        }
        let usage = selected?.usage ?? Usage()
        let payload: [String: Any] = [
            "network": model.network ?? "", "recording": model.active != nil, "enabled": model.preferences.enabled,
            "marked": model.network.map { model.preferences.networks.contains($0) } ?? false,
            "preview": model.preview, "wifiOff": model.wifiIsOff, "busy": model.disconnectBusy,
            "current": selected?.id == model.active?.id && model.active != nil,
            "selectedID": model.selectedID ?? "", "down": usage.down, "up": usage.up,
            "unobservedSeconds": selected?.unobservedSeconds ?? 0, "resumeCount": selected?.resumeCount ?? 0,
            "started": (selected?.started.timeIntervalSince1970 ?? 0)*1000,
            "ended": (selected?.ended?.timeIntervalSince1970 ?? selected?.lastSample.timeIntervalSince1970 ?? 0)*1000,
            "issue": model.storageIssue ?? model.issue ?? "", "alert": model.alert ?? "", "connection": model.connectionMessage ?? "",
            "details": model.details, "notice": model.notificationStatus,
            "theme": UserDefaults.standard.string(forKey: "appearance") ?? "light",
            "apps": rows(selected?.activityApps ?? [:], kind: "apps"), "outlet": rows(selected?.wifiApps ?? [:], kind: "outlet"),
            "points": (selected?.points ?? []).map { ["date": $0.date.timeIntervalSince1970*1000, "down": $0.down, "up": $0.up] },
            "preferences": ["networks": model.preferences.networks, "limit": model.preferences.limitMB, "burst": model.preferences.burstMB, "automatic": model.preferences.autoDisconnect == true, "disconnect": model.preferences.disconnectMB ?? 1000] as [String: Any],
            "history": model.sessions.reversed().map { ["id": $0.id, "network": $0.network, "date": $0.started.timeIntervalSince1970*1000, "total": $0.usage.total, "reason": $0.endReason ?? "记录中"] as [String: Any] }
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: encoded, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.receive(\(json))") { _, error in
            if let error { print("UI ERROR: \(error)") }

        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "toggle": model.toggle()
        case "mark": model.markCurrent()
        case "disconnect": model.disconnectCurrent()
        case "enable": model.enableWiFi()
        case "dismissAlert": model.alert = nil
        case "notify": model.requestNotifications()
        case "theme":
            if let theme = body["value"] as? String, ["light", "dark"].contains(theme) { UserDefaults.standard.set(theme, forKey: "appearance") }
        case "select": model.selectedID = (body["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        case "inspect":
            let source = body["scope"] as? String == "outlet" ? model.selected?.wifiApps : model.selected?.activityApps
            if let row = groupedProcesses(Array((source ?? [:]).values)).first(where: { $0.id == body["id"] as? String }) { model.inspect(row) }
        case "save":
            guard let networks = body["networks"] as? [String], networks.count <= 100,
                  let limit = body["limit"] as? Int64, let burst = body["burst"] as? Int64,
                  let disconnect = body["disconnect"] as? Int64, let automatic = body["automatic"] as? Bool,
                  (0...1_000_000).contains(limit), (0...1_000_000).contains(burst), (1...1_000_000).contains(disconnect) else { return }
            model.preferences.networks = networks; model.preferences.limitMB = limit; model.preferences.burstMB = burst
            model.preferences.disconnectMB = disconnect; model.preferences.autoDisconnect = automatic; model.updatePreferences()
        case "data": if !model.preview { NSWorkspace.shared.open(model.store.directory) }
        case "close": view.window?.close()
        case "minimize": view.window?.miniaturize(nil)
        case "zoom": view.window?.zoom(nil)
        default: break
        }
        DispatchQueue.main.async { self.publish() }
    }
}
