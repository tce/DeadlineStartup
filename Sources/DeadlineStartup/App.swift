import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    @Published var data = SavedData()
    @Published var error: String?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published private(set) var isLoading = true
    @Published private(set) var isSaving = false
    let file: URL
    let usesCloud: Bool
    private let disk: DeadlineFile
    private var snapshot: Data?
    private var canSave = false

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        // Use the same visible iCloud Drive file on each Mac. Never seed a new
        // cloud file from a second Mac's potentially older local copy.
        usesCloud = FileManager.default.fileExists(atPath: cloud.path)
        file = usesCloud ? cloud.appendingPathComponent("DeadlineStartup/deadlines.json") :
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DeadlineStartup/deadlines.json")
        disk = DeadlineFile(url: file, isCloud: usesCloud)
        Task { await reload() }
    }

    func reload() async {
        guard !isSaving else { return }
        do {
            let loaded = try await disk.load()
            if snapshot != loaded.bytes {
                let shared = loaded.data.sharingExistingDetails()
                if shared.deadlines != loaded.data.deadlines {
                    snapshot = try await disk.save(shared, expected: loaded.bytes)
                } else { snapshot = loaded.bytes }
                data = shared
            }
            canSave = true
        } catch {
            canSave = false
            self.error = "Could not load deadlines from \(file.path). The file has been preserved. \(error.localizedDescription)"
        }
        isLoading = false
    }

    func save(_ updated: SavedData) { Task { _ = await persist(updated) } }

    func persist(_ updated: SavedData) async -> Bool {
        guard canSave, !isSaving else { error = "The deadline file is not ready. Wait for it to load or reopen the app."; return false }
        isSaving = true
        defer { isSaving = false }
        var updated = updated
        let sessions = WritingSession.merging(data.writingSessions ?? [], updated.writingSessions ?? [])
        if !sessions.isEmpty { updated.writingSessions = sessions }
        do {
            snapshot = try await disk.save(updated, expected: snapshot)
            data = updated
            return true
        } catch {
            self.error = "Could not save deadlines: \(error.localizedDescription)"
            isSaving = false
            await reload()
            return false
        }
    }
    func upsert(_ deadline: Deadline) { upsert([deadline]) }
    func upsert(_ deadlines: [Deadline]) {
        let merged = deadlines.map { deadline in
            var deadline = deadline
            if let current = data.deadlines.first(where: { $0.id == deadline.id }) {
                deadline.about = current.about
                deadline.actions = current.actions
                deadline.overleafProjectURL = current.overleafProjectURL
                deadline.localProjectPath = current.localProjectPath
            }
            return deadline
        }
        save(data.upserting(merged))
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
        refreshLogin()
    }
    func refreshLogin() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var reminderWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var presentation: DispatchWorkItem?
    private var pasteMonitor: Any?
    private var priorityReset: DispatchWorkItem?
    private var presentationInFlight = false
    private var screenLocked = false
    private var normalCollectionBehavior: NSWindow.CollectionBehavior = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.reminderWindow,
                      NSApp.keyWindow === window, window.attachedSheet == nil,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v",
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return false }
                NotificationCenter.default.post(name: .conferencePasteRequested, object: nil)
                return true
            }
            return handled ? nil : event
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(self, selector: #selector(workspaceResumed), name: name, object: nil)
        }
        // Workspace wake arrives before the login screen is dismissed. Listen
        // for the session's unlock broadcast as well so focus is requested after it.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenDidLock), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenDidUnlock), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: "Deadline Startup")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show Deadlines", action: #selector(showReminders), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Deadline Startup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        NSApp.activate(ignoringOtherApps: true)
    }

    func attach(_ window: NSWindow) {
        reminderWindow = window
        window.delegate = self
        window.isReleasedWhenClosed = false
        normalCollectionBehavior = window.collectionBehavior
    }

    // Keep the small wake listener alive after dismissing the reminder window.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissReminders()
        return false
    }

    func dismissReminders() {
        presentation?.cancel()
        endFrontPresentation()
        reminderWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func screenDidLock(_ notification: Notification) {
        screenLocked = true
        presentation?.cancel()
        endFrontPresentation()
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        screenLocked = false
        schedulePresentation()
    }

    @objc private func workspaceResumed(_ notification: Notification) {
        schedulePresentation()
    }

    private func schedulePresentation() {
        // Coalesce system wake, display wake, and unlock into one presentation.
        presentation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.screenLocked else { return }
            self.showReminders()
        }
        presentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func endFrontPresentation() {
        priorityReset?.cancel()
        presentationInFlight = false
        reminderWindow?.level = .normal
        reminderWindow?.collectionBehavior = normalCollectionBehavior
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard presentationInFlight, let window = reminderWindow, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.attachedSheet?.makeKeyAndOrderFront(nil)
        // The activation has actually completed; drop the temporary priority.
        endFrontPresentation()
    }

    func applicationDidResignActive(_ notification: Notification) {
        // A user selecting another app always wins over a pending raise.
        endFrontPresentation()
    }

    @objc func showReminders() {
        guard !screenLocked else { return }
        NSApp.setActivationPolicy(.regular)
        NotificationCenter.default.post(name: .remindersResumed, object: nil)
        guard let window = reminderWindow else { return }
        priorityReset?.cancel()
        presentationInFlight = true
        var behavior = normalCollectionBehavior
        behavior.remove([.canJoinAllSpaces, .fullScreenPrimary])
        behavior.insert(.moveToActiveSpace)
        window.collectionBehavior = behavior
        // A short boost handles the asynchronous accessory-to-regular activation.
        // It is removed on activation, app switching, dismissal, or timeout.
        window.level = .floating
        NSApp.unhide(nil)
        window.deminiaturize(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive { applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification)) }
        let reset = DispatchWorkItem { [weak self] in self?.endFrontPresentation() }
        priorityReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: reset)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showReminders()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if sender.windows.contains(where: { $0.isDocumentEdited }) {
            let alert = NSAlert()
            alert.messageText = "Deadline details have unsaved changes"
            alert.informativeText = "Cancel and save your about text and actions before quitting, or quit without saving."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Without Saving")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        if WritingTracker.shared.hasWork {
            Task {
                let saved = await WritingTracker.shared.prepareForQuit()
                if !saved {
                    let alert = NSAlert()
                    alert.messageText = "Overleaf time could not be saved"
                    alert.informativeText = "Keep the app open and let iCloud finish syncing, then try quitting again."
                    alert.runModal()
                }
                sender.reply(toApplicationShouldTerminate: saved)
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let conferencePasteRequested = Notification.Name("DeadlineStartup.conferencePasteRequested")
    static let remindersResumed = Notification.Name("DeadlineStartup.remindersResumed")
}

struct WindowAccessor: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { WindowView(attach: attach) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowView: NSView {
        let attach: (NSWindow) -> Void
        init(attach: @escaping (NSWindow) -> Void) { self.attach = attach; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach(window) }
        }
    }
}

@main
struct DeadlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = Store()
    var body: some Scene {
        Window("Deadline Startup", id: "main") {
            ContentView(close: { delegate.dismissReminders() }).environmentObject(store)
                .background(WindowAccessor(attach: { delegate.attach($0) }))
                .frame(minWidth: 760, minHeight: 520)
                .onExitCommand { delegate.dismissReminders() }
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Button("Import Conference URL from Clipboard") {
                    NotificationCenter.default.post(name: .conferencePasteRequested, object: nil)
                }
            }
        }
        Settings { ProjectSettingsView() }
    }
}

struct ContentView: View {
    let close: () -> Void
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var phase
    @State private var editing: Deadline?
    @State private var showingAll = false
    @State private var deleting: Deadline?
    @State private var importInput: String?
    @State private var pendingImports: [Deadline] = []
    @State private var batchImport: DeadlineBatch?
    @State private var importedDateConfirmed = true
    @State private var scrollTarget: UUID?
    @State private var highlighted: UUID?
    private var visible: [Deadline] {
        showingAll ? store.data.deadlines.sorted { $0.date < $1.date } : Deadline.upcoming(store.data.deadlines)
    }
    /// Scrolls the deadline list to a deadline picked in the year grid,
    /// including past deadlines when the list is hiding it.
    private func reveal(_ deadline: Deadline) {
        if !visible.contains(where: { $0.id == deadline.id }) { showingAll = true }
        DispatchQueue.main.async {
            scrollTarget = deadline.id
            withAnimation { highlighted = deadline.id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if highlighted == deadline.id { withAnimation { highlighted = nil } }
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("A little clarity for what’s next.").font(.caption).foregroundStyle(.secondary)
                    Text("You should be writing").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).foregroundStyle(.secondary)
                }
                Spacer()
                Button { close() } label: { Image(systemName: "xmark").font(.title3).frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("Dismiss reminders (Esc)").accessibilityLabel("Dismiss reminders")
            }.padding(28)
            HStack {
                Text("\(visible.count) \(showingAll ? "saved" : "upcoming") deadlines").font(.headline)
                Spacer()
                Toggle("Include past & completed", isOn: $showingAll).toggleStyle(.checkbox)
                Button { importedDateConfirmed = true; editing = Deadline(date: Calendar.current.startOfDay(for: Date()), name: "", kind: store.data.kinds.first ?? "Abstract", link: "") } label: { Label("Add deadline", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 28).padding(.bottom, 16)
            HStack(spacing: 12) {
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 14, height: 1)
                DeadlineYearGrid(deadlines: store.data.deadlines, savedSessions: store.data.writingSessions ?? [], select: reveal).frame(maxWidth: 1000)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 14, height: 1)
            }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 10)
            if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 42)).foregroundStyle(.teal)
                    Text("Room to focus").font(.title2.bold())
                    Text("Add a deadline to see it here. Upcoming events appear in date order.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(visible) { deadline in
                                DeadlineRow(deadline: deadline, open: { PaperWindows.shared.open(deadline: deadline, store: store) }, edit: { importedDateConfirmed = true; editing = deadline }, toggleCompleted: {
                                    var copy = deadline; copy.completed.toggle(); store.upsert(copy)
                                }, delete: { deleting = deadline }, reportError: { store.error = $0 })
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2).opacity(highlighted == deadline.id ? 1 : 0))
                                .id(deadline.id)
                            }
                        }.padding(24)
                    }
                    .onChange(of: scrollTarget) { target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                        scrollTarget = nil
                    }
                }
            }
            Divider()
            HStack {
                Toggle("Open at login", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) })).toggleStyle(.switch)
                if store.loginNeedsApproval { Button("Approve in System Settings") { SMAppService.openSystemSettingsLoginItems() } }
                Spacer()
                Text(store.usesCloud ? "iCloud Drive" : "On this Mac").font(.caption).foregroundStyle(.secondary)
                    .help(store.file.path)
                Text("⌘V to import a URL · Esc to dismiss").font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .disabled(store.isLoading || store.isSaving)
        .overlay {
            if store.isLoading || store.isSaving {
                ProgressView(store.isLoading ? "Loading deadlines…" : "Saving deadlines…")
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(ConferenceWindowDrop(importURL: { importInput = $0 }, reportError: { store.error = $0 }))
        .sheet(item: $editing) { deadline in DeadlineEditor(deadline: deadline, kinds: store.data.kinds, dateConfirmed: importedDateConfirmed) { store.upsert($0) } }
        .sheet(isPresented: Binding(get: { importInput != nil }, set: { if !$0 { importInput = nil } }), onDismiss: {
            if pendingImports.count == 1 { editing = pendingImports.first }
            else if !pendingImports.isEmpty { batchImport = DeadlineBatch(deadlines: pendingImports) }
            pendingImports = []
        }) {
            ConferenceImportView(input: importInput ?? "") { deadlines, confirmed in
                importedDateConfirmed = confirmed
                pendingImports = deadlines.map { deadline in
                    var imported = deadline
                    // Re-importing the same conference/date edits the existing reminder.
                    if confirmed, let existing = store.data.deadlines.first(where: {
                        $0.kind.caseInsensitiveCompare(deadline.kind) == .orderedSame &&
                        Calendar.current.isDate($0.date, inSameDayAs: deadline.date) &&
                        ($0.name.caseInsensitiveCompare(deadline.name) == .orderedSame ||
                         ($0.url?.host == deadline.url?.host && $0.url?.path == deadline.url?.path))
                    }) {
                        imported.id = existing.id
                        imported.completed = existing.completed
                        imported.about = existing.about
                        imported.actions = existing.actions
                        imported.overleafProjectURL = existing.overleafProjectURL
                        imported.localProjectPath = existing.localProjectPath
                    }
                    return imported
                }
                importInput = nil
            }
        }
        .sheet(item: $batchImport) { batch in
            DeadlineBatchEditor(deadlines: batch.deadlines, kinds: store.data.kinds) { store.upsert($0) }
        }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("OK") { store.error = nil } } message: { Text(store.error ?? "") }
        .confirmationDialog("Delete this deadline?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let deleting { var data = store.data; data.deadlines.removeAll { $0.id == deleting.id }; store.save(data) }; deleting = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .conferencePasteRequested)) { _ in
            guard editing == nil, batchImport == nil, importInput == nil, deleting == nil, store.error == nil else { return }
            guard let url = ConferenceClipboard.url(from: .general) else {
                store.error = "Copy a conference website URL, then press Command-V in the reminder window."
                return
            }
            guard !BrowserLink.isImage(url) else { store.error = BrowserLink.imageMessage; return }
            importInput = url.absoluteString
        }
        .onChange(of: phase) { _ in
            store.refreshLogin()
            if phase == .active, editing == nil, batchImport == nil, importInput == nil { Task { await store.reload() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remindersResumed)) { _ in
            store.refreshLogin()
            store.objectWillChange.send()
            if editing == nil, batchImport == nil, importInput == nil { Task { await store.reload() } }
        }
    }
}

struct DeadlineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var deadline: Deadline
    let kinds: [String]
    @State var dateConfirmed = true
    var dismissOnSave = true
    var saveLabel = "Save deadline"
    let onSave: (Deadline) -> Void
    @State private var customKind = ""
    @State private var addingKind = false
    private var kind: String { (addingKind ? customKind : deadline.kind).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func optionalText(_ key: WritableKeyPath<Deadline, String?>) -> Binding<String> {
        Binding(get: { deadline[keyPath: key] ?? "" }, set: { deadline[keyPath: key] = $0 })
    }
    private var valid: Bool { dateConfirmed && !deadline.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !kind.isEmpty && (deadline.hasTime != true || (deadline.timeZoneIdentifier ?? "").isEmpty || TimeZone(identifier: deadline.timeZoneIdentifier!) != nil) && (deadline.link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || normalized.url != nil) }
    private var normalized: Deadline { var copy = deadline; copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines); copy.link = copy.link.trimmingCharacters(in: .whitespacesAndNewlines); copy.kind = kind; return copy }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(deadline.name.isEmpty ? "Add a deadline" : "Edit deadline").font(.title2.bold())
            if !dateConfirmed { Text("No due date was found. Set the due date below before saving.").foregroundStyle(.orange) }
            ScrollView { Form {
                TextField("Event title", text: $deadline.name, prompt: Text("CVPR 2027"))
                TextField("Full event name", text: optionalText(\.fullName))
                TextField("Event dates", text: optionalText(\.eventDates), prompt: Text("June 20–25, 2027"))
                TextField("Location", text: optionalText(\.location))
                TextField("Notes", text: optionalText(\.notes), axis: .vertical).lineLimit(2...4)
                DatePicker("Due date", selection: $deadline.date, displayedComponents: .date)
                    .environment(\.timeZone, deadline.hasTime == true ? deadline.timeZone : .current)
                    .onChange(of: deadline.date) { _ in dateConfirmed = true }
                Toggle("Specify deadline time", isOn: Binding(get: { deadline.hasTime == true }, set: { deadline.hasTime = $0 }))
                if deadline.hasTime == true {
                    DatePicker("Due time", selection: $deadline.date, displayedComponents: [.hourAndMinute])
                        .environment(\.timeZone, deadline.timeZone)
                    TextField("Time zone", text: optionalText(\.timeZoneIdentifier), prompt: Text(TimeZone.current.identifier))
                    Text("Use a zone such as America/New_York or Etc/GMT+12 (UTC−12). Displayed times use this zone.").font(.caption).foregroundStyle(.secondary)
                }
                Picker("Event type", selection: $deadline.kind) { ForEach(Array(Set(kinds + [deadline.kind])).sorted(), id: \.self) { Text($0).tag($0) } }.disabled(addingKind)
                Toggle("Add a custom event type", isOn: $addingKind)
                if addingKind { TextField("New type", text: $customKind) }
                TextField("Event URL (optional)", text: $deadline.link, prompt: Text("https://example.com"))
                if !deadline.link.isEmpty && normalized.url == nil { Text("Enter a complete http:// or https:// URL.").font(.caption).foregroundStyle(.red) }
            }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button(saveLabel) { onSave(normalized); if dismissOnSave { dismiss() } }.keyboardShortcut(.defaultAction).disabled(!valid) }
        }.padding(28).frame(width: 580, height: 650)
    }
}

