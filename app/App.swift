import SwiftUI
import AppKit
import CoreWLAN
import CoreLocation

// models

struct Device: Identifiable, Decodable, Hashable {
    let id: String
    let type: String

    var name: String {
        switch type {
        case "driver-hub": return "Driver Hub"
        case "control-hub": return "Control Hub"
        default: return "Unknown Device"
        }
    }

    var symbol: String {
        switch type {
        case "driver-hub": return "gamecontroller"
        case "control-hub": return "cpu"
        default: return "questionmark.square.dashed"
        }
    }
}

struct SubHub: Identifiable, Decodable, Hashable {
    let serialNumber: String
    let moduleAddress: Int?
    let formattedFirmwareVersionString: String?
    var id: String { serialNumber }

    var label: String {
        serialNumber == "(embedded)" ? "This Control Hub" : "Expansion Hub \(serialNumber)"
    }
}

enum Target: String, CaseIterable, Identifiable {
    case driverOS = "driver-hub-os"
    case controlOS = "control-hub-os"
    case firmware = "hub-firmware"
    case rcApp = "robot-controller-app"
    case dsApp = "driver-station-app"
    case sparkMax = "spark-max-firmware"
    case sparkFlex = "spark-flex-firmware"
    case servoHub = "servo-hub-firmware"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .driverOS: return "Driver Hub OS"
        case .controlOS: return "Control Hub OS"
        case .firmware: return "Hub Firmware"
        case .rcApp: return "Robot Controller App"
        case .dsApp: return "Driver Station App"
        case .sparkMax: return "SPARK MAX"
        case .sparkFlex: return "SPARK Flex"
        case .servoHub: return "Servo Hub"
        }
    }

    var detail: String {
        switch self {
        case .driverOS, .controlOS: return "Installs the latest operating system. The hub reboots when done."
        case .firmware: return "Updates the firmware of this hub or a connected Expansion Hub."
        case .rcApp: return "Installs the latest FTC Robot Controller app and opens it."
        case .dsApp: return "Installs the latest FTC Driver Station app and opens it."
        case .sparkMax, .sparkFlex, .servoHub: return "Flashes the latest firmware over USB recovery (DFU) mode."
        }
    }

    var symbol: String {
        switch self {
        case .driverOS, .controlOS: return "shippingbox"
        case .firmware: return "memorychip"
        case .rcApp, .dsApp: return "app.badge"
        case .sparkMax, .sparkFlex, .servoHub: return "bolt.fill"
        }
    }

    var isDfu: Bool { [.sparkMax, .sparkFlex, .servoHub].contains(self) }

    static func available(for type: String) -> [Target] {
        switch type {
        case "driver-hub": return [.driverOS, .dsApp]
        case "control-hub": return [.controlOS, .rcApp, .firmware]
        default: return []
        }
    }
}

struct UpdateInfo: Decodable, Hashable {
    let target: String
    let installed: String?
    let latest: String
    let updateAvailable: Bool
    let serial: String?
}

struct DeviceInfo: Decodable {
    let id: String
    let type: String
    let serial: String?
    let osVersion: String?
    let android: String?
    let rcReachable: Bool
    let updates: [UpdateInfo]
    var updateCount: Int { updates.filter(\.updateAvailable).count }
}

struct HubSettings: Decodable {
    struct Channel: Decodable, Hashable {
        let name: String
        let displayName: String
        let band: String?
        let overlaps: Bool
    }
    let name: String
    let password: String?
    let channel: String?
    let channels: [Channel]
    let rcVersion: String?
    let activeConfig: String?
}

struct DfuDevice: Decodable, Hashable, Identifiable {
    let serial: String
    let vid: String
    let pid: String
    var id: String { serial }
}

struct ClientVersion: Decodable {
    let current: String
    let latest: String?
    let updateAvailable: Bool
    let url: String
}

enum Page { case device, wifi, dfu }

// last line of output as json
func decodeLast<T: Decodable>(_ t: T.Type, _ out: String) -> T? {
    let json = out.split(separator: "\n").last.map(String.init) ?? ""
    return try? JSONDecoder().decode(t, from: Data(json.utf8))
}

struct Wifi: Decodable {
    struct Ping: Decodable {
        let reachable: Bool
        let lossPercent: Double
        let avgMs: Double?
    }
    let interface: String
    let connected: Bool
    var ssid: String?
    let ssidHidden: Bool
    let ip: String?
    let gateway: String?
    let onRcNetwork: Bool
    let rcAddress: String
    let ping: Ping
    let webServer: Bool
}

// macos only reveals the ssid with location access
final class SSIDReader: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        lm.delegate = self
    }

    var allowed: Bool {
        let s = lm.authorizationStatus
        return s == .authorizedAlways || s == .authorized
    }

    var undecided: Bool { lm.authorizationStatus == .notDetermined }

    func request() { lm.requestWhenInUseAuthorization() }

    func ssid() -> String? { CWWiFiClient.shared().interface()?.ssid() }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { onChange?() }
}

// thread safe string
final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var s = ""
    func add(_ t: String) { lock.lock(); s += t; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return s }
}

// runs node script

enum Runner {
    static let shellPath: String = {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lic", "printf '%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let s = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let extra = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:\(NSHomeDirectory())/Library/Android/sdk/platform-tools"
        return s.isEmpty ? "\(extra):/usr/bin:/bin" : "\(s):\(extra)"
    }()

    static var script: String {
        if let p = Bundle.main.path(forResource: "rev-hardware-client", ofType: "mjs") { return p }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.deletingLastPathComponent().appendingPathComponent("../rev-hardware-client.mjs").path
    }

    // streams lines, returns exit code and full stdout
    static func run(_ args: [String], onLine: @escaping (String) -> Void = { _ in }) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["node", script] + args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = shellPath
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let buf = Buffer()
            let handle: (FileHandle, Bool) -> Void = { h, keep in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                if keep { buf.add(s) }
                for line in s.split(separator: "\n") { onLine(String(line)) }
            }
            out.fileHandleForReading.readabilityHandler = { handle($0, true) }
            err.fileHandleForReading.readabilityHandler = { handle($0, false) }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                buf.add(String(data: rest, encoding: .utf8) ?? "")
                cont.resume(returning: (proc.terminationStatus, buf.text))
            }
            do { try p.run() } catch {
                onLine("Error: could not start node (\(error.localizedDescription))")
                cont.resume(returning: (127, ""))
            }
        }
    }
}

// state

@MainActor
final class Model: ObservableObject {
    @Published var devices: [Device] = []
    @Published var selected: Device?
    @Published var subHubs: [SubHub] = []
    @Published var serial = "(embedded)"
    @Published var log: [String] = []
    @Published var busy = false
    @Published var status: String?
    @Published var failed = false
    @Published var scanned = false
    @Published var discoverError: String?
    @Published var customSerial = ""
    @Published var wifi: Wifi?
    @Published var wifiBusy = false
    @Published var wifiFailed = false
    @Published var infos: [String: DeviceInfo] = [:]
    @Published var hubSettings: HubSettings?
    @Published var settingsError: String?
    @Published var settingsBusy = false
    @Published var dfuDevices: [DfuDevice] = []
    @Published var dfuSerial = ""
    @Published var dfuError: String?
    @Published var dfuScanned = false
    @Published var client: ClientVersion?
    let ssidReader = SSIDReader()

    var info: DeviceInfo? { selected.flatMap { infos[$0.id] } }

    func versions(_ t: Target) -> UpdateInfo? {
        info?.updates.first { u in
            u.target == t.rawValue && (t != .firmware || u.serial == targetSerial)
        }
    }

    var targetSerial: String {
        serial == "custom" ? customSerial.trimmingCharacters(in: .whitespaces) : serial
    }

    init() {
        ssidReader.onChange = { [weak self] in
            Task { @MainActor in self?.fillSSID() }
        }
    }

    func checkWifi() async {
        wifiBusy = true
        defer { wifiBusy = false }
        let (code, out) = await Runner.run(["wifi", "--json"])
        let json = out.split(separator: "\n").last.map(String.init) ?? ""
        if code == 0, let w = try? JSONDecoder().decode(Wifi.self, from: Data(json.utf8)) {
            wifi = w
            wifiFailed = false
            fillSSID()
        } else {
            wifiFailed = true
        }
    }

    func fillSSID() {
        guard wifi != nil, wifi?.ssid == nil, ssidReader.allowed, let n = ssidReader.ssid() else { return }
        wifi?.ssid = n
    }

    func refresh() async {
        busy = true
        defer { busy = false; scanned = true }
        let (code, out) = await Runner.run(["list", "--json"])
        let json = out.split(separator: "\n").last.map(String.init) ?? ""
        if code == 0, let d = try? JSONDecoder().decode([Device].self, from: Data(json.utf8)) {
            devices = d
            if let s = selected, !d.contains(s) { selected = nil }
            if selected == nil { selected = d.first }
        } else {
            devices = []
            setStatus("Couldn't list devices. Check that node and adb are installed.", failed: true)
        }
        await loadSubHubs()
        for d in devices { await loadInfo(d) }
        await loadSettings()
    }

    func select(_ d: Device) async {
        selected = d
        await loadSubHubs()
        if infos[d.id] == nil { await loadInfo(d) }
        await loadSettings()
    }

    func loadInfo(_ d: Device) async {
        let (code, out) = await Runner.run(["info", "--adb-id", d.id, "--json"])
        if code == 0, let i = decodeLast(DeviceInfo.self, out) { infos[d.id] = i }
    }

    func loadSettings() async {
        hubSettings = nil
        settingsError = nil
        guard let d = selected, d.type == "control-hub" else { return }
        settingsBusy = true
        defer { settingsBusy = false }
        let (code, out) = await Runner.run(["settings", "--adb-id", d.id, "--json"])
        if code == 0, let h = decodeLast(HubSettings.self, out) {
            hubSettings = h
        } else {
            settingsError = "Couldn't read hub settings. Is the Robot Controller app running?"
        }
    }

    func applySettings(name: String, password: String, channel: String) async {
        guard let d = selected, let h = hubSettings else { return }
        var args = ["settings", "--adb-id", d.id, "--yes", "--name", name]
        if password != (h.password ?? "") { args += ["--password", password] }
        if !channel.isEmpty && channel != h.channel { args += ["--channel", channel] }
        await runLogged(args, start: "Applying hub settings…", done: "Settings sent. Reconnect to the hub's new network.")
        await loadSettings()
    }

    func saveLogs() async {
        guard let d = selected else { return }
        busy = true
        defer { busy = false }
        log = []
        setStatus("Saving logs…", failed: false)
        let (code, out) = await Runner.run(["logs", "--adb-id", d.id, "--json"]) { [weak self] l in
            Task { @MainActor in if !l.hasPrefix("{") { self?.append(l) } }
        }
        struct R: Decodable { let dir: String; let files: [String] }
        if code == 0, let r = decodeLast(R.self, out) {
            setStatus("Saved \(r.files.count) log files to Downloads.", failed: false)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.dir)])
        } else {
            setStatus(log.last(where: { $0.hasPrefix("Error:") }) ?? "Couldn't save logs.", failed: true)
        }
    }

    func loadDfu() async {
        dfuError = nil
        let (code, out) = await Runner.run(["dfu-list", "--json"]) { [weak self] l in
            Task { @MainActor in if l.hasPrefix("Error:") { self?.dfuError = l } }
        }
        dfuScanned = true
        if code == 0, let d = decodeLast([DfuDevice].self, out) {
            dfuDevices = d
            if !d.contains(where: { $0.serial == dfuSerial }) { dfuSerial = d.first?.serial ?? "" }
        } else {
            dfuDevices = []
            dfuSerial = ""
        }
    }

    func checkClient() async {
        let (code, out) = await Runner.run(["version", "--check", "--json"])
        if code == 0 { client = decodeLast(ClientVersion.self, out) }
    }

    private func runLogged(_ args: [String], start: String, done: String) async {
        busy = true
        defer { busy = false }
        log = []
        setStatus(start, failed: false)
        let (code, _) = await Runner.run(args) { [weak self] l in
            Task { @MainActor in self?.append(l) }
        }
        if code == 0 { setStatus(done, failed: false) }
        else { setStatus(log.last(where: { $0.hasPrefix("Error:") }) ?? "Something went wrong.", failed: true) }
    }

    func loadSubHubs() async {
        subHubs = []
        serial = "(embedded)"
        discoverError = nil
        guard let d = selected, d.type == "control-hub" else { return }
        let (code, out) = await Runner.run(["discover-hubs", "--adb-id", d.id, "--json"])
        let json = out.split(separator: "\n").last.map(String.init) ?? ""
        if code == 0, let h = try? JSONDecoder().decode([SubHub].self, from: Data(json.utf8)) {
            subHubs = h
        } else {
            discoverError = "Couldn't list connected hubs. Is the Robot Controller app running? You can still enter a serial."
        }
    }

    func update(_ t: Target, flash: Bool) async {
        var args = ["update", t.rawValue]
        if t.isDfu {
            guard !dfuSerial.isEmpty else { return }
            args += ["--serial", dfuSerial]
        } else {
            guard let d = selected else { return }
            args += ["--adb-id", d.id]
            if t == .firmware { args += ["--serial", targetSerial] }
        }
        busy = true
        defer { busy = false }
        log = []
        if flash { args.append("--yes") }
        setStatus(flash ? "Updating \(t.title)…" : "Checking \(t.title)…", failed: false)
        let (code, _) = await Runner.run(args) { [weak self] l in
            Task { @MainActor in self?.append(l) }
        }
        if code == 0 {
            let v = log.lazy.compactMap { l -> String? in
                guard let r = l.range(of: ": version ") else { return nil }
                return l[r.upperBound...].split(separator: " ").first.map(String.init)
            }.first
            if flash {
                setStatus("\(t.title)\(v.map { " " + $0 } ?? "") update sent.", failed: false)
                if !t.isDfu, let d = selected { await loadInfo(d) }
            } else {
                setStatus("\(v.map { "Version \($0)" } ?? "The latest version") is downloaded and ready to install. Nothing was sent to the hub.", failed: false)
            }
        } else {
            let msg = log.last(where: { $0.hasPrefix("Error:") }) ?? "Update failed."
            setStatus(msg, failed: true)
        }
    }

    private func append(_ l: String) { log.append(l) }
    private func setStatus(_ s: String, failed f: Bool) { status = s; failed = f }
}

// accessibility settings

final class Prefs: ObservableObject {
    @AppStorage("textScale") var textScale: Double = 1.0
    @AppStorage("highContrast") var highContrast = false
    @AppStorage("reduceMotion") var reduceMotion = false
    @AppStorage("showLog") var showLog = false
}

extension View {
    func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular, prefs: Prefs) -> some View {
        font(.system(size: size * prefs.textScale, weight: prefs.highContrast && weight == .regular ? .medium : weight))
    }
}

// theme

enum Theme {
    static let bg = Color(white: 0.06)
    static let sidebar = Color(white: 0.08)
    static let panel = Color(white: 0.11)
    static let raised = Color(white: 0.15)
    static let control = Color(white: 0.17)
    static let accent = Color(red: 0.25, green: 0.55, blue: 1.0)

    static func stroke(_ hc: Bool) -> Color { .white.opacity(hc ? 0.4 : 0.07) }
    static func dim(_ hc: Bool) -> Color { .white.opacity(hc ? 0.9 : 0.55) }
}

// 1px top edge highlight
struct TopEdge: View {
    var radius: CGFloat
    var opacity: Double = 0.07
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(.white.opacity(opacity), lineWidth: 1)
            .mask(VStack(spacing: 0) { Rectangle().frame(height: 1.5); Spacer(minLength: 0) })
            .allowsHitTesting(false)
    }
}

// flat raised surface
struct Tactile: ViewModifier {
    var radius: CGFloat = 14
    var hc: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.stroke(hc), lineWidth: hc ? 1.5 : 1))
            .overlay(TopEdge(radius: radius))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

extension View {
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, *) { focusEffectDisabled() } else { self }
    }
    func tactile(_ hc: Bool, radius: CGFloat = 14) -> some View { modifier(Tactile(radius: radius, hc: hc)) }
}

struct PillStyle: ButtonStyle {
    var primary = false
    var reduceMotion = false
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(primary ? Color.black : Color.white.opacity(0.92))
            .background(Capsule().fill(primary
                ? Color(white: c.isPressed ? 0.82 : 0.94)
                : Color(white: c.isPressed ? 0.14 : 0.18)))
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.08)))
            .shadow(color: .black.opacity(0.3), radius: c.isPressed ? 0 : 2, y: c.isPressed ? 0 : 1)
            .scaleEffect(c.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

struct Chip: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.65))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct IconTile: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color = .white
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.control))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.06)))
            .overlay(TopEdge(radius: size * 0.26, opacity: 0.1))
            .accessibilityHidden(true)
    }
}

struct Logo: View {
    var size: CGFloat = 30
    var body: some View {
        if let p = Bundle.main.path(forResource: "logo", ofType: "png"), let img = NSImage(contentsOfFile: p) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                .accessibilityLabel("REV logo")
        } else {
            IconTile(symbol: "arrow.down.circle.fill", size: size, tint: Theme.accent)
        }
    }
}

// views

struct ContentView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var prefs: Prefs
    @State private var confirm: Target?
    @State private var logOpen = false
    @State private var page: Page = .device
    @State private var editName = ""
    @State private var editPassword = ""
    @State private var editChannel = ""
    @State private var showPassword = false
    @State private var confirmSettings = false

    var hc: Bool { prefs.highContrast }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke(hc)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if page == .wifi {
                        wifiPage
                    } else if page == .dfu {
                        dfuPage
                        if let s = m.status { statusCard(s) }
                        logCard
                    } else {
                        if let d = m.selected {
                            deviceHeader(d)
                            actions(d)
                        } else {
                            empty
                        }
                        if let s = m.status { statusCard(s) }
                        logCard
                    }
                }
                .padding(.horizontal, 36)
                .padding(.top, 44)
                .padding(.bottom, 36)
                .frame(maxWidth: 720, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
        }
        .frame(minWidth: 780, minHeight: 560)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .task { logOpen = prefs.showLog; await m.refresh() }
        .task { await m.checkClient() }
        .onChange(of: m.hubSettings?.name) { _ in
            editName = m.hubSettings?.name ?? ""
            editPassword = m.hubSettings?.password ?? ""
            editChannel = m.hubSettings?.channel ?? ""
        }
        .alert(item: $confirm) { t in
            Alert(
                title: Text("Install \(t.title)?"),
                message: Text(t.isDfu
                    ? "Keep the device plugged in until it finishes. Make sure it's really a \(t.title)."
                    : "Keep the hub plugged in and powered until it finishes. Don't run REV Hardware Client at the same time."),
                primaryButton: .default(Text("Install")) { Task { await m.update(t, flash: true) } },
                secondaryButton: .cancel()
            )
        }
    }

    // sidebar

    var sidebar: some View {
        sidebarBody.noFocusRing()
    }

    var sidebarBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Logo(size: 30)
                Text("Hub Updater").scaled(15, .semibold, prefs: prefs)
            }
            .padding(.top, 40)
            .padding(.horizontal, 16)
            .padding(.bottom, 22)

            HStack {
                Text("DEVICES").scaled(11, .semibold, prefs: prefs)
                    .foregroundStyle(Theme.dim(hc)).tracking(0.6)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if m.busy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            VStack(spacing: 2) {
                ForEach(m.devices) { d in sideRow(d) }
                if m.devices.isEmpty {
                    Text(m.scanned ? "No hubs connected" : "Looking…")
                        .scaled(13, prefs: prefs)
                        .foregroundStyle(Theme.dim(hc))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 8)

            Text("NETWORK").scaled(11, .semibold, prefs: prefs)
                .foregroundStyle(Theme.dim(hc)).tracking(0.6)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 8)

            wifiRow.padding(.horizontal, 8)

            Text("RECOVERY").scaled(11, .semibold, prefs: prefs)
                .foregroundStyle(Theme.dim(hc)).tracking(0.6)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 8)

            navRow("SPARK & Servo Hub", m.dfuScanned ? "\(m.dfuDevices.count) in DFU mode" : "USB firmware", "bolt.fill", .dfu) {
                Task { await m.loadDfu() }
            }
            .padding(.horizontal, 8)

            Spacer()

            if let c = m.client, c.updateAvailable, let u = URL(string: c.url) {
                Button { NSWorkspace.shared.open(u) } label: {
                    Label("Version \(c.latest ?? "") available", systemImage: "arrow.down.circle.fill")
                        .scaled(12, .medium, prefs: prefs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 20)
                .help("Open the release page for this app")
            }

            Button {
                Task { await m.refresh() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Refresh")
                    Spacer()
                    Keycap(text: "⌘R")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
            .keyboardShortcut("r")
            .disabled(m.busy)
            .padding(12)
            .help("Look for connected hubs")
        }
        .frame(width: 230)
        .background(Theme.sidebar)
    }

    func sideRow(_ d: Device) -> some View {
        let on = m.selected == d && page == .device
        let n = m.infos[d.id]?.updateCount ?? 0
        return Button {
            page = .device
            Task { await m.select(d) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: d.symbol)
                    .font(.system(size: 14 * prefs.textScale))
                    .frame(width: 20)
                    .foregroundStyle(on ? .white : Theme.dim(hc))
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name).scaled(13, .medium, prefs: prefs)
                    Text(d.id).scaled(11, prefs: prefs).monospaced()
                        .foregroundStyle(Theme.dim(hc)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if n > 0 {
                    Text("\(n)")
                        .font(.system(size: 10 * prefs.textScale, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.accent))
                        .help("\(n) update\(n == 1 ? "" : "s") available")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? Theme.raised : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(on ? Theme.stroke(hc) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(m.busy)
        .accessibilityLabel("\(d.name), \(d.id)\(n > 0 ? ", \(n) updates available" : "")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // main

    var empty: some View {
        VStack(spacing: 16) {
            IconTile(symbol: "cable.connector", size: 64)
            Text(m.scanned ? "No hubs connected" : "Looking for hubs…").scaled(20, .semibold, prefs: prefs)
            Text("Plug a Driver Hub or Control Hub into this Mac over USB, then press Refresh.")
                .scaled(13, prefs: prefs)
                .foregroundStyle(Theme.dim(hc))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
        .tactile(hc, radius: 20)
    }

    func deviceHeader(_ d: Device) -> some View {
        HStack(spacing: 16) {
            IconTile(symbol: d.symbol, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                Text(d.name).scaled(26, .bold, prefs: prefs)
                HStack(spacing: 6) {
                    Chip(symbol: "number", text: d.id)
                    Chip(symbol: "cable.connector", text: "USB")
                    if d.type == "control-hub" && !m.subHubs.isEmpty {
                        Chip(symbol: "square.stack.3d.up", text: "\(m.subHubs.count) hub\(m.subHubs.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    func actions(_ d: Device) -> some View {
        let targets = Target.available(for: d.type)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Updates").scaled(15, .semibold, prefs: prefs).accessibilityAddTraits(.isHeader)
            if targets.isEmpty {
                Text("This device isn't a recognized REV hub.")
                    .scaled(13, prefs: prefs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .tactile(hc)
            }
            ForEach(targets) { t in updateCard(t) }
            if d.type == "control-hub" { settingsCard }
            if d.type != "unknown" { diagnosticsCard }
        }
    }

    func versionLine(_ t: Target) -> some View {
        Group {
            if let v = m.versions(t) {
                HStack(spacing: 6) {
                    Chip(symbol: "checkmark.seal", text: "Installed \(v.installed ?? "none")")
                    Chip(symbol: "arrow.down.circle", text: "Latest \(v.latest)")
                    if v.updateAvailable {
                        Text("Update available").scaled(11, .semibold, prefs: prefs)
                            .foregroundStyle(Theme.accent)
                    }
                }
            } else if t == .firmware, m.info?.rcReachable == false {
                Text("Installed version unknown while the Robot Controller app isn't running.")
                    .scaled(11, prefs: prefs).foregroundStyle(Theme.dim(hc))
            }
        }
    }

    func sectionTitle(_ s: String) -> some View {
        Text(s).scaled(15, .semibold, prefs: prefs).accessibilityAddTraits(.isHeader).padding(.top, 10)
    }

    var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Hub settings")
            VStack(alignment: .leading, spacing: 14) {
                if let e = m.settingsError {
                    HStack {
                        Label(e, systemImage: "exclamationmark.triangle.fill")
                            .scaled(12, prefs: prefs).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try again") { Task { await m.loadSettings() } }
                            .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                    }
                } else if let h = m.hubSettings {
                    field("Name") {
                        TextField("Hub name", text: $editName).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Hub name")
                    }
                    field("Wi‑Fi password") {
                        HStack {
                            Group {
                                if showPassword { TextField("Password", text: $editPassword) }
                                else { SecureField("Password", text: $editPassword) }
                            }
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Wi‑Fi password")
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                        }
                    }
                    field("Channel") {
                        Picker("Channel", selection: $editChannel) {
                            if h.channel == nil { Text("Current").tag("") }
                            ForEach(h.channels.filter { !$0.overlaps || $0.name == h.channel }, id: \.name) { c in
                                Text(c.displayName).tag(c.name)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if let e = settingsProblem {
                        Text(e).scaled(11, prefs: prefs).foregroundStyle(.orange)
                    }
                    HStack {
                        Text("The hub restarts its Wi‑Fi after saving. Devices on it disconnect.")
                            .scaled(11, prefs: prefs).foregroundStyle(Theme.dim(hc))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Save") { confirmSettings = true }
                            .buttonStyle(PillStyle(primary: true, reduceMotion: prefs.reduceMotion))
                            .disabled(settingsProblem != nil || !settingsChanged || m.busy)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading settings…").scaled(12, prefs: prefs).foregroundStyle(Theme.dim(hc))
                    }
                }
            }
            .padding(18)
            .tactile(hc)
            .alert("Save hub settings?", isPresented: $confirmSettings) {
                Button("Save") {
                    Task { await m.applySettings(name: editName.trimmingCharacters(in: .whitespaces), password: editPassword, channel: editChannel) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The hub's Wi‑Fi network restarts. Phones and laptops connected to it will need to reconnect.")
            }
        }
    }

    var settingsChanged: Bool {
        guard let h = m.hubSettings else { return false }
        return editName.trimmingCharacters(in: .whitespaces) != h.name
            || editPassword != (h.password ?? "")
            || (!editChannel.isEmpty && editChannel != h.channel)
    }

    // same rules as the hub's manage page
    var settingsProblem: String? {
        let n = editName.trimmingCharacters(in: .whitespaces)
        if n.count < 2 || n.count > 32 { return "Name must be 2 to 32 characters." }
        if n.contains(where: \.isWhitespace) { return "Name can't contain spaces." }
        if editPassword != (m.hubSettings?.password ?? "") && (editPassword.count < 8 || editPassword.count > 63) {
            return "Password must be 8 to 63 characters."
        }
        return nil
    }

    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack {
            Text(label).scaled(13, prefs: prefs).foregroundStyle(Theme.dim(hc)).frame(width: 110, alignment: .leading)
            c()
        }
    }

    var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Diagnostics")
            VStack(alignment: .leading, spacing: 14) {
                let i = m.info
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], alignment: .leading, spacing: 10) {
                    info("Serial", i?.serial)
                    info("OS", i?.osVersion)
                    info("Android", i?.android)
                    if m.selected?.type == "control-hub" {
                        info("RC app", i?.rcReachable == true ? "Running" : "Not reachable")
                        if let h = m.hubSettings {
                            info("Active config", h.activeConfig)
                        }
                    }
                }
                Divider().overlay(Theme.stroke(hc))
                HStack {
                    Text("Saves Robot Controller, Driver Station, updater and Wi‑Fi logs, match logs and logcat to Downloads.")
                        .scaled(11, prefs: prefs).foregroundStyle(Theme.dim(hc))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Save logs") { Task { await m.saveLogs() } }
                        .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                        .disabled(m.busy)
                }
            }
            .padding(18)
            .tactile(hc)
        }
    }

    func info(_ k: String, _ v: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).scaled(11, .medium, prefs: prefs).foregroundStyle(Theme.dim(hc))
            Text(v ?? "—").scaled(13, .medium, prefs: prefs).monospaced().textSelection(.enabled).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // dfu

    func navRow(_ title: String, _ sub: String, _ symbol: String, _ p: Page, onOpen: @escaping () -> Void) -> some View {
        let on = page == p
        return Button {
            page = p
            onOpen()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14 * prefs.textScale))
                    .frame(width: 20)
                    .foregroundStyle(on ? .white : Theme.dim(hc))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaled(13, .medium, prefs: prefs)
                    Text(sub).scaled(11, prefs: prefs).foregroundStyle(Theme.dim(hc)).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Theme.stroke(hc) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    var dfuPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                IconTile(symbol: "bolt.fill", size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text("SPARK & Servo Hub").scaled(26, .bold, prefs: prefs)
                    HStack(spacing: 6) {
                        Chip(symbol: "cable.connector", text: "USB DFU")
                        Chip(symbol: "number", text: m.dfuSerial.isEmpty ? "No device" : m.dfuSerial)
                    }
                }
                Spacer()
                Button("Scan") { Task { await m.loadDfu() } }
                    .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                    .disabled(m.busy)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Put the device in recovery mode", systemImage: "info.circle")
                    .scaled(13, .semibold, prefs: prefs)
                Text("Unplug it, hold its mode button, plug it into this Mac over USB, then release. Press Scan. Pick the matching product below; the wrong firmware won't run.")
                    .scaled(12, prefs: prefs).foregroundStyle(Theme.dim(hc))
                    .fixedSize(horizontal: false, vertical: true)
                if let e = m.dfuError {
                    Label(e.replacingOccurrences(of: "Error: ", with: ""), systemImage: "exclamationmark.triangle.fill")
                        .scaled(12, prefs: prefs).foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if m.dfuDevices.count > 1 {
                    Picker("Device", selection: $m.dfuSerial) {
                        ForEach(m.dfuDevices) { d in Text(d.serial).tag(d.serial) }
                    }
                    .fixedSize()
                } else if m.dfuScanned && m.dfuDevices.isEmpty {
                    Text("No device in DFU mode found.").scaled(12, .medium, prefs: prefs).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .tactile(hc)

            VStack(alignment: .leading, spacing: 12) {
                ForEach([Target.sparkMax, .sparkFlex, .servoHub]) { t in updateCard(t) }
            }
        }
    }

    func updateCard(_ t: Target) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: t.symbol, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).scaled(15, .semibold, prefs: prefs)
                    Text(t.detail).scaled(12, prefs: prefs)
                        .foregroundStyle(Theme.dim(hc))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button("Check") { Task { await m.update(t, flash: false) } }
                    .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                    .help("Download and verify without touching the hub")
                Button("Install") { confirm = t }
                    .disabled((t == .firmware && m.targetSerial.isEmpty) || (t.isDfu && m.dfuSerial.isEmpty))
                    .buttonStyle(PillStyle(primary: true, reduceMotion: prefs.reduceMotion))
            }
            .disabled(m.busy)

            versionLine(t)

            if t == .firmware {
                Divider().overlay(Theme.stroke(hc))
                HStack {
                    Text("Target").scaled(13, prefs: prefs).foregroundStyle(Theme.dim(hc))
                    Spacer()
                    Picker("Target", selection: $m.serial) {
                        Text("This Control Hub").tag("(embedded)")
                        ForEach(m.subHubs.filter { $0.serialNumber != "(embedded)" }) { h in
                            Text(h.label + (h.formattedFirmwareVersionString.map { " · \($0)" } ?? "")).tag(h.serialNumber)
                        }
                        Divider()
                        Text("Other serial…").tag("custom")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(m.busy)
                }
                if m.serial == "custom" {
                    TextField("Expansion Hub serial, e.g. DQ2ABCDE", text: $m.customSerial)
                        .textFieldStyle(.roundedBorder)
                        .scaled(13, prefs: prefs)
                        .accessibilityLabel("Expansion Hub serial")
                }
                if let e = m.discoverError {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .scaled(12, prefs: prefs)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .tactile(hc)
    }

    // wifi

    var wifiRow: some View {
        Button {
            page = .wifi
            if m.wifi == nil { Task { await m.checkWifi() } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.system(size: 14 * prefs.textScale))
                    .frame(width: 20)
                    .foregroundStyle(page == .wifi ? .white : Theme.dim(hc))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Wi‑Fi").scaled(13, .medium, prefs: prefs)
                    Text(m.wifi.map { $0.onRcNetwork ? "Robot Controller" : ($0.connected ? "Not an RC network" : "Not connected") } ?? "Check connection")
                        .scaled(11, prefs: prefs)
                        .foregroundStyle(Theme.dim(hc)).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let w = m.wifi {
                    Circle().fill(w.onRcNetwork && w.ping.reachable ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(page == .wifi ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(page == .wifi ? Theme.stroke(hc) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wi‑Fi")
        .accessibilityAddTraits(page == .wifi ? .isSelected : [])
    }

    var wifiPage: some View {
        let w = m.wifi
        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                IconTile(symbol: w?.connected == false ? "wifi.slash" : "wifi", size: 56,
                         tint: w.map { $0.onRcNetwork ? Theme.accent : .white } ?? .white)
                VStack(alignment: .leading, spacing: 6) {
                    Text(w?.ssid ?? "Wi‑Fi").scaled(26, .bold, prefs: prefs)
                    HStack(spacing: 6) {
                        if let w {
                            Chip(symbol: w.onRcNetwork ? "checkmark.circle" : "xmark.circle",
                                 text: w.onRcNetwork ? "RC network" : "Not RC network")
                            Chip(symbol: "network", text: w.interface)
                        } else {
                            Chip(symbol: "hourglass", text: m.wifiBusy ? "Checking" : "Not checked")
                        }
                    }
                }
                Spacer()
                Button {
                    Task { await m.checkWifi() }
                } label: {
                    HStack(spacing: 6) {
                        if m.wifiBusy { ProgressView().controlSize(.mini) }
                        Text(m.wifiBusy ? "Checking" : "Check again")
                    }
                }
                .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                .disabled(m.wifiBusy)
            }

            if m.wifiFailed {
                Label("Couldn't read Wi‑Fi info. Check that node is installed.", systemImage: "exclamationmark.triangle.fill")
                    .scaled(13, prefs: prefs).foregroundStyle(.orange)
            }

            if let w {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    stat("Ping \(w.rcAddress)", w.ping.reachable ? "\(Int((w.ping.avgMs ?? 0).rounded())) ms" : "No reply",
                         w.ping.reachable ? "\(Int(w.ping.lossPercent))% packet loss" : "Hub not reachable", "dot.radiowaves.left.and.right", w.ping.reachable)
                    stat("RC web server", w.webServer ? "Up" : "Down",
                         w.webServer ? "Port 8080 answering" : "Robot Controller app may be closed", "server.rack", w.webServer)
                    stat("This Mac", w.ip ?? "No address", "IP address", "laptopcomputer", w.connected)
                    stat("Gateway", w.gateway ?? "None", w.onRcNetwork ? "Robot Controller" : "Router", "point.3.connected.trianglepath.dotted", w.onRcNetwork)
                }

                HStack(spacing: 10) {
                    if w.ssid == nil && w.ssidHidden {
                        Button(m.ssidReader.undecided ? "Show network name" : "Allow location in Settings") {
                            if m.ssidReader.undecided {
                                m.ssidReader.request()
                            } else if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
                                NSWorkspace.shared.open(u)
                            }
                        }
                        .buttonStyle(PillStyle(reduceMotion: prefs.reduceMotion))
                        .help("macOS only shares Wi‑Fi names with apps that have location access")
                    }
                    if w.webServer, let u = URL(string: "http://\(w.rcAddress):8080") {
                        Button("Open Robot Controller page") { NSWorkspace.shared.open(u) }
                            .buttonStyle(PillStyle(primary: true, reduceMotion: prefs.reduceMotion))
                    }
                }

                if !w.onRcNetwork {
                    Text("To connect, join the hub's Wi‑Fi network (usually named after the team, ending in -RC) from the menu bar.")
                        .scaled(12, prefs: prefs)
                        .foregroundStyle(Theme.dim(hc))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func stat(_ title: String, _ value: String, _ sub: String, _ symbol: String, _ ok: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(symbol: symbol, size: 34, tint: ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaled(11, .medium, prefs: prefs).foregroundStyle(Theme.dim(hc))
                Text(value).scaled(17, .semibold, prefs: prefs).monospacedDigit().textSelection(.enabled)
                Text(sub).scaled(11, prefs: prefs).foregroundStyle(Theme.dim(hc))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tactile(hc, radius: 14)
        .accessibilityElement(children: .combine)
    }

    func statusCard(_ s: String) -> some View {
        HStack(spacing: 12) {
            if m.busy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: m.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(m.failed ? .orange : .green)
                    .accessibilityHidden(true)
            }
            Text(s).scaled(13, .medium, prefs: prefs).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .tactile(hc, radius: 12)
        .accessibilityElement(children: .combine)
    }

    var logCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if prefs.reduceMotion { logOpen.toggle() } else { withAnimation(.snappy) { logOpen.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(logOpen ? 90 : 0))
                    Text("Details").scaled(13, .medium, prefs: prefs)
                    Spacer()
                }
                .foregroundStyle(Theme.dim(hc))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(logOpen ? "expanded" : "collapsed")

            if logOpen {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if m.log.isEmpty { Text("Nothing yet.").foregroundStyle(Theme.dim(hc)) }
                            ForEach(Array(m.log.enumerated()), id: \.offset) { i, l in
                                Text(l).id(i)
                            }
                        }
                        .font(.system(size: 11 * prefs.textScale, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                    .frame(height: 170)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.6)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke(hc)))
                    .onChange(of: m.log.count) { n in proxy.scrollTo(n - 1) }
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                LabeledContent("Text size") {
                    HStack {
                        Image(systemName: "textformat.size.smaller").accessibilityHidden(true)
                        Slider(value: $prefs.textScale, in: 0.85...1.6, step: 0.05)
                            .accessibilityLabel("Text size")
                            .accessibilityValue("\(Int(prefs.textScale * 100)) percent")
                        Image(systemName: "textformat.size.larger").accessibilityHidden(true)
                    }
                }
                Toggle("Increase contrast", isOn: $prefs.highContrast)
                Toggle("Reduce motion", isOn: $prefs.reduceMotion)
                Toggle("Show details by default", isOn: $prefs.showLog)
            }
            Section {
                Button("Reset to defaults") {
                    prefs.textScale = 1; prefs.highContrast = false
                    prefs.reduceMotion = false; prefs.showLog = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
        .preferredColorScheme(.dark)
    }
}

@main
struct RevHubUpdaterApp: App {
    @StateObject private var model = Model()
    @StateObject private var prefs = Prefs()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(prefs)
                .transaction { if prefs.reduceMotion { $0.animation = nil } }
                .ignoresSafeArea()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        Settings {
            SettingsView().environmentObject(prefs)
        }
    }
}
