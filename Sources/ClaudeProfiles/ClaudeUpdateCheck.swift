import AppKit
import ApplicationServices

struct MenuEntry: Equatable {
    let menuIndex: Int
    let menuName: String
    let itemIndex: Int
    let itemName: String
}

struct ScriptResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ClaudeUpdateCheck {
    enum Activation {
        case alreadyRunning
        case launched
        case notInstalled
        case failed(String)

        var isFreshLaunch: Bool {
            if case .launched = self { return true }
            return false
        }
    }

    enum Lookup {
        case found(MenuEntry)
        case notFound
        case failed(ScriptResult)
    }

    enum AccessibilityChoice {
        case openSettings
        case justOpenClaude
        case cancel
    }

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let caption = "Opens Claude and runs its own update check. Profiles follow automatically after Claude updates."
    static let manualPath = "In Claude, choose Claude → Check for Updates…"
    static let accessibilitySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private static let updateItemPrefix = "check for update"
    private static let permissionErrorCodes = ["-1743", "-25211", "-1719", "-25204"]

    static func isUpdateMenuItem(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix(updateItemPrefix)
    }

    static func updateMenuItem(in entries: [MenuEntry]) -> MenuEntry? {
        guard let firstMenu = entries.map(\.menuIndex).min() else { return nil }
        return entries.first { $0.menuIndex == firstMenu && isUpdateMenuItem($0.itemName) }
            ?? entries.first { isUpdateMenuItem($0.itemName) }
    }

    static func parseMenuEntries(_ output: String) -> [MenuEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let menuIndex = Int(fields[0]), let itemIndex = Int(fields[2]) else { return nil }
            return MenuEntry(menuIndex: menuIndex, menuName: fields[1], itemIndex: itemIndex, itemName: fields[3])
        }
    }

    static func isPermissionFailure(_ stderr: String) -> Bool {
        permissionErrorCodes.contains { stderr.contains($0) }
    }

    static func permissionMessage(_ stderr: String) -> String {
        if stderr.contains("-1743") {
            return "Claude Profiles is not allowed to control System Events. Allow it in System Settings → Privacy & Security → Automation."
        }
        return "Claude Profiles is not allowed to use Accessibility. Allow it in System Settings → Privacy & Security → Accessibility."
    }

    static let listMenuScript = """
    on run argv
        set targetBundleID to item 1 of argv
        set output to ""
        tell application "System Events"
            set targetProcess to first application process whose bundle identifier is targetBundleID
            set barItems to menu bar items of menu bar 1 of targetProcess
            repeat with barIndex from 1 to count of barItems
                set barItem to item barIndex of barItems
                set menuName to name of barItem
                if barIndex > 1 and menuName is not missing value then
                    set itemNames to name of every menu item of menu 1 of barItem
                    repeat with itemIndex from 1 to count of itemNames
                        set itemName to item itemIndex of itemNames
                        if itemName is not missing value then
                            set output to output & barIndex & tab & menuName & tab & itemIndex & tab & itemName & linefeed
                        end if
                    end repeat
                end if
            end repeat
        end tell
        return output
    end run
    """

    static let clickMenuItemScript = """
    on run argv
        set targetBundleID to item 1 of argv
        set barIndex to (item 2 of argv) as integer
        set itemIndex to (item 3 of argv) as integer
        tell application "System Events"
            set targetProcess to first application process whose bundle identifier is targetBundleID
            click menu item itemIndex of menu 1 of menu bar item barIndex of menu bar 1 of targetProcess
        end tell
        return "clicked"
    end run
    """

    static func runScript(_ script: String, arguments: [String], timeout: TimeInterval = 30) -> ScriptResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-"] + arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return ScriptResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        input.fileHandleForWriting.write(Data(script.utf8))
        try? input.fileHandleForWriting.close()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return ScriptResult(status: process.terminationStatus, stdout: stdout, stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func runScriptAsync(_ script: String, arguments: [String]) async -> ScriptResult {
        await Task.detached { runScript(script, arguments: arguments) }.value
    }

    @MainActor
    static func activateClaude() async -> Activation {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleID).first {
            if #available(macOS 14.0, *) {
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
            return .alreadyRunning
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) else { return .notInstalled }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return .launched
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func findUpdateItem(attempts: Int) async -> Lookup {
        var lookup = Lookup.notFound
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let result = await runScriptAsync(listMenuScript, arguments: [claudeBundleID])
            if result.status != 0 {
                if isPermissionFailure(result.stderr) { return .failed(result) }
                lookup = .failed(result)
            } else if let entry = updateMenuItem(in: parseMenuEntries(result.stdout)) {
                return .found(entry)
            } else {
                lookup = .notFound
            }
        }
        return lookup
    }

    static func click(_ entry: MenuEntry) async -> ScriptResult {
        await runScriptAsync(clickMenuItemScript, arguments: [claudeBundleID, String(entry.menuIndex), String(entry.itemIndex)])
    }

    @MainActor
    static func askAboutAccessibility() -> AccessibilityChoice {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Accessibility to check for Claude updates"
        alert.informativeText = "Claude Profiles clicks Claude's own “Check for Updates…” menu item through System Events. macOS only allows that once Claude Profiles is enabled under Privacy & Security → Accessibility. It only reads Claude's menu names and clicks that one item."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Just Open Claude")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .openSettings
        case .alertSecondButtonReturn: return .justOpenClaude
        default: return .cancel
        }
    }

    @MainActor
    static func showInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
