// The accessibility probe the verify scripts drive the app with.
//
// The repo rule is AXUIElementCreateApplication(pid) and nothing else (see
// CLAUDE.md, "Driving the built app against a scratch library"): synthetic
// pointer events confirm the wrong half of the system, and System Events
// resolves pids to whichever copy of Listen it feels like. There is no pyobjc
// on a stock machine, so the scripts compile this file with swiftc instead.
//
//   axprobe texts <pid>              every element, one line each:
//                                    role <tab> subrole <tab> title <tab> value
//   axprobe press <pid> <needle>     AXPress the first pressable element whose
//                                    title, value or description contains
//                                    <needle>, case-insensitively
//   axprobe hasclose <pid> <title>   "yes"/"no": does the window whose title
//                                    contains <title> expose a close button
//
// Exit 3 means this terminal has no Accessibility permission, which is a fact
// about the harness and not about the build.

import AppKit
import ApplicationServices

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    else { return nil }
    return value
}

func string(_ element: AXUIElement, _ name: String) -> String {
    (attribute(element, name) as? String) ?? ""
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func walk(_ element: AXUIElement, depth: Int = 0,
          budget: inout Int, visit: (AXUIElement) -> Bool) {
    guard depth < 60, budget > 0 else { return }
    budget -= 1
    guard visit(element) else { return }
    for child in children(element) {
        walk(child, depth: depth + 1, budget: &budget, visit: visit)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3, let pid = pid_t(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: axprobe texts|press|hasclose <pid> [needle]\n".utf8))
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data(
        "this terminal has no Accessibility permission; grant it in System Settings\n".utf8))
    exit(3)
}

let app = AXUIElementCreateApplication(pid)
var budget = 40_000

switch arguments[1] {
case "texts":
    var lines = 0
    walk(app, budget: &budget) { element in
        let role = string(element, kAXRoleAttribute)
        let subrole = string(element, kAXSubroleAttribute)
        let title = string(element, kAXTitleAttribute)
        let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
        let described = string(element, kAXDescriptionAttribute)
        if !title.isEmpty || !value.isEmpty || !described.isEmpty {
            print("\(role)\t\(subrole)\t\(title)\t\(value)\t\(described)")
            lines += 1
        }
        return true
    }
    // An empty dump is a display asleep or a window that never drew, and a
    // script grepping it for absence would pass on nothing. Make that state
    // loud instead. (".agents": a sleeping display empties the AX tree.)
    exit(lines == 0 ? 4 : 0)

case "press":
    guard arguments.count >= 4 else { exit(2) }
    let needle = arguments[3].lowercased()
    var pressed = false
    walk(app, budget: &budget) { element in
        guard !pressed else { return false }
        let haystack = [string(element, kAXTitleAttribute),
                        (attribute(element, kAXValueAttribute) as? String) ?? "",
                        string(element, kAXDescriptionAttribute)]
            .joined(separator: " ").lowercased()
        if haystack.contains(needle) {
            var names: CFArray?
            AXUIElementCopyActionNames(element, &names)
            if let actions = names as? [String], actions.contains(kAXPressAction) {
                AXUIElementPerformAction(element, kAXPressAction as CFString)
                pressed = true
                return false
            }
        }
        return true
    }
    print(pressed ? "pressed" : "not found")
    exit(pressed ? 0 : 1)

case "focus":
    // axprobe focus <pid> <placeholder-needle>: give the field the caret. The
    // Ask surfaces draw their chips and setup card only once the composer has
    // focus, so a script that reads before focusing reads a bar that is
    // deliberately quiet.
    guard arguments.count >= 4 else { exit(2) }
    let needle = arguments[3].lowercased()
    var focused = false
    walk(app, budget: &budget) { element in
        guard !focused else { return false }
        let role = string(element, kAXRoleAttribute)
        guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
        else { return true }
        guard string(element, kAXPlaceholderValueAttribute).lowercased().contains(needle)
        else { return true }
        focused = AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
        return !focused
    }
    print(focused ? "focused" : "not found")
    exit(focused ? 0 : 1)

case "fields":
    // axprobe fields <pid>: every text field with its placeholder, for
    // debugging a walk that cannot find the one it wants.
    walk(app, budget: &budget) { element in
        let role = string(element, kAXRoleAttribute)
        if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String {
            print("\(role)\t\(string(element, kAXPlaceholderValueAttribute))"
                + "\t\((attribute(element, kAXValueAttribute) as? String) ?? "")")
        }
        return true
    }
    exit(0)

case "settext":
    // axprobe settext <pid> <placeholder-needle> <text>: put text into the
    // field whose placeholder matches, through AX rather than keystrokes, so
    // it lands in the field the assertion is about and no other.
    guard arguments.count >= 5 else { exit(2) }
    let needle = arguments[3].lowercased()
    let text = arguments[4]
    var wrote = false
    walk(app, budget: &budget) { element in
        guard !wrote else { return false }
        let role = string(element, kAXRoleAttribute)
        guard role == kAXTextFieldRole as String || role == kAXTextAreaRole as String
        else { return true }
        let placeholder = string(element, kAXPlaceholderValueAttribute)
        guard placeholder.lowercased().contains(needle) else { return true }
        wrote = AXUIElementSetAttributeValue(
            element, kAXValueAttribute as CFString, text as CFString) == .success
        return !wrote
    }
    print(wrote ? "wrote" : "not found")
    exit(wrote ? 0 : 1)

case "selectrow":
    // The documented shape for a table: set kAXSelectedRowsAttribute on the
    // table, never a synthetic click on the row (CLAUDE.md, "set
    // kAXSelectedRowsAttribute on a table to select a person"). The optional
    // trailing number picks the nth matching row, for lists where a group
    // heading and its row carry the same word.
    guard arguments.count >= 4 else { exit(2) }
    let needle = arguments[3].lowercased()
    let wantedMatch = arguments.count >= 5 ? (Int(arguments[4]) ?? 1) : 1
    var matches = 0
    var selected = false
    walk(app, budget: &budget) { element in
        guard !selected else { return false }
        guard string(element, kAXRoleAttribute) == kAXRowRole as String else { return true }
        var text = ""
        var inner = 500
        walk(element, budget: &inner) { part in
            text += " " + string(part, kAXTitleAttribute)
                + " " + ((attribute(part, kAXValueAttribute) as? String) ?? "")
            return true
        }
        guard text.lowercased().contains(needle) else { return false }
        matches += 1
        guard matches == wantedMatch else { return false }
        var parent = attribute(element, kAXParentAttribute).map { $0 as! AXUIElement }
        var hops = 0
        while let candidate = parent, hops < 6 {
            let role = string(candidate, kAXRoleAttribute)
            if role == kAXTableRole as String || role == kAXOutlineRole as String {
                let rows = [element] as CFArray
                selected = AXUIElementSetAttributeValue(
                    candidate, kAXSelectedRowsAttribute as CFString, rows) == .success
                break
            }
            parent = attribute(candidate, kAXParentAttribute).map { $0 as! AXUIElement }
            hops += 1
        }
        return false
    }
    print(selected ? "selected" : "not found")
    exit(selected ? 0 : 1)

case "hasclose":
    guard arguments.count >= 4 else { exit(2) }
    let needle = arguments[3].lowercased()
    let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    for window in windows {
        let title = string(window, kAXTitleAttribute).lowercased()
        guard title.contains(needle) else { continue }
        let close = attribute(window, kAXCloseButtonAttribute)
        print(close == nil ? "no" : "yes")
        exit(0)
    }
    print("no such window")
    exit(1)

default:
    exit(2)
}
