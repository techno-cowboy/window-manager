import AppKit
import ApplicationServices

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    var frame: CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size,
              CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pos as! AXValue, .cgPoint, &p)
        AXValueGetValue(size as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    func setFrame(_ r: CGRect) {
        var p = r.origin, s = r.size
        let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
        // size → position → size: a window may get clamped while still on the old screen.
        set(kAXSizeAttribute, sv)
        set(kAXPositionAttribute, pv)
        set(kAXSizeAttribute, sv)
    }

    var allWindows: [AXUIElement] { attr(kAXWindowsAttribute) ?? [] }

    /// Standard, visible windows (no sheets, palettes, minimized or fullscreen windows),
    /// front-most first.
    var movableWindows: [AXUIElement] {
        allWindows.filter { w in
            (w.attr(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                && (w.attr(kAXMinimizedAttribute) as Bool?) != true
                && (w.attr("AXFullScreen") as Bool?) != true
        }
    }

    /// The CGWindowID behind an AX window (private but long-standing API, used by
    /// most window managers – there is no public way to get it).
    var windowID: CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(self, &id) == .success && id != 0 ? id : nil
    }
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// A live window of an app, front-most first.
struct LiveWindow {
    let element: AXUIElement
    let frame: CGRect
    let id: CGWindowID?
    let title: String
}

extension AXUIElement {
    var liveWindows: [LiveWindow] {
        movableWindows.compactMap { w in
            w.frame.map { LiveWindow(element: w, frame: $0, id: w.windowID, title: w.attr(kAXTitleAttribute) ?? "") }
        }
    }
}

enum WindowMover {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    struct Result {
        var moved = 0
        /// Window numbers of saved windows that were matched by title or order.
        var learnedIDs: [UUID: UInt32] = [:]
    }

    /// Moves windows of all running apps that have a rule.
    @MainActor
    static func apply(rules: [Rule], onlyBundleID: String? = nil) -> Result {
        var result = Result()
        guard isTrusted else { return result }
        let screens = Screens.current()

        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier,
                  onlyBundleID == nil || onlyBundleID == bid,
                  let rule = rules.first(where: { $0.enabled && $0.bundleID == bid })
            else { continue }
            move(pid: app.processIdentifier, rule: rule, screens: screens, result: &result)
        }
        return result
    }

    private static func move(pid: pid_t, rule: Rule, screens: [ScreenRef], result: inout Result) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)

        // Apps with "enhanced UI" (e.g. Chromium/Electron with VoiceOver hooks) animate
        // or ignore AX moves; switch it off temporarily.
        let enhanced = (appEl.attr("AXEnhancedUserInterface") as Bool?) == true
        if enhanced { appEl.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { appEl.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        let live = appEl.liveWindows
        // Windows that exist but can't be moved right now (e.g. minimized) keep their saved slot.
        let hiddenIDs = Set(appEl.allWindows.compactMap(\.windowID)).subtracting(live.compactMap(\.id))

        let plan = plan(live.map { ($0.id, $0.title, $0.frame) }, rule: rule, screens: screens, hiddenIDs: hiddenIDs)
        for (i, frame) in plan.frames.sorted(by: { $0.key < $1.key }) {
            live[i].element.setFrame(frame)
            result.moved += 1
        }
        result.learnedIDs.merge(plan.learnedIDs) { _, new in new }
    }

    /// Decides where each live window of an app goes. Returns live index → new frame
    /// (only for windows that actually need to move).
    ///
    /// The display comes from the matched saved window (each window has its own);
    /// windows without a match go to the rule's main display. The placement decides
    /// where on that display the window ends up.
    static func plan(_ live: [(id: CGWindowID?, title: String, frame: CGRect)], rule: Rule,
                     screens: [ScreenRef], hiddenIDs: Set<CGWindowID> = [])
        -> (frames: [Int: CGRect], learnedIDs: [UUID: UInt32]) {
        let byKey = Dictionary(screens.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let matches = match(live.map { ($0.id, $0.title) }, to: rule.windows, hiddenIDs: hiddenIDs)
        var frames: [Int: CGRect] = [:]
        var learned: [UUID: UInt32] = [:]

        for (i, w) in live.enumerated() {
            let saved = matches[i].map { rule.windows[$0] }
            if let saved, let id = w.id, saved.windowID != id { learned[saved.id] = id }

            guard let target = byKey[saved?.displayKey ?? rule.displayKey] else { continue } // not connected
            let source = Screens.screen(containing: w.frame, in: screens)

            let newFrame: CGRect
            switch rule.placement {
            case .saved where saved != nil:
                newFrame = denormalize(saved!.frame, in: target.visibleFrame)
            case .saved, .keepRelative:
                if source?.key == target.key { continue } // already on the right display
                newFrame = targetFrame(for: w.frame, from: source, to: target, placement: .keepRelative)
            default:
                newFrame = targetFrame(for: w.frame, from: source, to: target, placement: rule.placement)
            }
            let f = newFrame.integral
            if !nearlyEqual(f, w.frame) { frames[i] = f }
        }
        return (frames, learned)
    }

    /// Assigns live windows (front-most first) to saved windows. Returns live index → saved index.
    ///
    /// Order of precedence:
    /// 1. same window number (window was open the whole time, e.g. re-docking)
    /// 2. user-defined "title contains" filter
    /// 3. identical title as when saved
    /// 4. remaining windows in front-to-back order
    /// Saved windows with a title filter are only matched by 1 or 2.
    static func match(_ live: [(id: CGWindowID?, title: String)], to saved: [SavedWindow],
                      hiddenIDs: Set<CGWindowID> = []) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var free = saved.indices.filter { saved[$0].windowID.map { !hiddenIDs.contains($0) } ?? true }

        func pass(_ fits: (_ live: Int, _ saved: SavedWindow) -> Bool) {
            for l in live.indices where result[l] == nil {
                if let k = free.firstIndex(where: { fits(l, saved[$0]) }) {
                    result[l] = free.remove(at: k)
                }
            }
        }

        pass { l, s in live[l].id != nil && s.windowID == live[l].id }
        pass { l, s in !s.trimmedTitleMatch.isEmpty && live[l].title.localizedCaseInsensitiveContains(s.trimmedTitleMatch) }
        pass { l, s in s.trimmedTitleMatch.isEmpty && !s.title.isEmpty && s.title == live[l].title }
        pass { _, s in s.trimmedTitleMatch.isEmpty }
        return result
    }

    /// Current arrangement of an app: the screen of its front-most window and every
    /// window with its own screen and position.
    static func capture(pid: pid_t, screens: [ScreenRef]) -> (displayKey: String, windows: [SavedWindow])? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let live = appEl.liveWindows
        guard let first = live.first, let main = Screens.screen(containing: first.frame, in: screens) else { return nil }
        let windows = live.map { w in
            let screen = Screens.screen(containing: w.frame, in: screens) ?? main
            return SavedWindow(displayKey: screen.key, frame: normalize(w.frame, in: screen.visibleFrame),
                               title: w.title, windowID: w.id)
        }
        return (main.key, windows)
    }

    static func normalize(_ r: CGRect, in s: CGRect) -> CGRect {
        let w = min(r.width / s.width, 1), h = min(r.height / s.height, 1)
        let x = min(max((r.minX - s.minX) / s.width, 0), 1 - w)
        let y = min(max((r.minY - s.minY) / s.height, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func denormalize(_ r: CGRect, in s: CGRect) -> CGRect {
        CGRect(x: s.minX + r.minX * s.width, y: s.minY + r.minY * s.height,
               width: r.width * s.width, height: r.height * s.height)
    }

    private static func nearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    static func targetFrame(for w: CGRect, from source: ScreenRef?, to target: ScreenRef, placement: Placement) -> CGRect {
        let t = target.visibleFrame
        let size = CGSize(width: min(w.width, t.width), height: min(w.height, t.height))
        switch placement {
        case .maximize:
            return t
        case .leftHalf:
            return CGRect(x: t.minX, y: t.minY, width: (t.width / 2).rounded(), height: t.height)
        case .rightHalf:
            let half = (t.width / 2).rounded()
            return CGRect(x: t.maxX - half, y: t.minY, width: half, height: t.height)
        case .center:
            return CGRect(x: t.midX - size.width / 2, y: t.midY - size.height / 2, width: size.width, height: size.height)
        case .keepRelative, .saved:
            // Keep the window's relative position within the screen's free space.
            var rx: CGFloat = 0.5, ry: CGFloat = 0.5
            if let s = source?.visibleFrame {
                let freeX = s.width - w.width, freeY = s.height - w.height
                if freeX > 0 { rx = min(max((w.minX - s.minX) / freeX, 0), 1) }
                if freeY > 0 { ry = min(max((w.minY - s.minY) / freeY, 0), 1) }
            }
            return CGRect(x: t.minX + rx * (t.width - size.width),
                          y: t.minY + ry * (t.height - size.height),
                          width: size.width, height: size.height)
        }
    }
}
