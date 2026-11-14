import Foundation

@main
struct Emit {
    static func main() {
        precondition(EmacsIntegration.connectionArguments == ["--socket-name", "DeadlineStartup"])
        precondition(EmacsIntegration.daemonArguments == ["--daemon=DeadlineStartup"])
        let token = UUID()
        precondition(EmacsIntegration.frameReady(output: "Waiting for Emacs...\n\"\(token.uuidString)\"\n", token: token))
        precondition(!EmacsIntegration.frameReady(output: "nil\n", token: token))
        precondition(!EmacsIntegration.frameReady(output: "\"\(UUID().uuidString)\"\n", token: token))
        print(";;; Generated test setup -*- lexical-binding: t; -*-")
        print(EmacsIntegration.prepare)
        print("(setq deadline-test-token \"\(token.uuidString)\")")
        print("(setq deadline-test-frame-parameters '\(EmacsIntegration.frameParameters(token: token)))")
        print("(setq deadline-test-readiness '\(EmacsIntegration.readinessExpression(token: token)))")
    }
}
