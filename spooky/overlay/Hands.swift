// Hands — the agent's own mouse and keyboard.
//
// It never moves your cursor, because it never uses a cursor. Every action
// goes through the macOS Accessibility API: it asks the button to press
// itself (AXPress) and hands the text field its new value (AXValue). The
// pointer stays exactly where you left it, in whatever app you were using,
// and the two of you can work at the same time without colliding.
//
// This is how Codex does computer use on a Mac, and checking that is what
// settled the design: its service binary imports the whole AXUIElement
// family and links ScreenCaptureKit, and the only CoreGraphics event symbol
// anywhere in the bundle is CGEventGetFlags — it *reads* modifier keys and
// synthesises nothing. Its cursor-driving API is declared target: "linux",
// for a VM. The little cursor people see on screen is drawn, not real.
//
// Elements are addressed by index into the tree that `tree` printed. The
// walk is deterministic, so the same index means the same element on the
// next call — and `--expect` re-checks the label before acting, so a UI that
// moved underneath the agent fails loudly instead of clicking the wrong row.

import Cocoa
import ApplicationServices

// MARK: - argument plumbing

let argv = CommandLine.arguments
func flag(_ name: String) -> Bool { argv.contains(name) }
func opt(_ name: String) -> String? {
    guard let i = argv.firstIndex(of: name), i + 1 < argv.count else { return nil }
    return argv[i + 1]
}
func optInt(_ name: String, _ fallback: Int) -> Int { Int(opt(name) ?? "") ?? fallback }
func optDouble(_ name: String) -> Double? { Double(opt(name) ?? "") }

func emit(_ obj: Any) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(0)
}
func fail(_ message: String, hint: String? = nil, code: Int32 = 1) -> Never {
    var out: [String: Any] = ["ok": false, "error": message]
    if let hint = hint { out["hint"] = hint }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    exit(code)
}

// MARK: - accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    if let s = v as? String { return s.isEmpty ? nil : s }
    if let n = v as? NSNumber { return n.stringValue }
    return nil
}
func bool(_ el: AXUIElement, _ name: String) -> Bool? { attr(el, name) as? Bool }

func children(_ el: AXUIElement) -> [AXUIElement] {
    guard let v = attr(el, kAXChildrenAttribute as String) else { return [] }
    return (v as? [AXUIElement]) ?? []
}

func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success,
          let list = names as? [String] else { return [] }
    return list
}

func frame(_ el: AXUIElement) -> [String: Double]? {
    guard let p = attr(el, kAXPositionAttribute as String),
          let s = attr(el, kAXSizeAttribute as String) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return ["x": point.x, "y": point.y, "w": size.width, "h": size.height]
}

// The label a human would use for this thing, from whichever attribute the
// app actually filled in. Apps are wildly inconsistent about which one.
func label(_ el: AXUIElement) -> String? {
    for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute,
                kAXHelpAttribute, kAXPlaceholderValueAttribute] as [String] {
        if let s = str(el, key) { return s }
    }
    if let t = attr(el, kAXTitleUIElementAttribute as String) {
        return str(t as! AXUIElement, kAXValueAttribute as String)
            ?? str(t as! AXUIElement, kAXTitleAttribute as String)
    }
    return nil
}

// MARK: - the deterministic walk
//
// Same order every time, so an index printed by `tree` still means the same
// element when `press` re-walks a moment later. Depth-first, children in the
// order the app reports them, no sorting, no set iteration.

struct Node {
    let el: AXUIElement
    let role: String
    let subrole: String?
    let label: String?
    let acts: [String]
    let depth: Int
    let enabled: Bool
    let focused: Bool
    let box: [String: Double]?
}

// Groups that only exist for layout carry no label and no actions. Keeping
// them would bury the eight things you can actually click under four hundred
// you cannot.
func worthReporting(_ n: Node) -> Bool {
    if !n.acts.isEmpty { return true }
    if n.label != nil { return true }
    if n.role == kAXTextFieldRole || n.role == kAXTextAreaRole { return true }
    return false
}

func walk(_ root: AXUIElement, maxNodes: Int, maxDepth: Int) -> [Node] {
    var out: [Node] = []
    var visited = 0

    func visit(_ el: AXUIElement, _ depth: Int) {
        if out.count >= maxNodes || visited >= maxNodes * 12 || depth > maxDepth { return }
        visited += 1
        let role = str(el, kAXRoleAttribute as String) ?? "AXUnknown"
        let node = Node(
            el: el,
            role: role,
            subrole: str(el, kAXSubroleAttribute as String),
            label: label(el),
            acts: actions(el),
            depth: depth,
            enabled: bool(el, kAXEnabledAttribute as String) ?? true,
            focused: bool(el, kAXFocusedAttribute as String) ?? false,
            box: frame(el)
        )
        if worthReporting(node) { out.append(node) }
        for child in children(el) { visit(child, depth + 1) }
    }

    visit(root, 0)
    return out
}

func describe(_ n: Node, _ index: Int) -> [String: Any] {
    var d: [String: Any] = ["index": index, "role": n.role, "depth": n.depth, "actions": n.acts]
    if let s = n.subrole { d["subrole"] = s }
    if let l = n.label { d["label"] = l.count > 200 ? String(l.prefix(200)) + "…" : l }
    if let b = n.box { d["frame"] = b }
    if !n.enabled { d["enabled"] = false }
    if n.focused { d["focused"] = true }
    return d
}

// MARK: - finding the app

func runningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
}

func findApp(_ needle: String) -> NSRunningApplication {
    let want = needle.lowercased()
    let apps = runningApps()
    if let exact = apps.first(where: { ($0.localizedName ?? "").lowercased() == want
                                    || ($0.bundleIdentifier ?? "").lowercased() == want }) { return exact }
    if let partial = apps.first(where: { ($0.localizedName ?? "").lowercased().contains(want) }) { return partial }
    if let pid = Int32(needle), let byPid = NSRunningApplication(processIdentifier: pid) { return byPid }
    fail("no running app matches \(needle)",
         hint: "run `spooky apps` for the list of names it can see")
}

// The element the walk starts from: the app's focused window if it has one,
// otherwise the whole app. Starting at the app would otherwise drag in every
// background window and make indices depend on which window is frontmost.
func rootFor(_ app: NSRunningApplication, windowIndex: Int?) -> (AXUIElement, String) {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    if let wi = windowIndex {
        let windows = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        guard wi < windows.count else {
            fail("window \(wi) does not exist — \(app.localizedName ?? "app") has \(windows.count)")
        }
        return (windows[wi], str(windows[wi], kAXTitleAttribute as String) ?? "window \(wi)")
    }
    if let focused = attr(axApp, kAXFocusedWindowAttribute as String) {
        let w = focused as! AXUIElement
        return (w, str(w, kAXTitleAttribute as String) ?? "focused window")
    }
    let windows = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    if let first = windows.first {
        return (first, str(first, kAXTitleAttribute as String) ?? "window 0")
    }
    return (axApp, app.localizedName ?? "application")
}

func requireTrusted() {
    guard AXIsProcessTrusted() else {
        fail("accessibility permission is not granted to this process",
             hint: "run `spooky setup` — it opens the exact pane and checks the box for you",
             code: 77)
    }
}

// Resolve --index against a fresh walk, and refuse if the label moved.
func resolve(_ nodes: [Node], _ index: Int, expect: String?) -> Node {
    guard index >= 0 && index < nodes.count else {
        fail("index \(index) is out of range — the tree has \(nodes.count) elements",
             hint: "re-run `tree`; the window may have changed since the index was printed")
    }
    let node = nodes[index]
    if let expect = expect {
        let got = node.label ?? ""
        if !got.lowercased().contains(expect.lowercased()) {
            fail("index \(index) is now \"\(got)\", not \"\(expect)\"",
                 hint: "the interface changed after `tree` ran — take a fresh tree and use the new index",
                 code: 65)
        }
    }
    return node
}

// MARK: - commands

let command = argv.count > 1 ? argv[1] : "help"

switch command {

case "trusted":
    emit(["ok": true, "trusted": AXIsProcessTrusted()])

case "apps":
    requireTrusted()
    let rows: [[String: Any]] = runningApps().map { app in
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let windows = (attr(axApp, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        var row: [String: Any] = [
            "name": app.localizedName ?? "?",
            "pid": Int(app.processIdentifier),
            "windows": windows.count,
            "frontmost": app.isActive,
        ]
        if let b = app.bundleIdentifier { row["bundle"] = b }
        let titles = windows.compactMap { str($0, kAXTitleAttribute as String) }
        if !titles.isEmpty { row["titles"] = titles }
        return row
    }
    emit(["ok": true, "apps": rows])

case "tree":
    requireTrusted()
    guard let name = opt("--app") else { fail("tree needs --app NAME") }
    let app = findApp(name)
    let (root, where_) = rootFor(app, windowIndex: opt("--window").flatMap { Int($0) })
    let nodes = walk(root, maxNodes: optInt("--max", 500), maxDepth: optInt("--depth", 60))
    emit([
        "ok": true,
        "app": app.localizedName ?? name,
        "pid": Int(app.processIdentifier),
        "window": where_,
        "count": nodes.count,
        "elements": nodes.enumerated().map { describe($1, $0) },
        "note": "Indices are positions in this list. Pass --expect with the label so a changed window fails instead of acting on the wrong element.",
    ])

case "press", "do":
    requireTrusted()
    guard let name = opt("--app") else { fail("press needs --app NAME") }
    let index = optInt("--index", -1)
    guard index >= 0 else { fail("press needs --index N from `tree`") }
    let app = findApp(name)
    let (root, _) = rootFor(app, windowIndex: opt("--window").flatMap { Int($0) })
    let nodes = walk(root, maxNodes: optInt("--max", 500), maxDepth: optInt("--depth", 60))
    let node = resolve(nodes, index, expect: opt("--expect"))
    let wanted = opt("--action") ?? (node.acts.contains(kAXPressAction as String) ? kAXPressAction as String : node.acts.first ?? "")
    guard !wanted.isEmpty else {
        fail("\(node.role) \"\(node.label ?? "")\" offers no accessibility action",
             hint: "this element cannot be pressed through the accessibility layer — `spooky click` will fall back to a real click, which does borrow the cursor",
             code: 66)
    }
    guard node.enabled else { fail("\"\(node.label ?? node.role)\" is disabled right now") }
    let rc = AXUIElementPerformAction(node.el, wanted as CFString)
    guard rc == .success else {
        fail("\(wanted) was refused by \(app.localizedName ?? name) (AXError \(rc.rawValue))")
    }
    emit(["ok": true, "action": wanted, "role": node.role,
          "label": node.label ?? "", "index": index,
          "cursor_touched": false])

case "set":
    requireTrusted()
    guard let name = opt("--app"), let text = opt("--text") else {
        fail("set needs --app NAME --index N --text \"...\"")
    }
    let index = optInt("--index", -1)
    guard index >= 0 else { fail("set needs --index N from `tree`") }
    let app = findApp(name)
    let (root, _) = rootFor(app, windowIndex: opt("--window").flatMap { Int($0) })
    let nodes = walk(root, maxNodes: optInt("--max", 500), maxDepth: optInt("--depth", 60))
    let node = resolve(nodes, index, expect: opt("--expect"))
    let key = flag("--selection") ? kAXSelectedTextAttribute as String : kAXValueAttribute as String
    let settable: Bool = {
        var b = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(node.el, key as CFString, &b)
        return b.boolValue
    }()
    guard settable else {
        fail("\(node.role) \"\(node.label ?? "")\" will not accept text through accessibility",
             hint: "some editors only take typed keys — `spooky type` falls back to real keystrokes",
             code: 66)
    }
    let rc = AXUIElementSetAttributeValue(node.el, key as CFString, text as CFTypeRef)
    guard rc == .success else { fail("the field refused the value (AXError \(rc.rawValue))") }
    emit(["ok": true, "set": key, "index": index, "role": node.role,
          "label": node.label ?? "", "chars": text.count, "cursor_touched": false])

case "focus":
    requireTrusted()
    guard let name = opt("--app") else { fail("focus needs --app NAME") }
    let app = findApp(name)
    let index = optInt("--index", -1)
    if index < 0 {
        app.activate(options: [])
        emit(["ok": true, "focused": app.localizedName ?? name, "cursor_touched": false])
    }
    let (root, _) = rootFor(app, windowIndex: opt("--window").flatMap { Int($0) })
    let nodes = walk(root, maxNodes: optInt("--max", 500), maxDepth: optInt("--depth", 60))
    let node = resolve(nodes, index, expect: opt("--expect"))
    let rc = AXUIElementSetAttributeValue(node.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    guard rc == .success else { fail("that element will not take focus (AXError \(rc.rawValue))") }
    emit(["ok": true, "focused": node.label ?? node.role, "index": index, "cursor_touched": false])

case "at":
    requireTrusted()
    guard let x = optDouble("--x"), let y = optDouble("--y") else { fail("at needs --x N --y N") }
    let system = AXUIElementCreateSystemWide()
    var found: AXUIElement?
    guard AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &found) == .success,
          let el = found else {
        fail("nothing accessible at \(Int(x)), \(Int(y))")
    }
    var pid: pid_t = 0
    AXUIElementGetPid(el, &pid)
    let owner = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    emit(["ok": true, "app": owner, "role": str(el, kAXRoleAttribute as String) ?? "?",
          "label": label(el) ?? "", "actions": actions(el),
          "frame": frame(el) ?? [:],
          "note": "Looked up by position — no pointer moved to get here."])

default:
    emit([
        "ok": true,
        "usage": [
            "apps", "tree --app NAME [--window N] [--max 500]",
            "press --app NAME --index N [--expect LABEL] [--action AXPress]",
            "set --app NAME --index N --text \"...\" [--selection] [--expect LABEL]",
            "focus --app NAME [--index N]", "at --x N --y N", "trusted",
        ],
        "note": "Every one of these acts through the accessibility layer. None of them move your cursor.",
    ])
}
