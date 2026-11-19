import Foundation
import Darwin
@main struct ProvenanceTests {
    static func main() throws {
        if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]), let identity = ProvenanceCollector.identity(pid) {
            let origin = ProvenanceCollector().capture(identity, at: Date())
            let data = try JSONEncoder().encode(origin)
            print(String(data: data, encoding: .utf8)!); return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n url = https://user:secret@example.org/team/repo.git?token=hidden\n".write(to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        let nested = root.appendingPathComponent("a/b")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let repo = ProvenanceCollector.repository(at: nested.path)
        precondition(repo?.0 == root.path && repo?.1 == "example.org/team/repo.git")
        let worktree = root.appendingPathComponent("worktree")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "gitdir: ../.git\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        precondition(ProvenanceCollector.repository(at: worktree.path)?.1 == "example.org/team/repo.git")
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]; child.currentDirectoryURL = root
        try child.run(); defer { if child.isRunning { child.terminate() } }
        guard let identity = ProvenanceCollector.identity(child.processIdentifier), let saved = ProvenanceCollector().capture(identity, at: Date()) else { fatalError("Cannot inspect local child") }
        precondition(saved.workingDirectory == root.path || saved.workingDirectory == "/private" + root.path)
        precondition(saved.remote == "example.org/team/repo.git")
        precondition(saved.ancestors.first?.pid == getpid())
        child.terminate(); child.waitUntilExit()
        precondition(ProvenanceCollector.identity(child.processIdentifier) == nil)
        let restored = try JSONDecoder().decode(ProcessOrigin.self, from: JSONEncoder().encode(saved))
        precondition(restored == saved)
        print("PASS repository discovery, worktree pointer, credential sanitization, live cwd/parent/start identity, retained metadata after exit")
    }
}
