import SwiftUI
import AppKit

/// A nonblocking progress dialog keeps login and editor windows accessible.
@MainActor
final class ProjectLaunchProgress: NSObject, ObservableObject, NSWindowDelegate {
    let title: String
    @Published private(set) var status: String
    @Published private(set) var finished = false
    @Published private(set) var failed = false
    private var controller: NSWindowController?

    init(title: String, status: String) {
        self.title = title; self.status = status
        super.init()
        let panel = NSPanel()
        panel.title = title
        panel.delegate = self
        panel.styleMask = [.titled, .closable, .utilityWindow]
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = NSHostingController(rootView: ProjectLaunchDialog(model: self))
        panel.setContentSize(NSSize(width: 520, height: 300))
        panel.center()
        controller = NSWindowController(window: panel)
        controller?.showWindow(nil)
    }
    func update(_ status: String) { guard !finished else { return }; self.status = status }
    func finish(_ status: String) { self.status = status; finished = true }
    func fail(_ status: String) { self.status = status; failed = true; finished = true }
    func windowWillClose(_ notification: Notification) {
        controller?.window?.contentViewController = nil
        controller = nil
    }
    func dismiss() { controller?.close(); controller?.window?.contentViewController = nil; controller = nil }
}

private struct ProjectLaunchDialog: View {
    @ObservedObject var model: ProjectLaunchProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                if model.finished {
                    Image(systemName: model.failed ? "exclamationmark.triangle" : "checkmark.circle").font(.title).foregroundStyle(model.failed ? .orange : .green)
                } else { ProgressView().controlSize(.small) }
                Text(model.title).font(.headline)
            }
            ScrollView {
                Text(model.status).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button(model.finished ? "Done" : "Hide progress") { model.dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: 300)
    }
}
