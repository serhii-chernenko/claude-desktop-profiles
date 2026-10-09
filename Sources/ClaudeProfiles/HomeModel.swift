import Foundation

enum ChipTone: Hashable {
    case positive
    case warning
    case neutral
}

struct StatusChip: Hashable {
    let text: String
    let tone: ChipTone
}

enum CardAction: Hashable {
    case open(String)
    case copyCommand(String)
    case unavailable
    case loading
}

struct ProfileCardModel: Identifiable, Hashable {
    let item: SidebarItem
    let name: String
    let colorHex: String?
    let glyph: String
    let usesSymbolGlyph: Bool
    let kind: String
    let chips: [StatusChip]
    let action: CardAction
    var checksClaudeUpdates = false

    var id: SidebarItem { item }
}

struct HomeEnvironment {
    var isRunning: (String) -> Bool
    var appVersion: (String) -> String?
    var fileExists: (String) -> Bool

    static func live(runningPaths: Set<String>) -> HomeEnvironment {
        HomeEnvironment(
            isRunning: { runningPaths.contains(standardizedPath($0)) },
            appVersion: { path in
                guard let bundle = Bundle(path: path),
                      let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
                guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return short }
                return "\(short) (\(build))"
            },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum HomeCards {
    static func shortVersion(_ raw: String) -> String {
        raw.split(separator: " ").first.map(String.init) ?? raw
    }

    static func kind(isDesktop: Bool, cli: Bool) -> String {
        switch (isDesktop, cli) {
        case (true, true): return "Desktop app + Terminal"
        case (true, false): return "Desktop app"
        default: return "Terminal only"
        }
    }

    static func main(sourcePath: String, sourceVersion: String?, environment: HomeEnvironment) -> ProfileCardModel {
        let installed = environment.fileExists(sourcePath)
        var chips: [StatusChip] = []
        if !installed {
            chips.append(StatusChip(text: "Not installed", tone: .warning))
        } else {
            if environment.isRunning(sourcePath) {
                chips.append(StatusChip(text: "Running", tone: .positive))
            }
        }
        let kind = installed ? sourceVersion.map { "Your regular Claude · \(shortVersion($0))" } ?? "Your regular Claude" : "Your regular Claude"
        return ProfileCardModel(
            item: .main,
            name: "Main Claude",
            colorHex: nil,
            glyph: "person.crop.circle.fill",
            usesSymbolGlyph: true,
            kind: kind,
            chips: chips,
            action: installed ? .open(sourcePath) : .unavailable,
            checksClaudeUpdates: installed
        )
    }

    static func card(for profile: Profile, details: ProfileDetails?, sourceVersion: String?, environment: HomeEnvironment) -> ProfileCardModel {
        let cli = details?.flag("cli") ?? !profile.isDesktop
        let initial = String(profile.name.prefix(1)).uppercased()
        var chips: [StatusChip] = []
        var action = CardAction.copyCommand("claude-\(profile.slug)")
        if profile.isDesktop && details == nil {
            chips.append(StatusChip(text: "Loading…", tone: .neutral))
            action = .loading
        } else if profile.isDesktop {
            let selfMode = details?.isSelfMode ?? false
            let appPath = details?.value("app") ?? profile.app
            let openTarget = selfMode ? appPath : details?.value("launcher")
            action = openTarget.map { environment.fileExists($0) ? .open($0) : .unavailable } ?? .unavailable
            if let appPath, environment.fileExists(appPath) {
                if environment.isRunning(appPath) {
                    chips.append(StatusChip(text: "Running", tone: .positive))
                }
                if let sourceVersion, let installedVersion = environment.appVersion(appPath) {
                    chips.append(installedVersion == sourceVersion
                        ? StatusChip(text: "Up to date", tone: .positive)
                        : StatusChip(text: "Rebuild needed", tone: .warning))
                }
            } else {
                chips.append(StatusChip(text: "Not built", tone: .warning))
            }
            if let mode = details?.mode {
                chips.append(StatusChip(text: mode == "self" ? "Self mode" : "Launcher mode", tone: .neutral))
            }
        } else if let folders = details?.dirs.count {
            chips.append(StatusChip(text: folders == 0 ? "No folders yet" : "\(folders) folder\(folders == 1 ? "" : "s")", tone: .neutral))
        }
        return ProfileCardModel(
            item: .profile(profile.slug),
            name: profile.name,
            colorHex: profile.color,
            glyph: initial,
            usesSymbolGlyph: false,
            kind: kind(isDesktop: profile.isDesktop, cli: cli),
            chips: chips,
            action: action
        )
    }

    static func cards(
        sourcePath: String,
        status: StatusSummary?,
        profiles: [Profile],
        details: [String: ProfileDetails],
        environment: HomeEnvironment
    ) -> [ProfileCardModel] {
        [main(sourcePath: sourcePath, sourceVersion: status?.sourceVersion, environment: environment)]
            + profiles.map { card(for: $0, details: details[$0.slug], sourceVersion: status?.sourceVersion, environment: environment) }
    }
}

enum SetupState: Hashable {
    case ok
    case warning
    case unknown
}

enum SetupCompletion: Hashable {
    case complete
    case incomplete
    case unknown
}

enum StepMark: Hashable {
    case done
    case pending
    case neutral
}

struct HowItWorksStep: Identifiable, Hashable {
    let number: Int
    let title: String
    let text: String
    let mark: StepMark

    var id: Int { number }
}

enum HowItWorks {
    static func setupMark(_ status: StatusSummary?) -> StepMark {
        switch SetupStatus.completion(status) {
        case .complete: return .done
        case .incomplete: return .pending
        case .unknown: return .neutral
        }
    }

    static func steps(status: StatusSummary?) -> [HowItWorksStep] {
        [
            HowItWorksStep(number: 1, title: "Create a profile", text: "Give it a name and a color.", mark: .neutral),
            HowItWorksStep(number: 2, title: "One-time setup", text: "Auto-updates and no repeated permission prompts.", mark: setupMark(status)),
            HowItWorksStep(number: 3, title: "Open it like any app", text: "Start it from the Dock or Spotlight and sign in.", mark: .neutral),
            HowItWorksStep(number: 4, title: "Optional: Terminal", text: "Turn on Terminal integration so `claude` picks the profile by folder.", mark: .neutral),
        ]
    }
}

enum SetupCopy {
    static let actionTitle = "Set up auto-rebuild & stable signing"
    static let bannerTitle = "Finish the one-time setup (about 1 minute)"
    static let explanation = "Without it, profiles stay on the old Claude version after Claude updates, and macOS asks for Keychain and permissions again after every rebuild."
    static let firstProfileNudge = "Do it now so your first profile is set up right."
    static let agentReason = "The auto-rebuild agent notices when Claude updates and rebuilds your profiles that are not running, so they follow the new version."
    static let certificateReason = "The stable signing certificate lives in your login keychain. It gives every rebuild the same identity, so macOS remembers your Keychain and permission choices."
    static let passwordNote = "Terminal opens once because macOS asks for your login password there. This app never handles passwords."
    static let followUpTitle = "Profile created. Finish the one-time setup now?"
    static let detailWarning = "Auto-updates are off until the one-time setup is done"

    static func bannerBody(hasProfiles: Bool) -> String {
        hasProfiles ? explanation : explanation + " " + firstProfileNudge
    }
}

struct SetupItem: Identifiable, Hashable {
    let anchor: String
    let title: String
    let detail: String
    let state: SetupState

    var id: String { title }
}

enum SetupStatus {
    static let commandLineAnchor = "setup-command-line"
    static let shellAnchor = "setup-shell"
    static let rebuildAnchor = "setup-rebuild"

    static func commandLineOK(_ status: StatusSummary?) -> Bool? {
        guard let installed = status?.cliInstalled else { return nil }
        return installed && status?.cliCurrent != false
    }

    static func identityOK(_ status: StatusSummary?) -> Bool? {
        guard let present = status?.identityPresent else { return nil }
        return present && (status?.identityUsable ?? false)
    }

    static func agentOK(_ status: StatusSummary?) -> Bool? {
        status?.agentLoaded
    }

    static func completion(_ status: StatusSummary?) -> SetupCompletion {
        let results = [agentOK(status), identityOK(status)]
        if results.contains(false) { return .incomplete }
        return results.allSatisfy { $0 == true } ? .complete : .unknown
    }

    static func needsSetup(_ status: StatusSummary?) -> Bool {
        completion(status) == .incomplete
    }

    private static func state(_ value: Bool?) -> SetupState {
        switch value {
        case .some(true): return .ok
        case .some(false): return .warning
        case .none: return .unknown
        }
    }

    static func items(status: StatusSummary?, shell: ShellStatus?) -> [SetupItem] {
        let commandLine = commandLineOK(status)
        let commandLineDetail: String
        switch (status?.cliInstalled, status?.cliCurrent) {
        case (.some(false), _): commandLineDetail = "Not installed"
        case (_, .some(false)): commandLineDetail = "Out of date"
        case (.some(true), _): commandLineDetail = "Up to date"
        default: commandLineDetail = "Unknown"
        }
        let identity = identityOK(status)
        let identityDetail: String
        switch (status?.identityPresent, status?.identityUsable) {
        case (.some(true), .some(true)): identityDetail = "Ready"
        case (.some(true), _): identityDetail = "Needs setup"
        case (.some(false), _): identityDetail = "Not set up"
        default: identityDetail = "Unknown"
        }
        return [
            SetupItem(anchor: rebuildAnchor, title: "Auto-rebuild agent",
                      detail: status?.agentLoaded == nil ? "Unknown" : (status?.agentLoaded == true ? "Loaded" : "Not set up"),
                      state: state(status?.agentLoaded)),
            SetupItem(anchor: rebuildAnchor, title: "Signing identity", detail: identityDetail, state: state(identity)),
            SetupItem(anchor: commandLineAnchor, title: "Command-line tool", detail: commandLineDetail, state: state(commandLine)),
            SetupItem(anchor: shellAnchor, title: "Shell integration",
                      detail: shell == nil ? "Unknown" : (shell?.installed == true ? "On" : "Off"),
                      state: state(shell?.installed)),
        ]
    }
}
