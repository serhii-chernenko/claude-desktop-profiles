import Foundation

protocol SizedInKB {
    var sizeKB: Int? { get }
}

extension SizedInKB {
    static func biggestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        (lhs.sizeKB ?? -1) > (rhs.sizeKB ?? -1)
    }
}

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

struct WorktreeProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let dataDir: String?
    let isRunning: Bool
    let hasRegistry: Bool
}

enum WorktreeState: String, Hashable {
    case active
    case archived
    case kept
    case pool
    case orphan
    case missing
    case unknown

    init(raw: String) {
        self = WorktreeState(rawValue: raw) ?? .unknown
    }

    var title: String {
        switch self {
        case .active: return "Active"
        case .archived: return "Archived"
        case .kept: return "Kept"
        case .pool: return "Spare"
        case .orphan: return "Orphan"
        case .missing: return "Missing"
        case .unknown: return "Unknown"
        }
    }
}

enum BranchState: Hashable {
    case noBranch
    case saved
    case unsaved(Int)
    case unknown

    init(raw: String?) {
        let value = raw?.trimmingCharacters(in: .whitespaces) ?? ""
        let unsavedPrefix = "unsaved:"
        if value == "none" {
            self = .noBranch
        } else if value == "saved" {
            self = .saved
        } else if value.hasPrefix(unsavedPrefix), let count = Int(value.dropFirst(unsavedPrefix.count)), count > 0 {
            self = .unsaved(count)
        } else {
            self = .unknown
        }
    }

    var hasBranch: Bool {
        switch self {
        case .saved, .unsaved: return true
        case .noBranch, .unknown: return false
        }
    }

    var unsavedCommits: Int {
        if case .unsaved(let count) = self { return count }
        return 0
    }
}

struct WorktreeEntry: Identifiable, Hashable, SizedInKB {
    let position: Int
    let profileID: String
    let name: String
    let path: String
    let repo: String?
    let branch: String?
    let state: WorktreeState
    let lastActive: Date?
    let idleDays: Int
    let isDirty: Bool?
    let sizeKB: Int?
    let isEligible: Bool
    let reason: String?
    let sessionTitle: String?
    var branchState: BranchState = .unknown
    var branchName: String?

    var id: String { "\(profileID)\t\(position)\t\(path)" }
    var selectionKey: String { "\(profileID)\t\(path)" }
    var isSelectable: Bool { isEligible || reason == WorktreeEntry.youngReason }
    static let youngReason = "recent"
    var repoName: String? { repo.map { ($0 as NSString).lastPathComponent } }
    var deletesBranchByDefault: Bool { branchState == .saved }
    var canChooseBranchDeletion: Bool { branchState.hasBranch }
}

struct WorktreeList: Equatable {
    var profiles: [WorktreeProfile] = []
    var entries: [WorktreeEntry] = []
}

enum WorktreeCleanKind: Hashable {
    case removed
    case wouldRemove
    case failed
    case blocked
    case skipped
    case branchDeleted
    case branchKept
    case wouldDeleteBranch
    case wouldKeepBranch
}

struct WorktreeCleanRow: Hashable {
    let kind: WorktreeCleanKind
    let profileID: String
    let path: String?
    let sizeKB: Int?
    let message: String?
    var branch: String?
    var unsavedCommits: Int?
}

struct WorktreeCleanSummary: Hashable {
    let removed: Int
    let freedKB: Int
    let failed: Int
    let blocked: Int
    var branchesDeleted: Int?
    var branchesKept: Int?
}

struct WorktreeCleanResult: Equatable {
    var rows: [WorktreeCleanRow] = []
    var summary: WorktreeCleanSummary?

    func rows(_ kind: WorktreeCleanKind) -> [WorktreeCleanRow] {
        rows.filter { $0.kind == kind }
    }

    var branchesDeleted: Int { summary?.branchesDeleted ?? rows(.branchDeleted).count }
    var branchesKept: Int { summary?.branchesKept ?? rows(.branchKept).count }
}

enum CacheKind: String, Hashable {
    case web
    case pane
    case version
    case vm
    case unknown

    init(raw: String) {
        self = CacheKind(rawValue: raw) ?? .unknown
    }
}

struct CacheItem: Identifiable, Hashable, SizedInKB {
    let profileID: String
    let relativePath: String
    let kind: CacheKind
    let sizeKB: Int?

    var id: String { "\(profileID):\(relativePath)" }
    var isPreselectedForCleanup: Bool { kind != .vm }
}

struct CacheList: Equatable {
    var profiles: [WorktreeProfile] = []
    var items: [CacheItem] = []
}

enum StorageKind: String, Hashable {
    case cache
    case panes
    case versions
    case vm
    case sessions
    case history
    case plugins
    case worktrees
    case other

    init(raw: String) {
        self = StorageKind(rawValue: raw) ?? .other
    }

    var title: String {
        switch self {
        case .cache: return "Cache"
        case .panes: return "Browser panes"
        case .versions: return "Claude Code versions"
        case .vm: return "Cowork VM"
        case .sessions: return "Sessions"
        case .history: return "History"
        case .plugins: return "Plugins"
        case .worktrees: return "Worktrees"
        case .other: return "Other"
        }
    }
}

enum StorageTool: String, Hashable {
    case caches
    case history
    case worktrees
    case nothing

    init(raw: String?) {
        switch raw {
        case "caches": self = .caches
        case "history": self = .history
        case "worktrees": self = .worktrees
        default: self = .nothing
        }
    }
}

enum StorageLocation: String, Hashable {
    case data
    case config
    case worktrees
    case other

    init(raw: String) {
        self = StorageLocation(rawValue: raw) ?? .other
    }
}

struct StorageProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let dataDir: String?
    let configDir: String?
    let isRunning: Bool

    var asWorktreeProfile: WorktreeProfile {
        WorktreeProfile(id: id, name: name, dataDir: dataDir, isRunning: isRunning, hasRegistry: false)
    }
}

struct StorageArea: Identifiable, Hashable, SizedInKB {
    let position: Int
    let profileID: String
    let location: StorageLocation
    let entry: String
    let kind: StorageKind
    let sizeKB: Int?
    let tool: StorageTool

    var id: String { "\(profileID)\t\(position)" }
}

struct SharedConfig: Hashable {
    let profileID: String
    let configDir: String
    let ownerID: String
}

struct StorageList: Equatable {
    var profiles: [StorageProfile] = []
    var areas: [StorageArea] = []
    var totals: [String: Int] = [:]
    var shared: [SharedConfig] = []

    func areas(of profileID: String) -> [StorageArea] {
        areas.filter { $0.profileID == profileID }
    }

    func totalKB(of profileID: String) -> Int {
        totals[profileID] ?? areas(of: profileID).compactMap(\.sizeKB).reduce(0, +)
    }

    var grandTotalKB: Int {
        profiles.map { totalKB(of: $0.id) }.reduce(0, +)
    }
}

struct HistoryProject: Identifiable, Hashable, SizedInKB {
    let profileID: String
    let name: String
    let cwd: String?
    let sessions: Int
    let sizeKB: Int?
    let lastDays: Int?

    var id: String { "\(profileID):\(name)" }
}

struct HistoryList: Equatable {
    var profiles: [StorageProfile] = []
    var projects: [HistoryProject] = []
    var shared: [SharedConfig] = []
}

enum SidebarItem: Hashable {
    case home
    case main
    case profile(String)
    case settings
}
