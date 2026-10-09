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
    @Published var selection: SidebarItem?
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

    let runner: CLIRunner?
    private(set) var nextLogID = 0

    init(runner: CLIRunner? = CLILocator.bundledCLI().map { CLIRunner(script: $0) }) {
        self.runner = runner
    }

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

    private enum RefreshPiece: Sendable {
        case list(CommandResult)
        case scan(CommandResult)
        case status(CommandResult)
        case shell(CommandResult)
        case agents(CommandResult)
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
            selection = profiles.first.map { .profile($0.slug) }
        case .none where !hasLoaded:
            selection = profiles.first.map { .profile($0.slug) }
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
    func run(_ title: String, _ arguments: [String], showsAlert: Bool = true, refreshAfter: Bool = true) async -> CommandResult? {
        guard let runner, activeCommand == nil else { return nil }
        activeCommand = title
        lastExitStatus = nil
        logVisible = true
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

    func startSetup() async {
        guard let result = await installCLI(), result.succeeded else { return }
        do {
            try SystemActions.openSetupInTerminal()
        } catch {
            failure = CommandFailure(title: "Could not open Terminal", message: error.localizedDescription)
        }
    }

    @discardableResult
    func installCLI() async -> CommandResult? {
        var arguments = ["install-cli"]
        if let runner {
            arguments += ["--from", runner.script.deletingLastPathComponent().deletingLastPathComponent().path]
        }
        return await run("Install command-line tool", arguments)
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
