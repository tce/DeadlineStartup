import Foundation

enum EmacsIntegration {
    static let serverName = "DeadlineStartup"
    static let connectionArguments = ["--socket-name", serverName]
    static let daemonArguments = ["--daemon=" + serverName]

    static func frameParameters(token: UUID) -> String {
        "((window-system . ns) (name . \"DeadlineStartup-\(token.uuidString)\") (deadline-startup-project . \"\(token.uuidString)\"))"
    }

    static func readinessExpression(token: UUID) -> String {
        "(catch 'found (dolist (frame (frame-list)) (when (and (display-graphic-p frame) (equal (frame-parameter frame 'deadline-startup-project) \"\(token.uuidString)\")) (throw 'found \"\(token.uuidString)\"))))"
    }

    static func frameReady(output: String, token: UUID) -> Bool {
        // emacsclient may print a waiting banner before the Lisp result.
        output.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "\"\(token.uuidString)\""
        }
    }

    // LaTeX mode hooks must leave the source buffer current for later hooks
    // and server-visit-files. The outline UI may select an indirect buffer.
    // These named, idempotent advices affect the running session only.
    static let prepare = #"""
    (progn
      (unless (featurep 'ns)
        (error "The connected Emacs server does not support macOS graphical frames. Start the server in Emacs.app rather than a terminal-only Emacs build."))
      (defun deadline-startup--preserve-source-buffer (function &rest args)
        (save-current-buffer (apply function args)))
      (defun deadline-startup--file-hook (function &rest args)
        (when (stringp buffer-file-name)
          (apply function args)))
      (when (fboundp 'latex-outline-editor)
        (unless (advice-member-p #'deadline-startup--preserve-source-buffer 'latex-outline-editor)
          (advice-add 'latex-outline-editor :around #'deadline-startup--preserve-source-buffer)))
      (when (fboundp 'my-project-hook)
        (unless (advice-member-p #'deadline-startup--file-hook 'my-project-hook)
          (advice-add 'my-project-hook :around #'deadline-startup--file-hook)))
      t)
    """#
}
