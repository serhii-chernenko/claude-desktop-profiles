import Foundation

struct Profile: Identifiable, Hashable {
    let slug: String
    let name: String
    let color: String?
    let isDesktop: Bool
    let app: String?
    let configDir: String
    let dataDir: String?

    var id: String { slug }
    var isDefault: Bool { slug == "default" }
}

struct ConfigDirEntry: Identifiable, Hashable {
    let path: String
    let projectCount: Int

    var id: String { path }
}

struct ScannedProject: Identifiable, Hashable {
    let configDir: String
    let cwd: String
    let sessions: Int
    let lastUsed: Date?
    let owner: String?

    var id: String { configDir + "\t" + cwd }
}

struct Candidate: Identifiable, Hashable {
    let app: String
    let launcher: String?
    let bundleID: String
    let dataDir: String?
    let configDir: String?
    let name: String
    let identity: String?

    var id: String { app }
    var appDisplayName: String { (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") }
}

struct ScanResult {
    var configs: [ConfigDirEntry] = []
    var dataDirs: [String] = []
    var projects: [ScannedProject] = []
    var candidates: [Candidate] = []
}

struct ProfileDetails: Equatable {
    var fields: [String: String] = [:]
    var dirs: [String] = []

    func value(_ key: String) -> String? {
        guard let raw = fields[key], raw != "-", !raw.isEmpty else { return nil }
        return raw
    }

    func flag(_ key: String) -> Bool? {
        guard let raw = value(key) else { return nil }
        return raw == "1"
    }

    var usesLegacyLayout: Bool { value("layout") == "legacy" }
    var mode: String? { value("mode") }
    var isSelfMode: Bool { mode == "self" }
    var canMoveToSelfMode: Bool { mode == "launcher" || usesLegacyLayout }

    var dockState: String? { value("dock")?.split(separator: " ").first.map(String.init) }
    var dockNeedsFix: Bool { dockState == "copy_pinned" || dockState == "old_launcher_pinned" }
}

struct ProfileProject: Identifiable, Hashable {
    let cwd: String
    let sessions: Int
    let lastUsed: Date?
    let isSymlink: Bool

    var id: String { cwd }
}

struct StatusSummary: Equatable {
    var cliInstalled: Bool?
    var cliPath: String?
    var cliCurrent: Bool?
    var identityName: String?
    var identityPresent: Bool?
    var identityUsable: Bool?
    var agentLabel: String?
    var agentLoaded: Bool?
    var sourceApp: String?
    var sourceVersion: String?
    var sourceTeamOK: Bool?
    var handlerScheme: String?
    var handlerBundleID: String?
    var home: String?
}

struct ShellStatus: Equatable {
    var installed = false
    var rcFile: String?
    var conflicts: [String] = []
}

struct LegacyAgent: Identifiable, Hashable {
    let label: String
    let plist: String
    let loaded: Bool
    let program: String?

    var id: String { label }
}

enum CheckLevel: String {
    case ok = "OK"
    case warn = "WARN"
    case fail = "FAIL"
    case info = "INFO"
    case detail
}

struct CheckLine: Identifiable, Hashable {
    let id: Int
    let level: CheckLevel
    let message: String
}

struct CheckReport: Identifiable {
    let id = UUID()
    let title: String
    let heading: String?
    let lines: [CheckLine]

    var failures: Int { lines.filter { $0.level == .fail }.count }
    var warnings: Int { lines.filter { $0.level == .warn }.count }
    var passes: Int { lines.filter { $0.level == .ok }.count }
}

enum LinkMode: String, CaseIterable, Identifiable {
    case symlink
    case move
    case copy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symlink: return "Share"
        case .move: return "Move"
        case .copy: return "Copy"
        }
    }

    var explanation: String {
        switch self {
        case .symlink: return "Symlink: both config folders see the same history from now on."
        case .move: return "Moves the history here; the old config folder no longer has it."
        case .copy: return "Independent copy; the two histories diverge from now on."
        }
    }
}

enum SidebarItem: Hashable {
    case home
    case main
    case profile(String)
    case settings
}
