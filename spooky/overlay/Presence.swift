// Presence — what the agent looks like while it is working.
//
// A drawn pointer glides to whatever it is about to act on, a ring pulses
// when it acts, and the screen edges glow for as long as it is driving. Then
// everything goes away. When the agent is idle there is nothing on screen at
// all — the glow is not a session badge you stop noticing by lunchtime.
//
//   hidden   nothing is being driven
//   accent   the agent is acting        (yellow by default; set any colour)
//   user     you touched the mouse, or hit pause
//
// The pointer is *drawn*, not your cursor. Your real pointer never moves, so
// you can keep working in another window while the agent works in this one —
// but you can still watch where it is going before it gets there, instead of
// clicks landing out of nowhere. This is the same trick Codex uses on macOS:
// paint a pointer, act through the accessibility API, never synthesise a
// mouse event.
//
// Taking control back needs nothing learned: touch the mouse and the border
// changes colour, the agent is locked out mid-task, and it stays locked out
// until you have been still for a moment.

import Cocoa

let fm = FileManager.default
let home = ProcessInfo.processInfo.environment["SPOOKY_HOME"]
    ?? (NSHomeDirectory() as NSString).appendingPathComponent(".spooky")
func inHome(_ n: String) -> String { (home as NSString).appendingPathComponent(n) }
let stampPath   = inHome("agent-input.stamp")
let lockPath    = inHome("agent-input.lock")
let statePath   = inHome("control.json")
let eventPath   = inHome("control-events.jsonl")
let pausePath   = inHome("paused.flag")
let configPath  = inHome("config.json")
let hudPosPath  = inHome("hud-position")
let pointerPath = inHome("pointer.json")
let sessionPath = inHome("session.json")
let labelPath   = inHome("label")

func argStr(_ name: String, _ fallback: String) -> String {
    guard let i = CommandLine.arguments.firstIndex(of: name),
          i + 1 < CommandLine.arguments.count else { return fallback }
    return CommandLine.arguments[i + 1]
}
let taskLabel = argStr("--label", "Spooky Action is acting")

enum Holder: String { case idle, agent, user, paused }

// MARK: - settings you can change without touching this file
//
// Everything visual lives in config.json so the agent can edit it on request
// — "make the border yellow" should be a thirty-second job, not a rebuild.

func colour(_ spec: String, _ fallback: NSColor) -> NSColor {
    let named: [String: NSColor] = [
        "yellow": NSColor(calibratedRed: 1.00, green: 0.83, blue: 0.10, alpha: 1),
        "amber":  NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.12, alpha: 1),
        "blue":   NSColor(calibratedRed: 0.15, green: 0.55, blue: 1.00, alpha: 1),
        "green":  NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.45, alpha: 1),
        "red":    NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.30, alpha: 1),
        "purple": NSColor(calibratedRed: 0.66, green: 0.40, blue: 1.00, alpha: 1),
        "pink":   NSColor(calibratedRed: 1.00, green: 0.38, blue: 0.72, alpha: 1),
        "orange": NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.15, alpha: 1),
        "white":  NSColor.white,
    ]
    let key = spec.trimmingCharacters(in: .whitespaces).lowercased()
    if let c = named[key] { return c }
    var hex = key
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let v = Int(hex, radix: 16) else { return fallback }
    return NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255,
                   green: CGFloat((v >> 8) & 0xff) / 255,
                   blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

struct Config {
    var accent = colour("yellow", .yellow)
    var userAccent = colour("blue", .blue)
    var wash: CGFloat = 0.055
    var idle = 2.0
    var linger = 1.4
    var selfWindow = 1.2
    var maxSeconds = 14400.0
    var showPointer = true
    var showGlow = true
    var hudCorner = "top"
    var glideSeconds = 0.34

    static func load() -> Config {
        var c = Config()
        guard let data = fm.contents(atPath: configPath),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return c }
        if let s = j["accent"] as? String { c.accent = colour(s, c.accent) }
        if let s = j["user_accent"] as? String { c.userAccent = colour(s, c.userAccent) }
        if let v = j["wash"] as? Double { c.wash = CGFloat(max(0, min(0.4, v))) }
        if let v = j["idle_seconds"] as? Double { c.idle = v }
        if let v = j["linger_seconds"] as? Double { c.linger = v }
        if let v = j["self_window"] as? Double { c.selfWindow = v }
        if let v = j["max_seconds"] as? Double { c.maxSeconds = v }
        if let v = j["pointer"] as? Bool { c.showPointer = v }
        if let v = j["glow"] as? Bool { c.showGlow = v }
        if let v = j["hud"] as? String { c.hudCorner = v }
        if let v = j["glide_seconds"] as? Double { c.glideSeconds = max(0.05, v) }
        return c
    }
}

var cfg = Config.load()
func tintFor(_ h: Holder) -> NSColor { h == .agent ? cfg.accent : cfg.userAccent }

// Quartz coordinates (origin at the top-left of the primary display, y going
// down) are what the accessibility API hands back, and Cocoa windows want the
// opposite. Everything crossing that line goes through here.
func cocoaPoint(fromQuartz p: CGPoint) -> NSPoint {
    let primary = NSScreen.screens.first?.frame.maxY ?? 0
    return NSPoint(x: p.x, y: primary - p.y)
}

// MARK: - the glow

final class BorderView: NSView {
    var holder: Holder = .idle
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        guard holder != .idle, cfg.showGlow else { return }
        let tint = tintFor(holder)

        // A wash over the whole screen, so the state reads even against a
        // wallpaper the same colour as the glow. This has to be obvious from
        // across the room, not a detail you find by looking for it.
        tint.withAlphaComponent(cfg.wash).setFill()
        bounds.fill()

        // Many strokes with falling opacity — cheap, and it reads as light
        // rather than as a rectangle drawn on the screen.
        let layers = 26
        for i in 0..<layers {
            tint.withAlphaComponent(pow(1 - CGFloat(i) / CGFloat(layers), 2) * 0.85).setStroke()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: CGFloat(i) * 2.3 + 1,
                                                               dy: CGFloat(i) * 2.3 + 1),
                                    xRadius: 18, yRadius: 18)
            path.lineWidth = 3
            path.stroke()
        }
    }
}

// MARK: - the drawn pointer
//
// A small window that follows the target around, rather than repainting a
// full-screen view sixty times a second. The arrow's tip sits exactly on the
// window's top-left corner plus `hot`, so placing the window places the tip.

let hot = NSPoint(x: 22, y: 22)
let pointerSize = NSSize(width: 260, height: 200)

final class PointerView: NSView {
    var holder: Holder = .agent
    var caption: String = ""
    var rippleAge: Double? = nil        // seconds since the click, nil when quiet
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let tint = tintFor(holder)

        // the pulse, drawn under the arrow so the arrow stays legible
        if let age = rippleAge {
            let t = min(1, age / 0.5)
            let r = 6 + 30 * t
            tint.withAlphaComponent((1 - t) * 0.75).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: hot.x - r, y: hot.y - r,
                                                   width: r * 2, height: r * 2))
            ring.lineWidth = 3
            ring.stroke()
            tint.withAlphaComponent((1 - t) * 0.22).setFill()
            ring.fill()
        }

        // the arrow — the familiar macOS shape, so it reads as a pointer at a
        // glance even though it is painted rather than real
        let a = NSBezierPath()
        a.move(to: NSPoint(x: hot.x, y: hot.y))
        a.line(to: NSPoint(x: hot.x, y: hot.y + 19))
        a.line(to: NSPoint(x: hot.x + 4.6, y: hot.y + 14.8))
        a.line(to: NSPoint(x: hot.x + 7.6, y: hot.y + 21.4))
        a.line(to: NSPoint(x: hot.x + 11.2, y: hot.y + 19.8))
        a.line(to: NSPoint(x: hot.x + 8.2, y: hot.y + 13.4))
        a.line(to: NSPoint(x: hot.x + 14.2, y: hot.y + 13.2))
        a.close()

        NSColor.black.withAlphaComponent(0.38).setFill()
        let shadow = a.copy() as! NSBezierPath
        var shift = AffineTransform.identity
        shift.translate(x: 1, y: 1.5)
        shadow.transform(using: shift)
        shadow.fill()

        tint.setFill()
        a.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        a.lineWidth = 1.4
        a.stroke()

        guard !caption.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        ]
        var text = caption
        if text.count > 34 { text = String(text.prefix(33)) + "…" }
        let size = (text as NSString).size(withAttributes: attrs)
        let chip = NSRect(x: hot.x + 18, y: hot.y + 20, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2).fill()
        tint.withAlphaComponent(0.85).setStroke()
        let outline = NSBezierPath(roundedRect: chip, xRadius: chip.height / 2, yRadius: chip.height / 2)
        outline.lineWidth = 1
        outline.stroke()
        (text as NSString).draw(at: NSPoint(x: chip.minX + 8, y: chip.minY + 4), withAttributes: attrs)
    }
}

// MARK: - the HUD

let corners = ["bottom", "top", "left", "right"]

final class HUDView: NSView {
    var holder: Holder = .agent
    var note: String = taskLabel
    var onPause: () -> Void = {}
    var onMove: () -> Void = {}
    var onDragged: (NSPoint) -> Void = { _ in }

    private var pauseRect = NSRect.zero
    private var moveRect = NSRect.zero
    private var dragOrigin: NSPoint?
    private var didDrag = false
    override var isFlipped: Bool { true }

    var labelText: String {
        switch holder {
        case .paused: return "Paused — click ▶ to hand it back"
        case .user:   return "You have the screen — the agent is waiting"
        default:      return note
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        let tint = tintFor(holder)

        NSColor.black.withAlphaComponent(0.84).setFill()
        let shape = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                                 yRadius: bounds.height / 2)
        shape.fill()
        tint.withAlphaComponent(0.9).setStroke()
        shape.lineWidth = 1.5
        shape.stroke()

        // the grab handle, so it looks draggable before you try
        NSColor.white.withAlphaComponent(0.28).setFill()
        for i in 0..<3 {
            let y = bounds.height / 2 - 5 + CGFloat(i) * 5
            NSBezierPath(roundedRect: NSRect(x: 11, y: y, width: 9, height: 1.6),
                         xRadius: 1, yRadius: 1).fill()
        }
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: 27, y: bounds.height / 2 - 4, width: 8, height: 8)).fill()

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
            .paragraphStyle: style,
        ]
        (labelText as NSString).draw(in: NSRect(x: 43, y: (bounds.height - 15) / 2,
                                                width: bounds.width - 43 - 76, height: 16),
                                     withAttributes: attrs)

        pauseRect = NSRect(x: bounds.width - 70, y: (bounds.height - 24) / 2, width: 30, height: 24)
        moveRect  = NSRect(x: bounds.width - 36, y: (bounds.height - 24) / 2, width: 30, height: 24)
        for (rect, glyph) in [(pauseRect, holder == .paused ? "▶" : "❚❚"), (moveRect, "⤢")] {
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            let g: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: glyph == "❚❚" ? 9 : 12, weight: .bold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            let s = (glyph as NSString).size(withAttributes: g)
            (glyph as NSString).draw(at: NSPoint(x: rect.midX - s.width / 2,
                                                 y: rect.midY - s.height / 2), withAttributes: g)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        didDrag = false
        if pauseRect.contains(p) || moveRect.contains(p) { dragOrigin = nil; return }
        dragOrigin = event.locationInWindow          // unflipped, window-relative
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let w = window else { return }
        didDrag = true
        let mouse = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: mouse.x - origin.x, y: mouse.y - origin.y))
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if didDrag, let w = window {
            onDragged(w.frame.origin)
        } else if pauseRect.contains(p) {
            onPause()
        } else if moveRect.contains(p) {
            onMove()
        }
        dragOrigin = nil
        didDrag = false
    }
}

// MARK: - the daemon

final class Presence {
    var glows: [(NSWindow, BorderView)] = []
    var hud: NSPanel!
    var hudView: HUDView!
    var pointerWindow: NSWindow!
    var pointerView: PointerView!

    var corner = "top"
    var pinned: NSPoint?                    // set once you drag the HUD somewhere
    var holder: Holder = .idle
    var lastUserMove = Date.distantPast
    var lastActed = Date.distantPast
    var paused = false
    let started = Date()
    var configSeen = Date.distantPast
    var labelSeen = Date.distantPast

    // pointer animation, all in Quartz coordinates
    var pointerTarget: CGPoint?
    var pointerAt: CGPoint?
    var pointerCaption = ""
    var pointerCommandSeen = Date.distantPast
    var rippleStart: Date?
    var clickWhenArrived = false

    /// One glow window per display, rebuilt whenever the displays change.
    ///
    /// `contentRect` is measured from the origin of the screen you hand in, so
    /// passing a screen *and* that screen's global frame placed every
    /// secondary display's window one whole screen further out — off the side
    /// of the monitor it was meant to cover. The primary screen starts at
    /// zero, so it looked fine and only the second monitor went dark. No
    /// `screen:` here: the frame is global, and setFrame says so out loud.
    func syncScreens() {
        for (w, _) in glows { w.orderOut(nil) }
        glows.removeAll()
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true                  // click straight through it
            w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
            w.setFrame(screen.frame, display: false)
            w.alphaValue = holder == .idle ? 0 : 1
            let v = BorderView(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.holder = holder
            w.contentView = v
            w.orderFrontRegardless()
            glows.append((w, v))
        }
    }

    func build() {
        syncScreens()

        pointerWindow = NSWindow(contentRect: NSRect(origin: .zero, size: pointerSize),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        pointerWindow.isOpaque = false
        pointerWindow.backgroundColor = .clear
        pointerWindow.hasShadow = false
        pointerWindow.ignoresMouseEvents = true
        pointerWindow.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        pointerWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                            .fullScreenAuxiliary]
        pointerWindow.alphaValue = 0
        pointerView = PointerView(frame: NSRect(origin: .zero, size: pointerSize))
        pointerWindow.contentView = pointerView
        pointerWindow.orderFrontRegardless()

        // A non-activating panel, so clicking pause does not pull focus out of
        // the app the agent is driving — which would change the thing being
        // acted on at the exact moment you are trying to stop it.
        hud = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 38),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        hud.isOpaque = false
        hud.backgroundColor = .clear
        hud.hasShadow = true
        hud.isMovableByWindowBackground = false
        hud.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 3)
        hud.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                  .fullScreenAuxiliary]
        hud.alphaValue = 0
        hudView = HUDView(frame: NSRect(x: 0, y: 0, width: 430, height: 38))
        hudView.onPause = { [weak self] in self?.togglePause() }
        hudView.onMove = { [weak self] in self?.cycleCorner() }
        hudView.onDragged = { [weak self] p in self?.pin(p) }
        hud.contentView = hudView
        hud.orderFrontRegardless()

        corner = cfg.hudCorner
        if let saved = try? String(contentsOfFile: hudPosPath, encoding: .utf8) {
            let parts = saved.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
            if parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]) {
                pinned = NSPoint(x: x, y: y)
            }
        }
        paused = fm.fileExists(atPath: pausePath)
        placeHUD()
        write()
    }

    // MARK: HUD placement

    /// The screen the cursor is on — so the pause button is never on the other
    /// monitor from your hand when you want it. A HUD you dragged somewhere
    /// deliberately stays put instead; that was a choice, not a default.
    func cursorScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func placeHUD() {
        if let p = pinned {
            if hud.frame.origin != p { hud.setFrameOrigin(p) }
            return
        }
        let f = cursorScreen().visibleFrame
        let w = hud.frame.width, h = hud.frame.height
        let pad: CGFloat = 14
        let origin: NSPoint
        switch corner {
        case "bottom": origin = NSPoint(x: f.midX - w / 2, y: f.minY + pad)
        case "left":   origin = NSPoint(x: f.minX + pad, y: f.midY - h / 2)
        case "right":  origin = NSPoint(x: f.maxX - w - pad, y: f.midY - h / 2)
        default:       origin = NSPoint(x: f.midX - w / 2, y: f.maxY - h - pad)
        }
        if hud.frame.origin != origin { hud.setFrameOrigin(origin) }
    }

    func cycleCorner() {
        // The ⤢ button also un-pins: it is the way back to a tidy position
        // after dragging the thing somewhere awkward.
        if pinned != nil {
            pinned = nil
            try? fm.removeItem(atPath: hudPosPath)
        } else {
            corner = corners[((corners.firstIndex(of: corner) ?? 1) + 1) % corners.count]
        }
        placeHUD()
        log(holder, "hud moved to \(pinned == nil ? corner : "a pinned spot")")
    }

    func pin(_ p: NSPoint) {
        pinned = p
        try? "\(Int(p.x)),\(Int(p.y))".write(toFile: hudPosPath, atomically: true, encoding: .utf8)
        log(holder, "hud dragged to \(Int(p.x)),\(Int(p.y))")
    }

    func togglePause() {
        paused.toggle()
        if paused {
            try? "1".write(toFile: pausePath, atomically: true, encoding: .utf8)
            set(.paused, "you pressed pause")
        } else {
            try? fm.removeItem(atPath: pausePath)
            lastUserMove = Date()
            set(.user, "you released pause")
        }
    }

    // MARK: control

    /// Was that movement the agent's own doing?
    ///
    /// Two signals, because one is not enough. The agent holds a lock for as
    /// long as it is driving — everything inside that window is its own. The
    /// stamp covers single actions taken outside a batch. Guessing from event
    /// timing alone loses the race both ways: a synthetic click arrives late
    /// and looks like a hand, a real hand mid-batch looks synthetic. The lock
    /// has no race to lose.
    func agentIsActing() -> Bool {
        if let t = try? String(contentsOfFile: lockPath, encoding: .utf8),
           let until = Double(t.trimmingCharacters(in: .whitespacesAndNewlines)),
           until > Date().timeIntervalSince1970 { return true }
        if let at = try? fm.attributesOfItem(atPath: stampPath),
           let m = at[.modificationDate] as? Date {
            return Date().timeIntervalSince(m) < cfg.selfWindow
        }
        return false
    }

    /// A run the agent opened and will close itself.
    ///
    /// The glow follows the *run*, not the individual clicks. An agent that
    /// presses something every couple of seconds would otherwise strobe the
    /// screen on and off between its own steps, which reads as a fault rather
    /// than as work — and trains you to ignore it.
    ///
    /// This deliberately does *not* suppress user detection. The lock does
    /// that, for the few milliseconds either side of synthetic input. Move
    /// your mouse mid-run and the screen is yours immediately, exactly as it
    /// is when no run is open; the run simply waits and picks back up.
    func sessionActive() -> Bool {
        guard let d = fm.contents(atPath: sessionPath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let until = j["until"] as? Double else { return false }
        return until > Date().timeIntervalSince1970          // a crashed agent expires
    }

    /// What the pill says. The agent rewrites it as the job moves on, so it
    /// describes the work rather than whichever click happened to start it.
    func reloadLabelIfChanged() {
        guard let at = try? fm.attributesOfItem(atPath: labelPath),
              let m = at[.modificationDate] as? Date, m > labelSeen else { return }
        labelSeen = m
        let text = (try? String(contentsOfFile: labelPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hudView.note = text.isEmpty ? taskLabel : String(text.prefix(60))
        hudView.needsDisplay = true
        write()
    }

    func watch() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .otherMouseDragged, .scrollWheel, .leftMouseDown]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self = self, !self.paused else { return }
            if self.agentIsActing() { return }
            self.lastUserMove = Date()
            if self.holder == .agent { self.set(.user, "you moved the mouse") }
        }
        // Monitors get plugged in, unplugged, and rearranged, and this process
        // outlives all of that. A glow built for a screen that no longer
        // exists is worse than none — it is a promise the tool stops keeping.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.syncScreens()
                self.placeHUD()
                self.write()
                self.log(self.holder, "displays changed — glow rebuilt for \(NSScreen.screens.count)")
        }

        // 60Hz, because the pointer is animating on this timer and anything
        // slower looks like it is teleporting between stops.
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func reloadConfigIfChanged() {
        guard let at = try? fm.attributesOfItem(atPath: configPath),
              let m = at[.modificationDate] as? Date, m > configSeen else { return }
        configSeen = m
        cfg = Config.load()
        if pinned == nil { corner = cfg.hudCorner }
        for (_, v) in glows { v.needsDisplay = true }
        hudView.needsDisplay = true
        pointerView.needsDisplay = true
        placeHUD()
        log(holder, "settings reloaded")
    }

    func tick() {
        if Date().timeIntervalSince(started) > cfg.maxSeconds { stop() }
        reloadConfigIfChanged()
        reloadLabelIfChanged()
        // The flag file is the truth, not our copy of it — so `spooky
        // pause` from a terminal and the button on screen mean the same thing,
        // and neither can leave the other stuck.
        let flagged = fm.fileExists(atPath: pausePath)
        if flagged != paused {
            paused = flagged
            if paused { set(.paused, "paused") } else { lastUserMove = Date(); set(.user, "unpaused") }
        }
        placeHUD()
        readPointerCommand()
        animatePointer()

        let acting = agentIsActing() || sessionActive()
        if acting { lastActed = Date() }
        let warm = Date().timeIntervalSince(lastActed) < cfg.linger

        if paused {
            if holder != .paused { set(.paused, "paused") }
        } else if holder == .user {
            if Date().timeIntervalSince(lastUserMove) > cfg.idle {
                set(warm || acting ? .agent : .idle, "you have been still")
            }
        } else if acting || warm {
            if holder != .agent { set(.agent, "the agent started acting") }
        } else if holder != .idle {
            set(.idle, "the agent finished")
        }
    }

    // MARK: the pointer

    /// The agent writes where it is about to act; we glide there and pulse.
    /// A file rather than a socket because it survives either side restarting,
    /// and because a missed frame here costs nothing.
    func readPointerCommand() {
        guard let at = try? fm.attributesOfItem(atPath: pointerPath),
              let m = at[.modificationDate] as? Date, m > pointerCommandSeen,
              let data = fm.contents(atPath: pointerPath),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        pointerCommandSeen = m

        if (j["action"] as? String) == "hide" {
            pointerTarget = nil; pointerAt = nil; clickWhenArrived = false
            return
        }
        guard let x = j["x"] as? Double, let y = j["y"] as? Double else { return }
        pointerTarget = CGPoint(x: x, y: y)
        pointerCaption = (j["label"] as? String) ?? ""
        clickWhenArrived = (j["action"] as? String) == "click"
        // Starting from where your real pointer is makes the first move read
        // as the agent picking up a copy of it, rather than something fading
        // in at a random spot.
        if pointerAt == nil {
            let m = NSEvent.mouseLocation
            let primary = NSScreen.screens.first?.frame.maxY ?? 0
            pointerAt = CGPoint(x: m.x, y: primary - m.y)
        }
        pointerView.caption = pointerCaption
        pointerView.needsDisplay = true
    }

    func animatePointer() {
        let wanted = cfg.showPointer && pointerTarget != nil && holder != .idle
        if (pointerWindow.alphaValue > 0) != wanted {
            NSAnimationContext.runAnimationGroup { c in
                c.duration = wanted ? 0.12 : 0.3
                pointerWindow.animator().alphaValue = wanted ? 1 : 0
            }
        }
        guard let target = pointerTarget, var at = pointerAt else { return }

        // Exponential ease: fast off the mark, settles without overshoot, and
        // needs no keyframes when the target changes mid-flight.
        let k = 1 - pow(0.001, 1.0 / 60.0 / cfg.glideSeconds)
        at.x += (target.x - at.x) * k
        at.y += (target.y - at.y) * k
        let arrived = hypot(target.x - at.x, target.y - at.y) < 1.2
        if arrived { at = target }
        pointerAt = at

        let c = cocoaPoint(fromQuartz: at)
        pointerWindow.setFrameOrigin(NSPoint(x: c.x - hot.x,
                                             y: c.y - (pointerSize.height - hot.y)))

        if arrived && clickWhenArrived {
            clickWhenArrived = false
            rippleStart = Date()
        }
        if let s = rippleStart {
            let age = Date().timeIntervalSince(s)
            if age > 0.55 { rippleStart = nil; pointerView.rippleAge = nil }
            else { pointerView.rippleAge = age }
            pointerView.needsDisplay = true
        }
        if pointerView.holder != holder {
            pointerView.holder = holder
            pointerView.needsDisplay = true
        }
    }

    /// How long until the drawn pointer reaches a target — so the agent can
    /// wait for it and let you actually see where the click is going to land.
    func stop() {
        log(.idle, "stopped")
        try? fm.removeItem(atPath: statePath)
        NSApplication.shared.terminate(nil)
    }

    func set(_ h: Holder, _ why: String) {
        guard h != holder else { return }
        holder = h
        for (w, v) in glows {
            v.holder = h
            v.needsDisplay = true
            NSAnimationContext.runAnimationGroup { c in
                c.duration = h == .idle ? 0.35 : 0.12
                w.animator().alphaValue = h == .idle ? 0 : 1
            }
        }
        if h == .idle { pointerTarget = nil; pointerAt = nil }
        hudView.holder = h == .idle ? .agent : h
        hudView.needsDisplay = true
        NSAnimationContext.runAnimationGroup { c in
            c.duration = h == .idle ? 0.35 : 0.12
            hud.animator().alphaValue = h == .idle ? 0 : 1
        }
        write()
        log(h, why)
    }

    /// Every handover, appended. This is what the agent watches so it can say
    /// "you took control" the moment it happens, instead of discovering it by
    /// having a click land somewhere unexpected.
    func log(_ h: Holder, _ why: String) {
        let line: [String: Any] = ["at": Date().timeIntervalSince1970,
                                   "holder": h.rawValue, "why": why]
        guard let d = try? JSONSerialization.data(withJSONObject: line),
              var text = String(data: d, encoding: .utf8) else { return }
        text += "\n"
        if let fh = FileHandle(forWritingAtPath: eventPath) {
            fh.seekToEndOfFile(); fh.write(text.data(using: .utf8)!); try? fh.close()
        } else {
            try? text.write(toFile: eventPath, atomically: true, encoding: .utf8)
        }
    }

    func write() {
        let payload: [String: Any] = [
            "holder": holder.rawValue, "paused": paused,
            "since": Date().timeIntervalSince1970, "idle_seconds": cfg.idle,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "screens": NSScreen.screens.count,
            "hud": pinned == nil ? corner : "pinned", "label": hudView.note,
            "session": sessionActive(),
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload) {
            try? d.write(to: URL(fileURLWithPath: statePath))
        }
    }
}

try? fm.createDirectory(atPath: home, withIntermediateDirectories: true)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)                 // no Dock icon, no menu bar
let presence = Presence()
presence.build()
presence.watch()

// Held for the process lifetime — a dropped source stops delivering signals.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { presence.stop() }
    src.resume()
    signalSources.append(src)
}
app.run()
