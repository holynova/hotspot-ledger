import Foundation
import AppKit
import CoreWLAN
import Darwin

struct CommandResult { let text: String; let status: Int32 }
enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 4) -> CommandResult {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var env = ProcessInfo.processInfo.environment; env["LC_ALL"] = "C"; env["LANG"] = "C"; process.environment = env
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(text: "", status: -1) }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); stop.cancel()
        return CommandResult(text: String(data: bytes, encoding: .utf8) ?? "", status: process.terminationStatus)
    }
}
final class Sampler {
    let interface: String
    private let provenance = ProvenanceCollector()
    init() {
        interface = Parse.wifiDevice(Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).text) ?? "en0"
    }
    func network() -> String? {
        if let ssid = CWWiFiClient.shared().interface(withName: interface)?.ssid(), !ssid.isEmpty, !ssid.lowercased().contains("redacted") { return ssid }
        return Parse.wifiName(Shell.run("/usr/sbin/networksetup", ["-getairportnetwork", interface]).text)
    }
    func processes(wifi: Bool) -> [String: ProcessUsage]? {
        var args = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        if wifi { args += ["-t", "wifi"] }
        let result = Shell.run("/usr/bin/nettop", args)
        guard result.status == 0, var data = Parse.nettop(result.text) else { return nil }
        for (key, item) in data {
            var buffer = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(item.pid, &buffer, UInt32(buffer.count))
            let path = n > 0 ? String(cString: buffer) : ""
            data[key]?.executable = path
            if let identity = ProvenanceCollector.identity(item.pid), identity.executable == path {
                data[key]?.startedAt = identity.started
                data[key]?.origin = provenance.capture(identity, at: Date())
            }
            if let appRange = path.range(of: ".app/Contents/") {
                let appPath = String(path[..<appRange.lowerBound]) + ".app"
                let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent
                data[key]?.name = appName
            } else if !path.isEmpty {
                data[key]?.name = URL(fileURLWithPath: path).lastPathComponent
            }
        }
        return data
    }
    func take(networks: [String], enabled: Bool) -> Sample {
        let name = network()
        guard enabled, let name, networks.contains(name) else {
            return Sample(date: Date(), network: name, interface: interface, counts: nil, wifi: nil, activity: nil,
                          issue: name == nil ? "无法读取 Wi-Fi 名称；请检查 Wi-Fi 连接及定位权限。" : nil)
        }
        let raw = Shell.run("/usr/sbin/netstat", ["-ibn", "-I", interface])
        let counts = raw.status == 0 ? Parse.interfaceCounts(raw.text, interface: interface) : nil
        let wifi = processes(wifi: true)
        let activity = processes(wifi: false)
        let finalName = network()
        guard finalName == name else {
            return Sample(date: Date(), network: finalName, interface: interface, counts: nil, wifi: nil, activity: nil, issue: "采样期间网络切换，已重新建立基线。")
        }
        return Sample(date: Date(), network: name, interface: interface, counts: counts, wifi: wifi, activity: activity,
                      issue: counts == nil ? "接口计数不可用，本段未计入。" : wifi == nil || activity == nil ? "进程采样失败；接口总量仍在记录。" : nil)
    }
    static func details(pid: Int32, expectedPath: String) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == expectedPath else { return "进程已退出或身份已变化。" }
        let cwd = Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]).text
            .split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) } ?? "无法读取"
        // Never persist complete command lines: they may contain credentials.
        let command = Shell.run("/bin/ps", ["-p", String(pid), "-o", "command="]).text
        let role: String
        if command.contains("wrangler") && command.contains("deploy") { role = "Cloudflare 网站发布 · wrangler deploy" }
        else if command.contains("vite") { role = "Vite 本地开发服务" }
        else if command.contains("http.server") { role = "Python 本地 HTTP 服务" }
        else { role = "未进一步识别" }
        return "任务：\(role)\n\n工作目录：\(cwd)"
    }
}
