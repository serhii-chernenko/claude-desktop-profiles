import SwiftUI

struct CreateProfileSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var color = Color(hex: Palette.defaults[0])!
    @State private var desktop = true
    @State private var cli = true
    @State private var dataDir = ""
    @State private var configDir = ""
    @State private var selectedProjects: Set<String> = []
    @State private var linkMode: LinkMode = .symlink
    @State private var folders: [String] = []
    @State private var logStart: Int?
    @State private var error: String?
    @State private var prepared = false
    @State private var confirmingMove = false

    private var slug: String { PlainParser.slugify(name) }
    private var nameValid: Bool { PlainParser.isValidName(name) && PlainParser.isValidSlug(slug) }
    private var slugTaken: Bool { model.profiles.contains { $0.slug == slug } }
    private var movesHistory: Bool { linkMode == .move && !selectedProjects.isEmpty }
    private var canCreate: Bool { nameValid && !slugTaken && (desktop || cli) && !model.isBusy }

    private var availableProjects: [ScannedProject] {
        model.scan.projects.filter { configDir.isEmpty || $0.configDir != configDir }
    }

    private var pickedConfig: ConfigDirEntry? {
        model.scan.configs.first { $0.path == configDir }
    }

    private var configSharingWarning: String? {
        StorageOwners.configSharingWarning(path: configDir, in: model.allProfiles)
    }

    private var dataSharingWarning: String? {
        guard desktop else { return nil }
        return StorageOwners.dataSharingWarning(path: dataDir, in: model.allProfiles)
    }

    var body: some View {
        CommandSheet(title: "New Profile",
                     subtitle: "A profile is a separate Claude account: its own desktop app copy, its own Claude Code history, or both.",
                     logStart: logStart, error: error, height: 720) {
            identitySection
            usageSection
            storageSection
            projectsSection
            if cli {
                foldersSection
            }
        } buttons: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            Button("Create Profile") {
                if movesHistory {
                    confirmingMove = true
                } else {
                    create()
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreate)
        }
        .onAppear(perform: prepare)
        .alert("Move session history?", isPresented: $confirmingMove) {
            Button("Move History", role: .destructive) { create() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The history of \(selectedProjects.count) project\(selectedProjects.count == 1 ? "" : "s") leaves its current profile or Main Claude and moves into the new profile. Quit Claude Code sessions in these projects first.")
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        color = Color(hex: Palette.suggested(forExistingCount: model.profiles.count)) ?? color
        desktop = model.sourceAppPresent
    }

    private var identitySection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("e.g. Work"))
            if !name.isEmpty {
                Group {
                    if !nameValid {
                        Text("Use letters and digits; no / : \" \\ and no leading or trailing spaces.")
                            .foregroundStyle(.red)
                    } else if slugTaken {
                        Text("A profile named “\(slug)” already exists.")
                            .foregroundStyle(.red)
                    } else {
                        Text(previewText)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            ActionRow(title: "Icon color",
                      caption: "Tints the profile's Dock icon so you can tell the apps apart.",
                      systemImage: "paintpalette") {
                ColorPicker("Icon color", selection: $color, supportsOpacity: false)
                    .labelsHidden()
            }
        } header: {
            Text("Profile")
        }
    }

    private var previewText: String {
        var parts: [String] = []
        if desktop { parts.append("App: Claude \(name).app") }
        if cli { parts.append("Command: claude-\(slug)") }
        return parts.joined(separator: " · ")
    }

    private var usageSection: some View {
        Section {
            ActionRow(title: "Claude desktop app",
                      caption: model.sourceAppPresent
                        ? "Builds a tinted copy of Claude.app with its own sign-in and Dock icon: one app per profile."
                        : "Needs Claude.app in Applications. Install it first to create a desktop profile.",
                      systemImage: "macwindow") {
                Toggle("Desktop app", isOn: $desktop)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .disabled(!model.sourceAppPresent)
            }
            ActionRow(title: "Terminal command",
                      caption: "Adds claude-\(slug.isEmpty ? "name" : slug) in Terminal and picks this profile automatically in its folders.",
                      systemImage: "terminal") {
                Toggle("Terminal command", isOn: $cli)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            if !desktop && !cli {
                Text("Turn on at least one of the two.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Use it for")
        }
    }

    private var configFolderCaption: String {
        let command = "claude-\(slug.isEmpty ? "name" : slug)"
        let users: String
        switch (desktop, cli) {
        case (true, true): users = "Used by the Code tab of this profile's app and by \(command) in Terminal"
        case (true, false): users = "Used by the Code tab of this profile's app"
        default: users = "Used by \(command) in Terminal"
        }
        return users + ": session history, settings and Claude Code sign-in. Picking ~/.claude shares them with Main Claude."
    }

    private var storageSection: some View {
        Section {
            if desktop {
                VStack(alignment: .leading, spacing: 3) {
                    Picker("Desktop data folder", selection: $dataDir) {
                        Text("Create new").tag("")
                        ForEach(model.scan.dataDirs, id: \.self) { dir in
                            Text(tildePath(dir)).tag(dir)
                        }
                    }
                    Text("Picking an existing folder reuses the sign-in and chats stored in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let warning = dataSharingWarning {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Picker("Claude Code config folder", selection: $configDir) {
                    Text("Create new").tag("")
                    ForEach(model.scan.configs) { config in
                        Text("\(tildePath(config.path)) (\(config.projectCount) projects)").tag(config.path)
                    }
                }
                Text(configFolderCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let warning = configSharingWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Storage")
        }
    }

    private var projectsSection: some View {
        Section {
            Text("Copy, move or share Claude Code history that currently lives in another profile's folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let config = pickedConfig {
                Label(StorageOwners.includedProjectsNote(folder: tildePath(config.path), count: config.projectCount),
                      systemImage: "checkmark.circle")
                    .font(.callout)
            }
            if availableProjects.isEmpty {
                Text("No projects in other folders.")
                    .foregroundStyle(.secondary)
            } else {
                ProjectChecklist(projects: availableProjects, selected: $selectedProjects)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("How", selection: $linkMode) {
                        ForEach(LinkMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(linkMode.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(selectedProjects.isEmpty)
            }
        } header: {
            Text("Bring projects from other folders (optional)")
        } footer: {
            Text("Selected project folders also become folders that pick this profile automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var foldersSection: some View {
        Section {
            FolderPickerList(folders: $folders, emptyText: "None. You can add folders later.")
        } header: {
            Text("Folders for automatic selection (optional)")
        } footer: {
            Text("Running claude inside these folders uses this profile without typing claude-\(slug.isEmpty ? "name" : slug).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func create() {
        guard let hex = color.hexString else { return }
        var arguments = ["new", "--name", name, "--color", hex]
        arguments.append(desktop ? "--desktop" : "--no-desktop")
        arguments.append(cli ? "--cli" : "--no-cli")
        if desktop && !dataDir.isEmpty { arguments += ["--data-dir", dataDir] }
        if !configDir.isEmpty { arguments += ["--config-dir", configDir] }
        if cli {
            for folder in folders { arguments += ["--dir", folder] }
        }
        let links = availableProjects.map(\.cwd).filter { selectedProjects.contains($0) }
        var seen = Set<String>()
        for cwd in links where seen.insert(cwd).inserted {
            arguments += ["--link", cwd]
        }
        if !seen.isEmpty { arguments += ["--link-mode", linkMode.rawValue] }
        arguments += ["--yes", "--plain"]
        error = nil
        logStart = model.nextLogID
        Task {
            guard let result = await model.run("Create \(name)", arguments, showsAlert: false) else { return }
            if result.succeeded {
                if let created = PlainParser.created(result.stdout) {
                    model.selection = .profile(created.slug)
                } else {
                    model.selection = .profile(slug)
                }
                dismiss()
                model.offerSetupAfterCreate()
            } else {
                error = result.failureSummary
            }
        }
    }
}
