import SwiftUI
import AppKit

/// Detail windows are opened explicitly, never selected as an empty launch scene.
@MainActor
final class PaperWindows {
    static let shared = PaperWindows()
    private var controllers: [UUID: NSWindowController] = [:]

    func open(deadline: Deadline, store: Store) {
        if let window = controllers[deadline.id]?.window, window.isVisible {
            window.deminiaturize(nil)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let content = DeadlineWorkspace(deadlineID: deadline.id).environmentObject(store)
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = "\(deadline.name) — \(deadline.kind)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 960, height: 620))
        window.minSize = NSSize(width: 740, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.center()
        let controller = NSWindowController(window: window)
        controllers[deadline.id] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
