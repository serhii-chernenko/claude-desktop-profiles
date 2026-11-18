import SwiftUI

struct WorktreeOutcome: Equatable {
    let text: String
    let details: [String]
    let isProblem: Bool
}

private struct WorktreeGroup: Identifiable {
    let profile: WorktreeProfile
    let entries: [WorktreeEntry]

    var id: String { profile.id }
}

private struct CacheGroup: Identifiable {
    let profile: WorktreeProfile
    let items: [CacheItem]
    let smallItems: [CacheItem]
    let vmItems: [CacheItem]

    var id: String { profile.id }
}

private struct WorktreeLoadKey: Hashable {
    let target: String
    let includeUncommitted: Bool
    let reload: Int
}

private struct CacheLoadKey: Hashable {
    let target: String
    let reload: Int
}

enum StoragePane: String, CaseIterable, Identifiable {
    case overview
    case worktrees
    case caches
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .worktrees: return "Worktrees"
        case .caches: return "Caches"
        case .history: return "History"
        }
    }

    var explanation: String {
        switch self {
        case .overview: return WorktreeCopy.overviewExplanation
        case .worktrees: return WorktreeCopy.explanation
        case .caches: return WorktreeCopy.cacheExplanation
        case .history: return WorktreeCopy.historyExplanation
        }
    }
}

enum WorktreeCopy {
    static let allTarget = "all"
    static let mainTarget = "main"
    static let dayOptions = [7, 14, 30, 60, 90]
    static let defaultDays = 30
    static let listTimeout: TimeInterval = 120
    static let storageTimeout: TimeInterval = 300
    static let scanFloorDays = 1
    static let smallCacheKB = 1024

    static let overviewExplanation = "Everything each profile keeps on disk, measured per folder. Nothing is deleted here: use the buttons to open the tab that cleans an area."

    static let explanation = "Worktrees are the folders the Code tab creates for sessions. Removing one deletes the whole folder, including ignored files such as .env, node_modules and build output. The session stays in the sidebar, but a removed worktree (and a deleted branch) is not restored when it resumes. A branch is deleted only when every commit on it is also on another branch or remote, and the default branch is never deleted."

    static let historyExplanation = "Claude Code keeps one history folder per project. Deleting one removes its conversations for good: they can no longer be resumed or read. Nothing is selected until you choose."

    static let vmWarning = "Claude should download a fresh VM disk the next time Cowork starts (not verified); anything installed inside the VM is lost."

    static let noDesktopAppNote = "This profile has no desktop app, so it has no Code worktrees or app caches."

    static let cacheExplanation = "The app rebuilds these caches when it needs them, so removing them is safe; the next launch is a little slower. Older Claude Code versions are downloaded again only if the app needs them. Sign-ins, cookies, settings and sessions are never touched."

    static func lastUsedText(days: Int?) -> String {
        guard let days else { return "last used unknown" }
        switch days {
        case 0: return "used today"
        case 1: return "used yesterday"
        default: return "used \(days) days ago"
        }
    }

    static func branchKeptText(_ reason: String?, unsavedCommits: Int?) -> String {
        guard let reason else { return "kept" }
        switch reason {
        case "unsaved": return "kept, \(plural(unsavedCommits ?? 0, "commit")) found nowhere else"
        case "checked_out": return "kept, still checked out in another worktree"
        case "kept_by_flag": return "kept as requested"
        case "protected": return "Default branch, kept"
        default:
            let failurePrefix = "failed:"
            return reason.hasPrefix(failurePrefix)
                ? "could not be deleted: " + reason.dropFirst(failurePrefix.count).trimmingCharacters(in: .whitespaces)
                : reason
        }
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    static func size(kilobytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(kilobytes) * 1024, countStyle: .file)
    }

    static func cliTarget(_ target: String) -> String {
        target == allTarget ? "--all" : target
    }

    static func reasonText(_ reason: String?, days: Int) -> String? {
        guard let reason else { return nil }
        switch reason {
        case "recent": return "Used in the last \(days) days"
        case "dirty": return "Uncommitted changes"
        case "pinned": return "Pinned session"
        case "keep_marker": return "Marked to keep"
        case "current": return "In use here"
        case "no_repo": return "Repository missing"
        case "not_a_worktree": return "Not a git worktree"
        case "missing": return "Already gone"
        case "bad_path": return "Unexpected location"
        case "outside": return "Not made by Claude"
        case "duplicate": return "Listed twice"
        case "detached": return "No branch (detached)"
        case "no_timestamp": return "Last use unknown"
        case "not_found": return "No longer listed"
        default: return reason
        }
    }

    static func quitNote(for profile: WorktreeProfile, noun: String) -> String {
        profile.id == mainTarget
            ? "Quit Claude to remove its \(noun)"
            : "Quit Claude \(profile.name) to remove its \(noun)"
    }

    private static let cacheNames: [String: String] = [
        "Cache": "Web cache",
        "Code Cache": "Script cache",
        "GPUCache": "Graphics cache",
        "GPUPersistentCache": "Graphics cache",
        "DawnGraphiteCache": "Graphics cache",
        "DawnWebGPUCache": "Graphics cache",
        "GraphiteDawnCache": "Graphics cache",
        "ShaderCache": "Shader cache",
        "GrShaderCache": "Shader cache",
    ]

    static func cacheTitle(_ item: CacheItem) -> String {
        let parts = item.relativePath.split(separator: "/").map(String.init)
        let leaf = parts.last ?? item.relativePath
        switch item.kind {
        case .web:
            return "App · " + (cacheNames[leaf] ?? leaf)
        case .pane:
            let partition = parts.count >= 3 ? parts[1] : ""
            return "Browser pane \(partition) · " + (cacheNames[leaf] ?? leaf)
        case .version:
            let product = parts.first == "claude-code-vm" ? "Claude Code for the VM" : "Claude Code"
            return "\(product) \(leaf) (older version)"
        case .vm:
            return "Cowork VM disk"
        case .unknown:
            return item.relativePath
        }
    }

    static func outcome(for result: CommandResult, names: [String: String], noun: String,
                        verb: String = "Removed", keptNote: String = "that can no longer be removed safely",
                        skipText: (String?) -> String?) -> WorktreeOutcome {
        let parsed = PlainParser.worktreeClean(result.stdout)
        guard let summary = parsed.summary else {
            return WorktreeOutcome(text: "The cleanup did not finish. " + result.failureSummary, details: [], isProblem: true)
        }
        var sentences: [String] = []
        if summary.removed > 0 {
            sentences.append("\(verb) \(plural(summary.removed, noun)) and freed \(size(kilobytes: summary.freedKB)).")
        } else {
            sentences.append("Nothing was removed.")
        }
        if parsed.branchesDeleted + parsed.branchesKept > 0 {
            sentences.append("Branches: \(parsed.branchesDeleted) deleted, \(parsed.branchesKept) kept.")
        }
        if summary.failed > 0 {
            sentences.append("\(plural(summary.failed, noun)) could not be removed.")
        }
        let skipped = parsed.rows(.skipped)
        if !skipped.isEmpty {
            sentences.append("Kept \(plural(skipped.count, noun)) \(keptNote).")
        }
        let blockedNames = parsed.rows(.blocked).map { names[$0.profileID] ?? $0.profileID }
        if !blockedNames.isEmpty {
            sentences.append("Skipped \(blockedNames.joined(separator: ", ")) because its app is running. Quit it and try again.")
        }
        let failures = parsed.rows(.failed).map { row -> String in
            let folder = ((row.path ?? "") as NSString).lastPathComponent
            return row.message.map { "\(folder): \($0)" } ?? folder
        }
        let skips = skipped.map { row -> String in
            let folder = ((row.path ?? "") as NSString).lastPathComponent
            return skipText(row.message).map { "\(folder): \($0)" } ?? folder
        }
        let keptBranches = parsed.rows(.branchKept).filter { $0.message != "kept_by_flag" }
        let branchNotes = keptBranches.map { row in
            "Branch \(row.branch ?? ""): " + branchKeptText(row.message, unsavedCommits: row.unsavedCommits)
        }
        let branchFailed = keptBranches.contains { $0.message?.hasPrefix("failed:") == true }
        let isProblem = summary.failed > 0 || summary.blocked > 0 || !skipped.isEmpty || branchFailed
        return WorktreeOutcome(text: sentences.joined(separator: " "), details: failures + skips + branchNotes, isProblem: isProblem)
    }

    static func worktreeCleanArguments(target: String, entries: [WorktreeEntry], keepsAllBranches: Bool,
                                       includeUncommitted: Bool, deletesBranch: (WorktreeEntry) -> Bool) -> [String] {
        var arguments = ["worktrees", cliTarget(target), "clean"]
        for entry in entries {
            arguments += ["--path", entry.path]
        }
        if keepsAllBranches {
            arguments.append("--keep-branches")
        } else {
            for entry in entries where entry.canChooseBranchDeletion {
                if deletesBranch(entry) {
                    if entry.branchState.unsavedCommits > 0 { arguments += ["--delete-branch", entry.path] }
                } else {
                    arguments += ["--keep-branch", entry.path]
                }
            }
        }
        if includeUncommitted { arguments.append("--include-uncommitted") }
        arguments += ["--yes", "--plain"]
        return arguments
    }

    static func names(of profiles: [WorktreeProfile]) -> [String: String] {
        Dictionary(profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

struct WorktreesSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var target: String
    @State private var pane: StoragePane = .overview

    init(initialTarget: String?) {
        _target = State(initialValue: initialTarget ?? WorktreeCopy.allTarget)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Clean Up Storage")
                    .font(.title2.weight(.semibold))
                Picker("Show", selection: $pane) {
                    ForEach(StoragePane.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.isBusy)
                Text(pane.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 6)
            switch pane {
            case .overview:
                OverviewPane(target: $target) { pane = $0 }
            case .worktrees:
                WorktreesPane(target: $target)
            case .caches:
                CachesPane(target: $target)
            case .history:
                HistoryPane(target: $target)
            }
        }
        .frame(width: 760, height: 760)
    }
}

struct ProfilePicker: View {
    @EnvironmentObject var model: AppModel
    @Binding var target: String

    var body: some View {
        Picker("Profile", selection: $target) {
            Text("All profiles").tag(WorktreeCopy.allTarget)
            Text("Main Claude").tag(WorktreeCopy.mainTarget)
            ForEach(model.profiles) { profile in
                Text(profile.isDesktop ? profile.name : "\(profile.name) (CLI only)").tag(profile.slug)
            }
        }
    }
}

extension AppModel {
    func isCLIOnlyTarget(_ target: String) -> Bool {
        profiles.first { $0.slug == target }.map { !$0.isDesktop } ?? false
    }
}

struct SelectionBar: View {
    let selectedCount: Int
    let selectableCount: Int
    let noun: String
    let selectAll: () -> Void
    let selectNone: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(selectedCount) of \(WorktreeCopy.plural(selectableCount, noun)) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Select All", action: selectAll)
                .disabled(selectableCount == 0 || selectedCount == selectableCount)
            Button("Select None", action: selectNone)
                .disabled(selectedCount == 0)
        }
    }
}

struct GroupHeader: View {
    let profile: WorktreeProfile
    let selected: Int
    let total: Int
    let noun: String

    var body: some View {
        HStack(spacing: 8) {
            Text(profile.name)
                .font(.headline)
            Text("\(WorktreeCopy.plural(total, noun)) · \(selected) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if profile.isRunning {
                Label(WorktreeCopy.quitNote(for: profile, noun: noun + "s"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

struct OutcomeBanner: View {
    let outcome: WorktreeOutcome

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(outcome.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: outcome.isProblem ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(outcome.isProblem ? Color.orange : Color.green)
            }
            ForEach(outcome.details, id: \.self) { detail in
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .padding(.leading, 22)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

struct LoadStateSection: View {
    let loadError: String?
    let isLoading: Bool
    let loadingText: String
    let emptyText: String

    var body: some View {
        Section {
            if let loadError {
                Label {
                    Text(loadError)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(loadingText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(emptyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SheetFooter: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let busyText: String?
    let summary: String?
    let actionTitle: String
    let canAct: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let busyText {
                ProgressView().controlSize(.small)
                Text(busyText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let summary {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            Button(actionTitle, role: .destructive, action: action)
                .disabled(!canAct)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct WorktreesPane: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("worktreesInactiveDays") private var storedDays = WorktreeCopy.defaultDays
    @Binding var target: String

    @State private var includeUncommitted = false
    @State private var keepAllBranches = false
    @State private var branchOverrides: [String: Bool] = [:]
    @State private var list = WorktreeList()
    @State private var listTarget = ""
    @State private var loadedKey: WorktreeLoadKey?
    @State private var selected: Set<String> = []
    @State private var sizesUnknown = false
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadCount = 0
    @State private var confirming = false
    @State private var outcome: WorktreeOutcome?

    private static let cleanTitle = "Clean up worktrees"

    private var days: Int {
        WorktreeCopy.dayOptions.contains(storedDays) ? storedDays : WorktreeCopy.defaultDays
    }

    private var daysBinding: Binding<Int> {
        Binding(get: { days }, set: { storedDays = $0 })
    }

    private var loadKey: WorktreeLoadKey {
        WorktreeLoadKey(target: target, includeUncommitted: includeUncommitted, reload: reloadCount)
    }

    private var runningIDs: Set<String> { Set(list.profiles.filter(\.isRunning).map(\.id)) }

    private func canSelect(_ entry: WorktreeEntry) -> Bool {
        entry.isSelectable && !runningIDs.contains(entry.profileID)
    }

    private func isOldEnough(_ entry: WorktreeEntry) -> Bool {
        entry.lastActive != nil && entry.idleDays >= days
    }

    private var selectable: [WorktreeEntry] { list.entries.filter(canSelect) }

    private var chosen: [WorktreeEntry] {
        selectable.filter { selected.contains($0.selectionKey) }
    }

    private var chosenKB: Int { chosen.compactMap(\.sizeKB).reduce(0, +) }

    private func deletesBranch(_ entry: WorktreeEntry) -> Bool {
        guard entry.canChooseBranchDeletion, !keepAllBranches else { return false }
        return branchOverrides[entry.selectionKey] ?? entry.deletesBranchByDefault
    }

    private var unsavedBranchesToDelete: [WorktreeEntry] {
        chosen.filter { $0.branchState.unsavedCommits > 0 && deletesBranch($0) }
    }

    private var targetHasNoDesktopApp: Bool { model.isCLIOnlyTarget(target) }

    private var groups: [WorktreeGroup] {
        list.profiles.compactMap { profile in
            let entries = list.entries.filter { $0.profileID == profile.id }
            guard !entries.isEmpty else { return nil }
            return WorktreeGroup(profile: profile, entries: entries.sorted(by: WorktreeEntry.biggestFirst))
        }
    }

    private var isCleaning: Bool { model.activeCommand == Self.cleanTitle }

    private var canClean: Bool {
        !chosen.isEmpty && loadedKey == loadKey && !isLoading && loadError == nil && !model.isBusy
    }

    var body: some View {
        Form {
            Section {
                ProfilePicker(target: $target)
                Picker("Check worktrees inactive for", selection: daysBinding) {
                    ForEach(WorktreeCopy.dayOptions, id: \.self) { count in
                        Text("\(count) days or more").tag(count)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Allow worktrees with uncommitted changes", isOn: $includeUncommitted)
                    Text("Off by default. Lets you also pick worktrees with uncommitted changes, including the ones archived sessions kept for that reason. Those changes are lost for good.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Keep all branches", isOn: $keepAllBranches)
                    Text("Removes only the folders. Otherwise each branch is deleted with its worktree when every commit on it is also on another branch or remote; branches with commits found nowhere else are kept unless you switch Delete branch on for that row.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if groups.isEmpty || loadError != nil {
                LoadStateSection(loadError: loadError, isLoading: isLoading,
                                 loadingText: "Scanning worktrees. Measuring sizes can take a few seconds.",
                                 emptyText: targetHasNoDesktopApp ? WorktreeCopy.noDesktopAppNote : "No worktrees found.")
            } else {
                Section {
                    SelectionBar(selectedCount: chosen.count, selectableCount: selectable.count, noun: "worktree",
                                 selectAll: { selected = Set(selectable.map(\.selectionKey)) },
                                 selectNone: { selected = [] })
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.entries) { entry in
                            WorktreeRow(entry: entry, days: days, profileRunning: group.profile.isRunning,
                                        canSelect: canSelect(entry),
                                        isSelected: selected.contains(entry.selectionKey),
                                        branchDeletes: deletesBranch(entry),
                                        branchControlEnabled: entry.canChooseBranchDeletion && !keepAllBranches,
                                        onBranchToggle: { branchOverrides[entry.selectionKey] = $0 }) { isOn in
                                toggle(entry.selectionKey, isOn)
                            }
                        }
                    } header: {
                        GroupHeader(profile: group.profile,
                                    selected: group.entries.filter { canSelect($0) && selected.contains($0.selectionKey) }.count,
                                    total: group.entries.count, noun: "worktree")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        if let outcome {
            OutcomeBanner(outcome: outcome)
        }
        Divider().padding(.top, 12)
        SheetFooter(busyText: busyText, summary: loadError == nil ? summaryLine : nil,
                    actionTitle: "Remove Selected…", canAct: canClean) { confirming = true }
            .task(id: loadKey) { await load() }
            .onChange(of: target) { _ in outcome = nil }
            .onChange(of: includeUncommitted) { _ in outcome = nil }
            .onChange(of: keepAllBranches) { _ in outcome = nil }
            .onChange(of: storedDays) { _ in preselect() }
            .confirmationDialog(confirmationTitle, isPresented: $confirming) {
                Button("Remove \(WorktreeCopy.plural(chosen.count, "Worktree"))", role: .destructive) { clean() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
    }

    private var busyText: String? {
        if isCleaning { return "Removing worktrees…" }
        if isLoading { return "Scanning worktrees…" }
        return nil
    }

    private var summaryLine: String {
        let total = WorktreeCopy.plural(list.entries.count, "worktree")
        var text: String
        if chosen.isEmpty {
            text = "\(total) · none selected"
        } else {
            let space = chosenKB > 0 ? " (\(WorktreeCopy.size(kilobytes: chosenKB)))" : ""
            text = "\(total) · \(chosen.count) selected\(space)"
        }
        if sizesUnknown { text += " · sizes unavailable" }
        return text
    }

    private var confirmationTitle: String {
        "Remove \(WorktreeCopy.plural(chosen.count, "worktree"))?"
    }

    private var confirmationMessage: String {
        let space = chosenKB > 0 ? " and frees about \(WorktreeCopy.size(kilobytes: chosenKB))" : ""
        var text = "This removes the folders of \(WorktreeCopy.plural(chosen.count, "worktree"))\(space), including ignored files such as .env, node_modules and build output."
        text += keepAllBranches
            ? " All branches are kept."
            : " Branches are deleted when every commit on them is also on another branch or remote."
        text += " Sessions stay in the sidebar, but a removed worktree and a deleted branch are not restored."
        let unsaved = unsavedBranchesToDelete
        if !unsaved.isEmpty {
            let names = unsaved.map { entry in
                "\(entry.branchName ?? entry.name) (\(WorktreeCopy.plural(entry.branchState.unsavedCommits, "commit")))"
            }
            text += " These branches have commits found nowhere else and will be deleted too: \(names.joined(separator: ", "))."
        }
        let young = chosen.filter { !isOldEnough($0) }.count
        if young > 0 {
            text += " \(young) of them were used in the last \(days) days."
        }
        let uncommitted = chosen.filter { $0.isDirty != false || $0.state == .kept }.count
        if loadedKey?.includeUncommitted == true && uncommitted > 0 {
            text += " \(uncommitted) may have uncommitted changes, which are lost for good."
        }
        return text
    }

    private func toggle(_ key: String, _ isOn: Bool) {
        if isOn { selected.insert(key) } else { selected.remove(key) }
    }

    private func preselect() {
        selected = Set(selectable.filter(isOldEnough).map(\.selectionKey))
    }

    private func load() async {
        guard let runner = model.runner else {
            loadError = "The command-line tool bundled with this app was not found."
            isLoading = false
            return
        }
        if listTarget != target {
            list = WorktreeList()
            selected = []
            branchOverrides = [:]
            listTarget = target
        }
        guard !targetHasNoDesktopApp else {
            loadedKey = nil
            loadError = nil
            isLoading = false
            return
        }
        let keepsSelection = !list.entries.isEmpty
        let key = loadKey
        isLoading = true
        loadError = nil
        loadedKey = nil
        var result = await runner.run(arguments(for: key, withSizes: true), timeout: WorktreeCopy.listTimeout, stopsOnCancel: true)
        guard !Task.isCancelled else { return }
        var measured = true
        if !result.succeeded && !result.isUnknownCommand {
            measured = false
            result = await runner.run(arguments(for: key, withSizes: false), timeout: WorktreeCopy.listTimeout, stopsOnCancel: true)
            guard !Task.isCancelled else { return }
        }
        if result.succeeded {
            list = PlainParser.worktrees(result.stdout)
            sizesUnknown = !measured
            loadedKey = key
            if keepsSelection {
                selected.formIntersection(selectable.map(\.selectionKey))
                branchOverrides = branchOverrides.filter { override in list.entries.contains { $0.selectionKey == override.key } }
            } else {
                preselect()
            }
        } else {
            list = WorktreeList()
            selected = []
            branchOverrides = [:]
            loadError = result.isUnknownCommand
                ? "This version of the command-line tool has no worktree cleanup. Update it in Setup & Settings."
                : result.failureSummary
        }
        isLoading = false
    }

    private func arguments(for key: WorktreeLoadKey, withSizes: Bool) -> [String] {
        var arguments = ["worktrees", WorktreeCopy.cliTarget(key.target), "list", "--older-than", String(WorktreeCopy.scanFloorDays)]
        if key.includeUncommitted { arguments.append("--include-uncommitted") }
        if !withSizes { arguments.append("--no-size") }
        arguments.append("--plain")
        return arguments
    }

    private func clean() {
        guard let key = loadedKey, key == loadKey, !chosen.isEmpty else { return }
        outcome = nil
        let arguments = WorktreeCopy.worktreeCleanArguments(target: key.target, entries: chosen, keepsAllBranches: keepAllBranches,
                                                            includeUncommitted: key.includeUncommitted, deletesBranch: deletesBranch)
        let names = WorktreeCopy.names(of: list.profiles)
        let days = days
        Task {
            guard let result = await model.run(Self.cleanTitle, arguments, showsAlert: false, refreshAfter: false) else {
                outcome = WorktreeOutcome(text: "Another command is still running. Try again in a moment.", details: [], isProblem: true)
                return
            }
            outcome = WorktreeCopy.outcome(for: result, names: names, noun: "worktree") {
                WorktreeCopy.reasonText($0, days: days)
            }
            reloadCount += 1
        }
    }
}

private struct CachesPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var target: String

    @State private var list = CacheList()
    @State private var listTarget = ""
    @State private var loadedKey: CacheLoadKey?
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadCount = 0
    @State private var confirming = false
    @State private var outcome: WorktreeOutcome?

    private static let cleanTitle = "Clear caches"

    private var loadKey: CacheLoadKey { CacheLoadKey(target: target, reload: reloadCount) }

    private var runningIDs: Set<String> { Set(list.profiles.filter(\.isRunning).map(\.id)) }

    private func canSelect(_ item: CacheItem) -> Bool { !runningIDs.contains(item.profileID) }

    private var selectable: [CacheItem] { list.items.filter(canSelect) }

    private var chosen: [CacheItem] { selectable.filter { selected.contains($0.id) } }

    private var chosenKB: Int { chosen.compactMap(\.sizeKB).reduce(0, +) }

    private var groups: [CacheGroup] {
        list.profiles.compactMap { profile in
            let items = list.items.filter { $0.profileID == profile.id }
            guard !items.isEmpty else { return nil }
            let ordered = items.sorted(by: CacheItem.biggestFirst)
            let isSmall: (CacheItem) -> Bool = { $0.kind != .vm && ($0.sizeKB ?? WorktreeCopy.smallCacheKB) < WorktreeCopy.smallCacheKB }
            return CacheGroup(profile: profile,
                              items: ordered.filter { !isSmall($0) && $0.kind != .vm },
                              smallItems: ordered.filter(isSmall),
                              vmItems: ordered.filter { $0.kind == .vm })
        }
    }

    private var isCleaning: Bool { model.activeCommand == Self.cleanTitle }

    private var canClean: Bool {
        !chosen.isEmpty && loadedKey == loadKey && !isLoading && loadError == nil && !model.isBusy
    }

    var body: some View {
        Form {
            Section {
                ProfilePicker(target: $target)
            }
            if groups.isEmpty || loadError != nil {
                LoadStateSection(loadError: loadError, isLoading: isLoading,
                                 loadingText: "Measuring caches…",
                                 emptyText: model.isCLIOnlyTarget(target) ? WorktreeCopy.noDesktopAppNote : "No caches to clear.")
            } else {
                Section {
                    SelectionBar(selectedCount: chosen.count, selectableCount: selectable.count, noun: "item",
                                 selectAll: { selected = Set(selectable.map(\.id)) },
                                 selectNone: { selected = [] })
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            CacheRow(item: item, canSelect: canSelect(item), isSelected: selected.contains(item.id)) { isOn in
                                if isOn { selected.insert(item.id) } else { selected.remove(item.id) }
                            }
                        }
                        if !group.smallItems.isEmpty {
                            SmallCachesRow(items: group.smallItems, canSelect: group.smallItems.contains(where: canSelect),
                                           isSelected: group.smallItems.allSatisfy { selected.contains($0.id) }) { isOn in
                                let ids = group.smallItems.filter(canSelect).map(\.id)
                                if isOn { selected.formUnion(ids) } else { selected.subtract(ids) }
                            }
                        }
                    } header: {
                        GroupHeader(profile: group.profile,
                                    selected: (group.items + group.smallItems + group.vmItems).filter { canSelect($0) && selected.contains($0.id) }.count,
                                    total: group.items.count + group.smallItems.count + group.vmItems.count, noun: "cache")
                    }
                    if !group.vmItems.isEmpty {
                        Section {
                            ForEach(group.vmItems) { item in
                                CacheRow(item: item, canSelect: canSelect(item), isSelected: selected.contains(item.id)) { isOn in
                                    if isOn { selected.insert(item.id) } else { selected.remove(item.id) }
                                }
                            }
                        } header: {
                            Text("Cowork VM disk · \(group.profile.name)")
                                .font(.subheadline.weight(.semibold))
                        } footer: {
                            Label(WorktreeCopy.vmWarning, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        if let outcome {
            OutcomeBanner(outcome: outcome)
        }
        Divider().padding(.top, 12)
        SheetFooter(busyText: busyText, summary: loadError == nil ? summaryLine : nil,
                    actionTitle: "Clear Selected…", canAct: canClean) { confirming = true }
            .task(id: loadKey) { await load() }
            .onChange(of: target) { _ in outcome = nil }
            .confirmationDialog("Clear \(WorktreeCopy.plural(chosen.count, "item"))?", isPresented: $confirming) {
                Button("Clear \(WorktreeCopy.plural(chosen.count, "Item"))", role: .destructive) { clean() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
    }

    private var busyText: String? {
        if isCleaning { return "Clearing caches…" }
        if isLoading { return "Measuring caches…" }
        return nil
    }

    private var summaryLine: String {
        let total = list.items.compactMap(\.sizeKB).reduce(0, +)
        let all = "\(WorktreeCopy.plural(list.items.count, "item")) (\(WorktreeCopy.size(kilobytes: total)))"
        guard !chosen.isEmpty else { return "\(all) · none selected" }
        return "\(all) · \(chosen.count) selected (\(WorktreeCopy.size(kilobytes: chosenKB)))"
    }

    private var confirmationMessage: String {
        var text = "This deletes \(WorktreeCopy.plural(chosen.count, "item")) and frees about \(WorktreeCopy.size(kilobytes: chosenKB)). The app rebuilds its caches as it needs them."
        if chosen.contains(where: { $0.kind == .version }) {
            text += " Older Claude Code versions are downloaded again only if the app needs them."
        }
        if chosen.contains(where: { $0.kind == .vm }) {
            text += " " + WorktreeCopy.vmWarning
        }
        return text
    }

    private func load() async {
        guard let runner = model.runner else {
            loadError = "The command-line tool bundled with this app was not found."
            isLoading = false
            return
        }
        if listTarget != target {
            list = CacheList()
            selected = []
            listTarget = target
        }
        guard !model.isCLIOnlyTarget(target) else {
            loadedKey = nil
            loadError = nil
            isLoading = false
            return
        }
        let keepsSelection = !list.items.isEmpty
        let key = loadKey
        isLoading = true
        loadError = nil
        loadedKey = nil
        let result = await runner.run(["caches", WorktreeCopy.cliTarget(key.target), "list", "--plain"],
                                      timeout: WorktreeCopy.listTimeout, stopsOnCancel: true)
        guard !Task.isCancelled else { return }
        if result.succeeded {
            list = PlainParser.caches(result.stdout)
            loadedKey = key
            if keepsSelection {
                selected.formIntersection(selectable.map(\.id))
            } else {
                selected = Set(selectable.filter(\.isPreselectedForCleanup).map(\.id))
            }
        } else {
            list = CacheList()
            selected = []
            loadError = result.isUnknownCommand
                ? "This version of the command-line tool cannot clear caches. Update it in Setup & Settings."
                : result.failureSummary
        }
        isLoading = false
    }

    private func clean() {
        guard let key = loadedKey, key == loadKey, !chosen.isEmpty else { return }
        outcome = nil
        var arguments = ["caches", WorktreeCopy.cliTarget(key.target), "clean"]
        for item in chosen {
            arguments += ["--item", item.id]
        }
        arguments += ["--yes", "--plain"]
        let names = WorktreeCopy.names(of: list.profiles)
        Task {
            guard let result = await model.run(Self.cleanTitle, arguments, showsAlert: false, refreshAfter: false) else {
                outcome = WorktreeOutcome(text: "Another command is still running. Try again in a moment.", details: [], isProblem: true)
                return
            }
            outcome = WorktreeCopy.outcome(for: result, names: names, noun: "item") {
                WorktreeCopy.reasonText($0, days: WorktreeCopy.defaultDays)
            }
            reloadCount += 1
        }
    }
}

struct SelectionCheckbox: View {
    let canSelect: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { canSelect && isSelected }, set: onToggle)) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .disabled(!canSelect)
        .frame(width: 18)
        .padding(.top, 1)
    }
}

private struct WorktreeRow: View {
    let entry: WorktreeEntry
    let days: Int
    let profileRunning: Bool
    let canSelect: Bool
    let isSelected: Bool
    let branchDeletes: Bool
    let branchControlEnabled: Bool
    let onBranchToggle: (Bool) -> Void
    let onToggle: (Bool) -> Void

    private var repoLine: String {
        [entry.repoName, entry.branchName == nil ? entry.branch : nil].compactMap { $0 }.joined(separator: " · ")
    }

    private var branchTitle: String {
        entry.branchName.map { "branch \($0)" } ?? "branch"
    }

    private var reasonLine: String? {
        if entry.isSelectable { return profileRunning ? "Waiting for the app to quit" : nil }
        return WorktreeCopy.reasonText(entry.reason, days: days)
    }

    @ViewBuilder
    private var branchStateLabel: some View {
        switch entry.branchState {
        case .saved:
            Text("saved")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsaved(let count):
            Text(WorktreeCopy.plural(count, "unsaved commit"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .noBranch, .unknown:
            EmptyView()
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionCheckbox(canSelect: canSelect, isSelected: isSelected, onToggle: onToggle)
                .help(canSelect ? "Select to remove" : "Can't be removed")
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.name)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(canSelect ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Badge(text: entry.state.title, tint: entry.state == .kept ? .orange : .secondary)
                        if entry.isDirty == true {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(.orange)
                                .help("Has uncommitted changes")
                                .accessibilityLabel("Uncommitted changes")
                        }
                    }
                    if !repoLine.isEmpty {
                        Text(repoLine)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let title = entry.sessionTitle {
                        Text(title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if let reasonLine {
                        Text(reasonLine)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if canSelect { onToggle(!isSelected) } }
                if entry.branchState.hasBranch {
                    HStack(spacing: 8) {
                        Text(branchTitle)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        branchStateLabel
                        Toggle("Delete branch", isOn: Binding(get: { branchDeletes }, set: onBranchToggle))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .font(.caption)
                            .disabled(!branchControlEnabled)
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("last active \(relativeDate(entry.lastActive))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sizeKB = entry.sizeKB {
                    Text(WorktreeCopy.size(kilobytes: sizeKB))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .help(tildePath(entry.path))
    }
}

private struct CacheRow: View {
    let item: CacheItem
    let canSelect: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionCheckbox(canSelect: canSelect, isSelected: isSelected, onToggle: onToggle)
            VStack(alignment: .leading, spacing: 2) {
                Text(WorktreeCopy.cacheTitle(item))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(canSelect ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.relativePath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
            .onTapGesture { if canSelect { onToggle(!isSelected) } }
            Spacer(minLength: 12)
            if let sizeKB = item.sizeKB {
                Text(WorktreeCopy.size(kilobytes: sizeKB))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SmallCachesRow: View {
    let items: [CacheItem]
    let canSelect: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    private var totalKB: Int { items.compactMap(\.sizeKB).reduce(0, +) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionCheckbox(canSelect: canSelect, isSelected: isSelected, onToggle: onToggle)
            VStack(alignment: .leading, spacing: 2) {
                Text("Small caches")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(canSelect ? Color.primary : Color.secondary)
                Text("\(WorktreeCopy.plural(items.count, "folder")) under \(WorktreeCopy.size(kilobytes: WorktreeCopy.smallCacheKB)) each, mostly empty browser pane caches")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { if canSelect { onToggle(!isSelected) } }
            Spacer(minLength: 12)
            Text(WorktreeCopy.size(kilobytes: totalKB))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .help(items.map(\.relativePath).joined(separator: "\n"))
    }
}
