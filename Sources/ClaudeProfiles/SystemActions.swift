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

    static let terminalCloseDecisionHandler = """
    on closeMode(windowCount, tabCount)
        if windowCount is 1 and tabCount is 1 then return "quit"
        if tabCount > 1 then return "close tab"
        return "close window"
    end closeMode
    """

    static let closeTerminalScript = terminalCloseDecisionHandler + """


    on run argv
        set targetTTY to item 1 of argv
        if application "Terminal" is not running then return
        tell application "Terminal"
            set windowCount to count of windows
            repeat with candidateWindow in windows
                set tabCount to count of tabs of candidateWindow
                repeat with candidateTab in tabs of candidateWindow
                    if tty of candidateTab is targetTTY then
                        set mode to my closeMode(windowCount, tabCount)
                        if mode is "quit" then
                            quit
                        else if mode is "close tab" then
                            close candidateTab
                        else
                            close candidateWindow saving no
                        end if
                        return
                    end if
                end repeat
            end repeat
        end tell
    end run
    """

    static func setupCommandScript(cliPath: String, home: String?, cleanupDirectory: String) -> String {
        var lines = ["#!/bin/zsh", "clear"]
        lines.append("cleanup_directory=\(shellQuote(cleanupDirectory))")
        lines.append("trap 'rm -rf -- \"$cleanup_directory\"' EXIT")
        if let home, !home.isEmpty {
            lines.append("export CLAUDE_PROFILES_HOME=\(shellQuote(home))")
        }
        lines.append("terminal_tty=$(tty)")
        lines.append("close_this_terminal_window() {")
        lines.append("  ( trap '' HUP; sleep 1; osascript - \"$terminal_tty\" <<'CLOSE_TERMINAL_WINDOW'")
        lines.append(closeTerminalScript)
        lines.append("CLOSE_TERMINAL_WINDOW")
        lines.append("  ) >/dev/null 2>&1 &!")
        lines.append("}")
        lines.append("/bin/zsh \(shellQuote(cliPath)) setup")
        lines.append("setup_status=$?")
        lines.append("if (( setup_status == 0 )); then")
        lines.append("  print")
        lines.append("  print 'Setup finished. Closing this window.'")
        lines.append("  close_this_terminal_window")
        lines.append("  exit 0")
        lines.append("fi")
        lines.append("print")
        lines.append("print \"Setup failed (exit $setup_status). The output above shows why.\"")
        lines.append("print -n 'Press Return to close'")
        lines.append("read -r")
        lines.append("close_this_terminal_window")
        lines.append("exit $setup_status")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes a `.command` file that runs the installed CLI's `setup` and opens it in Terminal.
    /// The file removes itself and leaves Terminal (or closes only its own tab or window) when setup succeeds; on failure it waits for Return.
    static func openSetupInTerminal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("claude-profiles-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("Claude Profiles Setup.command")
        let contents = setupCommandScript(
            cliPath: installedCLIPath,
            home: ProcessInfo.processInfo.environment["CLAUDE_PROFILES_HOME"],
            cleanupDirectory: directory.path
        )
        try contents.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-a", "Terminal", script.path]
        try opener.run()
    }
}
