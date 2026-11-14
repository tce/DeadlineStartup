import Foundation

enum OverleafProject {
    static func projectURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", let host = url.host?.lowercased(),
              ["overleaf.com", "www.overleaf.com"].contains(host), url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 2, parts[0] == "project", parts[1].count == 24,
              parts[1].allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return URL(string: "https://www.overleaf.com/project/\(parts[1])")
    }
    static func starter(name: String) -> String {
        let replacements: [Character: String] = ["\\": "\\textbackslash{}", "{": "\\{", "}": "\\}", "$": "\\$", "&": "\\&", "#": "\\#", "%": "\\%", "_": "\\_", "~": "\\textasciitilde{}", "^": "\\textasciicircum{}"]
        let title = name.map { replacements[$0] ?? String($0) }.joined()
        return "\\documentclass{article}\n\\usepackage[utf8]{inputenc}\n\\title{\(title)}\n\\author{}\n\\date{}\n\\begin{document}\n\\maketitle\n\\section{Introduction}\n% Start writing here.\n\\end{document}\n"
    }
    static func creationRequest(name: String, archiveURL: URL = LocalProjectTemplate.archiveURL) -> URLRequest {
        let fields = ["snip_uri": archiveURL.absoluteString, "snip_name": name + ".zip", "engine": "pdflatex"]
        func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        var request = URLRequest(url: URL(string: "https://www.overleaf.com/docs")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields.sorted { $0.key < $1.key }.map { encoded($0.key) + "=" + encoded($0.value) }.joined(separator: "&").data(using: .utf8)
        return request
    }
}
