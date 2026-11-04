import AppKit

/// A currently connected display, with frames in Accessibility coordinates
/// (global, origin at the top-left of the primary display, y grows downwards).
struct ScreenRef {
    let key: String
    let systemName: String
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let isBuiltin: Bool
}

enum Screens {
    /// Stable identifier for a display. DisplayLink displays get a new
    /// CGDirectDisplayID on every reconnect, so we key on vendor/model/serial.
    static func current() -> [ScreenRef] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryMaxY = primary.frame.maxY

        func flip(_ r: NSRect) -> CGRect {
            CGRect(x: r.minX, y: primaryMaxY - r.maxY, width: r.width, height: r.height)
        }

        struct Raw { let screen: NSScreen; let id: CGDirectDisplayID; let vendor: UInt32; let model: UInt32; let serial: UInt32; let builtin: Bool }

        let raws: [Raw] = screens.compactMap { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            return Raw(screen: screen, id: id,
                       vendor: CGDisplayVendorNumber(id),
                       model: CGDisplayModelNumber(id),
                       serial: CGDisplaySerialNumber(id),
                       builtin: CGDisplayIsBuiltin(id) != 0)
        }

        // Displays without a serial number fall back to their left-to-right
        // order among displays of the same vendor/model.
        var positionIndex: [Int: Int] = [:]
        let groups = Dictionary(grouping: raws.indices.filter { !raws[$0].builtin && raws[$0].serial == 0 }) {
            "\(raws[$0].vendor)-\(raws[$0].model)"
        }
        for (_, idxs) in groups {
            for (n, i) in idxs.sorted(by: { raws[$0].screen.frame.minX < raws[$1].screen.frame.minX }).enumerated() {
                positionIndex[i] = n + 1
            }
        }

        var seen: [String: Int] = [:]
        return raws.indices.map { i in
            let r = raws[i]
            var key: String
            if r.builtin {
                key = "builtin"
            } else if r.serial != 0 {
                key = "\(r.vendor)-\(r.model)-\(r.serial)"
            } else {
                key = "\(r.vendor)-\(r.model)-pos\(positionIndex[i] ?? 0)"
            }
            seen[key, default: 0] += 1
            if seen[key]! > 1 { key += "#\(seen[key]!)" }

            return ScreenRef(key: key,
                             systemName: r.builtin ? "MacBook (built-in)" : r.screen.localizedName,
                             displayID: r.id,
                             frame: flip(r.screen.frame),
                             visibleFrame: flip(r.screen.visibleFrame),
                             isBuiltin: r.builtin)
        }
    }

    static func screen(containing rect: CGRect, in screens: [ScreenRef]) -> ScreenRef? {
        screens.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
            .flatMap { area($0.frame.intersection(rect)) > 0 ? $0 : nil }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
