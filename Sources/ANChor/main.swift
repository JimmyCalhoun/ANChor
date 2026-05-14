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
    
    var isConnected: Bool { channel != nil }
    var currentMode: NoiseMode = .quiet
    var batteryLeft: Int = -1
    var batteryRight: Int = -1
    var batteryCase: Int = -1
    var onUpdate: (() -> Void)?
    
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
    
    @objc private func doConnect() {
        guard let dev = IOBluetoothDevice(addressString: "68-F2-1F-3E-C2-CD") else {
            log("Device not found"); return
        }
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
            log("✅ Connected")
            // Drain initial data
            let drainEnd = Date().addingTimeInterval(2.0)
            while Date() < drainEnd {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            log("Drained initial, querying state...")
            doRefreshState()
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
    
    func setMode(_ mode: NoiseMode) {
        let modeVal = mode.rawValue
        let block: @convention(block) () -> Void = { [weak self] in
            guard let self = self else { return }
            self.log("setMode: \(mode.label)")
            let resp = self.sendAndWait(bmapPacket(fblock: 31, func_id: 3, op: 5, payload: [modeVal, 0x00]))
            if let r = resp, r.count >= 5 && r[2] & 0x0F == 6 {
                self.currentMode = mode
                self.log("✅ mode switched")
            } else {
                self.log("❌ mode switch failed")
            }
            DispatchQueue.main.async { self.onUpdate?() }
        }
        perform(#selector(runBlock(_:)), on: btThread!, with: block, waitUntilDone: false)
    }
    
    @objc private func runBlock(_ block: Any) {
        if let b = block as? () -> Void { b() }
    }
    
    func disconnect() {
        _ = channel?.close()
        channel = nil
    }
    
    // RFCOMM Delegate
    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        let bytes = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: UInt8.self), count: len))
        log("RX(\(len)): \(bytes.prefix(20).map{String(format:"%02x",$0)}.joined(separator:" "))")
        responseData = bytes
        responseReceived = true
    }
    
    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        log("CLOSED")
        channel = nil
        DispatchQueue.main.async { self.onUpdate?() }
    }
}

// ─── Menu Bar ───────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let bose = BoseManager.shared
    
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
        // Menu bar text
        if let button = statusItem.button {
            if bose.isConnected && bose.batteryLeft >= 0 {
                let level = min(bose.batteryLeft, bose.batteryRight > 0 ? bose.batteryRight : bose.batteryLeft)
                button.title = " \(level)% \(bose.currentMode.icon)"
            } else {
                button.title = ""
            }
        }
        
        // Build menu
        let menu = NSMenu()
        let header = NSMenuItem(title: "James QC Ultra 2 Earbuds", action: nil, keyEquivalent: "")
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
    @objc func quit() { bose.disconnect(); NSApp.terminate(nil) }
}

// ─── Launch ─────────────────────────────────────────────────────────────────
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
