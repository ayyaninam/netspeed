import SwiftUI
import AppKit
import ServiceManagement

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

    static let resultKey = "lastResult"

    private var process: Process?
    private var lineBuffer = ""
    private var rawTail = ""
    private var resultEvent: [String: Any]?
    private var userCancelled = false
    private var timeoutTask: Task<Void, Never>?
    private var activityToken: NSObjectProtocol?

    init() {
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

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        if model.running, let v = model.displaySpeed, v > 0 {
            Text("\(model.phase == .upload ? "↑" : "↓")\(Int(v.rounded()))")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        } else {
            Image(systemName: "speedometer")
        }
    }
}

// MARK: - Root view

struct ContentView: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        VStack(spacing: 0) {
            TopStatsView(model: model)
                .padding(.top, 16)
                .padding(.horizontal, 18)
            ZStack {
                GaugeView(model: model)
                centerOverlay
            }
            .frame(height: 248)
            .padding(.top, 4)
            StatusLine(model: model)
            Group {
                if model.running {
                    LiveStatsView(model: model)
                } else if let r = model.lastResult {
                    ResultDetailsView(result: r)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 18)
            Divider().overlay(Color.faintLine)
            FooterView(model: model)
        }
        .frame(width: 320)
        .background(LinearGradient(colors: [.bgTop, .bgBottom], startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(.dark)
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
            case .idle:
                if let r = model.lastResult {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        caption("Last test \(relFormatter.localizedString(for: r.date, relativeTo: Date()))")
                    }
                } else {
                    caption("Ready — hit GO")
                }
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
func activities(for r: TestResult) -> [Activity] {
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

struct ResultDetailsView: View {
    let result: TestResult

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                latStat("PING", fmtLatency(result.idleLatencyMs))
                vDivider
                latStat("LOADED", fmtLatency(result.loadedLatencyMs))
                vDivider
                bloatStat
            }
            if let meta = metaLine {
                Text(meta)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(Color.dimText.opacity(0.85))
                    .lineLimit(1)
            }
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

    private var metaLine: String? {
        var parts: [String] = []
        if let j = result.jitterMs { parts.append("jitter \(fmtLatency(j))") }
        if let l = fmtLoss(result.packetLossPct) { parts.append("loss \(l)") }
        if let s = result.serverName {
            parts.append([s, result.serverLocation].compactMap { $0 }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
                Text(result.bloatMs.map { "+\(fmtLatency($0))" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                if let b = result.bloatMs {
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

// MARK: - Live stats (while a test is running)

struct LiveStatsView: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        HStack(spacing: 0) {
            stat(icon: "clock", color: .accentPing, label: "PING",
                 value: model.livePing.map { fmtLatency($0) } ?? "…")
            Rectangle().fill(Color.faintLine).frame(width: 1, height: 30)
            stat(icon: "waveform.path.ecg", color: .accentRPM, label: "JITTER",
                 value: model.liveJitter.map { fmtLatency($0) } ?? "…")
        }
    }

    private func stat(icon: String, color: Color, label: String, value: String) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
                Text(label).font(.system(size: 8.5, weight: .semibold)).tracking(0.7).foregroundStyle(Color.dimText)
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Footer

struct FooterView: View {
    @ObservedObject var model: SpeedTestModel

    var body: some View {
        HStack {
            Text("Ookla Speedtest CLI")
                .font(.system(size: 10))
                .foregroundStyle(Color.dimText.opacity(0.7))
            Spacer()
            Menu {
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
