// Drives a person's page and scrolls it under a parked pointer, which is the
// one gesture the hover bug in `.agents/notes/appkit.md` needs and the one the
// AX harness cannot make: "Scrolling moves the rows and not the pointer, and
// only the arrivals are reported".
//
//     xcrun swiftc -O tools/hover_scroll.swift -o .xcbuild/tools/hover_scroll
//     LISTEN_LIBRARY=/tmp/scratch LISTEN_DEBUG=1 \
//         ./Listen.app/Contents/MacOS/Listen > /tmp/trace.log 2>&1 &
//     .xcbuild/tools/hover_scroll <pid> 25
//     grep "hover" /tmp/trace.log      # every `in` must have an `out` under it
//
// Two things it knows that cost an hour each:
//
// 1. A wheel-click scroll does not reproduce the bug. The gesture has to be a
//    trackpad's: continuous, phased began/changed/ended, and then a momentum
//    tail. Responsive scrolling only runs for that shape.
// 2. `kAXSelectedRowsAttribute` takes the row *elements*. An array of indices
//    is accepted, returns success, and selects nothing, which reads exactly
//    like a roster that ignores AX.
//
// It parks the pointer on the list for the length of the run and puts it back
// where it found it, so it takes the mouse off whoever is at the keyboard.
import Cocoa

let pid = pid_t(CommandLine.arguments[1])!
let ticks = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "18")!
let app = AXUIElementCreateApplication(pid)

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func kids(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}
func title(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute as String) as? String) ?? "" }
func role(_ el: AXUIElement) -> String { (attr(el, kAXRoleAttribute as String) as? String) ?? "" }
func value(_ el: AXUIElement) -> String { (attr(el, kAXValueAttribute as String) as? String) ?? "" }
func frame(_ el: AXUIElement) -> CGRect {
    guard let p = attr(el, kAXPositionAttribute as String),
          let s = attr(el, kAXSizeAttribute as String) else { return .zero }
    var o = CGPoint.zero, z = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &o)
    AXValueGetValue(s as! AXValue, .cgSize, &z)
    return CGRect(origin: o, size: z)
}
func findMenuItem(_ el: AXUIElement, _ want: String, depth: Int = 0) -> AXUIElement? {
    if depth > 4 { return nil }
    for c in kids(el) {
        if role(c) == "AXMenuItem", title(c) == want { return c }
        if let hit = findMenuItem(c, want, depth: depth + 1) { return hit }
    }
    return nil
}
func find(_ el: AXUIElement, role wanted: String, depth: Int = 0) -> [AXUIElement] {
    if depth > 16 { return [] }
    var out: [AXUIElement] = []
    for c in kids(el) {
        if role(c) == wanted { out.append(c) }
        out += find(c, role: wanted, depth: depth + 1)
    }
    return out
}
func texts(_ el: AXUIElement, _ limit: Int) -> [String] {
    find(el, role: "AXStaticText").prefix(limit).map { value($0) }.filter { !$0.isEmpty }
}

guard let bar = attr(app, kAXMenuBarAttribute as String) else {
    print("no menu bar (Accessibility permission?)"); exit(2)
}
// "sidebar" stays on the library's own list and scrolls that instead, which is
// where the rows carrying a `HoverButton` are.
let where_ = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "person"
if where_ != "sidebar" {
    guard let people = findMenuItem(bar as! AXUIElement, "People") else {
        print("no People item"); exit(2)
    }
    print("pressing People: \(AXUIElementPerformAction(people, kAXPressAction as CFString).rawValue)")
    usleep(1_500_000)
}

guard let wins = attr(app, kAXWindowsAttribute as String) as? [AXUIElement],
      let win = wins.max(by: { frame($0).width * frame($0).height
                               < frame($1).width * frame($1).height })
else { print("no window"); exit(2) }
print("windows: \(wins.map { frame($0) })")
let winFrame = frame(win)
print("window \(winFrame)")

let tables = find(win, role: "AXTable")
print("tables: \(tables.count)")
if where_ != "sidebar", let table = tables.first {
    let rows = find(table, role: "AXRow")
    print("roster rows: \(rows.count), first: \(texts(table, 6))")
    // Row 0 is the section heading in the roster, so the first person is 1.
    func rightTexts() -> [String] {
        find(win, role: "AXStaticText")
            .filter { frame($0).minX > winFrame.midX }
            .prefix(8).map { value($0) }
    }
    // The rows are elements, not indices: `kAXSelectedRowsAttribute` takes the
    // row elements themselves, and an array of numbers is accepted and ignored.
    let wanted = rows.first { texts($0, 4).contains("Maxime") } ?? rows.first
    if let wanted {
        AXUIElementSetAttributeValue(wanted, kAXSelectedAttribute as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(table, kAXSelectedRowsAttribute as CFString,
                                     [wanted] as CFArray)
        usleep(2_000_000)
        print("selected \(texts(wanted, 4)), right pane: \(rightTexts())")
    }
}

print("right pane: \(find(win, role: "AXStaticText").filter { frame($0).minX > winFrame.midX }.prefix(12).map { value($0) })")
// The list is on the right half of the window, under the person's header.
let target = where_ == "sidebar"
    ? CGPoint(x: winFrame.minX + 200, y: winFrame.minY + 500)
    : CGPoint(x: winFrame.maxX - 250, y: winFrame.minY + 340)
let saved = NSEvent.mouseLocation
let screenH = NSScreen.screens.map(\.frame.maxY).max() ?? 0

print("warp to \(target)")
CGWarpMouseCursorPosition(target)
usleep(500_000)
if let m = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                   mouseCursorPosition: target, mouseButton: .left) {
    m.post(tap: .cghidEventTap)
}
usleep(700_000)
print("--- scrolling ---")
// A trackpad scroll, not a wheel click: continuous, phased, and followed by
// momentum. Responsive scrolling only runs for this shape, and it is the shape
// the bug was reported against.
func scroll(_ delta: Int32, phase: Int64, momentum: Int64) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                          wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
    e.location = target
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.post(tap: .cghidEventTap)
}
scroll(0, phase: 1, momentum: 0)          // began
usleep(20_000)
for _ in 0..<ticks { scroll(-40, phase: 2, momentum: 0); usleep(16_000) }
scroll(0, phase: 4, momentum: 0)          // ended, the finger lifts
usleep(16_000)
scroll(-60, phase: 0, momentum: 1)        // momentum begins
usleep(16_000)
var glide: Int32 = 55
while glide > 2 {                          // and decays, as a real flick does
    scroll(-glide, phase: 0, momentum: 2)
    glide = Int32(Double(glide) * 0.88)
    usleep(16_000)
}
scroll(0, phase: 0, momentum: 3)          // momentum ends
usleep(2_000_000)
print("--- settled ---")
fflush(stdout)
// Held still, so the state after the scroll can be photographed.
usleep(8_000_000)
CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: screenH - saved.y))
print("done")
