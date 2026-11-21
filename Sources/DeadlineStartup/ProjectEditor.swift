import AppKit
import UniformTypeIdentifiers

/// An application that can open a local LaTeX project.
struct ProjectEditor: Identifiable, Hashable {
    static let emacsID = "org.gnu.Emacs"

    let bundleID: String
    let name: String
    var id: String { bundleID }

    private struct Known {
        let name: String
        let bundleIDs: [String]
        /// Folder-based editors get the project folder; others get the main .tex file.
        let opensFolder: Bool
    }
    private static let known: [Known] = [
        Known(name: "TeXShop", bundleIDs: ["TeXShop"], opensFolder: false),
        Known(name: "TeXstudio", bundleIDs: ["org.texstudio.texstudio", "texstudio"], opensFolder: false),
        Known(name: "Visual Studio Code", bundleIDs: ["com.microsoft.VSCode"], opensFolder: true),
        Known(name: "Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], opensFolder: true),
        Known(name: "Zed", bundleIDs: ["dev.zed.Zed"], opensFolder: true),
        Known(name: "Sublime Text", bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"], opensFolder: true),
        Known(name: "BBEdit", bundleIDs: ["com.barebones.bbedit"], opensFolder: false),
    ]
    private static let searchDirectories = ["/Applications", "/Applications/TeX", NSHomeDirectory() + "/Applications"]

    static func isEmacs(_ bundleID: String?) -> Bool { bundleID == nil || bundleID == emacsID }

    /// Emacs (handled by the emacsclient integration) plus the known editors installed on this Mac.
    static func installed() -> [ProjectEditor] {
        [ProjectEditor(bundleID: emacsID, name: "Emacs")] + known.compactMap { editor in
            guard let url = locate(editor), let id = Bundle(url: url)?.bundleIdentifier else { return nil }
            return ProjectEditor(bundleID: id, name: editor.name)
        }
    }

    static func name(for bundleID: String?) -> String {
        if isEmacs(bundleID) { return "Emacs" }
        guard let bundleID else { return "Emacs" }
        if let editor = known.first(where: { $0.bundleIDs.contains(bundleID) }) { return editor.name }
        if let url = applicationURL(for: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func applicationURL(for bundleID: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        return known.first(where: { $0.bundleIDs.contains(bundleID) }).flatMap(locate)
    }

    static func opensFolder(_ bundleID: String) -> Bool {
        known.first(where: { $0.bundleIDs.contains(bundleID) })?.opensFolder ?? false
    }

    private static func locate(_ editor: Known) -> URL? {
        for id in editor.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        return searchDirectories.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(editor.name + ".app") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Lets the user pick any application; returns its bundle identifier.
    @MainActor static func chooseOther() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an application to open the project"
        panel.prompt = "Choose"
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }
}

/// Opens local projects in non-Emacs applications and tracks their sessions.
/// Other apps report no per-document close event, so a session counts time only
/// while its application is frontmost (and the screen is unlocked and awake),
/// and ends when the application quits.
@MainActor
final class ExternalEditors: NSObject {
    static let shared = ExternalEditors()
    private struct OpenProject { let sessionID: UUID; let bundleID: String }
    private var projects: [String: OpenProject] = [:]
    private var screenAvailable = true

    override init() {
        super.init()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(applicationChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationChanged), name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            center.addObserver(self, selector: #selector(screenUnavailable), name: name, object: nil)
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(self, selector: #selector(screenReturned), name: name, object: nil)
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenUnavailable), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenReturned), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    func open(deadline: Deadline, path: String, bundleID: String, store: Store, progress: ProjectLaunchProgress,
              reportError: @escaping @MainActor @Sendable (String) -> Void) {
        let name = ProjectEditor.name(for: bundleID)
        let fail: @MainActor (String) -> Void = { message in progress.fail(message); reportError(message) }
        guard let appURL = ProjectEditor.applicationURL(for: bundleID) else {
            fail("\(name) is not installed on this Mac. Use Open local project in… to choose another application."); return
        }
        let entry = URL(fileURLWithPath: path)
        let target = ProjectEditor.opensFolder(bundleID) ? entry.deletingLastPathComponent() : entry
        let alreadyOpen = projects[path].map { $0.bundleID == bundleID && isRunning(bundleID) } ?? false
        progress.update("Opening the project in \(name)…")
        NSWorkspace.shared.open([target], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message { fail("Could not open \(name): \(message)"); return }
                if alreadyOpen {
                    progress.finish("The project is already open in \(name). No additional opening was counted."); return
                }
                // Reopening in a different app ends the previous app's session.
                if let previous = self.projects.removeValue(forKey: path) { WritingTracker.shared.stop(previous.sessionID) }
                var local = deadline
                local.overleafProjectURL = nil
                let session = WritingTracker.shared.start(deadline: local, store: store, application: name,
                                                          activeTimeOnly: true, active: false)
                WritingTracker.shared.setProject(entry.absoluteString, sessionID: session)
                self.projects[path] = OpenProject(sessionID: session, bundleID: bundleID)
                // The app may have activated before this session existed.
                self.updateActive()
                progress.finish("Project opened in \(name). Time is counted while \(name) is the active app, until it quits.")
            }
        }
    }

    private func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func updateActive() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        for project in projects.values {
            WritingTracker.shared.setActive(screenAvailable && project.bundleID == front, sessionID: project.sessionID)
        }
    }

    @objc private func applicationChanged(_ notification: Notification) { updateActive() }
    @objc private func screenUnavailable(_ notification: Notification) { screenAvailable = false; updateActive() }
    @objc private func screenReturned(_ notification: Notification) { screenAvailable = true; updateActive() }
    @objc private func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let id = app.bundleIdentifier, !isRunning(id) else { return }
        for (path, project) in projects where project.bundleID == id {
            WritingTracker.shared.stop(project.sessionID)
            projects.removeValue(forKey: path)
        }
    }
}
