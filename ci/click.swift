import Cocoa
// usage: click <fx> <fy> [double] | key <code> | scroll <dy>
// fx, fy: доли окна Yume (0..1, от левого верхнего угла)
func yumeFrame() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var best: CGRect?
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "Yume" {
        guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.width > 400, (best == nil || r.width * r.height > best!.width * best!.height) { best = r }
    }
    return best
}
let a = CommandLine.arguments
guard a.count >= 2 else { exit(2) }
func post(_ type: CGEventType, _ p: CGPoint, clicks: Int64 = 1) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
    e?.setIntegerValueField(.mouseEventClickState, value: clicks)
    e?.post(tap: .cghidEventTap)
}
switch a[1] {
case "click":
    guard let f = yumeFrame(), a.count >= 4, let fx = Double(a[2]), let fy = Double(a[3]) else { print("no window"); exit(1) }
    let p = CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * fy)
    print("click at", p, "window", f)
    post(.mouseMoved, p); usleep(150_000)
    let n: Int64 = (a.count > 4 && a[4] == "double") ? 2 : 1
    for i in 1...n { post(.leftMouseDown, p, clicks: i); usleep(60_000); post(.leftMouseUp, p, clicks: i); usleep(90_000) }
case "key":
    guard let code = UInt16(a[2]) else { exit(2) }
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down); e?.post(tap: .cghidEventTap); usleep(60_000)
    }
case "scroll":
    guard let dy = Int32(a[2]) else { exit(2) }
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)
    e?.post(tap: .cghidEventTap)
default: exit(2)
}
