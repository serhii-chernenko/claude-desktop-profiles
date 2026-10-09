import AppKit
import SwiftUI

struct LogLine: Identifiable, Hashable {
    let id: Int
    let text: String
    let isError: Bool
    let isCommand: Bool
}

struct CommandFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum ActiveSheet: Identifiable {
    case create
    case adopt(Candidate)
    case remove(Profile)
    case check(CheckReport)
    case addProjects(Profile)

    var id: String {
        switch self {
        case .create: return "create"
        case .adopt(let candidate): return "adopt-" + candidate.id
        case .remove(let profile): return "remove-" + profile.slug
        case .check(let report): return "check-" + report.id.uuidString
        case .addProjects(let profile): return "projects-" + profile.slug
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var defaultProfile: Profile?
    @Published var scan = ScanResult()
    @Published var status: StatusSummary?
    @Published var statusAvailable = true
    @Published var shell: ShellStatus?
    @Published var legacyAgents: [LegacyAgent] = []
    @Published var details: [String: ProfileDetails] = [:]
    @Published var profileProjects: [String: [ProfileProject]] = [:]
    @Published var selection: SidebarItem? = .home
    @Published var hasLoaded = false
    @Published var isRefreshing = false
    @Published var activeCommand: String?
    @Published var log: [LogLine] = []
    @Published var logVisible = false
    @Published var lastExitStatus: Int32?
    @Published var failure: CommandFailure?
    @Published var sheet: ActiveSheet?
    @Published var dismissedCandidates: Set<String> = []
    @Published var loadError: String?
    @Published var layoutBlocks: [String: [LegacyAgent]] = [:]
    @Published var settingsScrollTarget: String?
    @Published var isCheckingClaudeUpdates = false
    @Published var showsSetupFollowUp = false

    let runner: CLIRunner?
    private(set) var nextLogID = 0
    private var lastAutoRefresh = Date.distantPast
    private var attemptedStaleCLIUpdate = false
    private static let autoRefreshMinimumInterval: TimeInterval = 2

    init(runner: CLIRunner? = CLILocator.bundledCLI().map { CLIRunner(script: $0) }) {
        self.runner = runner
    }

    var setupNeeded: Bool { SetupStatus.needsSetup(status) }

    var isBusy: Bool { activeCommand != nil }
    var cliMissing: Bool { runner == nil }

    var sourceAppPath: String { defaultProfile?.app ?? status?.sourceApp ?? "/Applications/Claude.app" }
    var sourceAppPresent: Bool { FileManager.default.fileExists(atPath: sourceAppPath) }

    var visibleCandidates: [Candidate] {
        let adoptedApps = Set(profiles.compactMap(\.app))
        return scan.candidates.filter { !adoptedApps.contains($0.app) && !dismissedCandidates.contains($0.id) }
    }

    func profile(_ slug: String) -> Profile? {
        profiles.first { $0.slug == slug }
    }

    var selectedProfile: Profile? {
        if case .profile(let slug) = selection { return profile(slug) }
        return nil
    }

    func refresh() async {
        guard let runner else {
            hasLoaded = true
            return
        }
        isRefreshing = true
        let selectedSlug = selectedProfile?.slug
        await withTaskGroup(of: RefreshPiece.self) { group in
            group.addTask { .list(await runner.run(["list", "--plain"], timeout: 60)) }
            group.addTask { .scan(await runner.run(["scan", "--plain"], timeout: 120)) }
            group.addTask { .status(await runner.run(["status", "--plain"], timeout: 60)) }
            group.addTask { .shell(await runner.run(["shell-init", "status", "--plain"], timeout: 30)) }
            group.addTask { .agents(await runner.run(["legacy-agents", "--plain"], timeout: 30)) }
            for await piece in group {
                apply(piece)
            }
        }
        if let selectedSlug, profile(selectedSlug) != nil {
            await loadDetails(for: selectedSlug)
        }
        for other in profiles where other.slug != selectedSlug {
            await loadDetails(for: other.slug)
        }
        isRefreshing = false
    }

    func autoRefresh() async {
        guard runner != nil, hasLoaded, !isBusy, !isRefreshing else { return }
        guard Date().timeIntervalSince(lastAutoRefresh) >= Self.autoRefreshMinimumInterval else { return }
        lastAutoRefresh = Date()
        await refreshReadOnlyState()
    }

    private func refreshReadOnlyState() async {
        guard let runner else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let selectedSlug = selectedProfile?.slug
        var pieces: [RefreshPiece] = []
        await withTaskGroup(of: RefreshPiece.self) { group in
            group.addTask { .list(await runner.run(["list", "--plain"], timeout: 60)) }
            group.addTask { .status(await runner.run(["status", "--plain"], timeout: 60)) }
            for await piece in group {
                pieces.append(piece)
            }
        }
        guard !isBusy else { return }
        pieces.forEach(apply)
        if let selectedSlug, profile(selectedSlug) != nil {
            await loadDetails(for: selectedSlug)
        }
        for slug in profiles.map(\.slug) where slug != selectedSlug && details[slug] == nil {
            await loadDetails(for: slug)
        }
    }

    private enum RefreshPiece: Sendable {
        case list(CommandResult)
        case scan(CommandResult)
        case status(CommandResult)
        case shell(CommandResult)
        case agents(CommandResult)
    }

    var allProfiles: [Profile] {
        (defaultProfile.map { [$0] } ?? []) + profiles
    }

    private func apply(_ piece: RefreshPiece) {
        switch piece {
        case .list(let result):
            if result.succeeded {
                let all = PlainParser.profiles(result.stdout)
                defaultProfile = all.first { $0.isDefault }
                profiles = all.filter { !$0.isDefault }
                loadError = nil
            } else {
                loadError = result.failureSummary
            }
            reconcileSelection()
            hasLoaded = true
        case .scan(let result):
            if result.succeeded { scan = PlainParser.scan(result.stdout) }
        case .status(let result):
            statusAvailable = !result.isUnknownCommand
            status = result.succeeded ? PlainParser.status(result.stdout) : nil
        case .shell(let result):
            shell = result.succeeded ? PlainParser.shellStatus(result.stdout) : nil
        case .agents(let result):
            legacyAgents = result.succeeded ? PlainParser.legacyAgents(result.stdout) : []
        }
    }

    private func reconcileSelection() {
        switch selection {
        case .profile(let slug) where profile(slug) == nil:
            selection = .home
        case .none:
            selection = .home
        default:
            break
        }
    }

    func loadDetails(for slug: String) async {
        guard let runner else { return }
        async let show = runner.run(["show", slug, "--plain"], timeout: 60)
        async let projects = runner.run(["projects", slug, "list", "--plain"], timeout: 60)
        let showResult = await show
        let projectsResult = await projects
        if showResult.succeeded {
            details[slug] = PlainParser.profileDetails(showResult.stdout)
        } else {
            let dirs = await runner.run(["dirs", slug, "list"], timeout: 30)
            var fallback = ProfileDetails()
            fallback.dirs = dirs.succeeded ? PlainParser.rows(dirs.stdout).map { $0[0] } : []
            details[slug] = fallback
        }
        profileProjects[slug] = projectsResult.succeeded ? PlainParser.profileProjects(projectsResult.stdout) : []
    }

    @discardableResult
    func run(_ title: String, _ arguments: [String], showsAlert: Bool = true, refreshAfter: Bool = true, revealsLog: Bool = true) async -> CommandResult? {
        guard let runner, activeCommand == nil else { return nil }
        activeCommand = title
        lastExitStatus = nil
        if revealsLog { logVisible = true }
        appendLog("$ claude-profiles " + arguments.map(Self.displayArgument).joined(separator: " "), isError: false, isCommand: true)
        let result = await runner.run(arguments) { line, isError in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.appendLog(line, isError: isError, isCommand: false)
                }
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        lastExitStatus = result.status
        activeCommand = nil
        if !result.succeeded && showsAlert {
            failure = CommandFailure(title: "\(title) failed", message: result.failureSummary)
        }
        if refreshAfter {
            await refresh()
        }
        return result
    }

    private static func displayArgument(_ argument: String) -> String {
        argument.contains(where: { $0 == " " || $0 == "'" || $0 == "\"" }) ? SystemActions.shellQuote(argument) : argument
    }

    private func appendLog(_ text: String, isError: Bool, isCommand: Bool) {
        if isCommand && !log.isEmpty {
            log.append(LogLine(id: nextLogID, text: "", isError: false, isCommand: false))
            nextLogID += 1
        }
        log.append(LogLine(id: nextLogID, text: text, isError: isError, isCommand: isCommand))
        nextLogID += 1
        if log.count > 4000 {
            log.removeFirst(log.count - 4000)
        }
    }

    func checkForClaudeUpdates() async {
        guard !isCheckingClaudeUpdates else { return }
        isCheckingClaudeUpdates = true
        defer { isCheckingClaudeUpdates = false }
        logVisible = true
        appendLog("Check for Claude Updates", isError: false, isCommand: true)
        guard AXIsProcessTrusted() else {
            await handleMissingAccessibility()
            return
        }
        let activation = await ClaudeUpdateCheck.activateClaude()
        switch activation {
        case .notInstalled:
            reportUpdateCheckProblem("Claude is not installed, so there is nothing to check.", title: "Claude not found")
            return
        case .failed(let reason):
            reportUpdateCheckProblem("Could not open Claude: \(reason)", title: "Could not open Claude")
            return
        case .alreadyRunning, .launched:
            appendLog("Claude is active.", isError: false, isCommand: false)
        }
        switch await ClaudeUpdateCheck.findUpdateItem(attempts: activation.isFreshLaunch ? 20 : 2) {
        case .found(let entry):
            let result = await ClaudeUpdateCheck.click(entry)
            if result.status == 0 {
                appendLog("Clicked “\(entry.itemName)” in Claude's “\(entry.menuName)” menu. Claude runs its own update check; profiles follow automatically after Claude updates.", isError: false, isCommand: false)
            } else {
                reportClickFailure(result, detail: "Could not click “\(entry.itemName)”.")
            }
        case .notFound:
            reportUpdateCheckFallback("Claude's menu has no “Check for Updates…” item.", title: "Update item not found")
        case .failed(let result):
            reportClickFailure(result, detail: "Could not read Claude's menu.")
        }
    }

    private func handleMissingAccessibility() async {
        appendLog("Accessibility access is not granted to Claude Profiles, so Claude's update menu cannot be clicked.", isError: true, isCommand: false)
        switch ClaudeUpdateCheck.askAboutAccessibility() {
        case .openSettings:
            NSWorkspace.shared.open(ClaudeUpdateCheck.accessibilitySettingsURL)
            appendLog("Opened Accessibility settings. Enable Claude Profiles there, then run the check again.", isError: false, isCommand: false)
        case .justOpenClaude:
            _ = await ClaudeUpdateCheck.activateClaude()
            appendLog(ClaudeUpdateCheck.manualPath, isError: false, isCommand: false)
            ClaudeUpdateCheck.showInfo(title: "Check for updates in Claude", message: ClaudeUpdateCheck.manualPath)
        case .cancel:
            appendLog("Cancelled.", isError: false, isCommand: false)
        }
    }

    private func reportClickFailure(_ result: ScriptResult, detail: String) {
        if ClaudeUpdateCheck.isPermissionFailure(result.stderr) {
            reportUpdateCheckFallback(ClaudeUpdateCheck.permissionMessage(result.stderr), title: "Permission needed")
        } else {
            let reason = result.stderr.isEmpty ? "osascript exited \(result.status)." : result.stderr
            reportUpdateCheckFallback("\(detail) \(reason)", title: "Could not run the update check")
        }
    }

    private func reportUpdateCheckProblem(_ problem: String, title: String) {
        appendLog(problem, isError: true, isCommand: false)
        ClaudeUpdateCheck.showInfo(title: title, message: problem)
    }

    private func reportUpdateCheckFallback(_ problem: String, title: String) {
        appendLog(problem, isError: true, isCommand: false)
        appendLog(ClaudeUpdateCheck.manualPath, isError: false, isCommand: false)
        ClaudeUpdateCheck.showInfo(title: title, message: "\(problem)\n\n\(ClaudeUpdateCheck.manualPath)")
    }

    func clearLog() {
        log.removeAll()
        lastExitStatus = nil
    }

    func runCheck(_ profile: Profile) async {
        guard let result = await run("Check \(profile.name)", ["check", profile.slug, "--plain"], showsAlert: false, refreshAfter: false) else { return }
        let parsed = PlainParser.checkLines(result.stdout + (result.succeeded ? "" : "\n" + result.stderr))
        sheet = .check(CheckReport(title: "Check: \(profile.name)", heading: parsed.heading, lines: parsed.lines))
    }

    func recolor(_ profile: Profile, hex: String) async {
        await run("Recolor \(profile.name)", ["recolor", profile.slug, "--color", hex])
    }

    func migrateLayout(_ profile: Profile) async {
        layoutBlocks[profile.slug] = nil
        guard let result = await run("Move \(profile.name) to the new layout", ["migrate-layout", profile.slug, "--yes", "--plain"], showsAlert: false) else { return }
        guard !result.succeeded else { return }
        let blockers = PlainParser.legacyAgents(result.stdout)
        if blockers.isEmpty {
            failure = CommandFailure(title: "Move to new layout failed", message: result.failureSummary)
        } else {
            layoutBlocks[profile.slug] = blockers
        }
    }

    func showLegacyAgents() {
        settingsScrollTarget = SettingsView.legacyAgentsAnchor
        selection = .settings
    }

    func offerSetupAfterCreate() {
        guard setupNeeded else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            showsSetupFollowUp = setupNeeded
        }
    }

    func startSetup() async {
        guard let result = await installCLI(), result.succeeded else { return }
        do {
            try SystemActions.openSetupInTerminal()
        } catch {
            failure = CommandFailure(title: "Could not open Terminal", message: error.localizedDescription)
        }
    }

    @discardableResult
    func installCLI(quiet: Bool = false) async -> CommandResult? {
        guard let runner else { return nil }
        let arguments = ["install-cli", "--from", runner.script.deletingLastPathComponent().deletingLastPathComponent().path]
        return await run("Install command-line tool", arguments, showsAlert: !quiet, revealsLog: !quiet)
    }

    func updateInstalledCLIIfStale() async {
        guard let runner, !attemptedStaleCLIUpdate, hasLoaded, !isBusy, status?.cliCurrent == false else { return }
        attemptedStaleCLIUpdate = true
        let bundledRoot = runner.script.deletingLastPathComponent().deletingLastPathComponent()
        let installedRoot = Self.installedCLIRoot(linkPath: status?.cliPath)
        let decision = CLIUpdatePolicy.decide(
            bundled: Self.version(in: bundledRoot),
            installed: Self.version(in: installedRoot)
        )
        appendLog(decision.message, isError: false, isCommand: false)
        guard decision.shouldInstall, let result = await installCLI(quiet: true) else { return }
        appendLog(result.succeeded
                  ? "Updated the installed command-line tool to match this app."
                  : "Could not update the installed command-line tool. Open Setup & Settings and press Update.",
                  isError: !result.succeeded, isCommand: false)
    }

    private static func installedCLIRoot(linkPath: String?) -> URL {
        guard let linkPath, !linkPath.isEmpty else {
            return URL(fileURLWithPath: NSHomeDirectory() + "/.local/share/claude-profiles")
        }
        return URL(fileURLWithPath: linkPath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func version(in root: URL) -> String? {
        guard let text = try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var preferredShell: String {
        (ProcessInfo.processInfo.environment["SHELL"] ?? "").hasSuffix("bash") ? "bash" : "zsh"
    }

    func setShellIntegration(_ enabled: Bool) async {
        if enabled {
            if status?.cliInstalled != true {
                guard let installed = await installCLI(), installed.succeeded else { return }
            }
            await run("Enable shell integration", ["shell-init", "install", preferredShell])
        } else {
            await run("Disable shell integration", ["shell-init", "uninstall", preferredShell])
        }
    }
}
