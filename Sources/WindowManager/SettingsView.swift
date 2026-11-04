import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject private var store = Store.shared
    @ObservedObject private var coordinator = Coordinator.shared

    /// Layout whose rules are shown in the editor (defaults to the active one).
    @State private var editingID: UUID?
    @State private var layoutToDelete: Layout?

    private var editing: Layout? {
        editingID.flatMap(store.layout) ?? store.activeLayout
    }

    var body: some View {
        Form {
            if !coordinator.isTrusted {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Window Manager needs Accessibility access to move windows.")
                        Spacer()
                        Button("Open…") { openAccessibilitySettings() }
                    }
                }
            }

            layoutsSection
            if let editing { rulesSection(editing) }
            displaysSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 760, minHeight: 620)
        .onAppear { coordinator.refreshScreens() }
        .confirmationDialog(
            "Delete layout “\(layoutToDelete?.name ?? "")”?",
            isPresented: Binding(get: { layoutToDelete != nil }, set: { if !$0 { layoutToDelete = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let id = layoutToDelete?.id {
                    if editingID == id { editingID = nil }
                    store.deleteLayout(id)
                }
                layoutToDelete = nil
            }
        }
    }

    // MARK: - Layouts

    private var layoutsSection: some View {
        Section {
            if store.layouts.isEmpty {
                Text("No layouts yet. Arrange your windows and click “Save Current Arrangement…”.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(store.layouts.enumerated()), id: \.element.id) { i, layout in
                layoutRow(layout, index: i)
            }
        } header: {
            HStack {
                Text("Layouts")
                Spacer()
                Button("Save Current Arrangement…") {
                    if let id = coordinator.promptSaveNewLayout() { editingID = id }
                }
                Button("Empty Layout") {
                    editingID = store.addLayout(name: "New Layout")
                }
            }
        } footer: {
            Text("The active layout (●) is applied automatically when displays are connected or an app launches.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func layoutRow(_ layout: Layout, index: Int) -> some View {
        let isActive = store.activeLayout?.id == layout.id
        let isEditing = editing?.id == layout.id
        return HStack(spacing: 10) {
            Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .help(isActive ? "Active layout" : "")
            TextField("Name", text: nameBinding(layout.id))
                .textFieldStyle(.roundedBorder)
            Text("\(layout.rules.count) \(layout.rules.count == 1 ? "app" : "apps")")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(index < 9 ? "⌃⌥⌘\(index + 1)" : "")
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: 56)
            Button("Apply") { coordinator.apply(layoutID: layout.id) }
            Button(isEditing ? "Editing" : "Edit") { editingID = layout.id }
                .disabled(isEditing)
                .frame(width: 120)
            Menu {
                Button("Update with Current Arrangement") { coordinator.captureInto(layoutID: layout.id) }
                Button("Duplicate") { store.duplicateLayout(layout.id) }
                Button("Move Up") { store.moveLayoutUp(layout.id) }.disabled(index == 0)
                Divider()
                Button("Delete…", role: .destructive) { layoutToDelete = layout }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { store.layout(id)?.name ?? "" },
            set: { new in
                if let i = store.layouts.firstIndex(where: { $0.id == id }) { store.layouts[i].name = new }
            }
        )
    }

    private func rulesBinding(_ id: UUID) -> Binding<[Rule]> {
        Binding(
            get: { store.layout(id)?.rules ?? [] },
            set: { new in
                if let i = store.layouts.firstIndex(where: { $0.id == id }) { store.layouts[i].rules = new }
            }
        )
    }

    // MARK: - Rules

    private func rulesSection(_ layout: Layout) -> some View {
        let rules = rulesBinding(layout.id)
        return Section {
            if layout.rules.isEmpty {
                Text("No apps in this layout. Add apps or update it with the current arrangement.")
                    .foregroundStyle(.secondary)
            }
            ForEach(rules) { $rule in
                let perWindow = rule.windows.count > 1
                HStack(spacing: 10) {
                    Toggle("", isOn: $rule.enabled).labelsHidden()
                    AppIcon(bundleID: rule.bundleID)
                    Text(rule.appName)
                        .frame(width: 150, alignment: .leading)
                        .lineLimit(1)
                        .foregroundStyle(rule.enabled ? .primary : .secondary)
                    if perWindow {
                        Text("\(rule.windows.count) windows – display per window")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !rule.windows.isEmpty {
                        displayPicker(Binding(
                            get: { rule.windows[0].displayKey },
                            set: { rule.windows[0].displayKey = $0; rule.displayKey = $0 }
                        ))
                    } else {
                        displayPicker($rule.displayKey)
                    }
                    Picker("Placement", selection: $rule.placement) {
                        ForEach(Placement.allCases.filter { $0 != .saved || !rule.windows.isEmpty }) {
                            Text($0.title).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Button {
                        rules.wrappedValue.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove app from layout")
                }

                if perWindow {
                    ForEach(Array(rule.windows.indices), id: \.self) { i in
                        windowRow(rule: $rule, index: i)
                    }
                }
            }
        } header: {
            HStack {
                Text("Apps in “\(layout.name)”")
                Spacer()
                addRuleMenu(layout)
            }
        }
    }

    /// One saved window of an app that has several.
    private func windowRow(rule: Binding<Rule>, index i: Int) -> some View {
        let window = rule.wrappedValue.windows[i]
        let field = { (kp: WritableKeyPath<SavedWindow, String>) in
            Binding<String>(
                get: { rule.wrappedValue.windows.indices.contains(i) ? rule.wrappedValue.windows[i][keyPath: kp] : "" },
                set: { if rule.wrappedValue.windows.indices.contains(i) { rule.wrappedValue.windows[i][keyPath: kp] = $0 } }
            )
        }
        return HStack(spacing: 10) {
            Image(systemName: "macwindow")
                .foregroundStyle(.secondary)
                .padding(.leading, 56)
            Text(window.title.isEmpty ? "Window \(i + 1)" : "“\(window.title)”")
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(.secondary)
                .frame(width: 180, alignment: .leading)
                .help("Title when saved: \(window.title)")
            TextField("Title contains… (optional)", text: field(\.titleMatch))
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)
                .help("Identifies the window by this text in its title, e.g. the name of a tab or profile. Leave empty to match by the window itself, its title or its order.")
            displayPicker(field(\.displayKey))
            Button {
                rule.wrappedValue.windows.remove(at: i)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove window from layout")
        }
    }

    private func displayPicker(_ selection: Binding<String>) -> some View {
        Picker("Display", selection: selection) {
            ForEach(store.displays) { d in
                Text(displayLabel(d)).tag(d.key)
            }
            if !store.displays.contains(where: { $0.key == selection.wrappedValue }) {
                Text("Unknown Display").tag(selection.wrappedValue)
            }
        }
        .labelsHidden()
    }

    private func addRuleMenu(_ layout: Layout) -> some View {
        Menu("Add App") {
            ForEach(runningApps(notIn: layout), id: \.processIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "?") {
                    addRule(to: layout.id, bundleID: app.bundleIdentifier!, name: app.localizedName ?? app.bundleIdentifier!)
                }
            }
            Divider()
            Button("Choose Other App…") { pickApp(for: layout.id) }
        }
        .fixedSize()
    }

    private func runningApps(notIn layout: Layout) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in !layout.rules.contains { $0.bundleID == app.bundleIdentifier } }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func addRule(to layoutID: UUID, bundleID: String, name: String) {
        guard let i = store.layouts.firstIndex(where: { $0.id == layoutID }),
              !store.layouts[i].rules.contains(where: { $0.bundleID == bundleID }) else { return }
        let defaultDisplay = store.displays.first { $0.key != "builtin" && coordinator.connectedKeys.contains($0.key) }
            ?? store.displays.first
        store.layouts[i].rules.append(Rule(bundleID: bundleID, appName: name, displayKey: defaultDisplay?.key ?? "builtin"))
    }

    private func pickApp(for layoutID: UUID) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            addRule(to: layoutID, bundleID: bid, name: name)
        }
    }

    private func displayLabel(_ d: KnownDisplay) -> String {
        coordinator.connectedKeys.contains(d.key) ? d.name : "\(d.name) (not connected)"
    }

    // MARK: - Displays

    private var displaysSection: some View {
        Section {
            ForEach($store.displays) { $display in
                HStack(spacing: 10) {
                    Circle()
                        .fill(coordinator.connectedKeys.contains(display.key) ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                        .help(coordinator.connectedKeys.contains(display.key) ? "Connected" : "Not connected")
                    TextField("Name", text: $display.name)
                        .textFieldStyle(.roundedBorder)
                    Text(display.key)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 170, alignment: .trailing)
                        .help("Vendor-model-serial number")
                    let inUse = store.layouts.contains { $0.rules.contains { $0.displayKeys.contains(display.key) } }
                    Button {
                        store.displays.removeAll { $0.key == display.key }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(inUse || coordinator.connectedKeys.contains(display.key))
                    .help(inUse ? "Used in a layout" : "Forget display")
                }
            }
        } header: {
            HStack {
                Text("Displays")
                Spacer()
                Button("Identify") { coordinator.identifyScreens() }
                    .help("Briefly shows each display's name on it.")
            }
        } footer: {
            Text("Give your displays meaningful names (e.g. “Left”, “Center”, “Right”). They are recognized by serial number – even if DisplayLink numbers them differently after reconnecting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Automatically apply the active layout when displays are connected/disconnected or an app launches", isOn: $store.autoApply)
            LabeledContent("Delay after display change") {
                HStack {
                    Slider(value: $store.delay, in: 1...15, step: 1).frame(width: 180)
                    Text("\(Int(store.delay)) s").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { coordinator.launchAtLogin },
                set: { coordinator.launchAtLogin = $0 }
            ))
            LabeledContent("Keyboard shortcuts") {
                VStack(alignment: .trailing) {
                    Text("⌃⌥⌘1 … 9  Apply layout")
                    Text("⌃⌥⌘W  Reapply active layout")
                }
                .monospaced()
            }
            LabeledContent("Status") { Text(coordinator.status).foregroundStyle(.secondary) }
        }
    }
}

private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed").resizable()
            }
        }
        .frame(width: 20, height: 20)
    }
}
