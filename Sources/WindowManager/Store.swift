import AppKit

enum Placement: String, Codable, CaseIterable, Identifiable {
    case saved, keepRelative, maximize, leftHalf, rightHalf, center
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saved: "Gespeicherte Position"
        case .keepRelative: "Position beibehalten"
        case .maximize: "Maximieren"
        case .leftHalf: "Linke Hälfte"
        case .rightHalf: "Rechte Hälfte"
        case .center: "Zentrieren"
        }
    }
}

/// One window of an app as it was when the layout was saved.
struct SavedWindow: Codable, Identifiable {
    var id = UUID()
    var displayKey: String
    /// Frame relative to the screen's visible area (0…1).
    var frame: CGRect
    /// Window title at the time of saving (for browsers: the active tab).
    var title: String = ""
    /// macOS window number. Stable while the window stays open, so it reliably
    /// identifies the window across dock/undock; meaningless after the app restarts.
    var windowID: UInt32?
    /// Optional, user-defined: the window is recognised by this text in its title.
    var titleMatch: String = ""

    var trimmedTitleMatch: String { titleMatch.trimmingCharacters(in: .whitespaces) }

    init(displayKey: String, frame: CGRect, title: String = "", windowID: UInt32? = nil) {
        self.displayKey = displayKey
        self.frame = frame
        self.title = title
        self.windowID = windowID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        displayKey = try c.decode(String.self, forKey: .displayKey)
        frame = try c.decode(CGRect.self, forKey: .frame)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        windowID = try c.decodeIfPresent(UInt32.self, forKey: .windowID)
        titleMatch = try c.decodeIfPresent(String.self, forKey: .titleMatch) ?? ""
    }
}

struct Rule: Codable, Identifiable {
    var id = UUID()
    var bundleID: String
    var appName: String
    /// Target for placements other than `.saved`, and for windows that match no saved window.
    var displayKey: String
    var placement: Placement = .keepRelative
    var enabled = true
    /// Saved windows, front-most first. Used by `.saved`.
    var windows: [SavedWindow] = []

    init(bundleID: String, appName: String, displayKey: String,
         placement: Placement = .keepRelative, windows: [SavedWindow] = []) {
        self.bundleID = bundleID
        self.appName = appName
        self.displayKey = displayKey
        self.placement = placement
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case id, bundleID, appName, displayKey, placement, enabled, windows
        case savedFrames // previous format, read-only
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decode(String.self, forKey: .appName)
        displayKey = try c.decode(String.self, forKey: .displayKey)
        placement = try c.decodeIfPresent(Placement.self, forKey: .placement) ?? .keepRelative
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        if let windows = try c.decodeIfPresent([SavedWindow].self, forKey: .windows) {
            self.windows = windows
        } else {
            let frames = try c.decodeIfPresent([CGRect].self, forKey: .savedFrames) ?? []
            windows = frames.map { [displayKey] in SavedWindow(displayKey: displayKey, frame: $0) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(appName, forKey: .appName)
        try c.encode(displayKey, forKey: .displayKey)
        try c.encode(placement, forKey: .placement)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(windows, forKey: .windows)
    }

    /// All displays this rule may put windows on.
    var displayKeys: Set<String> { Set([displayKey] + windows.map(\.displayKey)) }
}

struct Layout: Codable, Identifiable {
    var id = UUID()
    var name: String
    var rules: [Rule] = []
}

struct KnownDisplay: Codable, Identifiable, Hashable {
    var key: String
    var name: String
    var id: String { key }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var layouts: [Layout] { didSet { save(layouts, "layouts") } }
    @Published var activeLayoutID: UUID? { didSet { defaults.set(activeLayoutID?.uuidString, forKey: "activeLayout") } }
    @Published var displays: [KnownDisplay] { didSet { save(displays, "displays") } }
    @Published var autoApply: Bool { didSet { defaults.set(autoApply, forKey: "autoApply") } }
    @Published var delay: Double { didSet { defaults.set(delay, forKey: "delay") } }

    private let defaults = UserDefaults.standard

    private init() {
        var migrated = false
        if let saved: [Layout] = Self.load("layouts") {
            layouts = saved
        } else if let oldRules: [Rule] = Self.load("rules"), !oldRules.isEmpty {
            // Version 1 had a single, unnamed rule list.
            layouts = [Layout(name: "Standard", rules: oldRules)]
            migrated = true
        } else {
            layouts = []
        }
        activeLayoutID = defaults.string(forKey: "activeLayout").flatMap(UUID.init(uuidString:))
        displays = Self.load("displays") ?? []
        autoApply = defaults.object(forKey: "autoApply") as? Bool ?? true
        delay = defaults.object(forKey: "delay") as? Double ?? 3

        if migrated {
            save(layouts, "layouts")
            defaults.removeObject(forKey: "rules")
        }
    }

    /// The layout used for automatic arranging. Falls back to the first one.
    var activeLayout: Layout? {
        layouts.first { $0.id == activeLayoutID } ?? layouts.first
    }

    func layout(_ id: UUID) -> Layout? { layouts.first { $0.id == id } }

    func displayName(_ key: String) -> String {
        displays.first { $0.key == key }?.name ?? "Unbekannter Bildschirm"
    }

    func register(_ screens: [ScreenRef]) {
        for s in screens where !displays.contains(where: { $0.key == s.key }) {
            displays.append(KnownDisplay(key: s.key, name: s.systemName))
        }
    }

    @discardableResult
    func addLayout(name: String, rules: [Rule] = []) -> UUID {
        let new = Layout(name: name, rules: rules)
        layouts.append(new)
        if activeLayoutID.flatMap(layout) == nil { activeLayoutID = new.id }
        return new.id
    }

    func deleteLayout(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        if activeLayoutID == id { activeLayoutID = layouts.first?.id }
    }

    func duplicateLayout(_ id: UUID) {
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { return }
        var copy = layouts[i]
        copy.id = UUID()
        copy.name += " Kopie"
        copy.rules = copy.rules.map { var r = $0; r.id = UUID(); return r }
        layouts.insert(copy, at: i + 1)
    }

    func moveLayoutUp(_ id: UUID) {
        guard let i = layouts.firstIndex(where: { $0.id == id }), i > 0 else { return }
        layouts.swapAt(i, i - 1)
    }

    /// Updates a layout with a freshly captured arrangement. For every captured app the
    /// displays, window positions and placement ("saved position") are overwritten; only
    /// on/off and the user's title filters are kept. Rules for apps that aren't running
    /// right now stay in the layout.
    func merge(_ captured: [Rule], into id: UUID) {
        guard let i = layouts.firstIndex(where: { $0.id == id }) else { return }
        var rules = layouts[i].rules
        for c in captured {
            if let j = rules.firstIndex(where: { $0.bundleID == c.bundleID }) {
                let old = rules[j].windows
                rules[j].appName = c.appName
                rules[j].displayKey = c.displayKey
                rules[j].placement = c.placement
                // Keep user-defined title filters for windows that are still the same.
                rules[j].windows = c.windows.map { new in
                    var w = new
                    let previous = old.first { $0.windowID != nil && $0.windowID == new.windowID }
                        ?? old.first { !$0.trimmedTitleMatch.isEmpty && new.title.localizedCaseInsensitiveContains($0.trimmedTitleMatch) }
                    if let previous { w.titleMatch = previous.titleMatch }
                    return w
                }
            } else {
                rules.append(c)
            }
        }
        layouts[i].rules = rules
    }

    /// Remembers the window numbers of windows that were matched by title or order,
    /// so they are found directly next time.
    func learnWindowIDs(_ ids: [UUID: UInt32], in layoutID: UUID) {
        guard !ids.isEmpty, let i = layouts.firstIndex(where: { $0.id == layoutID }) else { return }
        var layout = layouts[i]
        for r in layout.rules.indices {
            for w in layout.rules[r].windows.indices {
                if let id = ids[layout.rules[r].windows[w].id] { layout.rules[r].windows[w].windowID = id }
            }
        }
        layouts[i] = layout
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
