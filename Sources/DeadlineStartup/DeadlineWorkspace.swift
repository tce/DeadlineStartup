import SwiftUI
import AppKit

struct DeadlineWorkspace: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var tracker = WritingTracker.shared
    let deadlineID: UUID
    @State private var original: Deadline?
    @State private var about = ""
    @State private var actions: [DeadlineAction] = []
    @State private var newAction = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var editingProject = false
    @State private var projectLink = ""
    private var dirty: Bool { original != nil && (about != (original?.about ?? "") || actions != (original?.actions ?? []) || !newAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(original?.name ?? "Deadline details").font(.title2.bold())
                    if let original { Text("\(original.kind) · \(original.deadlineDescription)").font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                Button {
                    if let deadline = store.data.deadlines.first(where: { $0.id == deadlineID }) {
                        OverleafWindows.shared.open(deadline: deadline, store: store)
                    }
                } label: { Label("Open Overleaf", systemImage: "arrow.up.right.square") }
                Menu {
                    Button("Link an existing Overleaf project…") {
                        projectLink = original?.overleafProjectURL ?? ""; editingProject = true
                    }
                } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).frame(width: 18)
                Text(dirty ? "Unsaved changes" : "Saved").font(.caption).foregroundStyle(.secondary)
                Button(saving ? "Saving…" : "Save") { Task { _ = await save() } }
                    .keyboardShortcut("s").buttonStyle(.borderedProminent)
                    .disabled(!dirty || saving || store.isSaving || original == nil)
            }.padding(24)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let sessions = tracker.sessions(in: store.data).filter { session in
                    store.data.deadlines.first(where: { $0.id == deadlineID }).map { session.belongs(to: $0) } ?? false
                }
                HStack(spacing: 24) {
                    Label("Opened \(sessions.count) times", systemImage: "arrow.up.right.square")
                    Label("Total time: \(WritingSession.duration(sessions.reduce(0) { $0 + $1.seconds }))", systemImage: "clock")
                    Spacer()
                }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 16)
            }
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("about").font(.title2.bold())
                    Text("Shared across this conference’s deadlines").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $about).font(.body).padding(8)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.2)))
                        .accessibilityLabel("What the paper is about")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("actions").font(.title2.bold())
                    Text("\(actions.filter(\.completed).count) of \(actions.count) completed").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Add an action", text: $newAction).onSubmit(addAction)
                        Button(action: addAction) { Image(systemName: "plus") }
                            .help("Add action").disabled(newAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach($actions) { $action in
                                HStack(alignment: .top) {
                                    Toggle("Complete action", isOn: $action.completed).labelsHidden().toggleStyle(.checkbox)
                                        .accessibilityLabel("Complete \(action.title)")
                                    TextField("Action", text: $action.title, axis: .vertical)
                                        .textFieldStyle(.plain).strikethrough(action.completed)
                                    Button { actions.removeAll { $0.id == action.id } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.plain).help("Remove action")
                                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            }
                            if actions.isEmpty { Text("Add the next steps for this paper.").foregroundStyle(.secondary).padding(.top, 20) }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(24)
        }
        .frame(minWidth: 740, minHeight: 460)
        .disabled(original == nil || saving)
        .background(WorkspaceCloseGuard(dirty: dirty, save: save))
        .task {
            if let deadline = store.data.deadlines.first(where: { $0.id == deadlineID }) {
                original = deadline; about = deadline.about ?? ""; actions = deadline.actions ?? []
            } else { failure = "This deadline no longer exists." }
        }
        .onChange(of: store.data.deadlines) { _ in
            guard !dirty, !saving, let latest = store.data.deadlines.first(where: { $0.id == deadlineID }) else { return }
            original = latest; about = latest.about ?? ""; actions = latest.actions ?? []
        }
        .sheet(isPresented: $editingProject) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Link Overleaf project").font(.title2.bold())
                TextField("https://www.overleaf.com/project/…", text: $projectLink)
                Text("Use the project’s editor URL. This link is shared with this conference’s other deadlines.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { editingProject = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save project link") {
                        guard let url = OverleafProject.projectURL(projectLink), let original else { return }
                        Task {
                            if await store.persist(store.data.linkingOverleaf(url.absoluteString, for: original)) { editingProject = false }
                            else { failure = store.error }
                        }
                    }.disabled(OverleafProject.projectURL(projectLink) == nil || store.isSaving)
                }
            }.padding(24).frame(width: 480)
        }
        .alert("Unable to save details", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }
    private func addAction() {
        let title = newAction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        actions.append(DeadlineAction(title: title)); newAction = ""
    }
    private func save() async -> Bool {
        guard let original, var current = store.data.deadlines.first(where: { $0.id == deadlineID }) else {
            failure = "This deadline no longer exists."; return false
        }
        guard current.about == original.about, current.actions == original.actions else {
            failure = "These details changed in another window. Your text is still here; copy it before reopening the deadline to load the latest version."; return false
        }
        saving = true
        defer { saving = false }
        let pending = newAction.trimmingCharacters(in: .whitespacesAndNewlines)
        var savedActions = actions
        if !pending.isEmpty { savedActions.append(DeadlineAction(title: pending)) }
        current.about = about
        current.actions = savedActions
        guard await store.persist(store.data.sharingDetails(from: current)) else { failure = store.error; return false }
        actions = savedActions
        newAction = ""
        self.original = current
        return true
    }
}

private struct WorkspaceCloseGuard: NSViewRepresentable {
    let dirty: Bool
    let save: () async -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.dirty = dirty
        context.coordinator.save = save
        DispatchQueue.main.async {
            if let window = nsView.window { window.delegate = context.coordinator; window.isDocumentEdited = dirty }
        }
    }
    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        var dirty = false
        var save: (() async -> Bool)?
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard dirty else { return true }
            let alert = NSAlert()
            alert.messageText = "Save changes to this deadline?"
            alert.informativeText = "Your about text and actions have unsaved changes."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes")
            alert.beginSheetModal(for: sender) { response in
                if response == .alertFirstButtonReturn {
                    Task { @MainActor in if await self.save?() == true { sender.close() } }
                } else if response == .alertThirdButtonReturn { sender.close() }
            }
            return false
        }
    }
}
