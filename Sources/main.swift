import SwiftUI
import AppKit
import Darwin
import ServiceManagement
import SystemConfiguration

// ============================================================
// NetSpeed — menu bar speed test, engine = Ookla Speedtest CLI
// (official binary bundled at Contents/Resources/speedtest).
// jsonl schema captured live 2026-08-12 (CLI 1.2.0.84):
//   {"type":"ping","ping":{"jitter":0.0,"latency":13.532,"progress":0.2}}
//   {"type":"download","download":{"bandwidth":2350649,"bytes":1448,"elapsed":0,"progress":0.0}}   // bandwidth = bytes/sec
//   {"type":"upload","upload":{...}}
//   {"type":"result","ping":{"jitter":3.0,"latency":15.098,...},
//     "download":{"bandwidth":...,"latency":{"iqm":23.928,...}},
//     "upload":{"bandwidth":...,"latency":{"iqm":26.562,...}},
//     "packetLoss":0,"server":{"name":"Ufone","location":"Islamabad",...},
//     "result":{"id":"...","url":"..."}}
// Phases arrive strictly in order: testStart → ping → download → upload → result.
// ============================================================

// MARK: - Persisted result

struct TestResult: Codable, Equatable {
    var downloadMbps: Double
    var uploadMbps: Double
    var idleLatencyMs: Double? = nil
    var jitterMs: Double? = nil
    var packetLossPct: Double? = nil
    var loadedDownMs: Double? = nil
    var loadedUpMs: Double? = nil
    var serverName: String? = nil
    var serverLocation: String? = nil
    var resultUrl: String? = nil
    var date: Date
}

extension TestResult {
    // Worst-direction loaded latency governs how the line feels when busy.
    var loadedLatencyMs: Double? {
        [loadedDownMs, loadedUpMs].compactMap { $0 }.max()
    }

    var bloatMs: Double? {
        guard let idle = idleLatencyMs, let loaded = loadedLatencyMs else { return nil }
        return max(0, loaded - idle)
    }
}

// MARK: - Test engine

@MainActor
final class SpeedTestModel: ObservableObject {
    enum Phase: Equatable { case idle, starting, ping, download, upload, failed(String) }

    @Published var phase: Phase = .idle
    @Published private(set) var running = false
    @Published var livePing: Double?
    @Published var liveJitter: Double?
    @Published var liveDown: Double?
    @Published var liveUp: Double?
    @Published var lastResult: TestResult?
    @Published var launchAtLogin = false
    @Published var loginItemError: String?
    @Published var menuBarMode: String {
        didSet { UserDefaults.standard.set(menuBarMode, forKey: Self.menuBarModeKey) }
    }

    static let resultKey = "lastResult"
    static let menuBarModeKey = "menuBarMode"

    private var process: Process?
    private var lineBuffer = ""
    private var rawTail = ""
    private var resultEvent: [String: Any]?
    private var userCancelled = false
    private var timeoutTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?

    init() {
        menuBarMode = UserDefaults.standard.string(forKey: Self.menuBarModeKey) ?? "full"
        if let d = UserDefaults.standard.data(forKey: Self.resultKey),
           let r = try? JSONDecoder().decode(TestResult.self, from: d) { lastResult = r }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var displaySpeed: Double? { phase == .upload ? liveUp : liveDown }

    private static var engineURL: URL? { Bundle.main.url(forResource: "speedtest", withExtension: nil) }

    func start() {
        guard !running else { return }
        lineBuffer = ""; rawTail = ""; resultEvent = nil
        livePing = nil; liveJitter = nil; liveDown = nil; liveUp = nil
        userCancelled = false
        phase = .starting
        running = true
        activityToken = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "NetSpeed test")

        guard let engine = Self.engineURL else {
            finishCleanup()
            phase = .failed("Bundled speedtest binary is missing — rebuild the app.")
            return
        }

        let p = Process()
        p.executableURL = engine
        p.arguments = ["--accept-license", "--accept-gdpr", "-f", "jsonl"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            finishCleanup()
            phase = .failed("Couldn't launch speedtest: \(error.localizedDescription)")
            return
        }
        process = p

        let handle = pipe.fileHandleForReading
        Task.detached(priority: .userInitiated) { [weak self] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                let text = String(decoding: data, as: UTF8.self)
                await MainActor.run { self?.consume(text) }
            }
            p.waitUntilExit()
            let status = p.terminationStatus
            await MainActor.run { self?.finished(status: status) }
        }

        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard let self, self.running else { return }
            self.rawTail += " [timed out after 180s]"
            self.process?.terminate()
        }
    }

    func cancel() {
        guard running else { return }
        userCancelled = true
        process?.terminate()
    }

    private func consume(_ chunk: String) {
        rawTail = String((rawTail + chunk).suffix(400))
        lineBuffer += chunk
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()
        for line in lines where !line.isEmpty { handleLine(line) }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ping":
            if let ping = obj["ping"] as? [String: Any] {
                if let v = ping["latency"] as? Double { livePing = v }
                if let v = ping["jitter"] as? Double { liveJitter = v }
            }
            phase = .ping
        case "download":
            if let d = obj["download"] as? [String: Any], let bw = d["bandwidth"] as? Double {
                liveDown = bw * 8 / 1_000_000
            }
            phase = .download
        case "upload":
            if let u = obj["upload"] as? [String: Any], let bw = u["bandwidth"] as? Double {
                liveUp = bw * 8 / 1_000_000
            }
            phase = .upload
        case "result":
            resultEvent = obj
        default:
            break
        }
    }

    private func finished(status: Int32) {
        finishCleanup()
        if userCancelled { phase = .idle; return }

        if let obj = resultEvent, let r = Self.buildResult(from: obj) {
            lastResult = r
            if let enc = try? JSONEncoder().encode(r) { UserDefaults.standard.set(enc, forKey: Self.resultKey) }
            phase = .idle
        } else {
            let tail = rawTail.trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .failed("speedtest failed (exit \(status)). \(tail)")
        }
    }

    private static func buildResult(from obj: [String: Any]) -> TestResult? {
        guard let d = obj["download"] as? [String: Any], let dbw = d["bandwidth"] as? Double,
              let u = obj["upload"] as? [String: Any], let ubw = u["bandwidth"] as? Double else { return nil }
        var r = TestResult(downloadMbps: dbw * 8 / 1_000_000, uploadMbps: ubw * 8 / 1_000_000, date: Date())
        if let ping = obj["ping"] as? [String: Any] {
            r.idleLatencyMs = ping["latency"] as? Double
            r.jitterMs = ping["jitter"] as? Double
        }
        r.packetLossPct = obj["packetLoss"] as? Double
        if let lat = d["latency"] as? [String: Any] { r.loadedDownMs = lat["iqm"] as? Double }
        if let lat = u["latency"] as? [String: Any] { r.loadedUpMs = lat["iqm"] as? Double }
        if let s = obj["server"] as? [String: Any] {
            r.serverName = s["name"] as? String
            r.serverLocation = s["location"] as? String
        }
        if let res = obj["result"] as? [String: Any] { r.resultUrl = res["url"] as? String }
        return r
    }

    private func finishCleanup() {
        timeoutTask?.cancel(); timeoutTask = nil
        if let t = activityToken { ProcessInfo.processInfo.endActivity(t); activityToken = nil }
        process = nil
        running = false
    }

    func setLaunchAtLogin(_ on: Bool) {
        loginItemError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { loginItemError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func quit() {
        cancel()
        NSApp.terminate(nil)
    }
}

// MARK: - Formatting

func fmtSpeed(_ v: Double?) -> String {
    guard let v else { return "—" }
    if v >= 100 { return String(format: "%.0f", v) }
    if v >= 10 { return String(format: "%.1f", v) }
    return String(format: "%.2f", v)
}

func fmtLatency(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v >= 100 ? String(format: "%.0f ms", v) : String(format: "%.1f ms", v)
}

func fmtBareMs(_ v: Double?) -> String {
    guard let v else { return "—" }
    return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

func fmtLoss(_ v: Double?) -> String? {
    guard let v else { return nil }
    if v == 0 { return "0%" }
    return String(format: "%.1f%%", v)
}

let relFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

// MARK: - System metrics (CPU / memory straight from Mach — no subprocesses)

final class SysSampler {
    private var prevCPU: host_cpu_load_info?

    func cpuPercent() -> Float {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        defer { prevCPU = info }
        guard let p = prevCPU else { return 0 }
        let user = Double(info.cpu_ticks.0 &- p.cpu_ticks.0)
        let sys = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- p.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let total = user + sys + idle + nice
        guard total > 0 else { return 0 }
        return Float(min((user + sys + nice) / total * 100, 100))
    }

    // Matches Activity Monitor's "Memory Used": active + wired + compressed.
    func ramPercent() -> Float {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count)
                    + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return Float(min(used / total * 100, 100))
    }
}

// MARK: - Per-app usage
// nettop reports the executable name truncated to 15 chars, which turns
// "Microsoft Update Assistant" into "Microsoft Updat" and Warp into "stable"
// (its binary is literally Contents/MacOS/stable). So we keep the pid instead
// and resolve a real name + icon from it.

struct AppUsage: Identifiable {
    let id: Int32          // pid
    let name: String
    let icon: NSImage?
    let down: Double
    let up: Double
    var total: Double { down + up }
}

@MainActor
final class AppNameResolver {
    private var cache: [Int32: (String, NSImage?)] = [:]

    func resolve(_ pid: Int32) -> (name: String, icon: NSImage?) {
        if let hit = cache[pid] { return hit }
        var out: (String, NSImage?) = ("pid \(pid)", nil)
        if let app = NSRunningApplication(processIdentifier: pid), let n = app.localizedName {
            out = (n, app.icon)
        } else {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                let path = String(cString: buf)
                if let r = path.range(of: ".app/", options: .backwards) {
                    let bundle = String(path[..<r.lowerBound]) + ".app"
                    out = ((bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: ""),
                           NSWorkspace.shared.icon(forFile: bundle))
                } else {
                    out = ((path as NSString).lastPathComponent, nil)
                }
            }
        }
        if cache.count > 300 { cache.removeAll() }   // pids get recycled; keep it bounded
        cache[pid] = out
        return out
    }
}

// One point of history. Float keeps the hour's ring at ~20 KB.
struct Sample: Equatable {
    let t: Date
    let down: Float
    let up: Float
    let ping: Float
    let cpu: Float
    let ram: Float
}

// MARK: - Keychain (radio credentials never live in source or defaults)

enum Keychain {
    static let service = "com.ayyan.netspeed"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Radio (Ubiquiti airOS) telemetry
// Schema verified live against a PowerBeam M5-400 on airOS v6.3.24:
// status.cgi -> host.{uptime,cpuload,devmodel,fwversion}
//               wireless.{signal,noisef,ccq,txrate,rxrate,txpower,essid,
//                         frequency,distance,chainrssi,polling.{quality,capacity}}

struct RadioStatus: Equatable {
    var model = "", essid = "", freq = "", fw = ""
    var signal = 0, noise = 0, txPower = 0
    var ccq = 0                  // per-mille in airOS
    var amq = 0, amc = 0         // airMAX quality / capacity, %
    var txRate = "", rxRate = ""
    var uptime = 0, distance = 0, ethSpeed = 0
    var cpu = 0.0
    var chains: [Int] = []
    var snr: Int { signal - noise }
    var chainSpread: Int { (chains.max() ?? 0) - (chains.min() ?? 0) }
}

struct RadioSample: Equatable {
    let t: Date
    let signal: Float
    let amc: Float
    let ccq: Float
}

@MainActor
final class RadioMonitor: ObservableObject {
    @Published var status: RadioStatus?
    @Published var error: String?
    @Published var host: String { didSet { UserDefaults.standard.set(host, forKey: "radioHost") } }
    @Published var user: String { didSet { UserDefaults.standard.set(user, forKey: "radioUser") } }
    @Published private(set) var history: [RadioSample] = []

    // status.cgi is expensive on an M-series radio (its CPU has been seen at
    // 94%), so poll gently — 60 s still gives an hour of history.
    static let cap = 60          // 60 × 60 s = 1 hour

    private var timer: Timer?
    private var cookie: String?
    private var busy = false

    var configured: Bool { !host.isEmpty && !user.isEmpty && Keychain.get("radioPassword") != nil }

    init() {
        host = UserDefaults.standard.string(forKey: "radioHost") ?? ""
        user = UserDefaults.standard.string(forKey: "radioUser") ?? ""
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 10
        refresh()
    }

    func savePassword(_ p: String) {
        Keychain.set(p, account: "radioPassword")
        cookie = nil
        refresh()
    }

    func refresh() {
        guard configured, !busy else { return }
        busy = true
        let h = host, u = user
        guard let pw = Keychain.get("radioPassword") else { busy = false; return }
        Task { [weak self] in
            let result = await Self.fetch(host: h, user: u, password: pw)
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let s):
                    self.status = s
                    self.error = nil
                    let shared = SharedRadio.shared
                    shared.signal = s.signal; shared.snr = s.snr
                    shared.amc = s.amc; shared.ccq = s.ccq
                    shared.reachable = true; shared.updatedAt = Date()
                    self.history.append(RadioSample(t: Date(), signal: Float(s.signal),
                                                    amc: Float(s.amc), ccq: Float(s.ccq) / 10))
                    if self.history.count > Self.cap {
                        self.history.removeFirst(self.history.count - Self.cap)
                    }
                case .failure(let e):
                    self.error = e.message
                    SharedRadio.shared.reachable = false
                    SharedRadio.shared.updatedAt = Date()
                }
            }
        }
    }

    // airOS wants a session cookie from login.cgi before status.cgi will answer.
    nonisolated private static func fetch(host: String, user: String, password: String) async -> Result<RadioStatus, RadioError> {
        let cfg = URLSessionConfiguration.ephemeral   // isolated cookie jar per fetch
        cfg.timeoutIntervalForRequest = 8
        cfg.httpShouldSetCookies = true
        let session = URLSession(configuration: cfg)
        guard let seed = URL(string: "http://\(host)/login.cgi?uri=/"),
              let loginURL = URL(string: "http://\(host)/login.cgi"),
              let statusURL = URL(string: "http://\(host)/status.cgi") else {
            return .failure(RadioError("bad host"))
        }
        do {
            _ = try await session.data(from: seed)
            var req = URLRequest(url: loginURL)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let esc = CharacterSet.alphanumerics
            let body = "username=\(user.addingPercentEncoding(withAllowedCharacters: esc) ?? user)"
                + "&password=\(password.addingPercentEncoding(withAllowedCharacters: esc) ?? password)&uri=/"
            req.httpBody = Data(body.utf8)
            _ = try await session.data(for: req)
            let (data, _) = try await session.data(from: statusURL)
            guard let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let h = j["host"] as? [String: Any],
                  let w = j["wireless"] as? [String: Any] else {
                return .failure(RadioError("login rejected or unexpected response"))
            }
            var s = RadioStatus()
            s.model = h["devmodel"] as? String ?? ""
            s.fw = h["fwversion"] as? String ?? ""
            s.uptime = h["uptime"] as? Int ?? 0
            s.cpu = h["cpuload"] as? Double ?? 0
            s.essid = w["essid"] as? String ?? ""
            s.freq = w["frequency"] as? String ?? ""
            s.signal = w["signal"] as? Int ?? 0
            s.noise = w["noisef"] as? Int ?? 0
            s.ccq = w["ccq"] as? Int ?? 0
            s.txPower = w["txpower"] as? Int ?? 0
            s.txRate = "\(w["txrate"] ?? "")"
            s.rxRate = "\(w["rxrate"] ?? "")"
            s.distance = w["distance"] as? Int ?? 0
            s.chains = (w["chainrssi"] as? [Int])?.filter { $0 > 0 } ?? []
            if let p = w["polling"] as? [String: Any] {
                s.amq = p["quality"] as? Int ?? 0
                s.amc = p["capacity"] as? Int ?? 0
            }
            if let ifs = j["interfaces"] as? [[String: Any]],
               let eth = ifs.first(where: { ($0["ifname"] as? String) == "eth0" }),
               let st = (eth["status"] as? [[String: Any]])?.first {
                s.ethSpeed = st["speed"] as? Int ?? 0
            }
            return .success(s)
        } catch {
            return .failure(RadioError(error.localizedDescription))
        }
    }
}

struct RadioError: Error {
    let message: String
    init(_ m: String) { message = m }
}

// MARK: - LAN devices
// A switched network hides other hosts' traffic from us, and the router exposes
// no per-client counters — so this lists WHO is present, never how much they use.

struct LanDevice: Identifiable, Equatable {
    let id: String        // MAC
    let ip: String
    let vendor: String
    let isGateway: Bool
    let isSelf: Bool
}

@MainActor
final class DeviceScanner: ObservableObject {
    @Published private(set) var devices: [LanDevice] = []
    @Published private(set) var scannedAt: Date?

    private var timer: Timer?

    private static let ouis: [String: String] = [
        "50:0F:F5": "Tenda", "E4:38:83": "Ubiquiti", "24:A4:3C": "Ubiquiti",
        "78:8A:20": "Ubiquiti", "DC:9F:DB": "Ubiquiti", "04:18:D6": "Ubiquiti",
        "98:EE:CB": "USB Ethernet", "AC:DE:48": "Apple", "F0:18:98": "Apple",
        "A4:83:E7": "Apple", "3C:22:FB": "Apple", "F4:D4:88": "Apple",
        "8C:85:90": "Apple", "BC:D0:74": "Apple", "D0:81:7A": "Apple",
        "50:ED:3C": "Apple", "14:7D:DA": "Apple", "C0:2C:5C": "Apple",
        "50:8F:4C": "Xiaomi", "64:CC:2E": "Xiaomi", "2C:F0:5D": "Micro-Star",
        "B0:BE:76": "TP-Link", "50:C7:BF": "TP-Link", "AC:84:C6": "TP-Link",
        "00:1A:11": "Google", "F8:0F:F9": "Google", "DA:A1:19": "Google",
        "1C:6A:1B": "Ubiquiti", "00:E0:4C": "Realtek", "5C:E9:1E": "Samsung",
        "C8:D0:83": "Huawei", "48:5F:99": "Cloud Network",
    ]

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer?.tolerance = 10
        scan()
    }

    func scan() {
        Task.detached(priority: .utility) {
            // One multicast ping makes live hosts answer, which populates the
            // ARP cache — far cheaper than sweeping 254 addresses.
            _ = try? await Self.run("/sbin/ping", ["-c", "2", "-t", "2", "224.0.0.1"])
            let arp = (try? await Self.run("/usr/sbin/arp", ["-an"])) ?? ""
            let gw = (try? await Self.run("/sbin/route", ["-n", "get", "default"])) ?? ""
            let gateway = gw.split(separator: "\n")
                .first { $0.contains("gateway:") }?
                .split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let mine = Set((try? await Self.run("/sbin/ifconfig", []))?
                .split(separator: "\n")
                .filter { $0.contains("inet ") }
                .compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) } ?? [])
            let parsed = Self.parse(arp, gateway: gateway, mine: mine)
            await MainActor.run { [weak self] in
                self?.devices = parsed
                self?.scannedAt = Date()
            }
        }
    }

    // "? (192.168.0.1) at 50:f:f5:52:55:e8 on en9 ifscope [ethernet]"
    nonisolated private static func parse(_ text: String, gateway: String, mine: Set<String>) -> [LanDevice] {
        var out: [LanDevice] = []
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            guard let ipStart = line.firstIndex(of: "("),
                  let ipEnd = line.firstIndex(of: ")"), ipStart < ipEnd else { continue }
            let ip = String(line[line.index(after: ipStart)..<ipEnd])
            let parts = line.split(separator: " ")
            guard let atIdx = parts.firstIndex(of: "at"), parts.count > atIdx + 1 else { continue }
            let raw = String(parts[atIdx + 1])
            guard raw.contains(":") else { continue }
            let mac = raw.split(separator: ":")
                .map { $0.count == 1 ? "0" + $0 : String($0) }
                .joined(separator: ":").uppercased()
            guard mac != "FF:FF:FF:FF:FF:FF", !mac.hasPrefix("01:00:5E"), !seen.contains(mac) else { continue }
            seen.insert(mac)
            let oui = mac.split(separator: ":").prefix(3).joined(separator: ":")
            out.append(LanDevice(id: mac, ip: ip, vendor: ouis[oui] ?? "—",
                                 isGateway: ip == gateway, isSelf: mine.contains(ip)))
        }
        return out.sorted {
            if $0.isGateway != $1.isGateway { return $0.isGateway }
            return Self.ipKey($0.ip) < Self.ipKey($1.ip)
        }
    }

    nonisolated private static func ipKey(_ ip: String) -> UInt32 {
        ip.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | (UInt32($1) ?? 0) }
    }

    private static func run(_ path: String, _ args: [String]) async throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Shared radio snapshot
// The logger needs the radio's numbers on the same row as the network ones, so
// RadioMonitor publishes its latest reading here and NetMonitor reads it.

@MainActor
final class SharedRadio {
    static let shared = SharedRadio()
    var signal = 0, snr = 0, amc = 0, ccq = 0
    var reachable = false
    var updatedAt: Date?
}

// MARK: - Live network monitor
// Lightweight by design: a 2 s byte-counter poll (getifaddrs syscall, no
// subprocess), pings + CSV log every 10 s, and per-app sampling (nettop)
// only while there is actual traffic. Logs: ~/Library/Application Support/
// NetSpeed/netlog-YYYY-MM-DD.csv, pruned after 14 days.

@MainActor
final class NetMonitor: ObservableObject {
    @Published var downBps: Double = 0
    @Published var upBps: Double = 0
    @Published var gwPingMs: Double?
    @Published var inetPingMs: Double?
    @Published var netName: String = "—"
    @Published var iface: String = ""
    @Published var todayDown: UInt64 = 0
    @Published var todayUp: UInt64 = 0
    @Published var dailyTotals: [String: [Double]] = [:]   // "yyyy-MM-dd" -> [down, up]
    @Published var topApps: [AppUsage] = []
    @Published var cpuPct: Float = 0
    @Published var ramPct: Float = 0
    @Published private(set) var history: [Sample] = []

    static let historyCap = 720          // 720 × 5 s = 1 hour
    static let dailyKey = "dailyTotals"  // 31 days of per-day byte totals

    let logDir: URL

    private var timer: Timer?
    private var lastIn: UInt32?
    private var lastOut: UInt32?
    private var lastSampleAt: Date?
    private var tickCount = 0
    private var gateway: String?
    private var lastNettop: [Int32: (UInt64, UInt64)] = [:]
    private var lastNettopAt: Date?
    private var dayKey = ""
    private let sys = SysSampler()
    private var lastGoodPing: Float = 0
    private let names = AppNameResolver()
    // fault-isolation state
    private var pbPingMs: Double?
    private var linkMbit = 0
    private var errIn: UInt32 = 0
    private var errOut: UInt32 = 0
    private var lastErrTotal: UInt32 = 0
    private var prevIface = ""
    private var prevLinkMbit = 0
    private var routeLostAt: Date?
    private var lastTickAt: Date?
    private var radioWasReachable = true

    init() {
        logDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NetSpeed", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        dayKey = Self.dayString()
        restoreToday()
        pruneOldLogs()
        refreshPrimary()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 0.2
        prevIface = iface
        logEvent("app_start", "NetSpeed launched")
        tick()
    }

    private func tick() {
        tickCount += 1
        sampleCounters()                 // every 1 s
        if tickCount % 5 == 1 {          // every 5 s
            if let gw = gateway { pingOnce(gw, into: \.gwPingMs) }
            pingOnce("1.1.1.1", into: \.inetPingMs)
            let radioHost = UserDefaults.standard.string(forKey: "radioHost") ?? ""
            if !radioHost.isEmpty { pingOnce(radioHost, into: \.pbPingMs) }
            recordHistory()
            sampleTopApps()
        }
        if tickCount % 10 == 1 {         // every 10 s
            refreshPrimary()
            detectEvents()
            appendLog()
            persistToday()
        }
    }

    // MARK: history ring (1 hour at 5 s resolution)

    private func recordHistory() {
        cpuPct = sys.cpuPercent()
        ramPct = sys.ramPercent()
        if let p = inetPingMs, p > 0 { lastGoodPing = Float(p) }
        history.append(Sample(t: Date(), down: Float(downBps), up: Float(upBps),
                              ping: lastGoodPing, cpu: cpuPct, ram: ramPct))
        if history.count > Self.historyCap {
            history.removeFirst(history.count - Self.historyCap)
        }
    }

    // MARK: interface byte counters (32-bit in if_data — wrap-safe deltas)

    private func sampleCounters() {
        guard !iface.isEmpty, let st = Self.linkStats(iface) else { return }
        let inB = st.inBytes, outB = st.outBytes
        linkMbit = st.mbit
        errIn = st.ierrs
        errOut = st.oerrs
        let now = Date()
        defer { lastIn = inB; lastOut = outB; lastSampleAt = now }
        guard let li = lastIn, let lo = lastOut, let t = lastSampleAt else { return }
        let dt = now.timeIntervalSince(t)
        guard dt > 0.5,
              let din = Self.counterDelta(prev: li, now: inB),
              let dout = Self.counterDelta(prev: lo, now: outB) else { return }
        downBps = Double(din) / dt
        upBps = Double(dout) / dt
        rollDayIfNeeded()
        todayDown += din
        todayUp += dout
    }

    // if_data counters are 32-bit. Going backwards is a genuine wrap only when
    // the previous value sat near the ceiling; otherwise the interface was
    // reset (adapter unplugged, Wi-Fi reconnected) and the "delta" is phantom
    // traffic — up to ~4 GB of it — that must not land in the daily totals.
    private static func counterDelta(prev: UInt32, now: UInt32) -> UInt64? {
        if now >= prev {
            let d = UInt64(now - prev)
            return d < 2_000_000_000 ? d : nil
        }
        guard prev > 3_500_000_000 else { return nil }
        return UInt64(now &- prev)
    }

    struct LinkStats {
        let inBytes: UInt32, outBytes: UInt32
        let ierrs: UInt32, oerrs: UInt32
        let baudrate: UInt32
        var mbit: Int { Int(baudrate / 1_000_000) }
    }

    static func linkStats(_ name: String) -> LinkStats? {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return nil }
        defer { freeifaddrs(ifap) }
        var cursor = ifap
        while let p = cursor {
            let ifa = p.pointee
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               String(cString: ifa.ifa_name) == name,
               let data = ifa.ifa_data {
                let d = data.assumingMemoryBound(to: if_data.self).pointee
                return LinkStats(inBytes: d.ifi_ibytes, outBytes: d.ifi_obytes,
                                 ierrs: d.ifi_ierrors, oerrs: d.ifi_oerrors,
                                 baudrate: d.ifi_baudrate)
            }
            cursor = ifa.ifa_next
        }
        return nil
    }


    // MARK: primary interface / network name / gateway (SystemConfiguration)

    private func refreshPrimary() {
        guard let store = SCDynamicStoreCreate(nil, "NetSpeed" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let primary = global["PrimaryInterface"] as? String else {
            iface = ""; netName = "offline"; gateway = nil
            return
        }
        if primary != iface {
            iface = primary
            lastIn = nil; lastOut = nil    // never diff counters across interfaces
        }
        gateway = global["Router"] as? String
        if let svc = global["PrimaryService"] as? String,
           let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(svc)" as CFString) as? [String: Any],
           let name = setup["UserDefinedName"] as? String {
            netName = name
        } else {
            netName = primary
        }
    }

    // MARK: ping (one /sbin/ping -c 1 per target per 10 s)

    private func pingOnce(_ target: String, into keyPath: ReferenceWritableKeyPath<NetMonitor, Double?>) {
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/sbin/ping")
            p.arguments = ["-c", "1", "-t", "2", target]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var ms: Double?
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let s = String(decoding: data, as: UTF8.self)
                if let r = s.range(of: #"time=[0-9.]+"#, options: .regularExpression) {
                    ms = Double(s[r].dropFirst(5))
                }
            }
            let value = ms
            await MainActor.run { [weak self] in self?[keyPath: keyPath] = value }
        }
    }

    // MARK: per-app usage (nettop deltas; skipped while the line is idle)

    private func sampleTopApps() {
        guard downBps + upBps > 20_000 else {
            topApps = []; lastNettop = [:]; lastNettopAt = nil
            return
        }
        Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            p.arguments = ["-P", "-x", "-l", "1", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var current: [Int32: (UInt64, UInt64)] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 3,
                      let bin = UInt64(parts[parts.count - 2]),
                      let bout = UInt64(parts[parts.count - 1]) else { continue }
                // Trailing ".<pid>" on the (possibly space-containing) name column.
                let token = parts[0..<(parts.count - 2)].joined(separator: " ")
                guard let dot = token.lastIndex(of: "."),
                      let pid = Int32(token[token.index(after: dot)...]) else { continue }
                let prev = current[pid] ?? (0, 0)
                current[pid] = (prev.0 + bin, prev.1 + bout)
            }
            await MainActor.run { [weak self] in self?.digestNettop(current) }
        }
    }

    private func digestNettop(_ current: [Int32: (UInt64, UInt64)]) {
        let now = Date()
        defer { lastNettop = current; lastNettopAt = now }
        guard let t = lastNettopAt, !lastNettop.isEmpty else { return }
        let dt = now.timeIntervalSince(t)
        guard dt > 1 else { return }
        var rows: [AppUsage] = []
        for (pid, cur) in current {
            guard let prev = lastNettop[pid], cur.0 >= prev.0, cur.1 >= prev.1 else { continue }
            let down = Double(cur.0 - prev.0) / dt
            let up = Double(cur.1 - prev.1) / dt
            guard down + up > 5_000 else { continue }
            let info = names.resolve(pid)
            rows.append(AppUsage(id: pid, name: info.name, icon: info.icon, down: down, up: up))
        }
        topApps = Array(rows.sorted { $0.total > $1.total }.prefix(3))
    }

    // MARK: daily totals

    private func rollDayIfNeeded() {
        let today = Self.dayString()
        if today != dayKey {
            writeDailyRollup(for: dayKey, down: todayDown, up: todayUp)
            logEvent("day_rollover", "\(dayKey) -> \(today)")
            dayKey = today
            todayDown = 0; todayUp = 0
            pruneOldLogs()
        }
    }

    private func restoreToday() {
        let d = UserDefaults.standard
        if let raw = d.dictionary(forKey: Self.dailyKey) as? [String: [Double]] {
            dailyTotals = raw
        }
        if d.string(forKey: "todayKey") == dayKey {
            todayDown = UInt64(d.double(forKey: "todayDown"))
            todayUp = UInt64(d.double(forKey: "todayUp"))
        }
    }

    private func persistToday() {
        let d = UserDefaults.standard
        d.set(dayKey, forKey: "todayKey")
        d.set(Double(todayDown), forKey: "todayDown")
        d.set(Double(todayUp), forKey: "todayUp")
        dailyTotals[dayKey] = [Double(todayDown), Double(todayUp)]
        if dailyTotals.count > 40 {
            let keep = Set(dailyTotals.keys.sorted().suffix(31))
            dailyTotals = dailyTotals.filter { keep.contains($0.key) }
        }
        d.set(dailyTotals, forKey: Self.dailyKey)
    }

    // MARK: week / month roll-ups

    private func sumDays(_ keys: Set<String>) -> (down: UInt64, up: UInt64) {
        var down = 0.0, up = 0.0
        for (day, v) in dailyTotals where keys.contains(day) && v.count == 2 {
            down += v[0]; up += v[1]
        }
        return (UInt64(down), UInt64(up))
    }

    var monthToDate: (down: UInt64, up: UInt64) {
        let prefix = String(dayKey.prefix(7))                    // "yyyy-MM"
        return sumDays(Set(dailyTotals.keys.filter { $0.hasPrefix(prefix) }))
    }

    var weekToDate: (down: UInt64, up: UInt64) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let days = (0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }.map { f.string(from: $0) }
        return sumDays(Set(days))
    }

    // Days actually recorded this month — makes a partial history honest.
    var monthDaysCovered: Int {
        let prefix = String(dayKey.prefix(7))
        return dailyTotals.keys.filter { $0.hasPrefix(prefix) }.count
    }

    // MARK: CSV log

    // Columns are grouped so a reader can attribute a fault: gw_ms is cable +
    // switch port + router; pb_ms adds the router's forwarding to the radio;
    // inet_ms adds the radio link and the ISP; rssi/amc say whether the radio
    // itself was degrading. ierrs/oerrs and link_mbit catch a failing cable.
    private static let logHeader =
        "time,down_Bps,up_Bps,gw_ms,pb_ms,inet_ms,cpu_pct,ram_pct," +
        "link_mbit,ierrs,oerrs,rssi,snr,amc,ccq,network,iface,top_app\n"

    private func appendLog() {
        let file = logDir.appendingPathComponent("netlog-\(Self.dayString()).csv")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? Self.logHeader.write(to: file, atomically: true, encoding: .utf8)
        }
        let r = SharedRadio.shared
        let fresh = (r.updatedAt.map { Date().timeIntervalSince($0) < 180 } ?? false) && r.reachable
        let safeName = netName.replacingOccurrences(of: ",", with: " ")
        let topName = (topApps.first?.name ?? "").replacingOccurrences(of: ",", with: " ")
        let ms: (Double?) -> String = { $0.map { String(format: "%.1f", $0) } ?? "" }
        let row = "\(Self.timeString()),\(Int(downBps)),\(Int(upBps)),"
            + "\(ms(gwPingMs)),\(ms(pbPingMs)),\(ms(inetPingMs)),"
            + String(format: "%.0f,%.0f,", cpuPct, ramPct)
            + "\(linkMbit),\(errIn),\(errOut),"
            + (fresh ? "\(r.signal),\(r.snr),\(r.amc),\(r.ccq)," : ",,,,")
            + "\(safeName),\(iface),\(topName)\n"
        append(row, to: file)
    }

    private func append(_ text: String, to file: URL) {
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(text.utf8))
            try? h.close()
        }
    }

    // MARK: events — the timeline that explains an outage after the fact

    func logEvent(_ kind: String, _ detail: String) {
        let file = logDir.appendingPathComponent("events.csv")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "time,event,detail\n".write(to: file, atomically: true, encoding: .utf8)
        }
        append("\(Self.timeString()),\(kind),\(detail.replacingOccurrences(of: ",", with: " "))\n", to: file)
    }

    private func detectEvents() {
        let now = Date()
        // A sampling gap means the Mac slept — without this, sleep reads as downtime.
        if let last = lastTickAt, now.timeIntervalSince(last) > 90 {
            logEvent("sleep_gap", String(format: "%.0f min not sampled", now.timeIntervalSince(last) / 60))
        }
        lastTickAt = now

        if iface.isEmpty, routeLostAt == nil {
            routeLostAt = now
            logEvent("route_lost", "no default route — LAN side (router, cable or adapter)")
        } else if !iface.isEmpty, let lost = routeLostAt {
            logEvent("route_restored", String(format: "down %.1f min", now.timeIntervalSince(lost) / 60))
            routeLostAt = nil
        }

        if !iface.isEmpty, iface != prevIface {
            if !prevIface.isEmpty { logEvent("iface_changed", "\(prevIface) -> \(iface)") }
            prevIface = iface
            prevLinkMbit = 0
            lastErrTotal = 0
        }
        if linkMbit > 0, linkMbit != prevLinkMbit {
            if prevLinkMbit > 0 {
                logEvent("link_speed_changed", "\(prevLinkMbit) -> \(linkMbit) Mb — suspect cable if it dropped")
            }
            prevLinkMbit = linkMbit
        }
        let errTotal = errIn &+ errOut
        if errTotal > lastErrTotal {
            if lastErrTotal > 0 {
                logEvent("iface_errors", "+\(errTotal - lastErrTotal) on \(iface) — cable or port")
            }
            lastErrTotal = errTotal
        }
        let r = SharedRadio.shared
        if let u = r.updatedAt, Date().timeIntervalSince(u) < 180 {
            if r.reachable != radioWasReachable {
                logEvent(r.reachable ? "radio_up" : "radio_down", r.reachable ? "" : "PowerBeam not answering")
                radioWasReachable = r.reachable
            }
        }
    }

    // MARK: daily rollup — one tiny row per day, kept indefinitely

    private func writeDailyRollup(for day: String, down: UInt64, up: UInt64) {
        let file = logDir.appendingPathComponent("daily.csv")
        if !FileManager.default.fileExists(atPath: file.path) {
            try? "date,down_bytes,up_bytes,down_gb,up_gb\n".write(to: file, atomically: true, encoding: .utf8)
        }
        let row = String(format: "%@,%llu,%llu,%.2f,%.2f\n", day, down, up,
                         Double(down) / 1e9, Double(up) / 1e9)
        append(row, to: file)
    }

    // Retention: 7 days of per-second detail (~2 MB/day). events.csv and
    // daily.csv are tiny and are never pruned.
    private func pruneOldLogs() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let keep = Set((0..<7).compactMap {
            Calendar.current.date(byAdding: .day, value: -$0, to: Date())
        }.map { "netlog-\(f.string(from: $0)).csv" })
        let files = (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("netlog-")
            && !keep.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func dayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}

// MARK: - Rate / byte formatting

func fmtRate(_ bps: Double) -> String {          // menu bar: 0, 42K, 1.2M, 45M
    if bps < 1_000 { return "0" }
    if bps < 1_000_000 { return "\(Int(bps / 1_000))K" }
    if bps < 10_000_000 { return String(format: "%.1fM", bps / 1_000_000) }
    return "\(Int(bps / 1_000_000))M"
}

func fmtRateFull(_ bps: Double) -> String {      // popover: 340 KB/s, 1.24 MB/s
    if bps < 1_000 { return "0 B/s" }
    if bps < 1_000_000 { return String(format: "%.0f KB/s", bps / 1_000) }
    return String(format: "%.2f MB/s", bps / 1_000_000)
}

func fmtBytes(_ b: UInt64) -> String {           // today totals: 82 MB, 2.31 GB
    let d = Double(b)
    if d < 1_000_000 { return String(format: "%.0f KB", d / 1_000) }
    if d < 1_000_000_000 { return String(format: "%.0f MB", d / 1_000_000) }
    return String(format: "%.2f GB", d / 1_000_000_000)
}

// MARK: - Menu bar status image
// Two stacked 8.5 pt rows (↓ over ↑), each with a 4-bar vertical meter
// (signal style, ascending) + ping in a small side column. Bars = share of
// the line's measured capacity (last speed test): cyan/purple while normal,
// amber past ~60%, red when the pipe is effectively full. Colored image, so
// the ink flips with the menu bar's light/dark appearance.

private func meterLevel(_ bps: Double, capacityMbps: Double?) -> Int {
    let cap = (capacityMbps ?? 20) * 1_000_000 / 8   // Mbps → bytes/s, default 20 Mbit
    guard cap > 0 else { return 0 }
    let u = bps / cap
    if u > 0.9 { return 4 }
    if u > 0.6 { return 3 }
    if u > 0.25 { return 2 }
    if u > 0.05 { return 1 }
    return 0
}

private func meterColor(level: Int, accent: NSColor) -> NSColor {
    switch level {
    case 4: return NSColor(red: 1.0, green: 0.35, blue: 0.35, alpha: 1)   // saturated
    case 3: return NSColor(red: 1.0, green: 0.72, blue: 0.20, alpha: 1)   // getting full
    default: return accent
    }
}

// Re-rasterising the label every second costs real CPU, and while the line is
// idle nothing in it actually changes — so cache on the rendered content.
@MainActor
private var menuBarImageKey = ""
@MainActor
private var menuBarImageCached: NSImage?

@MainActor
func menuBarStatusImage(down: Double, up: Double, ping: Double?, showPing: Bool,
                        capDownMbps: Double?, capUpMbps: Double?) -> NSImage {
    let key = [fmtRate(down), fmtRate(up),
               showPing ? (ping.map { String(Int($0.rounded())) } ?? "—") : "",
               String(meterLevel(down, capacityMbps: capDownMbps)),
               String(meterLevel(up, capacityMbps: capUpMbps))].joined(separator: "|")
    if key == menuBarImageKey, let cached = menuBarImageCached { return cached }

    let textW: CGFloat = 33
    let barsX = textW + 2
    let barsW: CGFloat = 4 * 4.5
    let pingX = barsX + barsW + 5
    let width: CGFloat = showPing ? pingX + 17 : barsX + barsW + 2
    let size = NSSize(width: width, height: 22)

    let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    let ink: NSColor = dark ? .white : .black
    let accentDown = NSColor(red: 0.16, green: 0.78, blue: 0.99, alpha: 1)
    let accentUp = NSColor(red: 0.66, green: 0.53, blue: 0.99, alpha: 1)

    let image = NSImage(size: size, flipped: false) { _ in
        let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .medium)
        let tinyFont = NSFont.monospacedDigitSystemFont(ofSize: 6.5, weight: .regular)

        func draw(_ s: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (s as NSString).draw(at: NSPoint(x: x, y: y),
                                 withAttributes: [.font: font, .foregroundColor: color])
        }
        // 4 ascending vertical bars, filled per utilization level.
        func bars(_ bps: Double, capacity: Double?, accent: NSColor, baseY: CGFloat) {
            let level = meterLevel(bps, capacityMbps: capacity)
            let fill = meterColor(level: level, accent: accent)
            let heights: [CGFloat] = [3.5, 5, 6.5, 8]
            for i in 0..<4 {
                let color = i < level ? fill : ink.withAlphaComponent(0.18)
                color.setFill()
                NSBezierPath(roundedRect: NSRect(x: barsX + CGFloat(i) * 4.5, y: baseY,
                                                 width: 2.5, height: heights[i]),
                             xRadius: 1.25, yRadius: 1.25).fill()
            }
        }

        draw("↓", x: 0, y: 11, font: rowFont, color: accentDown)
        draw(fmtRate(down), x: 7, y: 11, font: rowFont, color: ink.withAlphaComponent(0.92))
        draw("↑", x: 0, y: 1, font: rowFont, color: accentUp)
        draw(fmtRate(up), x: 7, y: 1, font: rowFont, color: ink.withAlphaComponent(0.92))
        bars(down, capacity: capDownMbps, accent: accentDown, baseY: 12.5)
        bars(up, capacity: capUpMbps, accent: accentUp, baseY: 2)
        if showPing {
            let text = ping.map { String(format: "%.0f", $0.rounded()) } ?? "—"
            draw(text, x: pingX, y: 10.5, font: rowFont, color: ink.withAlphaComponent(0.8))
            draw("ms", x: pingX, y: 2.5, font: tinyFont, color: ink.withAlphaComponent(0.5))
        }
        return true
    }
    image.isTemplate = false
    menuBarImageKey = key
    menuBarImageCached = image
    return image
}

// MARK: - Palette

extension Color {
    static let bgTop = Color(red: 0.075, green: 0.09, blue: 0.17)
    static let bgBottom = Color(red: 0.045, green: 0.055, blue: 0.115)
    static let accentDL = Color(red: 0.16, green: 0.78, blue: 0.99)
    static let accentUL = Color(red: 0.66, green: 0.53, blue: 0.99)
    static let accentMid = Color(red: 0.36, green: 0.52, blue: 1.0)
    static let accentPing = Color(red: 0.99, green: 0.77, blue: 0.19)
    static let accentRPM = Color(red: 0.17, green: 0.85, blue: 0.72)
    static let faintLine = Color.white.opacity(0.08)
    static let dimText = Color.white.opacity(0.45)
}

// MARK: - App

@main
struct NetSpeedApp: App {
    @StateObject private var model = SpeedTestModel()
    @StateObject private var monitor = NetMonitor()
    @StateObject private var radio = RadioMonitor()
    @StateObject private var scanner = DeviceScanner()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model, monitor: monitor, radio: radio, scanner: scanner)
        } label: {
            MenuBarLabel(model: model, monitor: monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: SpeedTestModel
    @ObservedObject var monitor: NetMonitor

    var body: some View {
        if model.running, let v = model.displaySpeed, v > 0 {
            Text("\(model.phase == .upload ? "↑" : "↓")\(Int(v.rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        } else if model.menuBarMode == "icon" {
            Image(systemName: "speedometer")
        } else {
            Image(nsImage: menuBarStatusImage(
                down: monitor.downBps,
                up: monitor.upBps,
                ping: monitor.inetPingMs,
                showPing: model.menuBarMode == "full",
                capDownMbps: model.lastResult?.downloadMbps,
                capUpMbps: model.lastResult?.uploadMbps))
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var model: SpeedTestModel
    @ObservedObject var monitor: NetMonitor
    @ObservedObject var radio: RadioMonitor
    @ObservedObject var scanner: DeviceScanner
    @AppStorage("tab") private var tab = "speed"

    // Every tab renders inside one fixed-height frame: a MenuBarExtra(.window)
    // panel dismisses itself the moment its content changes height.
    private let bodyHeight: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            TopStatsView(model: model)
                .padding(.top, 16)
                .padding(.horizontal, 18)
            TabSwitcher(tab: $tab)
                .padding(.top, 10)
            Group {
                switch tab {
                case "radio": RadioTab(radio: radio)
                case "devices": DevicesTab(scanner: scanner)
                default: speedTab
                }
            }
            .frame(height: bodyHeight, alignment: .top)
            .padding(.top, 8)
            .padding(.horizontal, 14)
            Divider().overlay(Color.faintLine)
            FooterView(model: model, monitor: monitor)
        }
        .frame(width: 320)
        .background(LinearGradient(colors: [.bgTop, .bgBottom], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
    }

    private var speedTab: some View {
        VStack(spacing: 8) {
            ZStack {
                GaugeView(model: model)
                centerOverlay
            }
            .frame(height: 190)
            StatusLine(model: model)
            HistoryPanel(history: monitor.history).equatable()
            LiveStrip(monitor: monitor)
            ResultDetailsView(result: model.lastResult)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var centerOverlay: some View {
        switch model.phase {
        case .idle:
            GoButton { model.start() }
        case .failed(let msg):
            ErrorOverlay(message: msg) { model.start() }
        default:
            EmptyView()
        }
    }
}

// MARK: - Tab switcher

struct TabSwitcher: View {
    @Binding var tab: String

    var body: some View {
        HStack(spacing: 3) {
            item("Speed", "speed", icon: "speedometer")
            item("Radio", "radio", icon: "antenna.radiowaves.left.and.right")
            item("Devices", "devices", icon: "rectangle.connected.to.line.below")
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }

    private func item(_ title: String, _ value: String, icon: String) -> some View {
        let on = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(on ? .white : Color.dimText)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.white.opacity(0.12) : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Radio tab (PowerBeam / airOS)

struct RadioTab: View {
    @ObservedObject var radio: RadioMonitor
    @State private var pw = ""

    var body: some View {
        VStack(spacing: 8) {
            if !radio.configured {
                setupCard
            } else if let s = radio.status {
                statusCard(s)
                historyCard
                readingCard(s)
                linkCard(s)
            } else {
                SectionCard {
                    sectionLabel("RADIO")
                    Text(radio.error ?? "Connecting to the radio…")
                        .font(.system(size: 10))
                        .foregroundStyle(radio.error == nil ? Color.dimText : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var setupCard: some View {
        SectionCard {
            sectionLabel("RADIO — NOT CONFIGURED")
            Text("Point this at your airOS radio (PowerBeam, NanoStation, LiteBeam). The password is stored in your macOS Keychain, never in a file.")
                .font(.system(size: 10)).foregroundStyle(Color.dimText)
                .fixedSize(horizontal: false, vertical: true)
            field("Host / IP", text: $radio.host)
            field("Username", text: $radio.user)
            HStack(spacing: 6) {
                Text("Password").font(.system(size: 9.5)).foregroundStyle(Color.dimText).frame(width: 62, alignment: .leading)
                SecureField("", text: $pw)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            Button("Connect") { radio.savePassword(pw); pw = "" }
                .buttonStyle(.borderedProminent).tint(Color.accentDL).controlSize(.small)
                .disabled(radio.host.isEmpty || radio.user.isEmpty || pw.isEmpty)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 9.5)).foregroundStyle(Color.dimText).frame(width: 62, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10).monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
        }
    }

    private func statusCard(_ s: RadioStatus) -> some View {
        SectionCard {
            HStack {
                sectionLabel("RADIO", color: .accentRPM)
                Spacer()
                Text(s.model.isEmpty ? radio.host : s.model)
                    .font(.system(size: 9)).foregroundStyle(Color.dimText).lineLimit(1)
            }
            HStack(spacing: 0) {
                bigStat("SIGNAL", "\(s.signal)", "dBm", signalColor(s.signal))
                divider
                bigStat("SNR", "\(s.snr)", "dB", s.snr >= 25 ? .green : s.snr >= 15 ? .yellow : .orange)
                divider
                bigStat("CAPACITY", "\(s.amc)", "%", pctColor(s.amc))
            }
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            grid(s)
        }
    }

    private func grid(_ s: RadioStatus) -> some View {
        VStack(spacing: 4) {
            row("airMAX quality", "\(s.amq)%", pctColor(s.amq))
            row("CCQ", String(format: "%.1f%%", Double(s.ccq) / 10), pctColor(s.ccq / 10))
            row("TX / RX rate", "\(s.txRate) / \(s.rxRate) Mbps", .white.opacity(0.85))
            row("Chain balance", s.chains.map(String.init).joined(separator: " / ")
                + (s.chainSpread > 3 ? "  ⚠︎ \(s.chainSpread) dB" : ""),
                s.chainSpread > 3 ? .orange : .white.opacity(0.85))
            row("TX power", "\(s.txPower) dBm", .white.opacity(0.85))
            row("Noise floor", "\(s.noise) dBm", .white.opacity(0.85))
        }
    }

    private func linkCard(_ s: RadioStatus) -> some View {
        SectionCard {
            sectionLabel("LINK")
            VStack(spacing: 4) {
                row("Connected to", s.essid, .white.opacity(0.85))
                row("Frequency", s.freq, .white.opacity(0.85))
                row("Distance", s.distance > 0 ? String(format: "%.2f km", Double(s.distance) / 1000) : "—", .white.opacity(0.85))
                row("Ethernet", s.ethSpeed > 0 ? "\(s.ethSpeed) Mb full" : "—", .white.opacity(0.85))
                row("Radio uptime", fmtUptime(s.uptime), .white.opacity(0.85))
                row("Radio CPU", String(format: "%.0f%%", s.cpu), s.cpu > 70 ? .orange : .white.opacity(0.85))
                row("Firmware", s.fw, Color.dimText)
            }
        }
    }

    private var historyCard: some View {
        SectionCard {
            HStack {
                sectionLabel("RADIO — LAST HOUR")
                Spacer()
                Text("60 s samples").font(.system(size: 9)).foregroundStyle(Color.dimText)
            }
            if radio.history.count < 2 {
                Text("Collecting…").font(.system(size: 10)).foregroundStyle(Color.dimText)
                    .frame(maxWidth: .infinity).frame(height: 76)
            } else {
                VStack(spacing: 6) {
                    MetricChart(label: "SIGNAL (dBm, higher is better)",
                                series: [ChartSeries(values: radio.history.map { $0.signal + 100 }, color: .accentDL)],
                                fmt: { String(format: "%.0f", $0 - 100) }, scrub: nil, minTop: 50, height: 30)
                    MetricChart(label: "AIRMAX CAPACITY %",
                                series: [ChartSeries(values: radio.history.map(\.amc), color: .accentRPM)],
                                fmt: { String(format: "%.0f%%", $0) }, scrub: nil, fixedTop: 100, height: 30)
                }
            }
        }
    }

    // Turns the raw radio numbers into the sentence you'd say to the WISP.
    private func readingCard(_ s: RadioStatus) -> some View {
        SectionCard {
            sectionLabel("WHAT THIS MEANS")
            VStack(spacing: 5) {
                ForEach(verdicts(s), id: \.0) { v in
                    HStack(spacing: 6) {
                        Circle().fill(v.2).frame(width: 5, height: 5)
                        Text(v.0).font(.system(size: 10)).foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 4)
                        Text(v.1).font(.system(size: 9.5)).foregroundStyle(v.2.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private func verdicts(_ s: RadioStatus) -> [(String, String, Color)] {
        var out: [(String, String, Color)] = []
        let red = Color(red: 1, green: 0.35, blue: 0.35)
        out.append(("Signal strength",
                    s.signal >= -60 ? "strong" : s.signal >= -70 ? "weaker than ideal" : "poor — realign",
                    s.signal >= -60 ? .green : s.signal >= -70 ? .yellow : .orange))
        out.append(("Noise / SNR",
                    s.snr >= 25 ? "clean" : s.snr >= 15 ? "marginal" : "buried in noise",
                    s.snr >= 25 ? .green : s.snr >= 15 ? .yellow : red))
        out.append(("Dish alignment",
                    s.chainSpread <= 3 ? "chains balanced" : "\(s.chainSpread) dB off — re-aim",
                    s.chainSpread <= 3 ? .green : .orange))
        out.append(("Sector headroom",
                    s.amc >= 80 ? "plenty" : s.amc >= 50 ? "getting busy" : "oversubscribed — ask WISP",
                    s.amc >= 80 ? .green : s.amc >= 50 ? .yellow : .orange))
        out.append(("Link stability",
                    s.amq >= 80 ? "steady" : s.amq >= 60 ? "some contention" : "unstable polling",
                    s.amq >= 80 ? .green : s.amq >= 60 ? .yellow : .orange))
        return out
    }

    private var divider: some View { Rectangle().fill(Color.faintLine).frame(width: 1, height: 26) }

    private func bigStat(_ label: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 8.5, weight: .semibold)).tracking(0.7).foregroundStyle(Color.dimText)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(color)
                Text(unit).font(.system(size: 9)).foregroundStyle(Color.dimText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack {
            Text(k).font(.system(size: 10)).foregroundStyle(Color.dimText)
            Spacer()
            Text(v.isEmpty ? "—" : v).font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(c).lineLimit(1)
        }
    }

    private func signalColor(_ v: Int) -> Color {
        v >= -60 ? .green : v >= -70 ? .yellow : v >= -80 ? .orange : Color(red: 1, green: 0.35, blue: 0.35)
    }
    private func pctColor(_ v: Int) -> Color {
        v >= 80 ? .green : v >= 50 ? .yellow : .orange
    }
}

func fmtUptime(_ s: Int) -> String {
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Devices tab

struct DevicesTab: View {
    @ObservedObject var scanner: DeviceScanner

    var body: some View {
        VStack(spacing: 8) {
            SectionCard {
                HStack {
                    sectionLabel("DEVICES ON THIS NETWORK", color: .accentRPM)
                    Spacer()
                    Text("\(scanner.devices.count) seen")
                        .font(.system(size: 9)).foregroundStyle(Color.dimText)
                }
                if scanner.devices.isEmpty {
                    Text("Scanning…").font(.system(size: 10)).foregroundStyle(Color.dimText)
                        .frame(maxWidth: .infinity).frame(height: 60)
                } else {
                    VStack(spacing: 3) {
                        ForEach(scanner.devices.prefix(14)) { d in
                            HStack(spacing: 6) {
                                Image(systemName: d.isGateway ? "wifi.router" : d.isSelf ? "laptopcomputer" : "desktopcomputer")
                                    .font(.system(size: 9))
                                    .foregroundStyle(d.isGateway ? Color.accentPing : d.isSelf ? Color.accentDL : Color.dimText)
                                    .frame(width: 13)
                                Text(d.ip)
                                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.9))
                                    .frame(width: 92, alignment: .leading)
                                Text(d.vendor)
                                    .font(.system(size: 9.5)).foregroundStyle(Color.dimText)
                                    .lineLimit(1)
                                Spacer(minLength: 2)
                                if d.isGateway { tag("router", .accentPing) }
                                else if d.isSelf { tag("this Mac", .accentDL) }
                                Text(d.id.suffix(8))
                                    .font(.system(size: 8.5).monospacedDigit())
                                    .foregroundStyle(Color.dimText.opacity(0.7))
                            }
                            .frame(height: 15)
                        }
                    }
                }
            }
            SectionCard {
                sectionLabel("WHY THERE ARE NO PER-DEVICE SPEEDS")
                Text("A switch only sends this Mac its own traffic, so other devices' throughput is invisible from here. The router would have to report it — and this Tenda exposes no traffic API. Per-device graphs need a router that keeps them.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 8, weight: .bold)).foregroundStyle(c)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .background(Capsule().fill(c.opacity(0.14)))
    }
}

// MARK: - Top stats (download / upload)

struct TopStatsView: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        HStack(spacing: 0) {
            col(label: "DOWNLOAD", icon: "arrow.down", color: .accentDL, value: downText)
            Rectangle().fill(Color.faintLine).frame(width: 1, height: 34)
            col(label: "UPLOAD", icon: "arrow.up", color: .accentUL, value: upText)
        }
    }

    private var downText: String {
        model.running ? fmtSpeed(model.liveDown) : fmtSpeed(model.lastResult?.downloadMbps)
    }

    private var upText: String {
        model.running ? fmtSpeed(model.liveUp) : fmtSpeed(model.lastResult?.uploadMbps)
    }

    private func col(label: String, icon: String, color: Color, value: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(color)
                Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(Color.dimText)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("Mbps").font(.system(size: 10)).foregroundStyle(Color.dimText)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: value)
    }
}

// MARK: - Gauge

private let gaugeStartDeg = 135.0
private let gaugeSweepDeg = 270.0

private func gaugeT(_ v: Double) -> Double {
    let c = max(0, min(v, 1000))
    return log10(1 + c) / log10(1001.0)
}

struct GaugeView: View {
    @ObservedObject var model: SpeedTestModel

    private static let ticks: [(Double, String)] =
        [(0, "0"), (1, "1"), (5, "5"), (10, "10"), (50, "50"), (100, "100"), (250, "250"), (500, "500"), (1000, "1000")]

    var body: some View {
        let value = model.running
            ? (model.displaySpeed ?? 0)
            : (model.lastResult?.downloadMbps ?? 0)
        let tt = gaugeT(value)
        let arcColor: Color = model.phase == .upload ? .accentUL : .accentDL

        ZStack {
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.07), style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(gaugeStartDeg))
            Circle()
                .trim(from: 0, to: 0.75 * tt)
                .stroke(
                    AngularGradient(colors: [.accentDL, .accentMid, .accentUL],
                                    center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(gaugeSweepDeg)),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(gaugeStartDeg))
                .shadow(color: arcColor.opacity(0.5), radius: 8)
                .opacity(model.running ? 1 : 0.3)
            TicksLayer(ticks: Self.ticks.map { (gaugeT($0.0), $0.1) })
            NeedleView(t: tt)
                .opacity(model.running ? 1 : (model.lastResult != nil ? 0.25 : 0))
            if model.running { LiveReadout(model: model) }
        }
        .padding(24)
        .animation(.spring(response: 0.6, dampingFraction: 0.85), value: value)
    }
}

struct TicksLayer: View {
    let ticks: [(Double, String)]

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let r = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(0..<ticks.count, id: \.self) { i in
                    let deg = gaugeStartDeg + gaugeSweepDeg * ticks[i].0
                    let rad = CGFloat(deg) * .pi / 180
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 2, height: 8)
                        .rotationEffect(.degrees(deg - 90))
                        .position(x: c.x + (r - 18) * cos(rad), y: c.y + (r - 18) * sin(rad))
                    Text(ticks[i].1)
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.dimText)
                        .position(x: c.x + (r - 34) * cos(rad), y: c.y + (r - 34) * sin(rad))
                }
            }
        }
    }
}

struct NeedleView: View {
    let t: Double

    var body: some View {
        GeometryReader { geo in
            let r = min(geo.size.width, geo.size.height) / 2
            let len = r - 40
            let deg = gaugeStartDeg + gaugeSweepDeg * t
            ZStack {
                Capsule()
                    .fill(LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 3.5, height: len)
                    .offset(y: -len / 2)
                    .rotationEffect(.degrees(deg - 270))
                Circle().fill(.white).frame(width: 9, height: 9)
                Circle().fill(Color.bgTop).frame(width: 4, height: 4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct LiveReadout: View {
    @ObservedObject var model: SpeedTestModel

    private var isPingPhase: Bool { model.phase == .ping || model.phase == .starting }

    var body: some View {
        VStack(spacing: 3) {
            phaseChip
            Text(isPingPhase ? fmtBareMs(model.livePing) : fmtSpeed(model.displaySpeed))
                .font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Text(isPingPhase ? "ms ping" : "Mbps")
                .font(.system(size: 11))
                .foregroundStyle(Color.dimText)
        }
        .offset(y: 34)
    }

    @ViewBuilder private var phaseChip: some View {
        switch model.phase {
        case .starting: chip("CONNECTING…", Color.dimText)
        case .ping: chip("PING", .accentPing)
        case .download: chip("↓ DOWNLOAD", .accentDL)
        case .upload: chip("↑ UPLOAD", .accentUL)
        default: EmptyView()
        }
    }

    private func chip(_ s: String, _ c: Color) -> some View {
        Text(s)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(c)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.14)))
    }
}

// MARK: - GO / error overlays

struct GoButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color.white.opacity(0.03))
                Circle().stroke(
                    LinearGradient(colors: [.accentDL, .accentUL], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 3)
                Text("GO")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 104, height: 104)
            .contentShape(Circle())
            .shadow(color: Color.accentDL.opacity(hovering ? 0.55 : 0.25), radius: hovering ? 16 : 9)
            .scaleEffect(hovering ? 1.05 : 1)
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ErrorOverlay: View {
    let message: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark").font(.system(size: 22)).foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.dimText)
                .lineLimit(3)
                .multilineTextAlignment(.center)
                .frame(width: 210)
            Button("Try again", action: action)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentDL)
                .controlSize(.small)
        }
    }
}

// MARK: - Status line

struct StatusLine: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .starting: caption("Connecting…")
            case .ping: caption("Measuring ping…")
            case .download: caption("Measuring download…")
            case .upload: caption("Measuring upload…")
            case .failed: caption("Test failed")
            case .idle: caption("Ready — hit GO")
            }
            if model.running {
                Button { model.cancel() } label: {
                    Text("Stop").font(.system(size: 11, weight: .medium)).underline().foregroundStyle(Color.dimText)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 18)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(Color.dimText)
    }
}

// MARK: - Real-world analysis

// Waveform-style bufferbloat grade on added latency under load.
func bloatGrade(_ addedMs: Double) -> (String, Color) {
    switch addedMs {
    case ..<5: return ("A+", .green)
    case ..<30: return ("A", .green)
    case ..<60: return ("B", .accentRPM)
    case ..<200: return ("C", .yellow)
    case ..<400: return ("D", .orange)
    default: return ("F", Color(red: 1.0, green: 0.35, blue: 0.35))
    }
}

enum Verdict {
    case good(String), ok(String), bad(String), unknown

    var color: Color {
        switch self {
        case .good: return .green
        case .ok: return .yellow
        case .bad: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .unknown: return .dimText
        }
    }

    var text: String {
        switch self {
        case .good(let s), .ok(let s), .bad(let s): return s
        case .unknown: return "—"
        }
    }
}

struct Activity {
    let icon: String
    let label: String
    let verdict: Verdict
}

// Thresholds: Zoom group HD ≈ 4 Mbps each way; Netflix 4K 15 / HD 5 Mbps;
// gaming wants <60 ms ping. Loaded latency decides how it feels when the
// line is busy with anything else; packet loss hits realtime traffic first.
func activities(for result: TestResult?) -> [Activity] {
    let blank = [("video.fill", "Video meetings"), ("4k.tv", "4K streaming"), ("tv", "HD streaming"),
                 ("gamecontroller.fill", "Gaming"), ("safari", "Browsing")]
    guard let r = result else {
        return blank.map { Activity(icon: $0.0, label: $0.1, verdict: .unknown) }
    }
    let idle = r.idleLatencyMs
    let loaded = r.loadedLatencyMs
    let loss = r.packetLossPct

    func meetings() -> Verdict {
        guard let idle else { return .unknown }
        if r.downloadMbps < 4 || r.uploadMbps < 4 { return .bad("not enough bandwidth") }
        if let loss, loss > 2 { return .bad("packet loss") }
        if idle > 300 { return .bad("ping too high") }
        if idle > 150 { return .ok("borderline ping") }
        if let loss, loss > 0.5 { return .ok("some packet loss") }
        if let loaded, loaded > 400 { return .ok("choppy when line is busy") }
        return .good("smooth")
    }
    func fourK() -> Verdict {
        if r.downloadMbps >= 25 { return .good("smooth") }
        if r.downloadMbps >= 15 { return .ok("borderline") }
        return .bad("needs 15+ Mbps down")
    }
    func hd() -> Verdict {
        if r.downloadMbps >= 8 { return .good("smooth") }
        if r.downloadMbps >= 5 { return .ok("borderline") }
        return .bad("needs 5+ Mbps down")
    }
    func gaming() -> Verdict {
        guard let idle else { return .unknown }
        if let loss, loss > 1 { return .bad("packet loss") }
        if idle > 150 { return .bad("ping too high") }
        if idle > 60 { return .ok("playable, not ideal") }
        if let loaded, loaded > 230 { return .ok("lags when line is busy") }
        return .good("low ping")
    }
    func browsing() -> Verdict {
        guard let idle else { return .unknown }
        if idle <= 200 && r.downloadMbps >= 5 { return .good("snappy") }
        if idle <= 600 { return .ok("sluggish") }
        return .bad("slow")
    }

    return [
        Activity(icon: "video.fill", label: "Video meetings", verdict: meetings()),
        Activity(icon: "4k.tv", label: "4K streaming", verdict: fourK()),
        Activity(icon: "tv", label: "HD streaming", verdict: hd()),
        Activity(icon: "gamecontroller.fill", label: "Gaming", verdict: gaming()),
        Activity(icon: "safari", label: "Browsing", verdict: browsing()),
    ]
}

// Every row is always present — a MenuBarExtra(.window) panel dismisses itself
// when its content changes height, so this view must render one fixed shape
// whether or not a test has ever run.
struct ResultDetailsView: View {
    let result: TestResult?

    var body: some View {
        SectionCard {
            HStack {
                sectionLabel("LAST TEST")
                Spacer()
                if let result {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(relFormatter.localizedString(for: result.date, relativeTo: Date()))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.dimText)
                    }
                } else {
                    Text("no test yet")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.dimText)
                }
            }
            HStack(spacing: 0) {
                latStat("PING", fmtLatency(result?.idleLatencyMs))
                vDivider
                latStat("LOADED", fmtLatency(result?.loadedLatencyMs))
                vDivider
                bloatStat
            }
            Text(metaLine)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color.dimText.opacity(0.85))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            VStack(spacing: 6) {
                ForEach(activities(for: result), id: \.label) { a in
                    HStack(spacing: 7) {
                        Image(systemName: a.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dimText)
                            .frame(width: 15)
                        Text(a.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Circle().fill(a.verdict.color).frame(width: 6, height: 6)
                        Text(a.verdict.text)
                            .font(.system(size: 10))
                            .foregroundStyle(a.verdict.color.opacity(0.9))
                    }
                }
            }
        }
    }

    private var metaLine: String {
        guard let result else { return "run a test to see jitter, loss and server" }
        var parts: [String] = []
        if let j = result.jitterMs { parts.append("jitter \(fmtLatency(j))") }
        if let l = fmtLoss(result.packetLossPct) { parts.append("loss \(l)") }
        if let s = result.serverName {
            parts.append([s, result.serverLocation].compactMap { $0 }.joined(separator: ", "))
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var vDivider: some View {
        Rectangle().fill(Color.faintLine).frame(width: 1, height: 26)
    }

    private func latStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.7)
                .foregroundStyle(Color.dimText)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var bloatStat: some View {
        VStack(spacing: 2) {
            Text("BUFFERBLOAT")
                .font(.system(size: 8.5, weight: .semibold)).tracking(0.7)
                .foregroundStyle(Color.dimText)
            HStack(spacing: 4) {
                Text(result?.bloatMs.map { "+\(fmtLatency($0))" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                if let b = result?.bloatMs {
                    let (grade, color) = bloatGrade(b)
                    Text(grade)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(color.opacity(0.15)))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Section card container

struct SectionCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder _ builder: () -> Content) { content = builder() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.035)))
    }
}

func sectionLabel(_ s: String, color: Color = .dimText) -> some View {
    Text(s)
        .font(.system(size: 8.5, weight: .heavy))
        .tracking(0.8)
        .foregroundStyle(color)
}

// MARK: - History charts
// Hand-drawn Paths rather than Swift Charts: 4 charts × 720 points needs to
// stay cheap, and a shared scrub line across all of them is easier this way.

struct ChartSeries {
    let values: [Float]
    let color: Color
}

struct MetricChart: View {
    let label: String
    let series: [ChartSeries]
    let fmt: (Float) -> String
    let scrub: Int?
    var minTop: Float = 1
    var fixedTop: Float? = nil
    var height: CGFloat = 32

    private var top: Float {
        if let fixedTop { return fixedTop }
        let peak = series.flatMap(\.values).max() ?? 0
        return Swift.max(peak * 1.15, minTop)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 8, weight: .heavy)).tracking(0.7)
                    .foregroundStyle(Color.dimText)
                Spacer()
                ForEach(series.indices, id: \.self) { i in
                    let vals = series[i].values
                    let idx = scrub.map { Swift.min($0, vals.count - 1) } ?? (vals.count - 1)
                    Text(vals.indices.contains(idx) ? fmt(vals[idx]) : "—")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(series[i].color)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    ForEach(series.indices, id: \.self) { i in
                        let s = series[i]
                        area(s.values, in: geo.size)
                            .fill(LinearGradient(colors: [s.color.opacity(0.28), s.color.opacity(0.02)],
                                                 startPoint: .top, endPoint: .bottom))
                        line(s.values, in: geo.size)
                            .stroke(s.color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    }
                    if let scrub, let n = series.first?.values.count, n > 1 {
                        let x = geo.size.width * CGFloat(Swift.min(scrub, n - 1)) / CGFloat(n - 1)
                        Rectangle().fill(Color.white.opacity(0.35))
                            .frame(width: 1, height: geo.size.height)
                            .offset(x: x)
                    }
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
        }
    }

    private func points(_ values: [Float], in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let dx = size.width / CGFloat(values.count - 1)
        let cap = top
        return values.enumerated().map { i, v in
            let frac = cap > 0 ? CGFloat(Swift.max(v, 0) / cap) : 0
            let y = size.height - Swift.min(frac, 1) * size.height
            return CGPoint(x: CGFloat(i) * dx, y: y.isFinite ? y : size.height)
        }
    }

    private func line(_ values: [Float], in size: CGSize) -> Path {
        var p = Path()
        let pts = points(values, in: size)
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func area(_ values: [Float], in size: CGSize) -> Path {
        var p = line(values, in: size)
        let pts = points(values, in: size)
        guard let first = pts.first, let last = pts.last else { return p }
        p.addLine(to: CGPoint(x: last.x, y: size.height))
        p.addLine(to: CGPoint(x: first.x, y: size.height))
        p.closeSubpath()
        return p
    }
}

// Takes history by value and is Equatable, so SwiftUI skips rebuilding four
// 720-point Paths on the 1 Hz live-rate updates — history only changes every 5 s.
struct HistoryPanel: View, Equatable {
    let history: [Sample]
    @State private var scrub: Int?

    static func == (a: HistoryPanel, b: HistoryPanel) -> Bool { a.history == b.history }

    var body: some View {
        let h = history
        SectionCard {
            HStack {
                sectionLabel("LAST HOUR", color: .accentRPM)
                Spacer()
                Text(stampText(h))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(scrub == nil ? Color.dimText : .white.opacity(0.8))
            }
            if h.count < 2 {
                Text("Collecting… charts appear after a few samples.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.dimText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 176)
            } else {
                GeometryReader { geo in
                    VStack(alignment: .leading, spacing: 6) {
                        MetricChart(label: "NETWORK  ↓ / ↑",
                                    series: [ChartSeries(values: h.map(\.down), color: .accentDL),
                                             ChartSeries(values: h.map(\.up), color: .accentUL)],
                                    fmt: { fmtRate(Double($0)) + "B/s" },
                                    scrub: scrub, minTop: 50_000)
                        MetricChart(label: "PING",
                                    series: [ChartSeries(values: h.map(\.ping), color: .accentPing)],
                                    fmt: { String(format: "%.0f ms", $0) },
                                    scrub: scrub, minTop: 50)
                        MetricChart(label: "CPU",
                                    series: [ChartSeries(values: h.map(\.cpu), color: .accentRPM)],
                                    fmt: { String(format: "%.0f%%", $0) },
                                    scrub: scrub, fixedTop: 100)
                        MetricChart(label: "MEMORY",
                                    series: [ChartSeries(values: h.map(\.ram), color: .accentMid)],
                                    fmt: { String(format: "%.0f%%", $0) },
                                    scrub: scrub, fixedTop: 100)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            guard geo.size.width > 0, h.count > 1 else { return }
                            let frac = min(max(pt.x / geo.size.width, 0), 1)
                            scrub = Int((frac * CGFloat(h.count - 1)).rounded())
                        case .ended:
                            scrub = nil
                        }
                    }
                }
                .frame(height: 176)
            }
        }
    }

    private func stampText(_ h: [Sample]) -> String {
        guard let first = h.first, let last = h.last else { return "—" }
        if let scrub, h.indices.contains(scrub) {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let ago = Int(last.t.timeIntervalSince(h[scrub].t).rounded())
            return ago < 5 ? "now · \(f.string(from: h[scrub].t))"
                           : "\(ago / 60 > 0 ? "\(ago / 60)m " : "")\(ago % 60)s ago · \(f.string(from: h[scrub].t))"
        }
        let span = Int(last.t.timeIntervalSince(first.t) / 60)
        return span < 1 ? "hover to scrub" : "\(span) min · hover to scrub"
    }
}

// MARK: - Top apps by current throughput
// Always three rows (blank ones included) — the popover must not change height.

struct TopAppsView: View, Equatable {
    let apps: [AppUsage]

    // Icons are immutable per pid, so identity + rates fully describe a row.
    static func == (a: TopAppsView, b: TopAppsView) -> Bool {
        a.apps.count == b.apps.count
            && zip(a.apps, b.apps).allSatisfy { $0.id == $1.id && $0.down == $1.down && $0.up == $1.up }
    }

    private var peak: Double { max(apps.first?.total ?? 1, 1) }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                row(i < apps.count ? apps[i] : nil)
            }
        }
    }

    private func row(_ app: AppUsage?) -> some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentDL.opacity(0.15))
                    .frame(width: app.map { geo.size.width * CGFloat(min($0.total / peak, 1)) } ?? 0)
            }
            HStack(spacing: 5) {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                } else {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                        .frame(width: 12, height: 12)
                }
                Text(app?.name ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(app == nil ? Color.dimText : .white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let app {
                    Text("↓" + fmtRate(app.down))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.accentDL)
                        .frame(width: 40, alignment: .trailing)
                    Text("↑" + fmtRate(app.up))
                        .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.accentUL)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(height: 17)
    }
}

// MARK: - Live monitor card (always visible in the popover)

struct LiveStrip: View {
    @ObservedObject var monitor: NetMonitor

    var body: some View {
        SectionCard {
            HStack {
                sectionLabel("LIVE", color: .accentRPM)
                Spacer()
                Text("\(monitor.netName) (\(monitor.iface.isEmpty ? "—" : monitor.iface))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.dimText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: 0) {
                rateCol(icon: "arrow.down", color: .accentDL, value: fmtRateFull(monitor.downBps))
                Rectangle().fill(Color.faintLine).frame(width: 1, height: 20)
                rateCol(icon: "arrow.up", color: .accentUL, value: fmtRateFull(monitor.upBps))
            }
            Text(detailLine)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color.dimText)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(usageLine)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(Color.dimText)
                .lineLimit(1)
                .truncationMode(.middle)
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            TopAppsView(apps: monitor.topApps).equatable()
        }
    }

    // Fixed-width value slot so the row never re-centers as digits change.
    private func rateCol(icon: String, color: Color, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(color)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .frame(width: 84, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .animation(.default, value: value)
    }


    private var detailLine: String {
        let gw = monitor.gwPingMs.map { String(format: "%.1f ms", $0) } ?? "—"
        let net = monitor.inetPingMs.map { String(format: "%.0f ms", $0) } ?? "—"
        return "gw \(gw) · net \(net) · today ↓\(fmtBytes(monitor.todayDown)) ↑\(fmtBytes(monitor.todayUp))"
    }

    private var usageLine: String {
        let w = monitor.weekToDate
        let m = monitor.monthToDate
        let days = monitor.monthDaysCovered
        return "week ↓\(fmtBytes(w.down)) ↑\(fmtBytes(w.up)) · month ↓\(fmtBytes(m.down)) ↑\(fmtBytes(m.up)) (\(days)d)"
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var model: SpeedTestModel
    @ObservedObject var monitor: NetMonitor

    var body: some View {
        HStack {
            Text("Ookla Speedtest CLI")
                .font(.system(size: 10))
                .foregroundStyle(Color.dimText.opacity(0.7))
            Spacer()
            Menu {
                Picker("Menu bar", selection: $model.menuBarMode) {
                    Text("Speeds + ping").tag("full")
                    Text("Speeds only").tag("speeds")
                    Text("Icon only").tag("icon")
                }
                Button("Open logs folder") { NSWorkspace.shared.open(monitor.logDir) }
                Divider()
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                if let e = model.loginItemError {
                    Text("Login item: \(e)")
                }
                if let s = model.lastResult?.resultUrl, let url = URL(string: s) {
                    Button("Open last result on speedtest.net") { NSWorkspace.shared.open(url) }
                }
                Divider()
                Button("Quit NetSpeed") { model.quit() }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dimText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
