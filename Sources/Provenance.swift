import Foundation
import Darwin

struct ProcessIdentity: Equatable {
    var pid: Int32
    var parent: Int32
    var started: String
    var executable: String
}
// Local, bounded discovery; no git command or network access is used to inspect a repository.
final class ProvenanceCollector {
    private struct Entry { var identity: ProcessIdentity; var origin: ProcessOrigin; var checked: Date }
    private var cache: [Int32: Entry] = [:]
    static func identity(_ pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return ProcessIdentity(pid: pid, parent: Int32(info.pbi_ppid),
                               started: "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)", executable: String(cString: buffer))
    }
    // Read argv boundaries from the kernel instead of splitting a shell string.
    // Environment values are not returned or persisted.
    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size < 2_000_000 else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0 else { return [] }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 && argc < 4096 else { return [] }
        var index = 4
        while index < size && data[index] != 0 { index += 1 }
        while index < size && data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<argc {
            guard index < size else { break }
            let start = index
            while index < size && data[index] != 0 { index += 1 }
            result.append(String(decoding: data[start..<index], as: UTF8.self)); index += 1
        }
        return result
    }
    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let value = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return value.isEmpty ? nil : value
    }
    static func displayName(_ path: String) -> String {
        if let range = path.range(of: ".app/") { return URL(fileURLWithPath: String(path[..<range.lowerBound])+".app").deletingPathExtension().lastPathComponent }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    static func smallFile(_ path: URL) -> String? {
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 else { return nil }
        return try? String(contentsOf: path, encoding: .utf8)
    }
    static func repository(at cwd: String) -> (String, String?)? {
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<24 {
            let marker = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            var gitdir: URL?
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDir) {
                if isDir.boolValue { gitdir = marker }
                else if let text = smallFile(marker), text.hasPrefix("gitdir: ") {
                    gitdir = URL(fileURLWithPath: String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: dir).standardizedFileURL
                }
            } else if FileManager.default.fileExists(atPath: dir.appendingPathComponent("HEAD").path),
                      FileManager.default.fileExists(atPath: dir.appendingPathComponent("objects").path) { gitdir = dir }
            if var configDir = gitdir {
                if let common = smallFile(configDir.appendingPathComponent("commondir")) {
                    configDir = URL(fileURLWithPath: common.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: configDir).standardizedFileURL
                }
                let config = smallFile(configDir.appendingPathComponent("config")) ?? ""
                var origin = false
                var remote: String?
                for raw in config.split(separator: "\n") {
                    let line = raw.trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("[") { origin = line == "[remote \"origin\"]" }
                    else if origin, let equals = line.firstIndex(of: "="), line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                        remote = sanitizedRemote(String(line[line.index(after: equals)...])); break
                    }
                }
                return (dir.lastPathComponent == ".git" ? dir.deletingLastPathComponent().path : dir.path, remote)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }; dir = parent
        }
        return nil
    }
    func capture(_ id: ProcessIdentity, at date: Date) -> ProcessOrigin? {
        if let entry = cache[id.pid], entry.identity == id, date.timeIntervalSince(entry.checked) < 10 { return entry.origin }
        let cwd = Self.workingDirectory(id.pid)
        let repo = cwd.flatMap(Self.repository)
        var ancestors: [ProcessAncestor] = [], visited: Set<Int32> = [id.pid], parent = id.parent
        var operation: String?
        for _ in 0..<8 {
            guard parent > 1, !visited.contains(parent), let item = Self.identity(parent) else { break }
            visited.insert(parent)
            ancestors.append(ProcessAncestor(pid: parent, name: Self.displayName(item.executable), executable: item.executable))
            // Classify only Git commands; never save raw args or arbitrary shell text.
            if operation == nil, URL(fileURLWithPath: item.executable).lastPathComponent == "git", id.executable.contains("git-remote-") {
                let words = Self.arguments(parent)
                // Git's subcommand is a discrete argument; quoted paths remain intact.
                operation = ["clone", "fetch", "pull", "push", "ls-remote"].first { words.dropFirst().contains($0) }
            }
            parent = item.parent
        }
        // A process may exit or a PID may be reused while reading metadata.
        guard Self.identity(id.pid) == id else { return nil }
        let helperArgs = id.executable.contains("git-remote-") ? Self.arguments(id.pid) : []
        let actualRemote = helperArgs.count >= 3 ? sanitizedRemote(helperArgs[2]) : nil
        let result = ProcessOrigin(capturedAt: date, workingDirectory: cwd, repository: repo?.0,
                                   remote: repo?.1, operation: operation, ancestors: ancestors, transferRemote: actualRemote)
        cache[id.pid] = Entry(identity: id, origin: result, checked: date)
        if cache.count > 2048 { cache = cache.filter { date.timeIntervalSince($0.value.checked) < 120 } }
        return result
    }
}
