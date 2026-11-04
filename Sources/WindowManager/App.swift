import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Coordinator.shared.start() }
    }
}

@main
struct WindowManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Window Manager", systemImage: "macwindow.on.rectangle") {
            MenuContent()
        }

        Window("Window Manager", id: "settings") {
            SettingsView()
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentMinSize)
    }
}

let layoutShortcutModifiers: EventModifiers = [.control, .option, .command]

private struct MenuContent: View {
    @ObservedObject private var coordinator = Coordinator.shared
    @ObservedObject private var store = Store.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !coordinator.isTrusted {
            Button("⚠︎ Bedienungshilfen-Zugriff erlauben…") { openAccessibilitySettings() }
            Divider()
        }

        Section("Layouts") {
            if store.layouts.isEmpty {
                Text("Noch keine Layouts gespeichert")
            }
            ForEach(Array(store.layouts.enumerated()), id: \.element.id) { i, layout in
                let item = Toggle(layout.name, isOn: Binding(
                    get: { store.activeLayout?.id == layout.id },
                    set: { _ in coordinator.apply(layoutID: layout.id) }
                ))
                if i < 9 {
                    item.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: layoutShortcutModifiers)
                } else {
                    item
                }
            }
        }

        Divider()
        Menu("Aktuelle Anordnung speichern") {
            Button("Als neues Layout…") { coordinator.promptSaveNewLayout() }
            if !store.layouts.isEmpty {
                Divider()
                ForEach(store.layouts) { layout in
                    Button("In „\(layout.name)“ übernehmen") { coordinator.captureInto(layoutID: layout.id) }
                }
            }
        }
        Button("Aktives Layout erneut anwenden") { coordinator.applyNow() }
            .keyboardShortcut("w", modifiers: layoutShortcutModifiers)
            .disabled(store.layouts.isEmpty)
        Button("Bildschirme identifizieren") { coordinator.identifyScreens() }
        Divider()
        Text(coordinator.status)
        Divider()
        Button("Einstellungen…") {
            openWindow(id: "settings")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Beenden") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

func openAccessibilitySettings() {
    WindowMover.requestTrust()
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
        NSWorkspace.shared.open(url)
    }
}
