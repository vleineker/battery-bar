// BatteryBar — menu bar battery monitor for a Logitech mouse (USB receiver, HID++ 2.0)
// and a Sony WH-1000XM4 headphone (Bluetooth, via `pmset -g accps`).
//
// Battery is read-only. The only writes to the mouse are DPI and the onboard/host mode switch.

import AppKit
import IOKit.hid
import IOKit.ps
import ServiceManagement

// MARK: - Battery reading model

struct BatteryReading {
    var connected: Bool
    var percent: Int?
    var charging: Bool
    var raw: String
}

// MARK: - Logitech mouse (HID++ 2.0 over USB receiver)

enum LogitechReader {
    static let vendorID = 0x046d
    static let usagePage = 0xFF00

    // Reference type so the HID input-report callback and the polling loop below
    // both mutate the same storage via property access — never via an `inout`
    // binding, which the Swift runtime flags as an exclusivity conflict when the
    // callback fires re-entrantly during CFRunLoopRunInMode.
    final class ReplyBox { var replies: [[UInt8]] = [] }

    /// Sends one HID++ request and waits (bounded) for the matching reply.
    /// Returns nil on timeout, missing device, or protocol error.
    private static func ask(
        device: IOHIDDevice,
        box: ReplyBox,
        idx: UInt8,
        feat: UInt8,
        fn: UInt8,
        params: [UInt8] = [],
        timeout: TimeInterval = 1.0
    ) -> [UInt8]? {
        var msg: [UInt8] = [0x11, idx, feat, (fn << 4) | 0x0B] + params
        msg += [UInt8](repeating: 0, count: max(0, 20 - msg.count))
        box.replies.removeAll()
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0x11, msg, msg.count)
        if result != kIOReturnSuccess { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.05, true)
            for reply in box.replies where reply.count >= 4 && reply[1] == idx {
                if reply[2] == feat && reply[3] == msg[3] { return reply }
                if reply[2] == 0xFF || reply[2] == 0x8F { return nil } // HID++ error reply
            }
        }
        return nil
    }

    /// Opens the receiver's HID collection, wires up the input-report callback, and
    /// hands the caller an `askLocal` closure good for the lifetime of `body`.
    /// Centralizing open/schedule/close here is what let us add the DPI probe
    /// without duplicating the IOHIDManager/callback boilerplate a second time.
    private static func withSession<T>(_ body: (_ askLocal: (UInt8, UInt8, UInt8, [UInt8]) -> [UInt8]?) -> T?) -> T? {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(mgr, [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDPrimaryUsagePageKey: usagePage
        ] as CFDictionary)
        IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) }

        guard let deviceSet = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice>,
              let device = deviceSet.first else { return nil }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }

        let bufSize = 64
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        let box = ReplyBox()
        let context = Unmanaged.passUnretained(box).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufSize, { ctx, _, _, _, _, report, length in
            guard let ctx = ctx else { return }
            let box = Unmanaged<ReplyBox>.fromOpaque(ctx).takeUnretainedValue()
            box.replies.append(Array(UnsafeBufferPointer(start: report, count: length)))
        }, context)
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) }

        return body { idx, feat, fn, params in ask(device: device, box: box, idx: idx, feat: feat, fn: fn, params: params) }
    }

    /// Discovers device index + feature index at every call — never hardcoded,
    /// because the receiver can renumber devices across reconnects.
    static func read() -> BatteryReading {
        withSession { askLocal in
            for idx: UInt8 in [0x01, 0x02] {
                // Unified battery (0x1004), function 1 at the discovered feature index.
                if let root = askLocal(idx, 0x00, 0, [0x10, 0x04]), root.count > 4, root[4] != 0 {
                    let featIdx = root[4]
                    if let reply = askLocal(idx, featIdx, 1, []), reply.count > 6 {
                        let percent = Int(reply[4])
                        let state = reply[6]
                        let charging = state == 1 || state == 2
                        let raw = reply.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                        return BatteryReading(connected: true, percent: percent, charging: charging, raw: "idx=\(idx) feat=0x1004 raw=\(raw)")
                    }
                }
                // Fallback: battery status (0x1000), function 0.
                if let root = askLocal(idx, 0x00, 0, [0x10, 0x00]), root.count > 4, root[4] != 0 {
                    let featIdx = root[4]
                    if let reply = askLocal(idx, featIdx, 0, []), reply.count > 4 {
                        let percent = Int(reply[4])
                        let raw = reply.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                        return BatteryReading(connected: true, percent: percent, charging: false, raw: "idx=\(idx) feat=0x1000 raw=\(raw)")
                    }
                }
            }
            return BatteryReading(connected: false, percent: nil, charging: false, raw: "no response (mouse asleep or off)")
        } ?? BatteryReading(connected: false, percent: nil, charging: false, raw: "no Logitech HID collection found")
    }

    // MARK: DPI (feature 0x2202) and onboard-profile mode (feature 0x8100)
    //
    // Verified on a PRO X 2. 0x2202 fn5 reply: sensor, dpiX(2), defaultX(2), dpiY(2), defaultY(2), lod.
    // fn6 params: sensor, dpiX(2), dpiY(2), lod. The mouse rejects fn6 (error 5) while it obeys its
    // onboard profile, so setting DPI first switches it to host mode (0x8100 fn1 = 2; 1 = onboard).

    struct DPIState { var current: Int; var hostMode: Bool }

    private typealias Ask = (UInt8, UInt8, UInt8, [UInt8]) -> [UInt8]?
    private typealias DPIFeatures = (idx: UInt8, dpi: UInt8, onboard: UInt8)

    private static func dpiFeatures(_ ask: Ask) -> DPIFeatures? {
        for idx: UInt8 in [0x01, 0x02] {
            guard let d = ask(idx, 0x00, 0, [0x22, 0x02]), d.count > 4, d[4] != 0,
                  let o = ask(idx, 0x00, 0, [0x81, 0x00]), o.count > 4, o[4] != 0 else { continue }
            return (idx, d[4], o[4])
        }
        return nil
    }

    private static func dpiState(_ ask: Ask, _ f: DPIFeatures) -> (state: DPIState, lod: UInt8)? {
        guard let p = ask(f.idx, f.dpi, 5, [0x00]), p.count > 13,
              let m = ask(f.idx, f.onboard, 2, []), m.count > 4 else { return nil }
        return (DPIState(current: Int(p[5]) << 8 | Int(p[6]), hostMode: m[4] == 0x02), p[13])
    }

    static func readDPI() -> DPIState? {
        withSession { ask in dpiFeatures(ask).flatMap { dpiState(ask, $0)?.state } }
    }

    /// Switches the mouse to host mode if needed, sets X and Y DPI, and returns the state read back.
    static func setDPI(_ value: Int) -> DPIState? {
        withSession { ask in
            guard let f = dpiFeatures(ask), let before = dpiState(ask, f) else { return nil }
            if !before.state.hostMode { _ = ask(f.idx, f.onboard, 1, [0x02]) }
            let hi = UInt8(value >> 8), lo = UInt8(value & 0xFF)
            _ = ask(f.idx, f.dpi, 6, [0x00, hi, lo, hi, lo, before.lod])
            return dpiState(ask, f)?.state
        }
    }

    /// Hands control back to the profile stored in the mouse.
    static func useOnboardProfile() -> DPIState? {
        withSession { ask in
            guard let f = dpiFeatures(ask) else { return nil }
            _ = ask(f.idx, f.onboard, 1, [0x01])
            return dpiState(ask, f)?.state
        }
    }
}

// MARK: - Sony WH-1000XM4 (Bluetooth, via pmset)
//
// Verified against this machine: `pmset -g accps` reports the headphone as a
// non-internal power source named "-WH-1000XM4 (id=...)" with a current-capacity
// percentage and a discharging flag. IOPSCopyPowerSourcesInfo/List expose the same
// data that backs `pmset`, without shelling out and without touching
// IOBluetoothDevice (which crashed this process when tried).

enum SonyReader {
    static let nameHint = "WH-1000XM4"

    static func read() -> BatteryReading {
        // The public IOPSCopyPowerSourcesList omits accessories; `pmset -g accps` lists them.
        // Line format: " -WH-1000XM4 (id=123)\t70%; discharging present: true"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g", "accps"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else {
            return BatteryReading(connected: false, percent: nil, charging: false, raw: "pmset failed to run")
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()
        for line in output.split(separator: "\n") where line.contains(nameHint) {
            let fields = line.split(separator: "\t").last.map(String.init) ?? ""
            let percent = Int(fields.prefix { $0.isNumber })
            let charging = fields.contains("; charging") || fields.contains("; charged")
            return BatteryReading(connected: true, percent: percent, charging: charging, raw: line.trimmingCharacters(in: .whitespaces))
        }
        return BatteryReading(connected: false, percent: nil, charging: false, raw: "no \"\(nameHint)\" line in pmset -g accps (disconnected)")
    }
}

// MARK: - CLI mode (--list)

let args = CommandLine.arguments

func dpiLine(_ s: LogitechReader.DPIState?) -> String {
    guard let s = s else { return "mouse-dpi: sem resposta" }
    return "mouse-dpi: \(s.current) mode=\(s.hostMode ? "host" : "onboard")"
}

if let i = args.firstIndex(of: "--set-dpi") {
    guard args.count > i + 1, let value = Int(args[i + 1]), (100...6400).contains(value) else {
        print("uso: --set-dpi <100-6400>"); exit(1)
    }
    print(dpiLine(LogitechReader.setDPI(value))); exit(0)
}

if args.contains("--onboard") { print(dpiLine(LogitechReader.useOnboardProfile())); exit(0) }

if args.contains("--list") {
    func line(_ label: String, _ r: BatteryReading) {
        let pct = r.percent.map { "\($0)%" } ?? "sem leitura"
        print("\(label): connected=\(r.connected) percent=\(pct) charging=\(r.charging) raw=\"\(r.raw)\"")
    }
    line("mouse-logitech", LogitechReader.read())
    line("headphone-sony-wh1000xm4", SonyReader.read())
    print(dpiLine(LogitechReader.readDPI()))
    exit(0)
}

// MARK: - Menu bar app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var mouseReading = BatteryReading(connected: false, percent: nil, charging: false, raw: "")
    private var sonyReading = BatteryReading(connected: false, percent: nil, charging: false, raw: "")
    private var dpiState: LogitechReader.DPIState?
    private let hidQueue = DispatchQueue(label: "batterybar.hid")
    private let presets = [400, 800, 1200, 1600, 2400, 3200]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func refresh() { run { nil } }

    /// Runs an optional DPI change, then re-reads everything; serialized and off the main thread.
    private func run(_ change: @escaping () -> LogitechReader.DPIState?) {
        hidQueue.async { [weak self] in
            _ = change()
            let mouse = LogitechReader.read()
            var dpi = LogitechReader.readDPI()
            // The mouse may fall back to its onboard profile after a power cycle: re-apply the chosen DPI.
            let saved = UserDefaults.standard.integer(forKey: "dpi")
            if saved > 0, let d = dpi, d.current != saved || !d.hostMode { dpi = LogitechReader.setDPI(saved) }
            let sony = SonyReader.read()
            DispatchQueue.main.async {
                self?.mouseReading = mouse
                self?.sonyReading = sony
                self?.dpiState = dpi
                self?.updateTitle()
                self?.updateMenu()
            }
        }
    }

    // color nil = template image: the menu bar tints it like every other status icon.
    // A fixed .labelColor is 85% opaque and resolves outside the bar's appearance, so it looked dimmer.
    private func symbol(_ name: String, color: NSColor?) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let color = color { config = config.applying(.init(paletteColors: [color])) }
        let image = base.withSymbolConfiguration(config)
        image?.isTemplate = (color == nil)
        return image
    }

    private func segment(symbolName: String, reading: BatteryReading) -> NSAttributedString? {
        guard let percent = reading.percent else { return nil }
        let color: NSColor? = percent <= 15 ? .systemRed : nil
        let result = NSMutableAttributedString()
        if let img = symbol(symbolName, color: color) {
            let attachment = NSTextAttachment()
            attachment.image = img
            result.append(NSAttributedString(attachment: attachment))
        }
        result.append(NSAttributedString(string: " \(percent)%", attributes: color.map { [.foregroundColor: $0] } ?? [:]))
        if reading.charging, let bolt = symbol("bolt.fill", color: .systemYellow) {
            let attachment = NSTextAttachment()
            attachment.image = bolt
            result.append(NSAttributedString(string: " "))
            result.append(NSAttributedString(attachment: attachment))
        }
        return result
    }

    private func updateTitle() {
        let title = NSMutableAttributedString()
        let mouseSeg = segment(symbolName: "computermouse.fill", reading: mouseReading)
        let sonySeg = segment(symbolName: "headphones", reading: sonyReading)
        if mouseSeg == nil && sonySeg == nil {
            if let fallback = symbol("battery.0", color: nil) {
                let attachment = NSTextAttachment()
                attachment.image = fallback
                title.append(NSAttributedString(attachment: attachment))
            } else {
                title.append(NSAttributedString(string: "--"))
            }
        } else {
            if let mouseSeg = mouseSeg { title.append(mouseSeg) }
            if mouseSeg != nil && sonySeg != nil { title.append(NSAttributedString(string: "  ")) }
            if let sonySeg = sonySeg { title.append(sonySeg) }
        }
        statusItem.button?.attributedTitle = title
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = nil
        statusItem.menu = menu
        updateMenu()
    }

    private func deviceLine(_ label: String, _ reading: BatteryReading) -> String {
        if let percent = reading.percent {
            return "\(label): \(percent)%"
        }
        return reading.connected ? "\(label): sem leitura" : "\(label): desconectado"
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action != nil { item.target = self }
        menu.addItem(item)
        return item
    }

    private func updateMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        _ = add(menu, deviceLine("Mouse Logitech", mouseReading), nil)
        _ = add(menu, deviceLine("Fone Sony WH-1000XM4", sonyReading), nil)
        menu.addItem(.separator())
        let dpiItem = add(menu, dpiState.map { "Sensibilidade: \($0.current) DPI" } ?? "Sensibilidade: mouse sem resposta", nil)
        if let state = dpiState {
            let sub = NSMenu()
            for preset in presets {
                let item = add(sub, "\(preset) DPI", #selector(pickDPI(_:)))
                item.tag = preset
                item.state = state.current == preset ? .on : .off
            }
            sub.addItem(.separator())
            add(sub, "Usar perfil interno do mouse", #selector(useOnboard)).state = state.hostMode ? .off : .on
            dpiItem.submenu = sub
        }
        menu.addItem(.separator())
        _ = add(menu, "Atualizar agora", #selector(refresh), key: "r")
        add(menu, "Abrir ao iniciar sessão", #selector(toggleLoginItem)).state =
            (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Sair", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func pickDPI(_ sender: NSMenuItem) {
        let value = sender.tag
        UserDefaults.standard.set(value, forKey: "dpi")
        run { LogitechReader.setDPI(value) }
    }

    @objc private func useOnboard() {
        UserDefaults.standard.removeObject(forKey: "dpi")
        run { LogitechReader.useOnboardProfile() }
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("BatteryBar: login item toggle failed: \(error)")
        }
        updateMenu()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
