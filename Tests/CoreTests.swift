import Foundation
@main struct Tests {
 static func main() throws {
    var passed = 0
    func check(_ value: Bool, _ label: String) { if !value { fatalError("FAIL: \(label)") }; passed += 1; print("PASS \(label)") }
    check(Parse.wifiName("Current Wi-Fi Network: 桑苹果\n") == "桑苹果", "Unicode hotspot name")
    check(Parse.wifiName("You are not associated with an AirPort network.") == nil, "Disconnected Wi-Fi")
    check(Parse.wifiName("Current Wi-Fi Network: <redacted>") == nil, "Redacted SSID not accepted")
    let raw = ",bytes_in,bytes_out,\nnode.123,9000000,2000000,\nGoogle Chrome H.42,33,44,\n"
    let proc = Parse.nettop(raw)!
    check(proc["node.123"]?.usage.up == 2_000_000 && proc.count == 2, "nettop CSV parser")
    check(Parse.nettop("permission denied") == nil, "Collector error not empty success")
    let ns = "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll\nen0 1500 <Link#12> aa 1 0 60070113700 2 0 20092496828 0\nen0 1500 10.0.0.0 a 1 0 60070113700 2 0 20092496828 0"
    check(Parse.interfaceCounts(ns, interface: "en0") == Usage(down: 60070113700, up: 20092496828), "64-bit counters and no duplicate address rows")
    let engine = LedgerEngine(); engine.ledger.preferences.networks = ["桑苹果", "旅行热点"]
    engine.ledger.preferences.limitMB = 1; engine.ledger.preferences.burstMB = 1
    let t = Date(timeIntervalSince1970: 1000)
    func sample(_ time: Double, _ net: String? = "桑苹果", _ bytes: Int64, _ p: [String: ProcessUsage]? = proc) -> Sample {
        Sample(date: t.addingTimeInterval(time), network: net, interface: "en0", counts: Usage(down: bytes, up: 0), wifi: p, activity: p)
    }
    engine.ingest(sample(0, "桑苹果", 10_000_000))
    check(engine.active?.usage.total == 0, "Lifetime counters excluded from session baseline")
    var p2 = proc; p2["node.123"]?.usage.up += 1_200_000
    let alerts = engine.ingest(sample(2, "桑苹果", 11_200_000, p2))
    check(engine.active?.usage.total == 1_200_000, "Interface delta counted once")
    check(engine.active?.wifiApps["node.123"]?.usage.up == 1_200_000, "Per-process delta")
    check(alerts.count == 2, "Cumulative and burst warnings")
    check(engine.ingest(sample(4, "桑苹果", 11_200_000, p2)).isEmpty, "No repeated threshold notification")
    var p3=p2; p3["new.999"] = ProcessUsage(id:"new.999",name:"new",pid:999,executable:"",usage:Usage(down:900_000_000))
    engine.ingest(sample(6, "桑苹果", 11_200_000,p3))
    check(engine.active?.wifiApps["new.999"] == nil,"Newly observed process establishes baseline")
    engine.ingest(sample(8, "家里", 20_000_000))
    check(engine.active == nil && engine.ledger.sessions[0].usage.total == 1_200_000,"Unmetered network ends session without charging gap")
    engine.ingest(sample(10, "旅行热点", 30_000_000))
    check(engine.active?.usage.total == 0 && engine.ledger.sessions.count == 2,"Switch to another metered network")
    engine.ingest(sample(40, "旅行热点", 80_000_000))
    check(engine.ledger.sessions.count == 3 && engine.active?.usage.total == 0,"Sleep/gap splits session without inventing usage")
    engine.ingest(sample(42, "旅行热点", 10))
    check(engine.active?.usage.total == 0,"Counter reset does not cause a spike")
    engine.ingest(sample(44, "旅行热点", 100))
    check(engine.active?.usage.total == 90,"Counter resumes after reset")
    let encoded = try JSONEncoder().encode(engine.ledger)
    let restored = LedgerEngine(ledger: try JSONDecoder().decode(Ledger.self, from: encoded))
    check(restored.active == nil && restored.ledger.sessions.last?.usage.total == 90,"Restart preserves history and closes interrupted session")
    engine.ledger.preferences.enabled = false
    engine.ingest(sample(46, "旅行热点", 800))
    check(engine.active == nil,"Pause recording closes session")
    let legacy = Data("{\"networks\":[\"桑苹果\"],\"enabled\":true,\"limitMB\":500,\"burstMB\":100}".utf8)
    let migrated = try JSONDecoder().decode(Preferences.self, from: legacy)
    check(migrated.autoDisconnect != true, "Old preferences keep automatic disconnection disabled")
    let cutoff = LedgerEngine(); cutoff.ledger.preferences.networks = ["桑苹果"]
    cutoff.ledger.preferences.disconnectMB = 1
    cutoff.ingest(sample(0, "桑苹果", 0)); cutoff.ingest(sample(2, "桑苹果", 1_000_000))
    check(cutoff.takeDisconnectRequest() == nil, "No automatic disconnection by default")
    cutoff.ledger.preferences.autoDisconnect = true
    let request = cutoff.takeDisconnectRequest()
    check(request?.network == "桑苹果" && request?.interface == "en0", "Exact threshold disconnects the sampled network")
    check(cutoff.takeDisconnectRequest() == nil, "Only one disconnect attempt per session")
    let recovered = LedgerEngine(ledger: try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(cutoff.ledger)))
    check(recovered.ledger.sessions.last?.disconnectAttempted == true, "Disconnect attempt persists")
    cutoff.close("test"); cutoff.ingest(sample(4, "桑苹果", 2_000_000)); cutoff.ingest(sample(6, "桑苹果", 2_999_999))
    check(cutoff.takeDisconnectRequest() == nil, "Below threshold stays connected")
    cutoff.ingest(sample(8, "桑苹果", 3_000_000))
    check(cutoff.takeDisconnectRequest() != nil, "New session starts a fresh threshold budget")
    cutoff.close("test"); cutoff.ingest(sample(10, "家里", 100_000_000))
    check(cutoff.takeDisconnectRequest() == nil, "Unmarked Wi-Fi never triggers disconnect")
    cutoff.ledger.preferences.disconnectMB = Int64.max
    check(cutoff.takeDisconnectRequest() == nil, "Invalid stored threshold cannot overflow")
    check(formatBytes(1_000_000) == "1.0 MB" && formatBytes(1_000_000_000) == "1.00 GB", "Decimal data units")
    let pausedCutoff = LedgerEngine(); pausedCutoff.ledger.preferences.networks = ["桑苹果"]
    pausedCutoff.ledger.preferences.autoDisconnect = true; pausedCutoff.ledger.preferences.disconnectMB = 1
    pausedCutoff.ingest(sample(0, "桑苹果", 0)); pausedCutoff.ledger.preferences.enabled = false
    pausedCutoff.ingest(sample(2, "桑苹果", 5_000_000))
    check(pausedCutoff.takeDisconnectRequest() == nil, "Paused recording never triggers automatic disconnection")
    let switched = LedgerEngine(); switched.ledger.preferences.networks = ["桑苹果", "旅行热点"]
    switched.ledger.preferences.autoDisconnect = true; switched.ledger.preferences.disconnectMB = 1
    switched.ingest(sample(0, "桑苹果", 0)); switched.ingest(sample(2, "旅行热点", 5_000_000))
    check(switched.takeDisconnectRequest() == nil, "Network switch does not charge previous network traffic")
    let helpers = [ProcessUsage(id: "a", name: "Browser", pid: 1, executable: "/Applications/Browser.app/Contents/MacOS/Browser", usage: Usage(down: 10, up: 20)), ProcessUsage(id: "b", name: "Browser", pid: 2, executable: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", usage: Usage(down: 30, up: 40)), ProcessUsage(id: "c", name: "unknown", pid: 3, executable: "", usage: Usage(down: 5)), ProcessUsage(id: "d", name: "unknown", pid: 4, executable: "", usage: Usage(down: 6))]
    let grouped = groupedProcesses(helpers)
    check(grouped.count == 3 && grouped[0].usage == Usage(down: 40, up: 60), "Application and helper processes aggregate once")
    check(grouped[0].pid == 2 && grouped[0].id == "/Applications/Browser.app", "Highest-usage process represents grouped application")
    let resumeSource = LedgerEngine(); resumeSource.ledger.preferences.networks = ["桑苹果", "旅行热点"]
    resumeSource.ingest(sample(0, "桑苹果", 100, proc))
    resumeSource.ingest(sample(2, "桑苹果", 1_200_100, p2))
    let resumeID = resumeSource.active!.id
    resumeSource.ledger.sessions[0].cumulativeAlerted = true
    resumeSource.ledger.sessions[0].disconnectAttempted = true
    resumeSource.close("已退出程序")
    let stored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(resumeSource.ledger))
    let resumed = LedgerEngine(ledger: stored)
    check(resumed.active == nil, "Restart waits for fresh network identity")
    resumed.ingest(sample(120, "桑苹果", 90_000_000, p3))
    check(resumed.active?.id == resumeID && resumed.ledger.sessions.count == 1, "Same hotspot restart continues session ID")
    check(resumed.active?.usage.total == 1_200_000 && resumed.active?.wifiApps["node.123"]?.usage.up == 1_200_000, "Restart retains totals and app attribution without charging offline bytes")
    check(resumed.active?.unobservedSeconds == 118 && resumed.active?.resumeCount == 1 && resumed.active?.points?.isEmpty == true, "Unobserved gap tracked and chart starts a fresh segment")
    check(resumed.active?.cumulativeAlerted == true && resumed.active?.disconnectAttempted == true, "Resume retains warning and disconnect guards")
    resumed.ingest(sample(122, "桑苹果", 90_000_500, p3))
    check(resumed.active?.usage.total == 1_200_500, "Sampling continues from fresh baseline")
    let crash = LedgerEngine(ledger: resumed.ledger); crash.ingest(sample(200, "桑苹果", 100_000_000))
    check(crash.active?.id == resumeID && crash.active?.resumeCount == 2, "Crash recovery resumes with cumulative gap tracking")
    let changed = LedgerEngine(ledger: stored); changed.ingest(sample(120, "旅行热点", 90_000_000))
    check(changed.active?.id != resumeID && changed.ledger.sessions.count == 2, "Different hotspot starts new session")
    let adapter = LedgerEngine(ledger: stored); var otherAdapter = sample(120, "桑苹果", 90_000_000); otherAdapter.interface = "en1"; adapter.ingest(otherAdapter)
    check(adapter.active?.id != resumeID, "Different adapter cannot resume old session")
    let left = LedgerEngine(ledger: stored); left.ingest(sample(120, "家里", 90_000_000)); left.ingest(sample(122, "桑苹果", 90_000_500))
    check(left.active?.id != resumeID, "Observed network departure cancels restart continuation")
    resumeSource.ledger.sessions[0].endReason = "手动关闭 Wi-Fi"
    let explicitlyEnded = LedgerEngine(ledger: resumeSource.ledger); explicitlyEnded.ingest(sample(120, "桑苹果", 90_000_000))
    check(explicitlyEnded.active?.id != resumeID, "Explicit disconnect stays a session boundary")

    let legacyProcess = try JSONDecoder().decode(ProcessUsage.self, from: Data("{\"id\":\"git.1\",\"name\":\"git\",\"pid\":1,\"executable\":\"/usr/bin/git\",\"usage\":{\"down\":10,\"up\":0}}".utf8))
    check(legacyProcess.origin == nil && legacyProcess.startedAt == nil, "Legacy process records decode without invented attribution")
    check(sanitizedRemote("https://user:secret@github.com/owner/repo.git?token=hidden#fragment") == "github.com/owner/repo.git", "Remote strips credentials, query and fragment")
    check(sanitizedRemote("git@github.com:owner/repo.git?token=hidden") == "github.com/owner/repo.git", "SSH remote sanitization")
    check(sanitizedRemote("/tmp/local-repo") == nil, "Local path is not misreported as a remote")
    let origin = ProcessOrigin(capturedAt: t, workingDirectory: "/tmp/repo", repository: "/tmp/repo", remote: "github.com/owner/repo", operation: "fetch", ancestors: [ProcessAncestor(pid: 7, name: "Editor", executable: "/Applications/Editor.app/Contents/MacOS/Editor")])
    var attributed = ProcessUsage(id: "git.123", name: "git-remote-http", pid: 123, executable: "/usr/libexec/git-remote-http", usage: Usage(down: 100), startedAt: "10.1", origin: origin)
    let provenanceEngine = LedgerEngine(); provenanceEngine.ledger.preferences.networks = ["桑苹果"]
    provenanceEngine.ingest(sample(0, "桑苹果", 0, [attributed.id: attributed]))
    attributed.usage.down = 150
    provenanceEngine.ingest(sample(2, "桑苹果", 50, [attributed.id: attributed]))
    check(provenanceEngine.active?.activityApps.values.first?.origin == origin, "Origin retained with sampled byte delta")
    attributed.startedAt = "20.1"; attributed.usage.down = 9000
    provenanceEngine.ingest(sample(4, "桑苹果", 100, [attributed.id: attributed]))
    check(provenanceEngine.active?.activityApps.values.reduce(0, {$0+$1.usage.total}) == 50, "PID reuse does not charge unrelated lifetime bytes")
    attributed.usage.down = 9030
    provenanceEngine.ingest(sample(6, "桑苹果", 130, [attributed.id: attributed]))
    check(provenanceEngine.active?.activityApps.count == 2, "Reused PID gets a distinct retained record")
    var changedOrigin = origin; changedOrigin.repository = "/tmp/other"; changedOrigin.workingDirectory = "/tmp/other"
    attributed.origin = changedOrigin; attributed.usage.down = 9040
    provenanceEngine.ingest(sample(8, "桑苹果", 140, [attributed.id: attributed]))
    check(provenanceEngine.active?.activityApps.count == 3, "Changed provenance segments usage without rewriting older sources")
    let persistedOrigins = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(provenanceEngine.ledger))
    check(persistedOrigins.sessions.last?.activityApps.count == 3 && persistedOrigins.sessions.last?.activityApps.values.contains(where: {$0.origin?.repository == "/tmp/repo"}) == true, "Origin survives JSON round trip and process exit")
    check(groupedProcesses(Array(provenanceEngine.active!.activityApps.values)).first?.usage.total == 90, "Source segments aggregate exactly once")
    let midnight = Calendar.current.startOfDay(for: Date())
    let offset = midnight.timeIntervalSince(t)
    let across = LedgerEngine()
    across.ledger.preferences.networks = ["桑苹果"]
    across.ingest(sample(offset - 4, "桑苹果", 100))
    across.ingest(sample(offset - 2, "桑苹果", 145))
    across.ingest(sample(offset + 1, "桑苹果", 175))
    let history = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(across.active!))
    check(history.recordedDays[Session.dayKey(midnight)]?.total == 30 && history.recordedDays.values.map({ $0.total }).sorted() == [30, 45], "Midnight samples persist in separate local days")
    var legacySession = history
    legacySession.daily = nil
    check(legacySession.recordedDays.isEmpty && legacySession.usage.total == 75, "Legacy multi-day totals stay unallocated")
    let originalLanguage = UserDefaults.standard.string(forKey: "language")
    L10n.set("en"); check(L10n.choose("设置", "Settings") == "Settings" && L10n.text("关于热点账本") == "About Hotspot Ledger", "Native UI localization resolves supported labels")
    L10n.set("fr"); check(L10n.language == "en", "Unsupported language cannot overwrite saved choice")
    if let originalLanguage { UserDefaults.standard.set(originalLanguage, forKey: "language") } else { UserDefaults.standard.removeObject(forKey: "language") }
    print("\(passed) tests passed")
 }
}
