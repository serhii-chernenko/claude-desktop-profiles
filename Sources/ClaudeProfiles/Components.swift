import AppKit
import SwiftUI

extension Color {
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255,
                  opacity: 1)
    }

    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}

enum Palette {
    static let defaults = ["#3a7bd5", "#2ecc71", "#9b59b6", "#e67e22", "#e84393", "#16a085", "#f1c40f", "#c0392b"]

    static func suggested(forExistingCount count: Int) -> String {
        defaults[count % defaults.count]
    }
}

func tildePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

func relativeDate(_ date: Date?) -> String {
    guard let date else { return "unknown" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct ColorDot: View {
    let hex: String?
    var size: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Color(hex: hex) ?? Color.secondary.opacity(0.35))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .frame(width: size, height: size)
    }
}

struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }
}

/// A form row with a title, a one-line explanation underneath, and a trailing control.
struct ActionRow<Trailing: View>: View {
    let title: String
    let caption: String
    var systemImage: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

struct PathRow: View {
    let title: String
    let path: String?
    var missingText = "Not set"

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if let path {
                    Text(tildePath(path))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                    Button {
                        SystemActions.reveal(path)
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!FileManager.default.fileExists(atPath: path))
                    .help(FileManager.default.fileExists(atPath: path) ? "Reveal in Finder" : "Does not exist yet")
                } else {
                    Text(missingText).foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(title)
        }
    }
}

struct StatusLabel: View {
    let ok: Bool?
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
        }
    }

    private var symbol: String {
        switch ok {
        case .some(true): return "checkmark.circle.fill"
        case .some(false): return "exclamationmark.circle.fill"
        case .none: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }
}

struct FolderPickerList: View {
    @Binding var folders: [String]
    let emptyText: String

    var body: some View {
        if folders.isEmpty {
            Text(emptyText)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        ForEach(folders, id: \.self) { folder in
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text(tildePath(folder))
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    folders.removeAll { $0 == folder }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this folder")
            }
        }
        Button {
            for folder in SystemActions.chooseFolders() where !folders.contains(folder) {
                folders.append(folder)
            }
        } label: {
            Label("Add Folder…", systemImage: "plus")
        }
    }
}

struct InlineLog: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Text(model.activeCommand ?? "Working…")
                        .font(.callout.weight(.medium))
                }
                Spacer()
            }
            LogLinesView(lines: model.log)
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

struct ProjectChecklist: View {
    @EnvironmentObject var model: AppModel
    let projects: [ScannedProject]
    @Binding var selected: Set<String>
    @State private var query = ""

    private var filtered: [ScannedProject] {
        guard !query.isEmpty else { return projects }
        return projects.filter { $0.cwd.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter projects", text: $query)
                    .textFieldStyle(.plain)
                if !selected.isEmpty {
                    Text("\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear") { selected.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { project in
                        Toggle(isOn: binding(for: project.cwd)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tildePath(project.cwd))
                                    .font(.system(.callout, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(subtitle(project))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        Divider()
                    }
                    if filtered.isEmpty {
                        Text("No matching projects")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                }
            }
            .frame(height: 190)
        }
    }

    private func subtitle(_ project: ScannedProject) -> String {
        var parts = [origin(of: project), "\(project.sessions) session\(project.sessions == 1 ? "" : "s")"]
        if let lastUsed = project.lastUsed { parts.append("last used \(relativeDate(lastUsed))") }
        if let owner = project.owner { parts.append("folder rule: \(owner)") }
        return parts.joined(separator: " · ")
    }

    private func origin(of project: ScannedProject) -> String {
        let folder = tildePath(project.configDir)
        guard let owner = StorageOwners.configOwner(of: project.configDir, in: model.allProfiles) else {
            return "from \(folder)"
        }
        return "from \(folder) (\(owner))"
    }

    private func binding(for cwd: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(cwd) },
            set: { isOn in
                if isOn { selected.insert(cwd) } else { selected.remove(cwd) }
            }
        )
    }
}
