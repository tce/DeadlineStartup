import Foundation

/// Naming and entry-point rules are shared by creation and offline checks.
enum LocalProjectTemplate {
    static let defaultRepository = "https://github.com/tce/LatexPaperTemplate"
    static let repositoryKey = "projectTemplateRepository"
    static var repository: String { UserDefaults.standard.string(forKey: repositoryKey) ?? defaultRepository }
    static var archiveURL: URL { archiveURL(for: repository) ?? archiveURL(for: defaultRepository)! }

    static func repositoryURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        let repo = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        guard [parts[0], repo].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(repo)")
    }

    static func archiveURL(for repository: String) -> URL? {
        repositoryURL(repository)?.appendingPathComponent("archive/HEAD.zip")
    }
    static let parentDirectoryKey = "localProjectParentDirectory"

    static func folderName(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let name = title.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name == "." || name == ".." ? "Untitled project" : String(name.prefix(150))
    }

    static func availableDirectory(parent: URL, name: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> URL {
        let base = folderName(name)
        var candidate = parent.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while exists(candidate.path) {
            candidate = parent.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    static func entryFile(in directory: URL) throws -> URL {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: directory.path) else {
            throw failure("Could not read the downloaded template.")
        }
        var documents: [URL] = []
        for case let relative as String in enumerator {
            let file = directory.appendingPathComponent(relative)
            guard file.pathExtension.lowercased() == "tex", !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: #"(?m)^\s*\\documentclass(?:\s*\[[^\]]*\])?\s*\{"#, options: .regularExpression) != nil {
                documents.append(file)
            }
        }
        func rank(_ file: URL) -> Int {
            let depth = file.pathComponents.count - directory.pathComponents.count
            return depth * 10 + (["main.tex", "presentation.tex", "template.tex"].firstIndex(of: file.lastPathComponent.lowercased()) ?? 5)
        }
        guard let entry = documents.sorted(by: { rank($0) == rank($1) ? $0.path < $1.path : rank($0) < rank($1) }).first else {
            throw failure("The template does not contain a LaTeX document with a \\documentclass declaration.")
        }
        return entry
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalProjectTemplate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
