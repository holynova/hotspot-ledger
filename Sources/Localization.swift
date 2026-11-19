import Foundation

enum L10n {
    static var language: String {
        if let saved = UserDefaults.standard.string(forKey: "language"), ["zh", "en"].contains(saved) { return saved }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh" : "en"
    }
    static func choose(_ zh: String, _ en: String) -> String { language == "en" ? en : zh }
    static let changed = Notification.Name("LedgerLanguageChanged")
    static func set(_ value: String) {
        guard ["zh", "en"].contains(value) else { return }
        UserDefaults.standard.set(value, forKey: "language")
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func text(_ value: String) -> String {
        guard language == "en" else { return value }
        if let result = english[value] { return result }
        for (zh, en) in prefixes where value.hasPrefix(zh) { return en + String(value.dropFirst(zh.count)) }
        return value
    }
    private static let prefixes = [
        ("记录保存失败：", "Could not save records: "), ("无法关闭 Wi-Fi：", "Could not turn off Wi-Fi: "),
        ("无法开启 Wi-Fi：", "Could not turn on Wi-Fi: ")
    ]
    private static let english: [String: String] = [
        "热点账本":"Hotspot Ledger", "关于热点账本":"About Hotspot Ledger", "退出热点账本":"Quit Hotspot Ledger",
        "编辑":"Edit", "复制":"Copy", "粘贴":"Paste", "全选":"Select All", "打开热点账本":"Open Hotspot Ledger",
        "暂停 / 恢复记录":"Pause / Resume Recording", "退出":"Quit", "待机":"Idle",
        "系统通知未启用；窗口内提醒始终可用":"System notifications are off. In-app alerts remain available.",
        "系统通知已启用":"System notifications are on.", "系统通知未获授权；请在系统设置中开启":"Allow notifications in System Settings.",
        "历史文件无法读取，已停止写入以保护原文件。请打开数据目录检查。":"Cannot read the history file. Saving is paused to protect it. Check the data folder.",
        "无法读取 Wi-Fi 名称；请检查 Wi-Fi 连接及定位权限。":"Cannot read the Wi-Fi name. Check the connection and Location Services permission.",
        "采样期间网络切换，已重新建立基线。":"The network changed during sampling. A new baseline was created.",
        "接口计数不可用，本段未计入。":"Interface counters are unavailable. This interval was not counted.",
        "进程采样失败；接口总量仍在记录。":"Process sampling failed. Interface totals are still being recorded.",
        "正在关闭 Wi-Fi…":"Turning off Wi-Fi…", "正在开启 Wi-Fi…":"Turning on Wi-Fi…",
        "网络已改变，未关闭 Wi-Fi。":"The network changed. Wi-Fi was not turned off.",
        "Wi-Fi 未关闭，请在系统设置中检查。":"Wi-Fi is still on. Check System Settings.",
        "未找到 Wi-Fi 接口。":"Wi-Fi interface not found.",
        "达到用量阈值，Wi-Fi 已关闭。":"The usage limit was reached. Wi-Fi is off.",
        "Wi-Fi 已关闭。":"Wi-Fi is off.", "Wi-Fi 已关闭":"Wi-Fi is off",
        "本次用量达到断连阈值。可以在热点账本中重新开启 Wi-Fi。":"The session reached its cutoff limit. You can turn Wi-Fi back on in Hotspot Ledger.",
        "Wi-Fi 已开启，等待连接。":"Wi-Fi is on. Waiting for a connection.",
        "Wi-Fi 未开启，请检查系统设置。":"Wi-Fi is still off. Check System Settings.",
        "预览模式不请求系统权限":"Preview mode does not request system permissions.",
        "界面预览，不读取实际进程。":"Preview mode does not inspect real processes.",
        "正在读取进程信息…":"Reading process information…",
        "进程已退出或身份已变化。":"The process has exited or its identity has changed.",
        "热点用量提醒":"Hotspot usage alert", "短时间大量传输":"High short-term usage"
    ]
}
