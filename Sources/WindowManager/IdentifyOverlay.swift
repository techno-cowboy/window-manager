import AppKit
import SwiftUI

/// Shows a large label with the display's name on every screen for a few seconds,
/// so identical monitors can be told apart.
@MainActor
enum IdentifyOverlay {
    private static var windows: [NSWindow] = []

    static func show(screens: [ScreenRef], store: Store) {
        windows.forEach { $0.close() }
        windows = []

        for screen in NSScreen.screens {
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let ref = screens.first(where: { $0.displayID == CGDirectDisplayID(num.uint32Value) })
            else { continue }

            let size = NSSize(width: 520, height: 200)
            let rect = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                              width: size.width, height: size.height)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isOpaque = false
            window.backgroundColor = .clear
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary]
            window.contentView = NSHostingView(rootView: Label(name: store.displayName(ref.key), detail: ref.systemName))
            window.orderFrontRegardless()
            windows.append(window)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            windows.forEach { $0.close() }
            windows = []
        }
    }

    private struct Label: View {
        let name: String
        let detail: String
        var body: some View {
            VStack(spacing: 8) {
                Text(name).font(.system(size: 44, weight: .bold))
                Text(detail).font(.title3).foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
