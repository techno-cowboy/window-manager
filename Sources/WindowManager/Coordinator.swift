import AppKit
import ServiceManagement
import os

private let log = Logger(subsystem: "com.nilsmontag.WindowManager", category: "coordinator")

@MainActor
final class Coordinator: ObservableObject {
    static let shared = Coordinator()

    /// Key codes for 1…9 (ANSI/ISO layout), used for ⌃⌥⌘1…9.
    static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    @Published private(set) var connectedKeys: Set<String> = []
    @Published private(set) var status = "Bereit"
    @Published private(set) var isTrusted = WindowMover.isTrusted

    private let store = Store.shared
    private var pending: DispatchWorkItem?
    private var hotKeys: [HotKey] = []
    private var trustTimer: Timer?

    func start() {
        refreshScreens()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }

        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        wnc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bid = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.appLaunched(bid) }
        }

        let mods: NSEvent.ModifierFlags = [.control, .option, .command]
        hotKeys.append(HotKey(keyCode: 13 /* W */, modifiers: mods) { [weak self] in self?.applyNow() })
        for (i, code) in Self.digitKeyCodes.enumerated() {
            hotKeys.append(HotKey(keyCode: code, modifiers: mods) { [weak self] in self?.apply(index: i) })
        }

        if !isTrusted {
            WindowMover.requestTrust()
            // Poll until the user grants Accessibility access in System Settings.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    guard let self, WindowMover.isTrusted else { return }
                    self.isTrusted = true
                    t.invalidate()
                    self.applyNow()
                }
            }
        }
    }

    // MARK: - Events

    private func screensChanged() {
        refreshScreens()
        guard store.autoApply else { return }
        // DisplayLink screens come up in several steps and macOS restores windows
        // on its own afterwards, so wait until things have settled.
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScreens()
                self?.applyNow(reason: "Bildschirmänderung")
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + store.delay, execute: work)
    }

    private func appLaunched(_ bundleID: String?) {
        guard store.autoApply, let bundleID,
              store.activeLayout?.rules.contains(where: { $0.enabled && $0.bundleID == bundleID }) == true
        else { return }
        // Windows appear some time after launch; try a few times.
        for delay in [1.0, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, let layout = self.store.activeLayout else { return }
                let result = WindowMover.apply(rules: layout.rules, onlyBundleID: bundleID)
                self.store.learnWindowIDs(result.learnedIDs, in: layout.id)
            }
        }
    }

    // MARK: - Applying

    func refreshScreens() {
        let screens = Screens.current()
        store.register(screens)
        connectedKeys = Set(screens.map(\.key))
    }

    /// Makes a layout the active one and arranges the windows accordingly.
    func apply(layoutID: UUID) {
        guard store.layout(layoutID) != nil else { return }
        store.activeLayoutID = layoutID
        applyNow()
    }

    func apply(index: Int) {
        guard store.layouts.indices.contains(index) else { return }
        apply(layoutID: store.layouts[index].id)
    }

    /// Re-applies the active layout.
    func applyNow(reason: String? = nil) {
        isTrusted = WindowMover.isTrusted
        guard isTrusted else {
            status = "Keine Bedienungshilfen-Berechtigung"
            WindowMover.requestTrust()
            return
        }
        guard let layout = store.activeLayout else {
            status = "Noch kein Layout gespeichert"
            return
        }
        let result = WindowMover.apply(rules: layout.rules)
        store.learnWindowIDs(result.learnedIDs, in: layout.id)
        let moved = result.moved
        let time = Date().formatted(date: .omitted, time: .shortened)
        status = "„\(layout.name)“ \(time)\(reason.map { " (\($0))" } ?? ""): \(moved) Fenster verschoben"
        log.info("Applied \(layout.name, privacy: .public): moved \(moved) windows")
    }

    // MARK: - Capturing

    /// A rule for every regular app with a visible window, based on where it is right now.
    private func captureRules() -> [Rule]? {
        guard WindowMover.isTrusted else {
            status = "Keine Bedienungshilfen-Berechtigung"
            WindowMover.requestTrust()
            return nil
        }
        let screens = Screens.current()
        store.register(screens)
        refreshScreens()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let bid = app.bundleIdentifier, bid != Bundle.main.bundleIdentifier,
                  let (displayKey, windows) = WindowMover.capture(pid: app.processIdentifier, screens: screens)
            else { return nil }
            return Rule(bundleID: bid, appName: app.localizedName ?? bid, displayKey: displayKey,
                        placement: .saved, windows: windows)
        }
        .sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    /// Asks for a name and saves the current arrangement as a new layout.
    /// Entering the name of an existing layout updates that one instead.
    @discardableResult
    func promptSaveNewLayout() -> UUID? {
        guard let rules = captureRules() else { return nil }

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Aktuelle Anordnung speichern"
        alert.informativeText = "\(rules.count) Apps mit offenen Fenstern werden gespeichert. Wie soll das Layout heißen?"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "z. B. Büro, Meeting, Homeoffice"
        field.stringValue = "Layout \(store.layouts.count + 1)"
        alert.accessoryView = field
        alert.addButton(withTitle: "Speichern")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        var name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Layout \(store.layouts.count + 1)" }

        let id: UUID
        if let existing = store.layouts.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            store.merge(rules, into: existing.id)
            id = existing.id
            status = "„\(existing.name)“ aktualisiert: \(rules.count) Apps"
        } else {
            id = store.addLayout(name: name, rules: rules)
            status = "„\(name)“ gespeichert: \(rules.count) Apps"
        }
        store.activeLayoutID = id
        return id
    }

    /// Overwrites the window positions of an existing layout with the current arrangement.
    func captureInto(layoutID: UUID) {
        guard let layout = store.layout(layoutID), let rules = captureRules() else { return }
        store.merge(rules, into: layoutID)
        store.activeLayoutID = layoutID
        status = "„\(layout.name)“ aktualisiert: \(rules.count) Apps"
    }

    // MARK: - Misc

    func identifyScreens() {
        IdentifyOverlay.show(screens: Screens.current(), store: store)
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                status = "Autostart fehlgeschlagen: \(error.localizedDescription)"
            }
            objectWillChange.send()
        }
    }
}
