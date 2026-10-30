import Cocoa
import CoreGraphics

struct Connection: Decodable {
    let host: String
    let port: Int
    let user: String
    let identityFile: String
    let knownHosts: String
    var valid: Bool {
        host.range(of: "^[A-Za-z0-9][A-Za-z0-9.:-]*$", options: .regularExpression) != nil &&
        user.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil &&
        (1...65535).contains(port) &&
        [identityFile, knownHosts].allSatisfy { $0.hasPrefix("/") && !$0.contains("\\") && !$0.contains("\"") && !$0.contains("\n") && !$0.contains("\r") }
    }
}

let keyMap: [UInt16: Int] = [
  0:30,1:31,2:32,3:33,4:35,5:34,6:44,7:45,8:46,9:47,11:48,
  12:16,13:17,14:18,15:19,16:21,17:20,18:2,19:3,20:4,21:5,22:7,23:6,
  24:13,25:10,26:8,27:12,28:9,29:11,30:27,31:24,32:22,33:26,34:23,
  35:25,36:28,37:38,38:36,39:40,40:37,41:39,42:43,43:51,44:53,45:49,
  46:50,47:52,48:15,49:57,50:41,51:14,53:1,65:83,67:55,69:78,71:69,
  75:98,76:96,78:74,81:117,82:82,83:79,84:80,85:81,86:75,87:76,88:77,
  89:71,91:72,92:73,96:63,97:64,98:65,99:61,100:66,101:67,103:87,
  109:68,111:88,114:110,115:102,116:104,117:111,118:62,119:107,120:60,
  121:109,122:59,123:105,124:106,125:108,126:103]

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var pad: Pad!
    let status = NSTextField(labelWithString: "Connecting to iPad…")
    let hint = NSTextField(labelWithString: "Look at the iPad for its display.")
    var process: Process?
    var input: FileHandle?
    var ready = false
    var captured = false
    var buffer = ""
    var retries: Timer?
    var heartbeat: Timer?
    var lastReply = Date()
    var heldModifiers = Set<Int>()
    let writer = DispatchQueue(label: "ipad.input")

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Quit iPad Controls", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 460), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "iPad Controls"; window.delegate = self
        window.minSize = NSSize(width: 560, height: 380)
        window.backgroundColor = NSColor(calibratedRed: 0.065, green: 0.065, blue: 0.10, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        let title = NSTextField(labelWithString: "Your Mac. Your iPad controls.")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        status.font = .systemFont(ofSize: 14, weight: .medium)
        pad = Pad(); pad.owner = self
        pad.wantsLayer = true; pad.layer?.backgroundColor = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.19, alpha: 1).cgColor
        pad.layer?.cornerRadius = 18
        let buttons = NSStackView()
        for (name, action) in [("System info", #selector(info)), ("Esc → iPad", #selector(sendEscape)), ("Reconnect", #selector(reconnect))] {
            let button = NSButton(title: name, target: self, action: action)
            button.bezelStyle = .rounded; buttons.addArrangedSubview(button)
        }
        buttons.spacing = 12
        hint.font = .systemFont(ofSize: 13); hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title,status,pad,buttons,hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -28),
            pad.widthAnchor.constraint(equalTo: stack.widthAnchor),pad.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        connect()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, self.ready else { return }
            if Date().timeIntervalSince(self.lastReply) > 9 { self.reconnect() }
            else { self.send("PING") }
        }
    }
    func connect() {
        guard process == nil else { return }
        status.stringValue = "Connecting to iPad…"; status.textColor = .secondaryLabelColor
        let resources = Bundle.main.resourceURL!
        do {
            let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ipad-controls/connection.json")
            guard let data = try? Data(contentsOf: configURL),
                  let config = try? JSONDecoder().decode(Connection.self, from: data),
                  config.valid else {
                status.stringValue = "Setup needed: ~/.config/ipad-controls/connection.json"
                return
            }
            let script = try String(contentsOf: resources.appendingPathComponent("bridge.py"), encoding: .utf8)
            let quoted = "'" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-T", "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=4", "-o", "ServerAliveInterval=3", "-o", "ServerAliveCountMax=2", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=\"" + config.knownHosts + "\"", "-i", config.identityFile, "-p", String(config.port), config.user + "@" + config.host, "python3 -u -c " + quoted]
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            p.standardInput = stdin; p.standardOutput = stdout; p.standardError = stderr
            process = p; input = stdin.fileHandleForWriting; buffer = ""
            stdout.fileHandleForReading.readabilityHandler = { [weak self, weak p] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    guard let self = self, self.process === p else { return }
                    self.buffer += text
                    while let end = self.buffer.firstIndex(of: "\n") {
                        let line = String(self.buffer[..<end]); self.buffer.removeSubrange(...end)
                        if line == "READY" || line == "PONG" { self.lastReply = Date() }
                        if line == "READY" {
                            self.ready = true; self.status.stringValue = "Connected · Mouse and keyboard"
                            self.status.textColor = .systemGreen; self.pad.needsDisplay = true
                        }
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty { handle.readabilityHandler = nil }
            }
            p.terminationHandler = { [weak self, weak p] _ in DispatchQueue.main.async {
                guard let self = self, self.process === p else { return }
                self.release(); self.ready = false; self.process = nil; self.input = nil
                self.status.stringValue = "Disconnected · Check the connection. Retrying…"
                self.status.textColor = .systemOrange; self.pad.needsDisplay = true
                self.retries?.invalidate()
                self.retries = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.connect() }
            }}
            try p.run()
        } catch {
            process = nil; input = nil; status.stringValue = "Could not start: \(error.localizedDescription)"
        }
    }
    func send(_ line: String) {
        guard ready, let handle = input else { return }
        let data = Data((line + "\n").utf8)
        writer.async { try? handle.write(contentsOf: data) }
    }
    func capture() {
        guard ready, !captured else { return }
        captured = true; window.makeFirstResponder(pad)
        CGAssociateMouseAndMouseCursorPosition(0); NSCursor.hide()
        hint.stringValue = "Mouse + keyboard captured. Press Escape to release. ⌘ acts as Linux Super."
        pad.needsDisplay = true
    }
    func release() {
        send("RELEASE"); heldModifiers.removeAll()
        if captured { CGAssociateMouseAndMouseCursorPosition(1); NSCursor.unhide() }
        captured = false; hint.stringValue = "Look at the iPad for its display. Click the pad to control it."
        pad?.needsDisplay = true
    }
    @objc func info() { release(); send("INFO") }
    @objc func sendEscape() { send("KEY 1 1"); send("KEY 1 0") }
    @objc func reconnect() {
        release(); ready = false; retries?.invalidate()
        if let p = process { p.terminate() } else { connect() }
    }
    func windowDidResignKey(_ notification: Notification) { release() }
    func applicationWillResignActive(_ notification: Notification) { release() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        release(); writer.sync {}; try? input?.close(); process?.terminate()
    }
}

final class Pad: NSView {
    weak var owner: Controller?
    var dx = 0.0, dy = 0.0, wheel = 0.0
    override var acceptsFirstResponder: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let active = owner?.captured == true
        let text = active ? "Controlling iPad\nEscape releases your Mac" : "Click here to control iPad\nMouse · Keyboard · Scroll"
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.systemFont(ofSize: 20, weight: .medium),.foregroundColor:NSColor(calibratedRed: 0.78, green: 0.72, blue: 1, alpha: 1),.paragraphStyle:paragraph]
        (text as NSString).draw(in: NSRect(x: 12, y: bounds.midY - 30, width: bounds.width - 24, height: 64), withAttributes: attrs)
    }
    override func mouseDown(with e: NSEvent) { if owner?.captured != true { owner?.capture() } else { owner?.send("BUTTON 0 1") } }
    override func mouseUp(with e: NSEvent) { if owner?.captured == true { owner?.send("BUTTON 0 0") } }
    override func rightMouseDown(with e: NSEvent) { if owner?.captured == true { owner?.send("BUTTON 1 1") } }
    override func rightMouseUp(with e: NSEvent) { if owner?.captured == true { owner?.send("BUTTON 1 0") } }
    override func otherMouseDown(with e: NSEvent) { if owner?.captured == true { owner?.send("BUTTON 2 1") } }
    override func otherMouseUp(with e: NSEvent) { if owner?.captured == true { owner?.send("BUTTON 2 0") } }
    override func mouseMoved(with e: NSEvent) {
        guard owner?.captured == true else { return }
        dx += e.deltaX; dy += e.deltaY
        let x = max(-2048,min(2048,Int(dx))), y = max(-2048,min(2048,Int(dy)))
        dx -= Double(x); dy -= Double(y)
        if x != 0 || y != 0 { owner?.send("MOVE \(x) \(y)") }
    }
    override func mouseDragged(with e: NSEvent) { mouseMoved(with:e) }
    override func rightMouseDragged(with e: NSEvent) { mouseMoved(with:e) }
    override func otherMouseDragged(with e: NSEvent) { mouseMoved(with:e) }
    override func scrollWheel(with e: NSEvent) {
        guard owner?.captured == true else { return }
        wheel += Double(e.scrollingDeltaY) / (e.hasPreciseScrollingDeltas ? 12 : 1)
        let steps = max(-20,min(20,Int(wheel))); wheel -= Double(steps)
        if steps != 0 { owner?.send("WHEEL \(steps)") }
    }
    override func keyDown(with e: NSEvent) {
        guard owner?.captured == true else { return }
        if e.keyCode == 53 { owner?.release(); return }
        if let code = keyMap[e.keyCode] { owner?.send("KEY \(code) \(e.isARepeat ? 2 : 1)") }
    }
    override func keyUp(with e: NSEvent) {
        if owner?.captured == true, let code = keyMap[e.keyCode] { owner?.send("KEY \(code) 0") }
    }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if owner?.captured == true { keyDown(with:e); return true }; return false
    }
    override func flagsChanged(with e: NSEvent) {
        guard let o = owner, o.captured else { return }
        let modifiers: [(NSEvent.ModifierFlags,Int)] = [(.shift,42),(.control,29),(.option,56),(.command,125)]
        for (flag,code) in modifiers {
            let down = e.modifierFlags.contains(flag)
            if down != o.heldModifiers.contains(code) {
                o.send("KEY \(code) \(down ? 1 : 0)")
                if down { o.heldModifiers.insert(code) } else { o.heldModifiers.remove(code) }
            }
        }
        if e.keyCode == 57 { o.send("KEY 58 1"); o.send("KEY 58 0") }
    }
    override func viewDidMoveToWindow() { window?.acceptsMouseMovedEvents = true }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
