import AppKit
import ApplicationServices

/// An element of another app's accessibility tree: what the harness reads the screen and acts through.
/// Each call is a request the app answers on its main thread, so none is made while a step is timed.
struct AXElement: CustomStringConvertible {
    let ref: AXUIElement

    static func application(_ pid: pid_t) -> AXElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 10)
        return AXElement(ref: element)
    }

    static var systemWide: AXElement { AXElement(ref: AXUIElementCreateSystemWide()) }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(ref, attribute as CFString, &value) == .success ? value : nil
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }

    func element(_ attribute: String) -> AXElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElement(ref: value as! AXUIElement)
    }

    func elements(_ attribute: String) -> [AXElement] {
        (value(attribute) as? [AnyObject] ?? []).compactMap { item in
            CFGetTypeID(item) == AXUIElementGetTypeID() ? AXElement(ref: item as! AXUIElement) : nil
        }
    }

    var role: String { string(kAXRoleAttribute) ?? "" }
    var subrole: String { string(kAXSubroleAttribute) ?? "" }
    var identifier: String { string(kAXIdentifierAttribute) ?? "" }
    var title: String { string(kAXTitleAttribute) ?? "" }
    var label: String { string(kAXDescriptionAttribute) ?? "" }
    var children: [AXElement] { elements(kAXChildrenAttribute) }
    var parent: AXElement? { element(kAXParentAttribute) }
    var windows: [AXElement] { elements(kAXWindowsAttribute) }

    var pid: pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(ref, &pid)
        return pid
    }

    var frame: CGRect? {
        guard let position = value(kAXPositionAttribute), let size = value(kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    func press() throws {
        let result = AXUIElementPerformAction(ref, kAXPressAction as CFString)
        guard result == .success else { throw HarnessFailure("Couldn't press \(self): AX error \(result.rawValue)") }
    }

    func set(_ attribute: String, to value: CFTypeRef) throws {
        let result = AXUIElementSetAttributeValue(ref, attribute as CFString, value)
        guard result == .success else { throw HarnessFailure("Couldn't set \(attribute) of \(self): AX error \(result.rawValue)") }
    }

    /// The first element, breadth first, that `matches`, among at most `limit` elements.
    func first(limit: Int = 20_000, where matches: (AXElement) -> Bool) -> AXElement? {
        var queue = [self], index = 0
        while index < queue.count, index < limit {
            let element = queue[index]
            index += 1
            if matches(element) { return element }
            queue += element.children
        }
        return nil
    }

    func first(identifier: String) -> AXElement? { first { $0.identifier == identifier } }

    /// The nearest ancestor (or itself) with this role.
    func ancestor(role: String) -> AXElement? {
        var element: AXElement? = self
        while let current = element {
            if current.role == role { return current }
            element = current.parent
        }
        return nil
    }

    var description: String {
        var parts = [role]
        if !subrole.isEmpty { parts.append(subrole) }
        if !identifier.isEmpty { parts.append("#\(identifier)") }
        if !title.isEmpty { parts.append("title=\"\(title.prefix(60))\"") }
        if !label.isEmpty { parts.append("desc=\"\(label.prefix(60))\"") }
        if let value = value(kAXValueAttribute) as? String, !value.isEmpty { parts.append("value=\"\(value.prefix(60))\"") }
        if let frame { parts.append(String(format: "@%.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height)) }
        return parts.joined(separator: " ")
    }

    /// The tree under it, one element a line, for writing a journey (`botchu-journeys dump`).
    func dump(depth: Int = 0, maxDepth: Int = 40, into lines: inout [String]) {
        lines.append(String(repeating: "  ", count: depth) + description)
        guard depth < maxDepth else { return }
        for child in children { child.dump(depth: depth + 1, maxDepth: maxDepth, into: &lines) }
    }
}

struct HarnessFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

enum Permission {
    /// Fails fast, naming what to grant, when this process can't use the Accessibility API.
    static func requireAccessibility() throws {
        guard !AXIsProcessTrusted() else { return }
        let app = responsibleApp().map { "\($0.lastPathComponent) (\($0.path))" } ?? "the app this command runs in (Terminal, iTerm or BotChu)"
        throw HarnessFailure("""
            This process can't use the Accessibility API, which the journeys drive BotChu through.
            Grant Accessibility to \(app) in System Settings ▸ Privacy & Security ▸ Accessibility, then run this again.
            """)
    }

    /// The nearest app bundle among this process's ancestors, which macOS asks the permission of.
    static func responsibleApp() -> URL? {
        var pid = getpid()
        for _ in 0..<32 where pid > 1 {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if let range = path.range(of: ".app/") { return URL(fileURLWithPath: String(path[..<range.lowerBound]) + ".app") }
            }
            var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            guard sysctl(&name, 4, &info, &size, nil, 0) == 0, info.kp_eproc.e_ppid != pid else { return nil }
            pid = info.kp_eproc.e_ppid
        }
        return nil
    }
}
