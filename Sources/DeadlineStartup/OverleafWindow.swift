import SwiftUI
import WebKit
import AppKit

@MainActor
final class OverleafWindows: NSObject {
    static let shared = OverleafWindows()
    private var controllers: [UUID: NSWindowController] = [:]
    private var sessionIDs: [UUID: UUID] = [:]
    private var browsers: [UUID: OverleafBrowserModel] = [:]
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
    }
    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = controllers.first(where: { $0.value.window === window })?.key else { return }
        if let session = sessionIDs.removeValue(forKey: id) { WritingTracker.shared.stop(session) }
        browsers.removeValue(forKey: id)?.close()
        controllers.removeValue(forKey: id)
    }
    func open(deadline: Deadline, store: Store) {
        let progress = ProjectLaunchProgress(title: "Open Overleaf — " + deadline.name, status: "Opening Overleaf…")
        if let existing = store.data.deadlines.first(where: { $0.isSameConference(as: deadline) && controllers[$0.id]?.window != nil }),
           let window = controllers[existing.id]?.window { window.deminiaturize(nil); window.makeKeyAndOrderFront(nil); progress.finish("This project is already open in Overleaf. No additional opening was counted."); return }
        let session = WritingTracker.shared.start(deadline: deadline, store: store, application: "Overleaf")
        sessionIDs[deadline.id] = session
        let browser = OverleafBrowserModel(deadline: deadline, store: store, sessionID: session, progress: progress)
        browsers[deadline.id] = browser
        let window = NSWindow(contentViewController: NSHostingController(rootView: OverleafBrowser(model: browser)))
        window.title = "Overleaf — \(deadline.name)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        controllers[deadline.id] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class OverleafBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let deadline: Deadline
    private let store: Store
    private let sessionID: UUID
    private var closed = false
    private var progress: ProjectLaunchProgress
    @Published var status = "" { didSet { progress.update(status) } }
    @Published var busy = false
    @Published var project: URL?
    @Published var failed = false
    private var importing = false
    private var captured = false
    private var checkingDashboard = false

    init(deadline: Deadline, store: Store, sessionID: UUID, progress: ProjectLaunchProgress) {
        self.progress = progress
        self.deadline = deadline; self.store = store; self.sessionID = sessionID
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let url = deadline.overleafProjectURL.flatMap(OverleafProject.projectURL) {
            project = url
            status = "Loading your linked Overleaf project…"
            webView.load(URLRequest(url: url))
        } else {
            // Sign in before importing, so login redirects cannot lose the import.
            status = "Sign in to Overleaf if asked. Your template project will then be created and linked automatically. You can hide this progress dialog to sign in in the Overleaf window."
            webView.load(URLRequest(url: URL(string: "https://www.overleaf.com/project")!))
        }
        progress.update(status)
    }
    func close() {
        if !progress.finished { progress.finish("Overleaf window closed.") }
        closed = true; webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
    }
    func create() {
        guard !importing, !closed else { return }
        if progress.finished { progress.dismiss(); progress = ProjectLaunchProgress(title: "Create Overleaf project — " + deadline.name, status: "Preparing the template import…") }
        importing = true; captured = false; failed = false
        status = "Overleaf is downloading and importing the configured GitHub template…"
        webView.load(OverleafProject.creationRequest(name: deadline.name))
    }
    func retry() {
        progress.dismiss()
        progress = ProjectLaunchProgress(title: "Open Overleaf — " + deadline.name, status: "Retrying Overleaf…")
        importing = false; failed = false; webView.reload()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { busy = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        busy = false
        guard let url = webView.url else { return }
        if let canonical = OverleafProject.projectURL(url.absoluteString) {
            guard (importing || project == nil), !captured else {
                progress.finish("Project loaded in Overleaf. Writing time and opening count are being tracked.")
                return
            }
            captured = true
            project = canonical
            WritingTracker.shared.setProject(canonical.absoluteString, sessionID: sessionID)
            status = "Saving the Overleaf project link…"
            Task {
                let linked = store.data.linkingOverleaf(canonical.absoluteString, for: deadline)
                if await store.persist(linked) {
                    status = "Project linked and saved to iCloud. Future clicks reopen this project."
                    progress.finish(status)
                } else {
                    status = "Project created, but its link could not be saved. Copy this address before closing: \(canonical.absoluteString)"
                    failed = true
                    progress.fail(status)
                }
            }
        } else if project == nil, !importing, ["overleaf.com", "www.overleaf.com"].contains(url.host?.lowercased() ?? ""),
                  url.path == "/project" || url.path == "/project/" {
            findExistingOrCreate()
        } else if project != nil {
            status = "Complete any sign-in or access prompts in the Overleaf window. Your linked project will then open. You can hide this progress dialog."
        }
    }

    private func findExistingOrCreate() {
        guard !checkingDashboard else { return }
        checkingDashboard = true
        status = "Checking your Overleaf projects…"
        Task {
            defer { checkingDashboard = false }
            for _ in 0..<20 {
                guard !closed, !importing, !captured, let url = webView.url, ["/project", "/project/"].contains(url.path) else { return }
                let script = """
                (() => ({ready: /new project/i.test(document.body.innerText), links: Array.from(document.querySelectorAll('a[href*="/project/"]')).map(a => ({url:a.href, title:(a.getAttribute('title') || a.textContent || '').trim()}))}))()
                """
                if let result = try? await webView.evaluateJavaScript(script) as? [String: Any], result["ready"] as? Bool == true {
                    let links = result["links"] as? [[String: String]] ?? []
                    let matches = links.filter { link in
                        guard let title = link["title"] else { return false }
                        return title.compare(deadline.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                    }.compactMap { $0["url"].flatMap(OverleafProject.projectURL) }
                    let unique = Array(Set(matches))
                    if unique.count == 1 { webView.load(URLRequest(url: unique[0])) }
                    else if unique.count > 1 { status = "Several projects have this name. Open the intended project in the Overleaf window to link it."; progress.finish(status) }
                    else { create() }
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            status = "Open an existing project in the Overleaf window to link it, or choose Create template project."
            progress.finish(status)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        busy = false; failed = true
        status = "Overleaf could not load: \(error.localizedDescription)"
        progress.fail(status)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode == 404, let url = response.url, OverleafProject.projectURL(url.absoluteString) != nil {
            decisionHandler(.cancel)
            project = nil; importing = false
            create()
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private struct OverleafBrowser: View {
    @ObservedObject var model: OverleafBrowserModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status.isEmpty ? "Overleaf" : model.status).font(.callout).textSelection(.enabled)
                Spacer()
                if model.project == nil { Button("Create template project") { model.create() } }
                if model.failed { Button("Reload") { model.retry() } }
                if let project = model.project { Link("Open in browser", destination: project) }
            }.padding(14)
            Divider()
            OverleafWebView(webView: model.webView)
        }.frame(minWidth: 800, minHeight: 550)
    }
}
private struct OverleafWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
