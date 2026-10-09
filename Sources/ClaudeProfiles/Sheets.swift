import SwiftUI

struct AdoptSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let candidate: Candidate

    @State private var name: String
    @State private var slug: String
    @State private var slugEdited = false
    @State private var identity = ""
    @State private var logStart: Int?
    @State private var error: String?

    init(candidate: Candidate) {
        self.candidate = candidate
        _name = State(initialValue: candidate.name)
        _slug = State(initialValue: PlainParser.slugify(candidate.name))
    }

    private var slugTaken: Bool { model.profiles.contains { $0.slug == slug } }
    private var canAdopt: Bool {
        PlainParser.isValidName(name) && PlainParser.isValidSlug(slug) && !slugTaken
            && PlainParser.isValidIdentity(identity) && !model.isBusy
    }

    var body: some View {
        CommandSheet(title: "Adopt “\(candidate.appDisplayName)”",
                     subtitle: "Registers this existing copy as a profile without rebuilding or changing it. Afterwards it can be checked, recolored and rebuilt here like any other profile.",
                     logStart: logStart, error: error, width: 600, height: 600) {
            Section("Profile") {
                TextField("Name", text: $name)
                    .onChange(of: name) { newName in
                        if !slugEdited { slug = PlainParser.slugify(newName) }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Short name", text: Binding(get: { slug }, set: { slug = $0; slugEdited = true }))
                    Text(slugTaken ? "A profile with this short name already exists."
                         : PlainParser.isValidSlug(slug) ? "Used for the claude-\(slug) command."
                         : "Lowercase letters, digits and dashes only.")
                        .font(.caption)
                        .foregroundStyle(slugTaken || !PlainParser.isValidSlug(slug) ? .red : .secondary)
                }
            }
            Section("Found on this Mac") {
                PathRow(title: "App", path: candidate.app)
                PathRow(title: "Launcher", path: candidate.launcher, missingText: "None found")
                PathRow(title: "Data folder", path: candidate.dataDir, missingText: "Default for this name")
                PathRow(title: "Config folder", path: candidate.configDir, missingText: "Default for this name")
                LabeledContent("Bundle ID") {
                    Text(candidate.bundleID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Signing identity (optional)", text: $identity, prompt: Text("Leave empty to keep the default"))
                    Text(PlainParser.isValidIdentity(identity)
                         ? "The name of the code-signing certificate in your keychain this copy was signed with, if any. Keeps Keychain from asking again after rebuilds."
                         : "Use only letters, digits, space, dot, underscore and dash.")
                        .font(.caption)
                        .foregroundStyle(PlainParser.isValidIdentity(identity) ? Color.secondary : Color.red)
                }
            } header: {
                Text("Signing")
            }
        } buttons: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            Button("Adopt") { adopt() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdopt)
        }
    }

    private func adopt() {
        var arguments = ["adopt", "--slug", slug, "--name", name, "--app", candidate.app]
        if let launcher = candidate.launcher { arguments += ["--launcher", launcher] }
        if let dataDir = candidate.dataDir { arguments += ["--data-dir", dataDir] }
        if let configDir = candidate.configDir { arguments += ["--config-dir", configDir] }
        let trimmedIdentity = identity.trimmingCharacters(in: .whitespaces)
        if !trimmedIdentity.isEmpty { arguments += ["--identity", trimmedIdentity] }
        arguments.append("--yes")
        error = nil
        logStart = model.nextLogID
        let adoptedSlug = slug
        Task {
            guard let result = await model.run("Adopt \(name)", arguments, showsAlert: false) else { return }
            if result.succeeded {
                model.selection = .profile(adoptedSlug)
                dismiss()
            } else {
                error = result.failureSummary
            }
        }
    }
}

struct RemoveSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: Profile

    @State private var deleteData = false
    @State private var deleteConfig = false
    @State private var logStart: Int?
    @State private var error: String?

    private var details: ProfileDetails? { model.details[profile.slug] }
    private var configDir: String { details?.value("config_dir") ?? profile.configDir }
    private var dataDir: String? { details?.value("data_dir") ?? profile.dataDir }
    private var configIsMain: Bool { configDir == model.defaultProfile?.configDir }

    var body: some View {
        CommandSheet(title: "Remove “\(profile.name)”?",
                     subtitle: profile.isDesktop
                        ? "The app copy, its launcher and the profile entry are deleted. Your main Claude is not touched."
                        : "The profile entry, its claude-\(profile.slug) command and folder rules are removed.",
                     logStart: logStart, error: error, width: 560, height: logStart == nil ? 400 : 560) {
            Section {
                if profile.isDesktop {
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Also delete the desktop data folder", isOn: $deleteData)
                        Text("Sign-in, chats cache and local settings in \(tildePath(dataDir ?? "the data folder")). Cannot be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Also delete the Claude Code config folder", isOn: $deleteConfig)
                        .disabled(configIsMain)
                    Text(configIsMain
                         ? "This profile uses ~/.claude, which is never deleted."
                         : "Session history, settings and CLI sign-in in \(tildePath(configDir)). Cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Keep or delete data")
            } footer: {
                Text(profile.isDesktop
                     ? "Leave both off to keep everything; you can create or adopt the profile again later."
                     : "Leave it off to keep the history; a new profile can use this folder again later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            Button("Remove Profile", role: .destructive) { remove() }
                .disabled(model.isBusy)
        }
    }

    private func remove() {
        var arguments = ["remove", profile.slug]
        if deleteData { arguments.append("--delete-data") }
        if deleteConfig && !configIsMain { arguments.append("--delete-config") }
        arguments.append("--yes")
        error = nil
        logStart = model.nextLogID
        Task {
            guard let result = await model.run("Remove \(profile.name)", arguments, showsAlert: false) else { return }
            if result.succeeded {
                dismiss()
            } else {
                error = result.failureSummary
            }
        }
    }
}

struct CheckSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: CheckReport

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(report.title)
                    .font(.title2.weight(.semibold))
                HStack(spacing: 14) {
                    summary(count: report.passes, label: "OK", symbol: "checkmark.circle.fill", tint: .green)
                    summary(count: report.warnings, label: "Warnings", symbol: "exclamationmark.triangle.fill", tint: .orange)
                    summary(count: report.failures, label: "Failures", symbol: "xmark.octagon.fill", tint: .red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            Divider()
            List(report.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    icon(for: line.level)
                        .frame(width: 18)
                    Text(line.message)
                        .font(line.level == .detail ? .system(.caption, design: .monospaced) : .callout)
                        .foregroundStyle(line.level == .detail ? .secondary : .primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            HStack {
                Text(report.failures > 0 ? "Each failure names the fix." : "Warnings are informational unless something misbehaves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    SystemActions.copyToPasteboard(report.lines.map { "\($0.level.rawValue) \($0.message)" }.joined(separator: "\n"))
                }
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 640, height: 520)
    }

    private func summary(count: Int, label: String, symbol: String, tint: Color) -> some View {
        Label {
            Text("\(count) \(label)")
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func icon(for level: CheckLevel) -> some View {
        switch level {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .info: Image(systemName: "info.circle").foregroundStyle(.blue)
        case .detail: Color.clear
        }
    }
}

struct AddProjectsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: Profile

    @State private var selected: Set<String> = []
    @State private var mode: LinkMode = .symlink
    @State private var addFolders = true
    @State private var logStart: Int?
    @State private var error: String?
    @State private var needsConfirmation = false
    @State private var confirmingMove = false

    private var configDir: String { model.details[profile.slug]?.value("config_dir") ?? profile.configDir }
    private var projects: [ScannedProject] { model.scan.projects.filter { $0.configDir != configDir } }

    var body: some View {
        CommandSheet(title: "Add Projects to “\(profile.name)”",
                     subtitle: "Brings Claude Code session history from Main Claude or other profiles into this profile's config folder.",
                     logStart: logStart, error: error, width: 640, height: 640) {
            Section {
                if projects.isEmpty {
                    Text("No projects with session history were found in other config folders.")
                        .foregroundStyle(.secondary)
                } else {
                    ProjectChecklist(projects: projects, selected: $selected)
                }
            } header: {
                Text("Projects")
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("How", selection: $mode) {
                        ForEach(LinkMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Toggle("Also pick this profile automatically in these folders", isOn: $addFolders)
                    Text("Adds each project folder to this profile's folders, so claude there uses it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Options")
            } footer: {
                Text("Quit Claude Code sessions in these projects first; a running session can rewrite its project entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } buttons: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            if needsConfirmation {
                Button("Move Anyway", role: .destructive) { add(force: true) }
                    .disabled(model.isBusy)
            } else {
                Button(selected.isEmpty ? "Add Projects" : "Add \(selected.count) Project\(selected.count == 1 ? "" : "s")") {
                    if mode == .move {
                        confirmingMove = true
                    } else {
                        add(force: false)
                    }
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || model.isBusy)
            }
        }
        .onChange(of: mode) { _ in needsConfirmation = false }
        .onChange(of: selected) { _ in needsConfirmation = false }
        .alert("Move session history?", isPresented: $confirmingMove) {
            Button("Move History", role: .destructive) { add(force: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The history of \(selected.count) project\(selected.count == 1 ? "" : "s") leaves its current profile or Main Claude and is no longer available there. Quit Claude Code sessions in these projects first.")
        }
    }

    private func add(force: Bool) {
        var arguments = ["projects", profile.slug, "add", "--mode", mode.rawValue]
        if !addFolders { arguments.append("--no-dir") }
        if force { arguments.append("--yes") }
        var seen = Set<String>()
        arguments += projects.map(\.cwd).filter { selected.contains($0) && seen.insert($0).inserted }
        error = nil
        logStart = model.nextLogID
        Task {
            guard let result = await model.run("Add projects to \(profile.name)", arguments, showsAlert: false) else { return }
            if result.succeeded {
                dismiss()
            } else if !force && result.stderr.contains("--yes") {
                needsConfirmation = true
                error = result.failureSummary + "\n\nQuit that Claude first, or choose Move Anyway."
            } else {
                error = result.failureSummary
            }
        }
    }
}
