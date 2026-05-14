import Cocoa
import IOBluetooth

// ─── BMAP Protocol ──────────────────────────────────────────────────────────

func bmapPacket(fblock: UInt8, func_id: UInt8, op: UInt8, payload: [UInt8] = []) -> [UInt8] {
    return [fblock, func_id, op & 0x0F, UInt8(payload.count)] + payload
}

enum NoiseMode: UInt8, CaseIterable {
    case quiet = 0
    case aware = 1
    var label: String { self == .quiet ? "Quiet" : "Aware" }
    var icon: String { self == .quiet ? "🔇" : "👂" }
}

// ─── BT Manager (Thread-based for proper RunLoop) ───────────────────────────

class BoseManager: NSObject, IOBluetoothRFCOMMChannelDelegate {
    static let shared = BoseManager()
    
    private var channel: IOBluetoothRFCOMMChannel?
    private var responseData: [UInt8] = []
    private var responseReceived = false
    private var btThread: Thread?
    private var btRunLoop: RunLoop?
    private let ready = DispatchSemaphore(value: 0)
    private let logFile: FileHandle?
    private var reconnectTimer: Timer?
    private var pollTimer: Timer?
    
    var isConnected: Bool { channel != nil }
    var currentMode: NoiseMode = .quiet
    var batteryLeft: Int = -1
    var batteryRight: Int = -1
    var batteryCase: Int = -1
    var deviceName: String = "Bose Device"
    var onUpdate: (() -> Void)?
    
    // Known Bose Bluetooth name patterns
    private static let bosePatterns = [
        "Bose", "QC", "QuietComfort", "SoundSport", "NC 700",
        "Frames", "Sport Earbuds", "Ultra Open"
    ]
    
    override init() {
        let logPath = "/tmp/bosecontrol.log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        logFile = FileHandle(forWritingAtPath: logPath)
        super.init()
        startBTThread()
    }
    
    func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        logFile?.write(line.data(using: .utf8)!)
    }
    
    private func startBTThread() {
        btThread = Thread { [weak self] in
            self?.btRunLoop = RunLoop.current
            self?.ready.signal()
            // Keep thread alive
            let port = Port()
            RunLoop.current.add(port, forMode: .default)
            RunLoop.current.run()
        }
        btThread?.name = "BoseControl-BT"
        btThread?.start()
        ready.wait()
    }
    
    func connectAsync() {
        perform(#selector(doConnect), on: btThread!, with: nil, waitUntilDone: false)
    }
    
    /// Scan paired Bluetooth devices for a Bose BMAP-capable device
    private func findBoseDevice() -> IOBluetoothDevice? {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log("No paired devices")
            return nil
        }
        log("Scanning \(paired.count) paired devices...")
        
        // Prefer connected devices, fall back to paired
        var candidates: [(IOBluetoothDevice, Bool)] = []
        for dev in paired {
            let name = dev.name ?? ""
            let matches = Self.bosePatterns.contains { name.localizedCaseInsensitiveContains($0) }
            if matches {
                log("  Candidate: \(name) [\(dev.addressString ?? "?")] connected=\(dev.isConnected())")
                candidates.append((dev, dev.isConnected()))
            }
        }
        
        // Return first connected, or first candidate
        if let connected = candidates.first(where: { $0.1 }) {
            return connected.0
        }
        return candidates.first?.0
    }
    
    @objc private func doConnect() {
        // Auto-discover paired Bose device
        guard let dev = findBoseDevice() else {
            log("❌ No Bose device found")
            DispatchQueue.main.async { self.onUpdate?() }
            return
        }
        log("Found: \(dev.name ?? "unknown") [\(dev.addressString ?? "?")]")
        log("isConnected: \(dev.isConnected())")
        
        if !dev.isConnected() {
            log("openConnection...")
            _ = dev.openConnection(nil)
            let deadline = Date().addingTimeInterval(5.0)
            while !dev.isConnected() && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            log("Post-wait isConnected: \(dev.isConnected())")
        }
        
        log("Opening RFCOMM ch 2...")
        var chan: IOBluetoothRFCOMMChannel? = nil
        let result = dev.openRFCOMMChannelSync(&chan, withChannelID: 2, delegate: self)
        log("RFCOMM result: \(result)")
        
        if result == kIOReturnSuccess, let c = chan {
            channel = c
            deviceName = dev.name ?? "Bose Device"
            log("✅ Connected to \(deviceName)")
            stopReconnectTimer()
            // Drain initial data
            let drainEnd = Date().addingTimeInterval(2.0)
            while Date() < drainEnd {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            log("Drained initial, querying state...")
            doRefreshState()
            startPollTimer()
        } else {
            log("❌ RFCOMM failed: \(result)")
        }
        DispatchQueue.main.async { self.onUpdate?() }
    }
    
    @objc private func doRefreshState() {
        log("refreshState")
        // Current mode
        if let resp = sendAndWait(bmapPacket(fblock: 31, func_id: 3, op: 1)) {
            log("mode: \(resp.map{String(format:"%02x",$0)}.joined(separator:" "))")
            if resp.count >= 5 && resp[2] & 0x0F == 3 {
                if let mode = NoiseMode(rawValue: resp[4]) { currentMode = mode }
            }
        } else { log("mode: timeout") }
        
        // Battery
        if let resp = sendAndWait(bmapPacket(fblock: 2, func_id: 2, op: 1)) {
            log("batt: \(resp.map{String(format:"%02x",$0)}.joined(separator:" "))")
            if resp.count >= 5 && resp[2] & 0x0F == 3 {
                let payload = Array(resp[4...])
                var i = 0
                while i + 3 < payload.count {
                    let level = Int(payload[i])
                    let devId = payload[i + 3]
                    switch devId {
                    case 1: batteryLeft = level
                    case 2: batteryRight = level
                    case 3, 4: batteryCase = level
                    default: break
                    }
                    i += 4
                }
                log("battery: L=\(batteryLeft) R=\(batteryRight) C=\(batteryCase)")
            }
        } else { log("batt: timeout") }
        
        DispatchQueue.main.async { self.onUpdate?() }
    }
    
    private func sendAndWait(_ packet: [UInt8], timeout: TimeInterval = 2.0) -> [UInt8]? {
        guard let channel = channel else { return nil }
        responseData = []
        responseReceived = false
        
        var pkt = packet
        let writeOK = pkt.withUnsafeMutableBufferPointer { buf -> Bool in
            return channel.writeSync(buf.baseAddress!, length: UInt16(buf.count)) == kIOReturnSuccess
        }
        guard writeOK else { log("write FAILED"); return nil }
        
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !responseReceived {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return responseReceived ? responseData : nil
    }
    
    func refreshState() {
        perform(#selector(doRefreshState), on: btThread!, with: nil, waitUntilDone: false)
    }
    
    private var pendingMode: NoiseMode = .quiet
    
    func setMode(_ mode: NoiseMode) {
        pendingMode = mode
        perform(#selector(doSetMode), on: btThread!, with: nil, waitUntilDone: false)
    }
    
    @objc private func doSetMode() {
        let mode = pendingMode
        log("setMode: \(mode.label)")
        let resp = sendAndWait(bmapPacket(fblock: 31, func_id: 3, op: 5, payload: [mode.rawValue, 0x00]))
        if let r = resp, r.count >= 5 && r[2] & 0x0F == 6 {
            currentMode = mode
            log("✅ mode switched")
        } else {
            log("❌ mode switch failed: \(resp?.map{String(format:"%02x",$0)}.joined(separator:" ") ?? "nil")")
        }
        DispatchQueue.main.async { self.onUpdate?() }
    }
    
    func disconnect() {
        stopPollTimer()
        _ = channel?.close()
        channel = nil
    }
    
    // RFCOMM Delegate
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        let bytes = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: len))
        log("RX(\(len)): \(bytes.prefix(20).map{String(format:"%02x",$0)}.joined(separator:" "))")
        
        // Check for unsolicited STATUS (op=3) for mode [31.3]
        if bytes.count >= 5 && bytes[0] == 0x1F && bytes[1] == 0x03 && bytes[2] & 0x0F == 3 {
            if let mode = NoiseMode(rawValue: bytes[4]) {
                log("📡 Unsolicited mode change: \(mode.label)")
                currentMode = mode
                DispatchQueue.main.async { self.onUpdate?() }
            }
        }
        
        responseData = bytes
        responseReceived = true
    }
    
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log("CLOSED")
        channel = nil
        stopPollTimer()
        startReconnectTimer()
        DispatchQueue.main.async { self.onUpdate?() }
    }
    
    private func startReconnectTimer() {
        stopReconnectTimer()
        log("Starting auto-reconnect (every 5s)")
        guard let rl = btRunLoop else { return }
        perform(#selector(scheduleReconnectTimer), on: btThread!, with: nil, waitUntilDone: false)
    }
    
    @objc private func scheduleReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.channel == nil {
                self.log("Auto-reconnect attempt...")
                self.doConnect()
            }
            if self.channel != nil {
                self.log("Reconnected — stopping timer")
                self.stopReconnectTimer()
            }
        }
    }
    
    private func stopReconnectTimer() {
        if let t = reconnectTimer {
            t.invalidate()
            reconnectTimer = nil
        }
    }
    
    private func startPollTimer() {
        stopPollTimer()
        log("Starting state poll (every 10s)")
        perform(#selector(schedulePollTimer), on: btThread!, with: nil, waitUntilDone: false)
    }
    
    @objc private func schedulePollTimer() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.channel != nil else { return }
            self.log("Poll refresh")
            self.doRefreshState()
        }
    }
    
    private func stopPollTimer() {
        if let t = pollTimer {
            t.invalidate()
            pollTimer = nil
        }
    }
}

// ─── Menu Bar ───────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let bose = BoseManager.shared
    
    private let defaults = UserDefaults.standard
    private let kShowBattery = "showBatteryInBar"
    private let kShowMode = "showModeInBar"
    
    var showBatteryInBar: Bool {
        get { defaults.bool(forKey: kShowBattery) }
        set { defaults.set(newValue, forKey: kShowBattery); updateUI() }
    }
    var showModeInBar: Bool {
        get { defaults.bool(forKey: kShowMode) }
        set { defaults.set(newValue, forKey: kShowMode); updateUI() }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Bose")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        bose.onUpdate = { [weak self] in self?.updateUI() }
        updateUI()
        bose.connectAsync()
    }
    
    func updateUI() {
        if let button = statusItem.button {
            var parts: [String] = []
            if bose.isConnected && bose.batteryLeft >= 0 {
                if showBatteryInBar {
                    let level = min(bose.batteryLeft, bose.batteryRight > 0 ? bose.batteryRight : bose.batteryLeft)
                    parts.append("\(level)%")
                }
                if showModeInBar {
                    parts.append(bose.currentMode.icon)
                }
            }
            button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " ")
        }
        
        // Build menu
        let menu = NSMenu()
        let header = NSMenuItem(title: bose.deviceName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.attributedTitle = NSAttributedString(string: header.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        menu.addItem(header)
        
        if !bose.isConnected {
            menu.addItem(NSMenuItem(title: "⏳ Connecting...", action: nil, keyEquivalent: ""))
            menu.addItem(NSMenuItem.separator())
            let r = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
            r.target = self
            menu.addItem(r)
        } else {
            // Battery
            var battParts: [String] = []
            if bose.batteryLeft >= 0 { battParts.append("L:\(bose.batteryLeft)%") }
            if bose.batteryRight >= 0 { battParts.append("R:\(bose.batteryRight)%") }
            if bose.batteryCase >= 0 { battParts.append("Case:\(bose.batteryCase)%") }
            if !battParts.isEmpty {
                let b = NSMenuItem(title: "🔋 \(battParts.joined(separator: "  "))", action: nil, keyEquivalent: "")
                b.isEnabled = false
                menu.addItem(b)
            }
            menu.addItem(NSMenuItem.separator())
            
            let nc = NSMenuItem(title: "Noise Control", action: nil, keyEquivalent: "")
            nc.isEnabled = false
            menu.addItem(nc)
            
            for mode in NoiseMode.allCases {
                let item = NSMenuItem(title: "\(mode.icon)  \(mode.label)", action: #selector(modeClicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(mode.rawValue)
                item.state = mode == bose.currentMode ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let ref = NSMenuItem(title: "Refresh", action: #selector(refresh), keyEquivalent: "r")
            ref.target = self
            menu.addItem(ref)
        }
        menu.addItem(NSMenuItem.separator())
        
        // Display settings
        let settingsHeader = NSMenuItem(title: "Menu Bar Display", action: nil, keyEquivalent: "")
        settingsHeader.isEnabled = false
        menu.addItem(settingsHeader)
        
        let battToggle = NSMenuItem(title: "Show Battery %", action: #selector(toggleBattery), keyEquivalent: "")
        battToggle.target = self
        battToggle.state = showBatteryInBar ? .on : .off
        menu.addItem(battToggle)
        
        let modeToggle = NSMenuItem(title: "Show Mode Icon", action: #selector(toggleMode), keyEquivalent: "")
        modeToggle.target = self
        modeToggle.state = showModeInBar ? .on : .off
        menu.addItem(modeToggle)
        
        menu.addItem(NSMenuItem.separator())
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.keyEquivalentModifierMask = [.command]
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
    }
    
    @objc func modeClicked(_ sender: NSMenuItem) {
        guard let mode = NoiseMode(rawValue: UInt8(sender.tag)) else { return }
        bose.setMode(mode)
    }
    @objc func refresh() { bose.refreshState() }
    @objc func reconnect() { bose.disconnect(); bose.connectAsync() }
    @objc func toggleBattery() { showBatteryInBar = !showBatteryInBar }
    @objc func toggleMode() { showModeInBar = !showModeInBar }
    @objc func quit() { bose.disconnect(); NSApp.terminate(nil) }
}

// ─── Launch ─────────────────────────────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
