import Foundation

/// Parses the tab-separated `--plain` output of the CLI. Unknown row types and extra columns are ignored.
enum PlainParser {
    static func rows(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.components(separatedBy: "\t") }
    }

    static func optional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "-" ? nil : trimmed
    }

    static func flag(_ value: String?) -> Bool? {
        guard let value = optional(value) else { return nil }
        return value == "1" || value.lowercased() == "yes" || value.lowercased() == "true"
    }

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()

    static func date(_ value: String?) -> Date? {
        guard let value = optional(value) else { return nil }
        if let parsed = isoFormatter.date(from: value) { return parsed }
        return ISO8601DateFormatter().date(from: value)
    }

    static func profiles(_ text: String) -> [Profile] {
        rows(text).compactMap { columns in
            guard columns.count >= 6, !columns[0].isEmpty else { return nil }
            return Profile(
                slug: columns[0],
                name: columns[1],
                color: optional(columns[2]),
                isDesktop: columns[3] == "1",
                app: optional(columns[4]),
                configDir: columns[5],
                dataDir: columns.count > 6 ? optional(columns[6]) : nil
            )
        }
    }

    static func scan(_ text: String) -> ScanResult {
        var result = ScanResult()
        for columns in rows(text) {
            switch columns[0] {
            case "config" where columns.count >= 2:
                let count = columns.count > 2 ? Int(columns[2]) ?? 0 : 0
                result.configs.append(ConfigDirEntry(path: columns[1], projectCount: count))
            case "data" where columns.count >= 2:
                result.dataDirs.append(columns[1])
            case "project" where columns.count >= 3:
                result.projects.append(ScannedProject(
                    configDir: columns[1],
                    cwd: columns[2],
                    sessions: columns.count > 3 ? Int(columns[3]) ?? 0 : 0,
                    lastUsed: columns.count > 4 ? date(columns[4]) : nil,
                    owner: columns.count > 5 ? optional(columns[5]) : nil
                ))
            case "candidate" where columns.count >= 4:
                let app = columns[1]
                let fallbackName = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
                    .replacingOccurrences(of: "Claude ", with: "")
                result.candidates.append(Candidate(
                    app: app,
                    launcher: optional(columns[2]),
                    bundleID: columns[3],
                    dataDir: columns.count > 4 ? optional(columns[4]) : nil,
                    configDir: columns.count > 5 ? optional(columns[5]) : nil,
                    name: columns.count > 6 ? optional(columns[6]) ?? fallbackName : fallbackName,
                    identity: columns.count > 7 ? optional(columns[7]) : nil
                ))
            default:
                continue
            }
        }
        return result
    }

    static func profileDetails(_ text: String) -> ProfileDetails {
        var details = ProfileDetails()
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let key: String
            var value: String
            if let tab = rawLine.firstIndex(of: "\t") {
                key = String(rawLine[..<tab])
                let rest = rawLine[rawLine.index(after: tab)...]
                value = String(rest.split(separator: "\t", omittingEmptySubsequences: false).first ?? "")
            } else if let match = rawLine.range(of: #"^\S+\s{2,}"#, options: .regularExpression) {
                key = rawLine[match].trimmingCharacters(in: .whitespaces)
                value = String(rawLine[match.upperBound...])
                value = humanValue(for: key, value)
                if key == "dirs" {
                    details.dirs.append(contentsOf: value == "-" ? [] : value.components(separatedBy: ", "))
                    continue
                }
            } else {
                continue
            }
            if key == "dir" {
                if let path = optional(value) { details.dirs.append(path) }
            } else if !key.isEmpty {
                details.fields[key] = value
            }
        }
        return details
    }

    private static func humanValue(for key: String, _ value: String) -> String {
        switch key {
        case "color":
            return String(value.split(separator: " ").first ?? "-")
        case "app":
            return value.replacingOccurrences(of: #" \([^()]*\)$"#, with: "", options: .regularExpression)
        default:
            return value
        }
    }

    static func profileProjects(_ text: String) -> [ProfileProject] {
        rows(text).compactMap { columns in
            guard columns[0] == "project", columns.count >= 2 else { return nil }
            return ProfileProject(
                cwd: columns[1],
                sessions: columns.count > 2 ? Int(columns[2]) ?? 0 : 0,
                lastUsed: columns.count > 3 ? date(columns[3]) : nil,
                isSymlink: columns.count > 4 && columns[4] == "symlink"
            )
        }
    }

    static func status(_ text: String) -> StatusSummary {
        var status = StatusSummary()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "cli_installed":
                status.cliInstalled = flag(column(1))
                status.cliPath = optional(column(2))
            case "cli_current":
                status.cliCurrent = flag(column(1))
            case "identity":
                status.identityName = optional(column(1))
                status.identityPresent = flag(column(2))
                status.identityUsable = flag(column(3))
            case "agent":
                status.agentLabel = optional(column(1))
                status.agentLoaded = flag(column(2))
            case "source":
                status.sourceApp = optional(column(1))
                status.sourceVersion = optional(column(2))
                status.sourceTeamOK = flag(column(3))
            case "handler":
                status.handlerScheme = optional(column(1))
                status.handlerBundleID = optional(column(2))
            case "home":
                status.home = optional(column(1))
            default:
                continue
            }
        }
        return status
    }

    static func shellStatus(_ text: String) -> ShellStatus {
        var status = ShellStatus()
        for columns in rows(text) {
            switch columns[0] {
            case "installed":
                status.installed = flag(columns.count > 1 ? columns[1] : nil) ?? false
                status.rcFile = columns.count > 2 ? optional(columns[2]) : nil
            case "conflict" where columns.count >= 2:
                status.conflicts.append(columns[1...].joined(separator: " "))
            default:
                continue
            }
        }
        return status
    }

    static func legacyAgents(_ text: String) -> [LegacyAgent] {
        rows(text).compactMap { columns in
            guard columns[0] == "agent", columns.count >= 3 else { return nil }
            return LegacyAgent(
                label: columns[1],
                plist: columns[2],
                loaded: columns.count > 3 && columns[3] == "1",
                program: columns.count > 4 ? optional(columns[4]) : nil
            )
        }
    }

    static func worktrees(_ text: String) -> WorktreeList {
        var list = WorktreeList()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "profile" where columns.count >= 5 && !columns[1].isEmpty:
                list.profiles.append(WorktreeProfile(
                    id: columns[1],
                    name: optional(column(2)) ?? columns[1],
                    dataDir: optional(column(3)),
                    isRunning: flag(column(4)) ?? false,
                    hasRegistry: flag(column(5)) ?? false
                ))
            case "worktree" where columns.count >= 12 && !columns[1].isEmpty:
                list.entries.append(WorktreeEntry(
                    position: list.entries.count,
                    profileID: columns[1],
                    name: columns[2],
                    path: columns[3],
                    repo: optional(column(4)),
                    branch: optional(column(5)),
                    state: WorktreeState(raw: optional(column(6)) ?? ""),
                    lastActive: date(column(7)),
                    idleDays: Int(optional(column(8)) ?? "") ?? 0,
                    isDirty: flag(column(9)),
                    sizeKB: Int(optional(column(10)) ?? ""),
                    isEligible: flag(column(11)) ?? false,
                    reason: optional(column(12)),
                    sessionTitle: optional(column(13)),
                    branchState: BranchState(raw: column(14)),
                    branchName: optional(column(15))
                ))
            default:
                continue
            }
        }
        return list
    }

    static func caches(_ text: String) -> CacheList {
        var list = CacheList()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "profile" where columns.count >= 5 && !columns[1].isEmpty:
                list.profiles.append(WorktreeProfile(
                    id: columns[1],
                    name: optional(column(2)) ?? columns[1],
                    dataDir: optional(column(3)),
                    isRunning: flag(column(4)) ?? false,
                    hasRegistry: false
                ))
            case "cache" where columns.count >= 4 && !columns[1].isEmpty && !columns[2].isEmpty:
                list.items.append(CacheItem(
                    profileID: columns[1],
                    relativePath: columns[2],
                    kind: CacheKind(raw: columns[3]),
                    sizeKB: Int(optional(column(4)) ?? "")
                ))
            default:
                continue
            }
        }
        return list
    }

    static func worktreeClean(_ text: String) -> WorktreeCleanResult {
        var result = WorktreeCleanResult()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "blocked" where columns.count >= 2:
                result.rows.append(WorktreeCleanRow(kind: .blocked, profileID: columns[1], path: nil, sizeKB: nil, message: optional(column(2))))
            case "removed" where columns.count >= 3, "would_remove" where columns.count >= 3:
                result.rows.append(WorktreeCleanRow(
                    kind: columns[0] == "removed" ? .removed : .wouldRemove,
                    profileID: columns[1],
                    path: columns[2],
                    sizeKB: Int(optional(column(3)) ?? ""),
                    message: nil
                ))
            case "failed" where columns.count >= 3:
                result.rows.append(WorktreeCleanRow(kind: .failed, profileID: columns[1], path: columns[2], sizeKB: nil, message: optional(column(3))))
            case "skipped" where columns.count >= 3:
                result.rows.append(WorktreeCleanRow(kind: .skipped, profileID: columns[1], path: columns[2], sizeKB: nil, message: optional(column(3))))
            case "branch_deleted" where columns.count >= 4, "would_delete_branch" where columns.count >= 4:
                result.rows.append(WorktreeCleanRow(
                    kind: columns[0] == "branch_deleted" ? .branchDeleted : .wouldDeleteBranch,
                    profileID: columns[1],
                    path: columns[2],
                    sizeKB: nil,
                    message: nil,
                    branch: columns[3],
                    unsavedCommits: Int(optional(column(4)) ?? "")
                ))
            case "branch_kept" where columns.count >= 5, "would_keep_branch" where columns.count >= 5:
                result.rows.append(WorktreeCleanRow(
                    kind: columns[0] == "branch_kept" ? .branchKept : .wouldKeepBranch,
                    profileID: columns[1],
                    path: columns[2],
                    sizeKB: nil,
                    message: optional(column(4)),
                    branch: columns[3],
                    unsavedCommits: Int(optional(column(5)) ?? "")
                ))
            case "summary" where columns.count >= 5:
                result.summary = WorktreeCleanSummary(
                    removed: Int(columns[1]) ?? 0,
                    freedKB: Int(columns[2]) ?? 0,
                    failed: Int(columns[3]) ?? 0,
                    blocked: Int(columns[4]) ?? 0,
                    branchesDeleted: Int(optional(column(5)) ?? ""),
                    branchesKept: Int(optional(column(6)) ?? "")
                )
            default:
                continue
            }
        }
        return result
    }

    static func storage(_ text: String) -> StorageList {
        var list = StorageList()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "profile" where columns.count >= 5 && !columns[1].isEmpty:
                list.profiles.append(StorageProfile(
                    id: columns[1],
                    name: optional(column(2)) ?? columns[1],
                    dataDir: optional(column(3)),
                    configDir: optional(column(4)),
                    isRunning: flag(column(5)) ?? false
                ))
            case "area" where columns.count >= 6 && !columns[1].isEmpty:
                list.areas.append(StorageArea(
                    position: list.areas.count,
                    profileID: columns[1],
                    location: StorageLocation(raw: columns[2]),
                    entry: columns[3],
                    kind: StorageKind(raw: columns[4]),
                    sizeKB: Int(optional(column(5)) ?? ""),
                    tool: StorageTool(raw: optional(column(6)))
                ))
            case "total" where columns.count >= 3 && !columns[1].isEmpty:
                if let kilobytes = Int(columns[2]) { list.totals[columns[1]] = kilobytes }
            case "shared" where columns.count >= 4 && !columns[1].isEmpty:
                list.shared.append(SharedConfig(profileID: columns[1], configDir: columns[2], ownerID: columns[3]))
            default:
                continue
            }
        }
        return list
    }

    static func history(_ text: String) -> HistoryList {
        var list = HistoryList()
        for columns in rows(text) {
            func column(_ index: Int) -> String? { columns.count > index ? columns[index] : nil }
            switch columns[0] {
            case "profile" where columns.count >= 4 && !columns[1].isEmpty:
                list.profiles.append(StorageProfile(
                    id: columns[1],
                    name: optional(column(2)) ?? columns[1],
                    dataDir: nil,
                    configDir: optional(column(3)),
                    isRunning: flag(column(4)) ?? false
                ))
            case "project" where columns.count >= 6 && !columns[1].isEmpty && !columns[2].isEmpty:
                list.projects.append(HistoryProject(
                    profileID: columns[1],
                    name: columns[2],
                    cwd: optional(column(3)),
                    sessions: Int(optional(column(4)) ?? "") ?? 0,
                    sizeKB: Int(optional(column(5)) ?? ""),
                    lastDays: Int(optional(column(6)) ?? "")
                ))
            case "shared" where columns.count >= 4 && !columns[1].isEmpty:
                list.shared.append(SharedConfig(profileID: columns[1], configDir: columns[2], ownerID: columns[3]))
            default:
                continue
            }
        }
        return list
    }

    static func checkLines(_ text: String) -> (heading: String?, lines: [CheckLine]) {
        var heading: String?
        var lines: [CheckLine] = []
        for rawLine in text.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let level = [CheckLevel.ok, .warn, .fail, .info].first { level in
                rawLine.hasPrefix(level.rawValue + " ") || rawLine == level.rawValue
            }
            if let level {
                let message = String(rawLine.dropFirst(level.rawValue.count)).trimmingCharacters(in: .whitespaces)
                lines.append(CheckLine(id: lines.count, level: level, message: message))
            } else if heading == nil && lines.isEmpty {
                heading = trimmed
            } else {
                lines.append(CheckLine(id: lines.count, level: .detail, message: trimmed))
            }
        }
        return (heading, lines)
    }

    static func created(_ text: String) -> (slug: String, launcher: String?)? {
        for columns in rows(text).reversed() where columns[0] == "created" && columns.count >= 2 {
            return (columns[1], columns.count > 2 ? optional(columns[2]) : nil)
        }
        return nil
    }

    static func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var slug = ""
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.trimmingCharacters(in: .whitespaces) == name else { return false }
        let forbidden = CharacterSet(charactersIn: "/:\"\\\t\n").union(.controlCharacters)
        return name.unicodeScalars.allSatisfy { !forbidden.contains($0) }
    }

    static func isValidSlug(_ slug: String) -> Bool {
        guard slug.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else { return false }
        return !["default", "main", "all"].contains(slug)
    }

    static func isValidIdentity(_ identity: String) -> Bool {
        identity.isEmpty || identity.range(of: "^[A-Za-z0-9 ._-]+$", options: .regularExpression) != nil
    }
}
