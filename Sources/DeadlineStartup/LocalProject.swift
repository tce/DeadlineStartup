import AppKit

/// A waiting emacsclient lives for the client frame, so unrelated Emacs windows
/// do not affect the writing session. Never use --no-wait here.
@MainActor
final class LocalProjects: ObservableObject {
    static let shared = LocalProjects()
    private struct OpenProject {
        let process: Process
        let sessionID: UUID
        let frameName: String
    }
    private var projects: [String: OpenProject] = [:]
    private var launching: Set<String> = []
    @Published private(set) var isCreating = false

    // Run startup commands without blocking the UI, retaining their diagnostics.
    private func command(_ executable: URL, _ arguments: [String]) async throws -> (Int32, String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = executable.lastPathComponent == "emacsclient" ? EmacsIntegration.connectionArguments + arguments : arguments
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close(); try? FileManager.default.removeItem(at: log) }
        process.standardOutput = output
        process.standardError = output
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in continuation.resume(returning: finished.terminationStatus) }
            do { try process.run() }
            catch { continuation.resume(throwing: error) }
        }
        return (status, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    private func ensureServer(client: URL, editor: URL) async throws {
        let probe = try await command(client, ["--alternate-editor", "/usr/bin/false", "--eval", "t"])
        guard probe.0 != 0 else { return }
        // An alternate editor is a standalone fallback, not an Emacs server.
        // Start the actual daemon explicitly so emacsclient can wait on a frame.
        let started = try await command(editor, EmacsIntegration.daemonArguments)
        let ready = try await command(client, ["--alternate-editor", "/usr/bin/false", "--eval", "t"])
        guard ready.0 == 0 else {
            throw NSError(domain: "LocalProjects", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "Could not start the Emacs server.\n" + started.1 + "\n" + ready.1])
        }
    }

    private func executables() throws -> (URL, URL) {
        let roots = ["/Applications/Emacs.app/Contents/MacOS", NSHomeDirectory() + "/Applications/Emacs.app/Contents/MacOS", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for root in roots {
            let directory = URL(fileURLWithPath: root)
            let directClient = directory.appendingPathComponent("emacsclient")
            let client = FileManager.default.isExecutableFile(atPath: directClient.path) ? directClient : directory.appendingPathComponent("bin/emacsclient")
            let editor = directory.appendingPathComponent("Emacs")
            let lower = directory.appendingPathComponent("emacs")
            if FileManager.default.isExecutableFile(atPath: client.path) {
                if FileManager.default.isExecutableFile(atPath: editor.path) { return (client, editor) }
                if FileManager.default.isExecutableFile(atPath: lower.path) { return (client, lower) }
            }
        }
        throw NSError(domain: "LocalProjects", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not find Emacs and emacsclient. Install Emacs.app in Applications, or install them in /opt/homebrew/bin or /usr/local/bin."])
    }

    func create(deadline: Deadline, store: Store, reportError: @escaping @MainActor @Sendable (String) -> Void) {
        do { _ = try executables() }
        catch { reportError(error.localizedDescription); return }
        guard !isCreating else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a parent directory for " + deadline.name
        panel.message = "The configured project template will be downloaded into a new project folder named after the conference."
        panel.prompt = "Create project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let path = UserDefaults.standard.string(forKey: LocalProjectTemplate.parentDirectoryKey) {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        panel.begin { response in
            guard response == .OK, let parent = panel.url else { return }
            UserDefaults.standard.set(parent.path, forKey: LocalProjectTemplate.parentDirectoryKey)
            self.isCreating = true
            let progress = ProjectLaunchProgress(title: "Create local project — " + deadline.name, status: "Downloading the template from GitHub…")
            let fail: @MainActor @Sendable (String) -> Void = { message in progress.fail(message); reportError(message) }
            Task { @MainActor in
                defer { self.isCreating = false }
                do {
                    let entry = try await self.downloadTemplate(name: deadline.name, parent: parent, progress: progress)
                    progress.update("Saving the project location…")
                    guard await store.persist(store.data.linkingLocalProject(entry.path, for: deadline)) else {
                        fail("Project created at \(entry.deletingLastPathComponent().path), but its association could not be saved. " + (store.error ?? "")); return
                    }
                    var linked = deadline
                    linked.localProjectPath = entry.path
                    self.open(deadline: linked, store: store, progress: progress, reportError: reportError)
                } catch { fail("Could not create local project: \(error.localizedDescription)") }
            }
        }
    }

    private func downloadTemplate(name: String, parent: URL, progress: ProjectLaunchProgress) async throws -> URL {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appendingPathComponent("DeadlineTemplate-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("template.zip")
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        var request = URLRequest(url: LocalProjectTemplate.archiveURL)
        request.timeoutInterval = 120
        let (download, response) = try await URLSession.shared.download(for: request)
        defer { try? manager.removeItem(at: download) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LocalProjectTemplate.failure("GitHub could not provide the template ZIP (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Check your connection and repository access.")
        }
        try manager.moveItem(at: download, to: archive)
        progress.update("Checking the downloaded ZIP…")
        let listing = try await command(URL(fileURLWithPath: "/usr/bin/unzip"), ["-Z1", archive.path])
        guard listing.0 == 0, !listing.1.isEmpty,
              listing.1.split(separator: "\n").allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else {
            throw LocalProjectTemplate.failure("The downloaded template is not a valid project ZIP.")
        }
        progress.update("Extracting the template files…")
        let extracted = try await command(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", archive.path, unpacked.path])
        guard extracted.0 == 0 else { throw LocalProjectTemplate.failure("Could not unzip the template: " + extracted.1) }
        let roots = try manager.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        guard roots.count == 1, try roots[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LocalProjectTemplate.failure("The GitHub ZIP has an unexpected folder structure.")
        }
        let root = roots[0]
        progress.update("Finding the main LaTeX document…")
        let entry = try LocalProjectTemplate.entryFile(in: root)
        let relative = String(entry.path.dropFirst(root.path.count + 1))
        let destination = LocalProjectTemplate.availableDirectory(parent: parent, name: name)
        // Move only after download, extraction, and entry-point validation succeed.
        // Existing projects are never overwritten or downloaded again on reopen.
        progress.update("Creating project folder: " + destination.lastPathComponent)
        try manager.moveItem(at: root, to: destination)
        return destination.appendingPathComponent(relative)
    }

    func open(deadline: Deadline, store: Store, progress existingProgress: ProjectLaunchProgress? = nil, reportError: @escaping @MainActor @Sendable (String) -> Void) {
        guard let path = deadline.localProjectPath else {
            create(deadline: deadline, store: store, reportError: reportError); return
        }
        let progress = existingProgress ?? ProjectLaunchProgress(title: "Open in Emacs — " + deadline.name, status: "Locating Emacs…")
        let fail: @MainActor @Sendable (String) -> Void = { message in progress.fail(message); reportError(message) }
        do {
            let (client, editor) = try executables()
            if let existing = projects[path], existing.process.isRunning {
                // Names contain only a fixed prefix and a UUID, never user input.
                let focus = Process()
                focus.executableURL = client
                focus.arguments = EmacsIntegration.connectionArguments + ["--quiet", "--eval", "(dolist (frame (frame-list)) (when (equal (frame-parameter frame 'deadline-startup-project) \"\(existing.frameName.replacingOccurrences(of: "DeadlineStartup-", with: ""))\") (select-frame-set-input-focus frame)))"]
                focus.standardOutput = FileHandle.nullDevice
                focus.standardError = FileHandle.nullDevice
                try focus.run()
                progress.finish("The project is already open in Emacs. No additional opening was counted.")
                return
            }
            guard FileManager.default.fileExists(atPath: path) else {
                fail("The local project is missing at \(path). Use Create local project… to choose a new location."); return
            }
            guard launching.insert(path).inserted else { progress.finish("This project is already being opened. Please wait for Emacs."); return }
            Task { @MainActor in
                defer { launching.remove(path) }
                do {
                    progress.update("Connecting to Emacs and starting its server if needed…")
                    try await ensureServer(client: client, editor: editor)
                    progress.update("Preparing LaTeX and outline support…")
                    let prepared = try await command(client, ["--alternate-editor", "/usr/bin/false", "--eval", EmacsIntegration.prepare])
                    guard prepared.0 == 0 else {
                        throw LocalProjectTemplate.failure("Could not prepare Emacs LaTeX hooks: " + prepared.1)
                    }
                    progress.update("Opening the project frame in Emacs…")
                    let process = Process()
                    let token = UUID()
                    let frameName = "DeadlineStartup-" + token.uuidString
                    let log = FileManager.default.temporaryDirectory.appendingPathComponent(frameName + ".log")
                    FileManager.default.createFile(atPath: log.path, contents: nil)
                    let errors = try FileHandle(forWritingTo: log)
                    process.executableURL = client
                    process.currentDirectoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
                    process.arguments = EmacsIntegration.connectionArguments + ["--quiet", "--create-frame", "--display", "ns", "--alternate-editor", "/usr/bin/false", "--frame-parameters", EmacsIntegration.frameParameters(token: token), "--", path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = errors
                    process.terminationHandler = { finished in
                        let status = finished.terminationStatus
                        let signalled = finished.terminationReason == .uncaughtSignal
                        Task { @MainActor in
                            try? errors.close()
                            let diagnostic = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                            try? FileManager.default.removeItem(at: log)
                            if let project = self.projects[path], project.frameName == frameName {
                                WritingTracker.shared.stop(project.sessionID)
                                self.projects.removeValue(forKey: path)
                            } else if status == 0, !progress.finished {
                                progress.finish("The Emacs connection closed before startup completed. No opening was counted.")
                            }
                            if status != 0 {
                                let reason = signalled ? "terminated by signal \(status)" : "exit \(status)"
                                fail("The Emacs project connection ended (\(reason)).\n\(diagnostic)")
                            }
                        }
                    }
                    do { try process.run() }
                    catch {
                        try? errors.close(); try? FileManager.default.removeItem(at: log)
                        throw error
                    }
                    // Emacs can wait for file hooks or a user prompt. Do not kill
                    // the waiting client just because setup takes a few seconds.
                    let waitingSince = Date()
                    while process.isRunning {
                        let check = try await command(client, ["--quiet", "--alternate-editor", "/usr/bin/false", "--eval",
                            EmacsIntegration.readinessExpression(token: token)])
                        if check.0 == 0, EmacsIntegration.frameReady(output: check.1, token: token), process.isRunning {
                            var local = deadline
                            local.overleafProjectURL = nil
                            let session = WritingTracker.shared.start(deadline: local, store: store)
                            WritingTracker.shared.setProject(URL(fileURLWithPath: path).absoluteString, sessionID: session)
                            projects[path] = OpenProject(process: process, sessionID: session, frameName: frameName)
                            progress.finish("Project opened in Emacs. Writing time and opening count are now being tracked.")
                            return
                        }
                        if Date().timeIntervalSince(waitingSince) > 15 {
                            progress.update("Waiting for Emacs to finish opening the project. Check Emacs for a question or startup message. The launcher will keep waiting; it will not close your project.")
                        }
                        try await Task.sleep(for: .milliseconds(500))
                    }
                } catch { fail("Could not open Emacs: \(error.localizedDescription)") }
            }
        } catch { fail("Could not open Emacs: \(error.localizedDescription)") }
    }
}
