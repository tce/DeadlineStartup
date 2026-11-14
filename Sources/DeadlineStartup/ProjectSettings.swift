import SwiftUI
import AppKit

struct ProjectSettingsView: View {
    @State private var repository = LocalProjectTemplate.repository
    @State private var saved = false
    @AppStorage(LocalProjectTemplate.parentDirectoryKey) private var parentDirectory = ""
    var body: some View {
        Form {
            Section("Project template") {
                TextField("GitHub repository", text: $repository).onChange(of: repository) { _ in saved = false }
                Text("Used for new local and Overleaf projects. Use a public repository containing a LaTeX document. Existing projects keep their files.")
                    .font(.caption).foregroundStyle(.secondary)
                if LocalProjectTemplate.repositoryURL(repository) == nil {
                    Text("Enter an HTTPS repository URL, such as https://github.com/tce/LatexPaperTemplate.").font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Button("Use paper template") { repository = LocalProjectTemplate.defaultRepository }
                    Spacer()
                    if saved { Text("Saved").font(.caption).foregroundStyle(.secondary) }
                    Button("Save") {
                        guard let url = LocalProjectTemplate.repositoryURL(repository) else { return }
                        UserDefaults.standard.set(url.absoluteString, forKey: LocalProjectTemplate.repositoryKey)
                        repository = url.absoluteString
                        saved = true
                    }.disabled(LocalProjectTemplate.repositoryURL(repository) == nil)
                }
            }
            Section("Local projects") {
                Text(parentDirectory.isEmpty ? "Choose a parent directory when creating your first project." : parentDirectory)
                    .font(.callout).textSelection(.enabled)
                Button("Choose parent directory…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false; panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
                    if !parentDirectory.isEmpty { panel.directoryURL = URL(fileURLWithPath: parentDirectory) }
                    if panel.runModal() == .OK, let url = panel.url { parentDirectory = url.path }
                }
            }
        }.padding(24).frame(width: 570)
    }
}
