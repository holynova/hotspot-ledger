import Foundation

struct Usage: Codable, Equatable {
    var down: Int64 = 0
    var up: Int64 = 0
    var total: Int64 { down + up }
    static func + (a: Usage, b: Usage) -> Usage { Usage(down: a.down + b.down, up: a.up + b.up) }
    // A decreasing counter is a reset/closed-flow discontinuity, not negative usage.
    func delta(from old: Usage) -> Usage {
        Usage(down: down >= old.down ? down - old.down : 0,
              up: up >= old.up ? up - old.up : 0)
    }
}
struct ProcessAncestor: Codable, Equatable {
    var pid: Int32
    var name: String
    var executable: String
}
struct ProcessOrigin: Codable, Equatable {
    var capturedAt: Date
    var workingDirectory: String?
    var repository: String?
    var remote: String?
    var operation: String?
    var ancestors: [ProcessAncestor]
    var transferRemote: String? = nil
}
// Only retain the host and repository path. Credentials, query tokens and fragments never persist.
func sanitizedRemote(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.contains("://"), let url = URLComponents(string: value),
       ["http", "https", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""), let host = url.host {
        let path = url.percentEncodedPath
        guard !host.isEmpty, !path.isEmpty else { return nil }
        return host + path
    }
    if let colon = value.firstIndex(of: ":"), !value.hasPrefix("/"), !value.contains(" ") {
        let host = value[..<colon].split(separator: "@").last.map(String.init) ?? ""
        let path = value[value.index(after: colon)...].split(whereSeparator: { $0 == "?" || $0 == "#" }).first.map(String.init) ?? ""
        if !host.isEmpty && !path.isEmpty { return host + "/" + path }
    }
    return nil
}
struct ProcessUsage: Codable, Identifiable {
    var id: String
    var name: String
    var pid: Int32
    var executable: String
    var usage: Usage
    var startedAt: String? = nil
    var origin: ProcessOrigin? = nil
    var proxy: Bool {
        let n = (name + " " + executable).lowercased()
        return ["mihomo", "clash", "surge", "sing-box"].contains { n.contains($0) }
    }
}
struct RatePoint: Codable, Identifiable {
    var date: Date
    var down: Double
    var up: Double
    var id: Date { date }
}
struct Session: Codable, Identifiable {
    var id = UUID().uuidString
    var network: String
    var interface: String
    var started: Date
    var lastSample: Date
    var ended: Date?
    var endReason: String?
    var usage = Usage()
    var wifiApps: [String: ProcessUsage] = [:]
    var activityApps: [String: ProcessUsage] = [:]
    var sampleCount = 0
    var incompleteSamples = 0
    var cumulativeAlerted = false
    var disconnectAttempted: Bool? = false
    // Attribute an interval to the local calendar day of its closing sample.
    static func dayKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    var daily: [String: Usage]?
    var recordedDays: [String: Usage] {
        if let daily { return daily }
        let day = Self.dayKey(started)
        return day == Self.dayKey(lastSample) ? [day: usage] : [:]
    }
    var points: [RatePoint]? = []
    var unobservedSeconds: Double? = 0
    var resumeCount: Int? = 0
}
struct Preferences: Codable {
    var networks: [String] = []
    var enabled = true
    var limitMB: Int64 = 500
    var burstMB: Int64 = 100
    var autoDisconnect: Bool? = false
    var disconnectMB: Int64? = 1000
}
struct Ledger: Codable {
    var version = 1
    var preferences = Preferences()
    var sessions: [Session] = []
}
struct Sample {
    var date: Date
    var network: String?
    var interface: String
    var counts: Usage?
    var wifi: [String: ProcessUsage]?
    var activity: [String: ProcessUsage]?
    var issue: String?
}
struct AlertEvent {
    var title: String
    var message: String
}

enum Parse {
    static func nettop(_ text: String) -> [String: ProcessUsage]? {
        guard text.contains("bytes_in,bytes_out") else { return nil }
        var out: [String: ProcessUsage] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = Int32(cols[0][cols[0].index(after: dot)...]),
                  let down = Int64(cols[1]), let up = Int64(cols[2]), down >= 0, up >= 0 else { continue }
            let name = String(cols[0][..<dot])
            let key = String(cols[0])
            out[key] = ProcessUsage(id: key, name: name.isEmpty ? "进程 \(pid)" : name,
                                    pid: pid, executable: "", usage: Usage(down: down, up: up))
        }
        return out
    }
    static func interfaceCounts(_ text: String, interface: String) -> Usage? {
        let lines = text.split(separator: "\n")
        guard let header = lines.first?.split(whereSeparator: { $0.isWhitespace }),
              let di = header.firstIndex(of: "Ibytes"), let ui = header.firstIndex(of: "Obytes") else { return nil }
        for line in lines.dropFirst() {
            let c = line.split(whereSeparator: { $0.isWhitespace })
            guard c.count > max(di, ui), c[0] == interface, c[2].hasPrefix("<Link#"),
                  let down = Int64(c[di]), let up = Int64(c[ui]) else { continue }
            return Usage(down: down, up: up)
        }
        return nil
    }
    static func wifiName(_ text: String) -> String? {
        let prefix = "Current Wi-Fi Network: "
        guard let range = text.range(of: prefix) else { return nil }
        let name = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.lowercased().contains("redacted") else { return nil }
        return name
    }
    static func wifiDevice(_ text: String) -> String? {
        var wifi = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { wifi = line.contains("Wi-Fi") || line.contains("AirPort") }
            if wifi && line.hasPrefix("Device: ") { return String(line.dropFirst(8)) }
        }
        return nil
    }
}

final class LedgerEngine {
    var ledger: Ledger
    private(set) var previous: Sample?
    private var window: [(Date, Usage)] = []
    private var lastBurst: Date = .distantPast
    private var resumableID: String?
    init(ledger: Ledger = Ledger()) {
        self.ledger = ledger
        if let last = ledger.sessions.last, last.ended == nil || ["已退出程序", "程序退出或采集中断"].contains(last.endReason ?? "") {
            resumableID = last.id
        }
        for i in self.ledger.sessions.indices where self.ledger.sessions[i].ended == nil {
            self.ledger.sessions[i].ended = self.ledger.sessions[i].lastSample
            self.ledger.sessions[i].endReason = "程序退出或采集中断"
        }
    }
    var active: Session? { ledger.sessions.last.flatMap { $0.ended == nil ? $0 : nil } }
    func close(_ reason: String) {
        if let i = ledger.sessions.indices.last, ledger.sessions[i].ended == nil {
            ledger.sessions[i].ended = ledger.sessions[i].lastSample
            ledger.sessions[i].endReason = reason
        }
        previous = nil; window = []; resumableID = nil
    }
    // One attempt per session; never retry disruptive operations in a timer loop.
    func takeDisconnectRequest() -> (network: String, interface: String)? {
        guard ledger.preferences.autoDisconnect == true,
              let limit = ledger.preferences.disconnectMB, limit > 0, limit <= 1_000_000,
              let session = active, session.disconnectAttempted != true,
              session.usage.total >= limit * 1_000_000 else { return nil }
        ledger.sessions[ledger.sessions.count - 1].disconnectAttempted = true
        return (session.network, session.interface)
    }
    private func add(_ current: [String: ProcessUsage]?, _ old: [String: ProcessUsage]?, to totals: inout [String: ProcessUsage]) {
        guard let current, let old else { return }
        for (id, value) in current {
            // Newly observed processes start at a baseline; never import lifetime counters.
            guard let prior = old[id], prior.executable == value.executable, prior.startedAt == value.startedAt else { continue }
            let increment = value.usage.delta(from: prior.usage)
            guard increment.total > 0 else { continue }
            // New origin segments never retroactively assign earlier unknown bytes.
            let signature = originKey(value.origin)
            let recordID = value.startedAt.map { id + "@" + $0 + "#" + signature } ?? id
            var record = totals[recordID] ?? ProcessUsage(id: recordID, name: value.name, pid: value.pid, executable: value.executable, usage: Usage(), startedAt: value.startedAt, origin: value.origin)
            record.usage = record.usage + increment
            totals[recordID] = record
        }
    }
    @discardableResult func ingest(_ sample: Sample) -> [AlertEvent] {
        guard ledger.preferences.enabled, let network = sample.network,
              ledger.preferences.networks.contains(network), sample.counts != nil else {
            close(sample.issue ?? "已离开计费网络或暂停记录"); return []
        }
        // Resume only the most recent interrupted record after a fresh network check.
        // SSID matching is a logical continuation, not proof of continuous association.
        if let candidate = resumableID {
            resumableID = nil
            if let i = ledger.sessions.indices.last, ledger.sessions[i].id == candidate,
               ledger.sessions[i].network == network, ledger.sessions[i].interface == sample.interface,
               sample.date >= ledger.sessions[i].lastSample {
                ledger.sessions[i].unobservedSeconds = (ledger.sessions[i].unobservedSeconds ?? 0) + sample.date.timeIntervalSince(ledger.sessions[i].lastSample)
                ledger.sessions[i].resumeCount = (ledger.sessions[i].resumeCount ?? 0) + 1
                ledger.sessions[i].ended = nil; ledger.sessions[i].endReason = nil
                ledger.sessions[i].daily = ledger.sessions[i].recordedDays
                ledger.sessions[i].lastSample = sample.date
                // Keep totals and attribution; restart rates without bridging the unobserved gap.
                ledger.sessions[i].points = []
                previous = nil; window = []
            }
        }
        if let current = active,
           current.network != network || current.interface != sample.interface || sample.date.timeIntervalSince(current.lastSample) > 15 {
            close("网络切换、睡眠或采样中断")
        }
        if active == nil {
            ledger.sessions.append(Session(network: network, interface: sample.interface, started: sample.date, lastSample: sample.date))
        }
        let i = ledger.sessions.count - 1
        var alerts: [AlertEvent] = []
        if let prior = previous, let before = prior.counts, let after = sample.counts {
            let delta = after.delta(from: before)
            var days = ledger.sessions[i].recordedDays
            let day = Session.dayKey(sample.date)
            days[day] = (days[day] ?? Usage()) + delta
            ledger.sessions[i].daily = days
            ledger.sessions[i].usage = ledger.sessions[i].usage + delta
            add(sample.wifi, prior.wifi, to: &ledger.sessions[i].wifiApps)
            add(sample.activity, prior.activity, to: &ledger.sessions[i].activityApps)
            let dt = max(0.1, sample.date.timeIntervalSince(prior.date))
            var points = ledger.sessions[i].points ?? []
            points.append(RatePoint(date: sample.date, down: Double(delta.down) / dt, up: Double(delta.up) / dt))
            if points.count > 450 { points.removeFirst(points.count - 450) }
            ledger.sessions[i].points = points
            window.append((sample.date, delta))
            window.removeAll { sample.date.timeIntervalSince($0.0) > 60 }
            let recent = window.reduce(Usage()) { $0 + $1.1 }
            let limit = ledger.preferences.limitMB * 1_000_000
            if limit > 0 && ledger.sessions[i].usage.total >= limit && !ledger.sessions[i].cumulativeAlerted {
                ledger.sessions[i].cumulativeAlerted = true
                alerts.append(AlertEvent(title: "热点用量提醒", message: L10n.choose("\(network)：本次已用 \(formatBytes(ledger.sessions[i].usage.total))", "\(network): \(formatBytes(ledger.sessions[i].usage.total)) used this session")))
            }
            if ledger.preferences.burstMB > 0 && recent.total >= ledger.preferences.burstMB * 1_000_000 && sample.date.timeIntervalSince(lastBurst) > 60 {
                lastBurst = sample.date
                alerts.append(AlertEvent(title: "短时间大量传输", message: L10n.choose("最近最多 60 秒已传输 \(formatBytes(recent.total))，请检查进程排行。", "\(formatBytes(recent.total)) transferred in the last 60 seconds or less. Check app activity.")))
            }
        }
        ledger.sessions[i].lastSample = sample.date
        ledger.sessions[i].sampleCount += 1
        if sample.wifi == nil || sample.activity == nil { ledger.sessions[i].incompleteSamples += 1 }
        previous = sample
        return alerts
    }
}
func formatBytes(_ bytes: Int64) -> String {
    if bytes >= 1_000_000_000 { return String(format: "%.2f GB", Double(bytes) / 1e9) }
    if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1e6) }
    if bytes >= 1_000 { return String(format: "%.1f KB", Double(bytes) / 1e3) }
    return "\(bytes) B"
}

func processGroupKey(_ row: ProcessUsage) -> String {
    if let range = row.executable.range(of: ".app/") { return String(row.executable[..<range.lowerBound])+".app" }
    return row.executable.isEmpty ? row.id : row.executable
}
func groupedProcesses(_ rows: [ProcessUsage]) -> [ProcessUsage] {
    Dictionary(grouping: rows, by: processGroupKey).map { key, values in
        var row = values.max { $0.usage.total < $1.usage.total }!
        row.id = key; row.usage = values.reduce(Usage()) { $0 + $1.usage }; return row
    }.sorted { $0.usage.total > $1.usage.total }
}

func originKey(_ origin: ProcessOrigin?) -> String {
    guard let o = origin else { return "unknown" }
    // JSON encoding avoids delimiter collisions in paths without retaining command lines.
    return (try? JSONEncoder().encode([o.workingDirectory ?? "", o.repository ?? "", o.remote ?? "", o.transferRemote ?? "", o.operation ?? "", o.ancestors.map { $0.executable }.joined(separator: "\n")]).base64EncodedString()) ?? "unknown"
}
