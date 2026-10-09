import AppKit

enum SystemActions {
    static let installedCLIPath = NSHomeDirectory() + "/.local/share/claude-profiles/bin/claude-profiles"

    static func reveal(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    static func openApplication(_ path: String) {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func chooseFolders() -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose folders where `claude` should use this profile automatically."
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map(\.path)
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes a `.command` file that runs the installed CLI's `setup` and opens it in Terminal.
    static func openSetupInTerminal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-profiles-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("Claude Profiles Setup.command")
        var lines = ["#!/bin/zsh", "clear"]
        if let home = ProcessInfo.processInfo.environment["CLAUDE_PROFILES_HOME"], !home.isEmpty {
            lines.append("export CLAUDE_PROFILES_HOME=\(shellQuote(home))")
        }
        lines.append("/bin/zsh \(shellQuote(installedCLIPath)) setup")
        lines.append("print")
        lines.append("print 'Done. You can close this window and return to Claude Profiles.'")
        try (lines.joined(separator: "\n") + "\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", script.path]
        try opener.run()
    }
}
