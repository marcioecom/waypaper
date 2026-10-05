import AppKit
import CoreGraphics

extension NSScreen {
    var cgDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

enum DisplayIdentity {
    /// One playback target per independent physical display; skips mirror slaves and duplicate IDs.
    static func independentScreens(from screens: [NSScreen]) -> [(screen: NSScreen, displayID: CGDirectDisplayID)] {
        var seen = Set<CGDirectDisplayID>()
        var result: [(NSScreen, CGDirectDisplayID)] = []
        for screen in screens {
            guard let id = screen.cgDisplayID else { continue }
            if CGDisplayMirrorsDisplay(id) != 0 { continue }
            guard seen.insert(id).inserted else { continue }
            result.append((screen, id))
        }
        return result
    }

    static func persistentID(for displayID: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
        }
        let vendor = CGDisplayVendorNumber(displayID)
        let model = CGDisplayModelNumber(displayID)
        let serial = CGDisplaySerialNumber(displayID)
        if serial != 0 {
            return String(format: "serial:%04X-%04X-%08X", vendor, model, serial)
        }
        return String(format: "transient:%u", displayID)
    }

    static func localizedName(for screen: NSScreen) -> String {
        if #available(macOS 10.15, *) {
            let name = screen.localizedName
            if !name.isEmpty { return name }
        }
        return "Monitor"
    }
}
