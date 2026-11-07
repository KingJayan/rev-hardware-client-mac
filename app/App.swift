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
    var id: String { rawValue }

    var title: String {
        switch self {
        case .driverOS: return "Driver Hub OS"
        case .controlOS: return "Control Hub OS"
        case .firmware: return "Hub Firmware"
        }
    }

    var detail: String {
        switch self {
        case .driverOS: return "Installs the latest operating system. The hub reboots when done."
        case .controlOS: return "Installs the latest operating system. The hub reboots when done."
        case .firmware: return "Updates the firmware of this hub or a connected Expansion Hub."
        }
    }

    static func available(for type: String) -> [Target] {
        switch type {
        case "driver-hub": return [.driverOS]
        case "control-hub": return [.controlOS, .firmware]
        default: return []
        }
    }
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
    let ssidReader = SSIDReader()

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
        guard let d = selected else { return }
        busy = true
        defer { busy = false }
        log = []
        var args = ["update", t.rawValue, "--adb-id", d.id]
        if t == .firmware { args += ["--serial", targetSerial] }
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
    static let bg = Color(white: 0.055)
    static let sidebar = Color(white: 0.075)
    static let panelTop = Color(white: 0.125)
    static let panelBottom = Color(white: 0.095)
    static let raised = Color(white: 0.16)
    static let accent = Color(red: 0.25, green: 0.55, blue: 1.0)

    static func stroke(_ hc: Bool) -> Color { .white.opacity(hc ? 0.4 : 0.08) }
    static func dim(_ hc: Bool) -> Color { .white.opacity(hc ? 0.9 : 0.55) }
}

// raised surface with top highlight
struct Tactile: ViewModifier {
    var radius: CGFloat = 16
    var hc: Bool
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.panelTop, Theme.panelBottom], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        hc ? AnyShapeStyle(Theme.stroke(true))
                           : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom)),
                        lineWidth: hc ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
    }
}

extension View {
    func tactile(_ hc: Bool, radius: CGFloat = 16) -> some View { modifier(Tactile(radius: radius, hc: hc)) }
}

struct PillStyle: ButtonStyle {
    var primary = false
    var reduceMotion = false
    @Environment(\.isEnabled) var enabled

    func makeBody(configuration c: Configuration) -> some View {
        c.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .foregroundStyle(primary ? Color.black : Color.white)
            .background(
                Capsule().fill(primary
                    ? AnyShapeStyle(LinearGradient(colors: [.white, Color(white: 0.84)], startPoint: .top, endPoint: .bottom))
                    : AnyShapeStyle(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)))
            )
            .overlay(Capsule().strokeBorder(.white.opacity(primary ? 0 : 0.12)))
            .shadow(color: .black.opacity(0.5), radius: c.isPressed ? 1 : 4, y: c.isPressed ? 0 : 2)
            .scaleEffect(c.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.12)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.12)))
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
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color(white: 0.13)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }
}

struct IconTile: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color = .white
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: .black.opacity(0.6), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

// views

struct ContentView: View {
    @EnvironmentObject var m: Model
    @EnvironmentObject var prefs: Prefs
    @State private var confirm: Target?
    @State private var logOpen = false
    @State private var showWifi = false

    var hc: Bool { prefs.highContrast }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.stroke(hc)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if showWifi {
                        wifiPage
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
        .alert(item: $confirm) { t in
            Alert(
                title: Text("Install \(t.title)?"),
                message: Text("Keep the hub plugged in and powered until it finishes. Don't run REV Hardware Client at the same time."),
                primaryButton: .default(Text("Install")) { Task { await m.update(t, flash: true) } },
                secondaryButton: .cancel()
            )
        }
    }

    // sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "arrow.down.circle.fill", size: 30, tint: Theme.accent)
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

            Spacer()

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
        let on = m.selected == d && !showWifi
        return Button {
            m.selected = d
            showWifi = false
            Task { await m.loadSubHubs() }
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
        .accessibilityLabel("\(d.name), \(d.id)")
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
        }
    }

    func updateCard(_ t: Target) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(symbol: t == .firmware ? "memorychip" : "shippingbox", size: 40)
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
                    .disabled(t == .firmware && m.targetSerial.isEmpty)
                    .buttonStyle(PillStyle(primary: true, reduceMotion: prefs.reduceMotion))
            }
            .disabled(m.busy)

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
            showWifi = true
            if m.wifi == nil { Task { await m.checkWifi() } }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi")
                    .font(.system(size: 14 * prefs.textScale))
                    .frame(width: 20)
                    .foregroundStyle(showWifi ? .white : Theme.dim(hc))
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(showWifi ? Theme.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(showWifi ? Theme.stroke(hc) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Wi‑Fi")
        .accessibilityAddTraits(showWifi ? .isSelected : [])
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
