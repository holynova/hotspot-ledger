import Foundation
import AppKit
import Combine
import Network
import UserNotifications
import CoreWLAN

final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var sessions: [Session] = []
    @Published var preferences = Preferences()
    @Published var network: String?
    @Published var interface = ""
    @Published var issue: String?
    @Published var alert: String?
    @Published var rate = Usage()
    @Published var selectedID: String?
    @Published var details = ""
    @Published var notificationStatus = "系统通知未启用；窗口内提醒始终可用"
    @Published var storageIssue: String?
    @Published var lastSample: Date?
    @Published var disconnectBusy = false
    @Published var wifiIsOff = false
    @Published var connectionMessage: String?
    let preview = (CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true)
    let store: LedgerStore
    let engine: LedgerEngine
    private let collector = DispatchQueue(label: "cc.xiaosang.hotspot-ledger.sampler", qos: .utility)
    private var sampler: Sampler?
    private var busy = false
    private var timer: Timer?
    private var generation = 0
    private var monitor: NWPathMonitor?
    private var lastNetworkPath: String?
    private var observerTokens: [NSObjectProtocol] = []
    private var writable = true
    var active: Session? { engine.active }
    var selected: Session? { sessions.first { $0.id == selectedID } ?? sessions.last }
    override init() {
        store = LedgerStore()
        do { engine = (CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier?.hasSuffix(".preview") == true) ? LedgerEngine() : LedgerEngine(ledger: try store.load()) }
        catch { engine = LedgerEngine(); writable = false }
        super.init()
        if !writable { storageIssue = "历史文件无法读取，已停止写入以保护原文件。请打开数据目录检查。" }
        preferences = engine.ledger.preferences; sessions = engine.ledger.sessions
        if let i = CommandLine.arguments.firstIndex(of: "--network"), CommandLine.arguments.count > i + 1 {
            let name = CommandLine.arguments[i+1]
            if !preferences.networks.contains(name) { preferences.networks.append(name); engine.ledger.preferences = preferences }
        }
        if preview { makePreview(); return }
        UNUserNotificationCenter.current().delegate = self
        let workspace = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.boundary("电脑进入睡眠") })
        observerTokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.boundary("电脑唤醒"); self?.tick() })
        let path = NWPathMonitor(); monitor = path
        path.pathUpdateHandler = { [weak self] value in
            let key = "\(value.status):" + value.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
            DispatchQueue.main.async {
                guard let self else { return }
                if let old = self.lastNetworkPath, old != key { self.boundary("网络路径改变") }
                self.lastNetworkPath = key; self.tick()
            }
        }
        path.start(queue: collector)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            DispatchQueue.main.async { if s.authorizationStatus == .authorized { self?.notificationStatus = "系统通知已启用" } }
        }
    }
    func tick() {
        guard !preview, !busy, !disconnectBusy else { return }; busy = true
        let networks = preferences.networks, enabled = preferences.enabled, token = generation
        collector.async { [weak self] in
            guard let self else { return }
            if self.sampler == nil { self.sampler = Sampler() }
            let result = self.sampler!.take(networks: networks, enabled: enabled)
            let poweredOff = CWWiFiClient.shared().interface(withName: result.interface)?.powerOn() == false
            DispatchQueue.main.async {
                self.busy = false
                guard self.generation == token else { return }
                let old = self.engine.previous
                let alerts = self.engine.ingest(result)
                self.network = result.network; self.interface = result.interface
                if self.wifiIsOff && !poweredOff { self.connectionMessage = nil }
                self.wifiIsOff = poweredOff
                self.issue = self.wifiIsOff ? nil : result.issue; self.lastSample = result.date
                if let old, old.network == result.network, let before = old.counts, let after = result.counts,
                   result.date.timeIntervalSince(old.date) < 15 {
                    let dt = max(1, result.date.timeIntervalSince(old.date)), delta = after.delta(from: before)
                    self.rate = Usage(down: Int64(Double(delta.down) / dt), up: Int64(Double(delta.up) / dt))
                } else { self.rate = Usage() }
                self.sync(); self.save()
                for event in alerts { self.deliver(event) }
                if let request = self.engine.takeDisconnectRequest() {
                    self.sync(); self.save()
                    self.disconnect(network: request.network, interface: request.interface, automatic: true)
                }
            }
        }
    }
    func boundary(_ reason: String) {
        generation += 1; engine.close(reason); rate = Usage(); sync(); save()
    }
    func updatePreferences() {
        preferences.networks = Array(Set(preferences.networks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        preferences.limitMB = min(1_000_000, max(0, preferences.limitMB))
        preferences.burstMB = min(1_000_000, max(0, preferences.burstMB))
        preferences.disconnectMB = min(1_000_000, max(1, preferences.disconnectMB ?? 1000))
        if preferences.networks != engine.ledger.preferences.networks || preferences.enabled != engine.ledger.preferences.enabled {
            boundary("记录设置改变")
        }
        engine.ledger.preferences = preferences; save(); tick()
    }
    func markCurrent() {
        guard let network, !preferences.networks.contains(network) else { return }
        preferences.networks.append(network); updatePreferences()
    }
    func toggle() { preferences.enabled.toggle(); updatePreferences() }
    func sync() { sessions = engine.ledger.sessions }
    func save() {
        guard writable, !preview else { return }
        do { try store.save(engine.ledger); storageIssue = nil }
        catch { storageIssue = "记录保存失败：\(error.localizedDescription)" }
    }
    func stop() { timer?.invalidate(); monitor?.cancel(); boundary("已退出程序") }
    func requestNotifications() {
        if preview { notificationStatus = "预览模式不请求系统权限"; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, error in
            DispatchQueue.main.async { self?.notificationStatus = allowed ? "系统通知已启用" : "系统通知未获授权；请在系统设置中开启" }
        }
    }
    private func deliver(_ event: AlertEvent) {
        alert = event.title + "：" + event.message
        guard !preview else { return }
        let content = UNMutableNotificationContent(); content.title = event.title; content.body = event.message; content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) { completionHandler([.banner, .sound]) }
    func inspect(_ row: ProcessUsage) {
        if preview { details = "界面预览，不读取实际进程。"; return }
        details = "正在读取进程信息…"
        collector.async { [weak self] in
            let text = Sampler.details(pid: row.pid, expectedPath: row.executable)
            DispatchQueue.main.async { self?.details = text }
        }
    }
    func disconnectCurrent() {
        guard let network, !interface.isEmpty else { return }
        disconnect(network: network, interface: interface, automatic: false)
    }
    private func disconnect(network expected: String, interface device: String, automatic: Bool) {
        guard !disconnectBusy else { return }
        disconnectBusy = true; connectionMessage = "正在关闭 Wi-Fi…"
        // Invalidate an in-flight sample so it cannot reopen a closed session.
        generation += 1
        if preview { finishDisconnect(error: nil, automatic: automatic); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var error: String?
            if let wifi = CWWiFiClient.shared().interface(withName: device) {
                let name = wifi.ssid() ?? Parse.wifiName(Shell.run("/usr/sbin/networksetup", ["-getairportnetwork", device]).text)
                if name != expected { error = "网络已改变，未关闭 Wi-Fi。" }
                else {
                    do {
                        try wifi.setPower(false)
                        if wifi.powerOn() { error = "Wi-Fi 未关闭，请在系统设置中检查。" }
                    } catch let failure { error = "无法关闭 Wi-Fi：" + failure.localizedDescription }
                }
            } else { error = "未找到 Wi-Fi 接口。" }
            DispatchQueue.main.async { self.finishDisconnect(error: error, automatic: automatic) }
        }
    }
    private func finishDisconnect(error: String?, automatic: Bool) {
        disconnectBusy = false
        if let error { connectionMessage = error; return }
        boundary(automatic ? "达到断连阈值" : "手动关闭 Wi-Fi")
        wifiIsOff = true; network = nil; issue = nil
        connectionMessage = automatic ? "达到用量阈值，Wi-Fi 已关闭。" : "Wi-Fi 已关闭。"
        if automatic { deliver(AlertEvent(title: "Wi-Fi 已关闭", message: "本次用量达到断连阈值。可以在热点账本中重新开启 Wi-Fi。")) }
    }
    func enableWiFi() {
        guard !disconnectBusy else { return }
        disconnectBusy = true; connectionMessage = "正在开启 Wi-Fi…"
        if preview { wifiIsOff = false; disconnectBusy = false; network = "桑苹果"; connectionMessage = "Wi-Fi 已开启，等待连接。"; return }
        let device = interface
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                guard let wifi = CWWiFiClient.shared().interface(withName: device) else { throw NSError(domain: "WiFi", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到 Wi-Fi 接口"]) }
                try wifi.setPower(true)
                if !wifi.powerOn() { failure = "Wi-Fi 未开启，请检查系统设置。" }
            } catch { failure = "无法开启 Wi-Fi：" + error.localizedDescription }
            DispatchQueue.main.async {
                self.disconnectBusy = false
                self.connectionMessage = failure ?? "Wi-Fi 已开启，等待连接。"
                if failure == nil { self.wifiIsOff = false; self.tick() }
            }
        }
    }
    private func makePreview() {
        let now = Date()
        var session = Session(network: "桑苹果", interface: "en0", started: now.addingTimeInterval(-1104), lastSample: now)
        session.usage = Usage(down: 50_200_000, up: 378_400_000)
        let fixtures: [(String, String, Int64, Int64)] = [
            ("node", "/usr/local/bin/node", 300_000, 365_800_000),
            ("Safari", "/Applications/Safari.app/Contents/MacOS/Safari", 29_000_000, 3_400_000),
            ("Telegram", "/Applications/Telegram.app/Contents/MacOS/Telegram", 10_200_000, 4_000_000),
            ("App Store", "/System/Applications/App Store.app/Contents/MacOS/App Store", 9_000_000, 600_000),
            ("其他进程", "/System/Applications/Utilities/Activity Monitor.app/Contents/MacOS/Activity Monitor", 1_700_000, 4_600_000)]
        for (i, f) in fixtures.enumerated() {
            let row = ProcessUsage(id: "preview-\(i)", name: f.0, pid: Int32(i + 100), executable: f.1, usage: Usage(down: f.2, up: f.3))
            session.activityApps[row.id] = row
        }
        session.wifiApps["proxy"] = ProcessUsage(id: "proxy", name: "Clash Verge", pid: 999, executable: "/Applications/Clash Verge.app/Contents/MacOS/Clash Verge", usage: Usage(down: 47_700_000, up: 377_000_000))
        let uploads: [Double] = [0.1,0.12,0.09,0.15,0.3,0.2,0.15,0.5,0.3,0.2,0.16,0.14,0.35,0.5,0.24,0.3,0.7,0.9,0.45,1.2,3.2,7.1,6.4,6.9,5.2,6.1,6.8,6.5,6.3,6.3]
        let downloads: [Double] = [0.05,0.07,0.1,0.05,0.2,0.1,0.4,0.3,0.2,0.09,0.15,0.2,0.3,0.25,0.6,0.15,0.08,0.1,0.15,0.1,0.25,0.15,0.3,0.2,0.12,0.15,0.08,0.18,0.12,0.12]
        session.points = (0..<60).map { i in
            let factor = i % 2 == 0 ? 1.07 : 0.92
            return RatePoint(date: now.addingTimeInterval(Double(i-59)*5), down: downloads[i/2]*factor*1e6, up: uploads[i/2]*factor*1e6)
        }

        if CommandLine.arguments.contains("--preview-long") {
            session.network = "旅行使用的个人热点 Personal Travel Hotspot"
            if let key = session.activityApps.keys.first { session.activityApps[key]?.name = "Google Chrome 网络辅助进程 Network Service Helper" }
        }
        engine.ledger.sessions = [session]; engine.ledger.preferences.networks = ["桑苹果"]
        preferences = engine.ledger.preferences; network = session.network; interface = "en0"; lastSample = now; rate = Usage(down: 120_000, up: 6_300_000); sync()
    }

}
