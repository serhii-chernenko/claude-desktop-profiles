import SwiftUI

private struct StorageLoadKey: Hashable {
    let target: String
    let reload: Int
}

private enum StorageCopy {
    static let barHeight: CGFloat = 4
    static let minimumBarFraction = 0.02

    static func tint(for kind: StorageKind) -> Color {
        switch kind {
        case .cache: return .blue
        case .panes: return .indigo
        case .versions: return .purple
        case .vm: return .orange
        case .sessions: return .green
        case .history: return .pink
        case .plugins: return .teal
        case .worktrees: return .brown
        case .other: return .gray
        }
    }

    static func pane(for tool: StorageTool) -> StoragePane? {
        switch tool {
        case .caches: return .caches
        case .history: return .history
        case .worktrees: return .worktrees
        case .nothing: return nil
        }
    }

    static func buttonTitle(for tool: StorageTool) -> String {
        switch tool {
        case .caches: return "Clean caches…"
        case .history: return "Clean history…"
        case .worktrees: return "Clean worktrees…"
        case .nothing: return ""
        }
    }

    static func title(for area: StorageArea) -> String {
        area.location == .worktrees ? "Code worktrees" : area.entry
    }

    static func path(for area: StorageArea, in profile: StorageProfile) -> String {
        let base: String?
        switch area.location {
        case .data: base = profile.dataDir
        case .config: base = profile.configDir
        case .worktrees, .other: base = nil
        }
        guard let base else { return "Outside the profile folders" }
        return tildePath((base as NSString).appendingPathComponent(area.entry))
    }

    static func ownerName(of id: String, in list: StorageList) -> String {
        if id == WorktreeCopy.mainTarget { return "Main Claude" }
        return list.profiles.first { $0.id == id }?.name ?? id
    }
}

struct OverviewPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var target: String
    let openPane: (StoragePane) -> Void

    @State private var list = StorageList()
    @State private var loadedTarget = ""
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadCount = 0

    private var loadKey: StorageLoadKey { StorageLoadKey(target: target, reload: reloadCount) }

    private var showsList: Bool { !list.profiles.isEmpty && loadError == nil }

    var body: some View {
        Form {
            Section {
                ProfilePicker(target: $target)
                HStack {
                    Spacer()
                    Button("Measure Again") { reloadCount += 1 }
                        .disabled(isLoading || model.isBusy)
                }
            }
            if showsList {
                ForEach(list.profiles) { profile in
                    StorageProfileSection(profile: profile, list: list, openPane: openPane)
                }
                if list.profiles.count > 1 {
                    Section {
                        LabeledContent("All profiles together") {
                            Text(WorktreeCopy.size(kilobytes: list.grandTotalKB))
                                .font(.callout.weight(.semibold))
                        }
                    }
                }
            } else {
                LoadStateSection(loadError: loadError, isLoading: isLoading,
                                 loadingText: "Measuring storage. Large profiles can take a minute or two.",
                                 emptyText: "Nothing to show.")
            }
        }
        .formStyle(.grouped)
        .disabled(model.isBusy)
        .task(id: loadKey) { await load() }
        Divider().padding(.top, 12)
        HStack(spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
                Text("Measuring storage…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if showsList {
                Text("\(WorktreeCopy.plural(list.profiles.count, "profile")) · \(WorktreeCopy.size(kilobytes: list.grandTotalKB)) in total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            CloseButton()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func load() async {
        guard let runner = model.runner else {
            loadError = "The command-line tool bundled with this app was not found."
            isLoading = false
            return
        }
        if loadedTarget != target {
            list = StorageList()
            loadedTarget = target
        }
        isLoading = true
        loadError = nil
        let result = await runner.run(["storage", WorktreeCopy.cliTarget(target), "--plain"],
                                      timeout: WorktreeCopy.storageTimeout, stopsOnCancel: true)
        guard !Task.isCancelled else { return }
        if result.succeeded {
            list = PlainParser.storage(result.stdout)
        } else {
            list = StorageList()
            loadError = result.isUnknownCommand
                ? "This version of the command-line tool cannot measure storage. Update it in Setup & Settings."
                : result.failureSummary
        }
        isLoading = false
    }
}

struct CloseButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Close") { dismiss() }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isBusy)
    }
}

private struct StorageProfileSection: View {
    let profile: StorageProfile
    let list: StorageList
    let openPane: (StoragePane) -> Void

    private var totalKB: Int { list.totalKB(of: profile.id) }

    private var ordered: [StorageArea] {
        list.areas(of: profile.id).sorted(by: StorageArea.biggestFirst)
    }

    private func isSmall(_ area: StorageArea) -> Bool {
        (area.sizeKB ?? WorktreeCopy.smallCacheKB) < WorktreeCopy.smallCacheKB
    }

    private var sharedNotes: [SharedConfig] { list.shared.filter { $0.profileID == profile.id } }

    var body: some View {
        let smallAreas = ordered.filter(isSmall)
        Section {
            ForEach(ordered.filter { !isSmall($0) }) { area in
                StorageAreaRow(area: area, profile: profile, totalKB: totalKB, openPane: openPane)
            }
            if !smallAreas.isEmpty {
                Text("\(WorktreeCopy.plural(smallAreas.count, "small item")) under \(WorktreeCopy.size(kilobytes: WorktreeCopy.smallCacheKB)) each, \(WorktreeCopy.size(kilobytes: smallAreas.compactMap(\.sizeKB).reduce(0, +))) together")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(smallAreas.map(\.entry).joined(separator: "\n"))
            }
            ForEach(sharedNotes, id: \.configDir) { note in
                Label("The Claude Code config folder \(tildePath(note.configDir)) is shared with \(StorageCopy.ownerName(of: note.ownerID, in: list)), so it is counted there.",
                      systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            HStack(spacing: 8) {
                Text(profile.name)
                    .font(.headline)
                Spacer()
                Text("Total \(WorktreeCopy.size(kilobytes: totalKB))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct StorageAreaRow: View {
    let area: StorageArea
    let profile: StorageProfile
    let totalKB: Int
    let openPane: (StoragePane) -> Void

    private var fraction: Double {
        guard let sizeKB = area.sizeKB, totalKB > 0 else { return 0 }
        return max(StorageCopy.minimumBarFraction, min(1, Double(sizeKB) / Double(totalKB)))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(StorageCopy.title(for: area))
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Badge(text: area.kind.title, tint: StorageCopy.tint(for: area.kind))
                }
                Text(StorageCopy.path(for: area, in: profile))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                SizeBar(fraction: fraction, tint: StorageCopy.tint(for: area.kind))
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                Text(area.sizeKB.map { WorktreeCopy.size(kilobytes: $0) } ?? "unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let pane = StorageCopy.pane(for: area.tool) {
                    Button(StorageCopy.buttonTitle(for: area.tool)) { openPane(pane) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SizeBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(tint.opacity(0.7))
                    .frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: StorageCopy.barHeight)
    }
}
