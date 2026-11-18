import SwiftUI

private struct HistoryLoadKey: Hashable {
    let target: String
    let reload: Int
}

private struct HistoryGroup: Identifiable {
    let profile: StorageProfile
    let projects: [HistoryProject]

    var id: String { profile.id }
}

struct HistoryPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var target: String

    @State private var list = HistoryList()
    @State private var listTarget = ""
    @State private var loadedKey: HistoryLoadKey?
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadCount = 0
    @State private var confirming = false
    @State private var outcome: WorktreeOutcome?

    private static let cleanTitle = "Delete project history"

    private var loadKey: HistoryLoadKey { HistoryLoadKey(target: target, reload: reloadCount) }

    private var runningIDs: Set<String> { Set(list.profiles.filter(\.isRunning).map(\.id)) }

    private func canSelect(_ project: HistoryProject) -> Bool { !runningIDs.contains(project.profileID) }

    private var selectable: [HistoryProject] { list.projects.filter(canSelect) }

    private var chosen: [HistoryProject] { selectable.filter { selected.contains($0.id) } }

    private var chosenKB: Int { chosen.compactMap(\.sizeKB).reduce(0, +) }

    private var groups: [HistoryGroup] {
        list.profiles.compactMap { profile in
            let projects = list.projects.filter { $0.profileID == profile.id }
                .sorted(by: HistoryProject.biggestFirst)
            guard !projects.isEmpty else { return nil }
            return HistoryGroup(profile: profile, projects: projects)
        }
    }

    private var isCleaning: Bool { model.activeCommand == Self.cleanTitle }

    private var canClean: Bool {
        !chosen.isEmpty && loadedKey == loadKey && !isLoading && loadError == nil && !model.isBusy
    }

    private func ownerName(of id: String) -> String {
        if id == WorktreeCopy.mainTarget { return "Main Claude" }
        return list.profiles.first { $0.id == id }?.name ?? id
    }

    var body: some View {
        Form {
            Section {
                ProfilePicker(target: $target)
            }
            if groups.isEmpty || loadError != nil {
                LoadStateSection(loadError: loadError, isLoading: isLoading,
                                 loadingText: "Measuring history. Large profiles can take a minute or two.",
                                 emptyText: "No project history found.")
            } else {
                Section {
                    SelectionBar(selectedCount: chosen.count, selectableCount: selectable.count, noun: "project",
                                 selectAll: { selected = Set(selectable.map(\.id)) },
                                 selectNone: { selected = [] })
                    ForEach(list.shared, id: \.configDir) { note in
                        Label("The config folder \(tildePath(note.configDir)) is shared with \(ownerName(of: note.ownerID)); its history is listed once.",
                              systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.projects) { project in
                            HistoryRow(project: project, canSelect: canSelect(project), isSelected: selected.contains(project.id)) { isOn in
                                if isOn { selected.insert(project.id) } else { selected.remove(project.id) }
                            }
                        }
                    } header: {
                        GroupHeader(profile: group.profile.asWorktreeProfile,
                                    selected: group.projects.filter { canSelect($0) && selected.contains($0.id) }.count,
                                    total: group.projects.count, noun: "project")
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
                    actionTitle: "Delete Selected…", canAct: canClean) { confirming = true }
            .task(id: loadKey) { await load() }
            .onChange(of: target) { _ in outcome = nil }
            .confirmationDialog("Delete the history of \(WorktreeCopy.plural(chosen.count, "project"))?", isPresented: $confirming) {
                Button("Delete History of \(WorktreeCopy.plural(chosen.count, "Project"))", role: .destructive) { clean() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirmationMessage)
            }
    }

    private var busyText: String? {
        if isCleaning { return "Deleting history…" }
        if isLoading { return "Measuring history…" }
        return nil
    }

    private var summaryLine: String {
        let total = list.projects.compactMap(\.sizeKB).reduce(0, +)
        let all = "\(WorktreeCopy.plural(list.projects.count, "project")) (\(WorktreeCopy.size(kilobytes: total)))"
        guard !chosen.isEmpty else { return "\(all) · none selected" }
        return "\(all) · \(chosen.count) selected (\(WorktreeCopy.size(kilobytes: chosenKB)))"
    }

    private var confirmationMessage: String {
        let space = chosenKB > 0 ? " (\(WorktreeCopy.size(kilobytes: chosenKB)))" : ""
        return "Delete the history of \(WorktreeCopy.plural(chosen.count, "project"))\(space)? Those conversations can no longer be resumed or read; this cannot be undone."
    }

    private func load() async {
        guard let runner = model.runner else {
            loadError = "The command-line tool bundled with this app was not found."
            isLoading = false
            return
        }
        if listTarget != target {
            list = HistoryList()
            selected = []
            listTarget = target
        }
        let key = loadKey
        isLoading = true
        loadError = nil
        loadedKey = nil
        let result = await runner.run(["history", WorktreeCopy.cliTarget(key.target), "list", "--plain"],
                                      timeout: WorktreeCopy.storageTimeout, stopsOnCancel: true)
        guard !Task.isCancelled else { return }
        if result.succeeded {
            list = PlainParser.history(result.stdout)
            loadedKey = key
            selected.formIntersection(selectable.map(\.id))
        } else {
            list = HistoryList()
            selected = []
            loadError = result.isUnknownCommand
                ? "This version of the command-line tool cannot manage history. Update it in Setup & Settings."
                : result.failureSummary
        }
        isLoading = false
    }

    private func clean() {
        guard let key = loadedKey, key == loadKey, !chosen.isEmpty else { return }
        outcome = nil
        var arguments = ["history", WorktreeCopy.cliTarget(key.target), "clean"]
        for project in chosen {
            arguments += ["--project", project.id]
        }
        arguments += ["--yes", "--plain"]
        let names = Dictionary(list.profiles.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        Task {
            guard let result = await model.run(Self.cleanTitle, arguments, showsAlert: false, refreshAfter: false) else {
                outcome = WorktreeOutcome(text: "Another command is still running. Try again in a moment.", details: [], isProblem: true)
                return
            }
            outcome = WorktreeCopy.outcome(for: result, names: names, noun: "project", verb: "Deleted",
                                           keptNote: "that could not be deleted") {
                WorktreeCopy.reasonText($0, days: WorktreeCopy.defaultDays)
            }
            reloadCount += 1
        }
    }
}

private struct HistoryRow: View {
    let project: HistoryProject
    let canSelect: Bool
    let isSelected: Bool
    let onToggle: (Bool) -> Void

    private var title: String {
        project.cwd.map(tildePath) ?? project.name
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SelectionCheckbox(canSelect: canSelect, isSelected: isSelected, onToggle: onToggle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(canSelect ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if project.cwd != nil {
                    Text(project.name)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if canSelect { onToggle(!isSelected) } }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(WorktreeCopy.plural(project.sessions, "session")) · \(WorktreeCopy.lastUsedText(days: project.lastDays))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sizeKB = project.sizeKB {
                    Text(WorktreeCopy.size(kilobytes: sizeKB))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .help(project.name)
    }
}
