// progress-helper: a Finder-style progress window that scripts drive from the command line.
//
//   id=$(progress-helper start --label "Preparing “clip.mp4”" --icon clip.mp4 --watch-pid $$)
//   progress-helper update "$id" --total 120 --completed 30 --status "About a minute"
//   progress-helper cancelled "$id" && echo "user clicked stop"
//   progress-helper end "$id"
//
// Each session is a private folder in the user's temp dir holding a named pipe
// (`cmd`) that the window reads, the window's `pid`, and a `cancelled` marker the
// window writes when the user clicks stop or closes it. The marker stays until
// `end`, so a script that checks late still sees the cancel.

import Cocoa
import Darwin

let fm = FileManager.default

func fail(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("progress-helper: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage:
      progress-helper start [--label TEXT] [--status TEXT] [--icon FILE] [--watch-pid PID]
                            [--indeterminate] [--total N] [--completed N]
          Opens a window and prints its session id. With --watch-pid the window
          closes itself if that process exits. --icon shows that file's Finder icon;
          without one, the text and bar use the full width.
      progress-helper update SESSION [--label TEXT] [--status TEXT] [--icon FILE | --no-icon]
                                     [--indeterminate] [--total N] [--completed N]
      progress-helper cancelled SESSION    exit 0 if the user clicked stop, 1 if not
      progress-helper end SESSION          close the window and remove the session
      progress-helper setup-applescript    install the AppleScript library for this user

    """.data(using: .utf8)!)
    exit(64)
}

// MARK: - Options and the line protocol

struct Options {
    var label: String?, status: String?, icon: String?
    var noIcon = false
    var watchPid: Int32?
    var indeterminate = false
    var total: Double?, completed: Double?
}

func parseOptions(_ args: ArraySlice<String>) -> Options {
    var o = Options()
    var i = args.startIndex
    func value() -> String {
        i += 1
        guard i < args.endIndex else { usage() }
        return args[i]
    }
    while i < args.endIndex {
        switch args[i] {
        case "--label": o.label = value()
        case "--status": o.status = value()
        case "--icon": o.icon = value()
        case "--no-icon": o.noIcon = true
        case "--watch-pid": guard let p = Int32(value()) else { usage() }; o.watchPid = p
        case "--indeterminate": o.indeterminate = true
        case "--total": guard let n = Double(value()) else { usage() }; o.total = n
        case "--completed": guard let n = Double(value()) else { usage() }; o.completed = n
        default: usage()
        }
        i += 1
    }
    return o
}

func oneLine(_ s: String) -> String {
    s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
}

func protocolLines(_ o: Options) -> [String] {
    var lines: [String] = []
    if o.noIcon {
        lines.append("icon")
    } else if let v = o.icon {
        lines.append("icon " + oneLine(URL(fileURLWithPath: v).standardizedFileURL.path))
    }
    if let v = o.label { lines.append("label " + oneLine(v)) }
    if let v = o.status { lines.append("status " + oneLine(v)) }
    if o.indeterminate { lines.append("indeterminate") }
    if let v = o.total { lines.append("total \(v)") }
    if let v = o.completed { lines.append("completed \(v)") }
    return lines
}

// MARK: - Client side

func session(_ id: String) -> String {
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: id + "/cmd", isDirectory: &isDir), !isDir.boolValue else {
        fail("no such session: \(id)", 66)
    }
    return id
}

/// Writes lines to the session's pipe without blocking. Returns false when no window is reading it.
func send(_ dir: String, _ lines: [String]) -> Bool {
    guard !lines.isEmpty else { return true }
    let fd = open(dir + "/cmd", O_WRONLY | O_NONBLOCK)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    let data = Array((lines.joined(separator: "\n") + "\n").utf8)
    return write(fd, data, data.count) == data.count
}

func readPid(_ dir: String) -> pid_t? {
    guard let s = try? String(contentsOfFile: dir + "/pid", encoding: .utf8) else { return nil }
    return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines))
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func startSession(_ o: Options) -> Never {
    var template = Array((NSTemporaryDirectory() + "progress-helper.XXXXXX").utf8CString)
    guard mkdtemp(&template) != nil else { fail("cannot create a session folder") }
    let dir = String(cString: template)
    guard mkfifo(dir + "/cmd", 0o600) == 0 else { fail("cannot create the command pipe") }

    guard let exe = Bundle.main.executablePath else { fail("cannot locate own executable") }
    var args = ["--serve", dir]
    if let p = o.watchPid { args += ["--watch-pid", String(p)] }
    let window = Process()
    window.executableURL = URL(fileURLWithPath: exe)
    window.arguments = args
    window.standardInput = FileHandle.nullDevice
    window.standardOutput = FileHandle.nullDevice
    window.standardError = FileHandle.nullDevice
    do { try window.run() } catch { fail("cannot launch the window: \(error.localizedDescription)") }

    for _ in 0..<100 where !fm.fileExists(atPath: dir + "/ready") { usleep(50_000) }
    guard fm.fileExists(atPath: dir + "/ready") else {
        window.terminate()
        try? fm.removeItem(atPath: dir)
        fail("the window did not start")
    }
    _ = send(dir, protocolLines(o))
    print(dir)
    exit(0)
}

func update(_ id: String, _ o: Options) -> Never {
    let dir = session(id)
    if send(dir, protocolLines(o)) { exit(0) }
    // The window has gone. That's expected after a stop click, so stay quiet then.
    exit(fm.fileExists(atPath: dir + "/cancelled") ? 0 : 69)
}

func cancelled(_ id: String) -> Never {
    exit(fm.fileExists(atPath: session(id) + "/cancelled") ? 0 : 1)
}

func end(_ id: String) -> Never {
    let dir = session(id)
    _ = send(dir, ["quit"])
    if let pid = readPid(dir) {
        for _ in 0..<40 where isAlive(pid) { usleep(50_000) }
        if isAlive(pid) { kill(pid, SIGKILL) }
    }
    try? fm.removeItem(atPath: dir)
    exit(0)
}

/// Copies the bundled AppleScript library into ~/Library/Script Libraries.
/// Homebrew can't write into home folders, so users run this once after installing.
func setupAppleScript() -> Never {
    guard let exe = Bundle.main.executablePath else { fail("cannot locate own executable") }
    let binDir = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()
    let source = binDir.appendingPathComponent("../share/progress-helper/ProgressHelperLib.scptd").standardizedFileURL
    guard fm.fileExists(atPath: source.path) else { fail("cannot find \(source.path)") }
    let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Script Libraries")
    let target = folder.appendingPathComponent("ProgressHelperLib.scptd")
    do {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: source, to: target)
    } catch {
        fail("cannot install the AppleScript library: \(error.localizedDescription)")
    }
    print("Installed \(target.path)")
    print("Use it from any script with:  use script \"ProgressHelperLib\"")
    exit(0)
}

// MARK: - Window side

/// Clicks register even while another app is active, like Finder's stop button.
final class StopButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ProgressWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let dir: String
    let watchPid: pid_t?
    var window: NSWindow!
    var icon: NSImageView!
    var label: NSTextField!
    var bar: NSProgressIndicator!
    var status: NSTextField!
    var stopButton: NSButton!
    var pipeFD: Int32 = -1
    var keepOpenFD: Int32 = -1
    var reader: DispatchSourceRead?
    var pending = Data()
    var shown = false

    init(dir: String, watchPid: pid_t?) {
        self.dir = dir
        self.watchPid = watchPid
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()

        pipeFD = open(dir + "/cmd", O_RDONLY | O_NONBLOCK)
        // Hold a writer open too, so the pipe never reports end-of-file between clients.
        keepOpenFD = open(dir + "/cmd", O_WRONLY | O_NONBLOCK)
        guard pipeFD >= 0, keepOpenFD >= 0 else { exit(1) }
        let source = DispatchSource.makeReadSource(fileDescriptor: pipeFD, queue: .main)
        source.setEventHandler { [weak self] in self?.drainPipe() }
        source.resume()
        reader = source

        if let pid = watchPid {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                if !isAlive(pid) { exit(0) }
            }
        }

        try? String(getpid()).write(toFile: dir + "/pid", atomically: true, encoding: .utf8)
        try? "1".write(toFile: dir + "/ready", atomically: true, encoding: .utf8)
    }

    // Layout measured from Finder's compress window: 404 × 88 pt, content under a transparent title bar.
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 404, height: 88),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        // Float above other apps' windows so the progress window never gets buried.
        // It only moves when the user drags it.
        window.level = .floating
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.delegate = self
        let content = window.contentView!

        icon = NSImageView(frame: NSRect(x: 17.5, y: 16, width: 32, height: 32))
        content.addSubview(icon)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.usesSingleLineMode = true
        label.frame = NSRect(x: 62, y: 38, width: 330, height: 17)
        content.addSubview(label)

        bar = NSProgressIndicator(frame: NSRect(x: 62, y: 25.5, width: 308.5, height: 12))
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 100
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        content.addSubview(bar)

        func stopGlyph(_ circle: NSColor) -> NSImage {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
                .applying(.init(paletteColors: [.windowBackgroundColor, circle]))
            return NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop")!
                .withSymbolConfiguration(config)!
        }
        let pressed = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .white : .labelColor
        }
        let stop = StopButton(frame: NSRect(x: 378.5, y: 24.5, width: 14, height: 14))
        stop.setButtonType(.momentaryChange)
        stop.isBordered = false
        stop.imagePosition = .imageOnly
        stop.image = stopGlyph(.secondaryLabelColor)
        stop.alternateImage = stopGlyph(pressed)
        stop.target = self
        stop.action = #selector(stopClicked)
        content.addSubview(stop)
        stopButton = stop

        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.frame = NSRect(x: 62, y: 7.5, width: 330, height: 16)
        content.addSubview(status)
        layout()
    }

    // With an icon, text starts at 62 pt like Finder. Without one, it starts at the 20 pt margin
    // and the label, bar and status line stretch into the freed space.
    func layout() {
        let hasIcon = icon.image != nil
        icon.isHidden = !hasIcon
        let left: CGFloat = hasIcon ? 62 : 20
        let textRight: CGFloat = 392
        let barRight = stopButton.frame.minX - 8
        label.frame = NSRect(x: left, y: 38, width: textRight - left, height: 17)
        bar.frame = NSRect(x: left, y: 25.5, width: barRight - left, height: 12)
        status.frame = NSRect(x: left, y: 7.5, width: textRight - left, height: 16)
    }

    func drainPipe() {
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(pipeFD, &chunk, chunk.count)
            if n <= 0 { break }
            pending.append(contentsOf: chunk[0..<n])
        }
        while let newline = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...newline)
            apply(line)
        }
        if !shown {
            shown = true
            // Always open on the primary display (the one with the menu bar), not whichever
            // screen happens to have keyboard focus. Later windows step down and to the right.
            let area = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? .zero
            let step = CGFloat(otherVisibleSessions()) * 26
            window.setFrameOrigin(NSPoint(x: (area.midX - window.frame.width / 2).rounded() + step,
                                          y: (area.midY - window.frame.height / 2).rounded() - step))
            try? "1".write(toFile: dir + "/shown", atomically: true, encoding: .utf8)
            // Become the active app so the window draws as active (coloured buttons, blue bar),
            // the way Finder's progress window looks. If macOS declines, it still comes to the front.
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Counts other live sessions whose windows are on screen, so this one can open below them.
    func otherVisibleSessions() -> Int {
        let tmp = NSTemporaryDirectory()
        let mine = (dir as NSString).lastPathComponent
        let names = (try? fm.contentsOfDirectory(atPath: tmp)) ?? []
        return names.filter { name in
            guard name.hasPrefix("progress-helper."), name != mine else { return false }
            let other = (tmp as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: other + "/shown"), let pid = readPid(other) else { return false }
            return isAlive(pid)
        }.count
    }

    func apply(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let key = parts.first else { return }
        let value = parts.count > 1 ? String(parts[1]) : ""
        switch key {
        case "label": label.stringValue = value
        case "status": status.stringValue = value
        case "icon":
            icon.image = value.isEmpty ? nil : NSWorkspace.shared.icon(forFile: value)
            layout()
        case "indeterminate":
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        case "total":
            guard let n = Double(value), n > 0 else { return }
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.maxValue = n
        case "completed":
            guard let n = Double(value) else { return }
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = min(n, bar.maxValue)
        case "quit": exit(0)
        case "__stop": stopClicked()      // test hook: same path as clicking the stop button
        case "__dump": dumpState()        // test hook: write the window's state to state.json
        case "__close": window.performClose(nil)  // test hook: same path as the red close button
        default: break
        }
    }

    func dumpState() {
        let f = window.frame
        let state: [String: Any] = [
            "label": label.stringValue, "status": status.stringValue,
            "indeterminate": bar.isIndeterminate, "value": bar.doubleValue, "max": bar.maxValue,
            "visible": window.isVisible, "hasIcon": icon.image != nil,
            "appActive": NSApp.isActive, "isKey": window.isKeyWindow,
            "x": f.origin.x, "y": f.origin.y, "width": f.width, "height": f.height,
            "iconHidden": icon.isHidden,
            "screenIndex": NSScreen.screens.firstIndex { $0.frame.contains(NSPoint(x: f.midX, y: f.midY)) } ?? -1,
            "labelX": label.frame.minX, "labelWidth": label.frame.width,
            "barX": bar.frame.minX, "barWidth": bar.frame.width,
            "statusX": status.frame.minX, "statusWidth": status.frame.width,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/state.json"), options: .atomic)
        }
    }

    @objc func stopClicked() {
        try? "1".write(toFile: dir + "/cancelled", atomically: true, encoding: .utf8)
        window.orderOut(nil)
        exit(0)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopClicked()
        return false
    }
}

func serve(_ args: ArraySlice<String>) -> Never {
    guard let dir = args.first else { usage() }
    let o = parseOptions(args.dropFirst())
    setsid()                       // detach from the calling script's process group
    signal(SIGHUP, SIG_IGN)
    let app = NSApplication.shared
    let controller = ProgressWindow(dir: dir, watchPid: o.watchPid)
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
    exit(0)
}

// MARK: - Entry point

let argv = CommandLine.arguments
guard argv.count >= 2 else { usage() }
switch argv[1] {
case "--serve": serve(argv[2...])
case "start": startSession(parseOptions(argv[2...]))
case "update": guard argv.count >= 3 else { usage() }; update(argv[2], parseOptions(argv[3...]))
case "cancelled": guard argv.count == 3 else { usage() }; cancelled(argv[2])
case "end": guard argv.count == 3 else { usage() }; end(argv[2])
case "setup-applescript": setupAppleScript()
case "-h", "--help", "help": usage()
default: usage()
}
