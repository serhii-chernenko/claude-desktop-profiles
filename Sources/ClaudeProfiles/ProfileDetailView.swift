import SwiftUI

struct ProfileDetailView: View {
    @EnvironmentObject var model: AppModel
    let profile: Profile

    @State private var colorDraft: Color
    @State private var syncedHex: String?
    @State private var recolorTask: Task<Void, Never>?

    init(profile: Profile) {
        self.profile = profile
        _colorDraft = State(initialValue: Color(hex: profile.color) ?? Color(hex: Palette.defaults[0])!)
        _syncedHex = State(initialValue: Color(hex: profile.color)?.hexString)
    }

    private var details: ProfileDetails? { model.details[profile.slug] }
    private var cliEnabled: Bool { details?.flag("cli") ?? !profile.isDesktop }
    private var launcher: String? { details?.value("launcher") }
    private var projects: [ProfileProject] { model.profileProjects[profile.slug] ?? [] }
    private var usesLegacyLayout: Bool { profile.isDesktop && (details?.usesLegacyLayout ?? false) }

    var body: some View {
        Form {
            header
            actions
            paths
            if cliEnabled {
                folders
            }
            projectsSection
        }
        .formStyle(.grouped)
        .onChange(of: profile.color) { newColor in
            recolorTask?.cancel()
            syncedHex = Color(hex: newColor)?.hexString
            if let color = Color(hex: newColor) { colorDraft = color }
        }
        .onChange(of: colorDraft.hexString) { newHex in
            scheduleRecolor(newHex)
        }
        .onDisappear { recolorTask?.cancel() }
    }

    private func scheduleRecolor(_ newHex: String?) {
        guard let newHex, newHex.lowercased() != syncedHex?.lowercased() else { return }
        recolorTask?.cancel()
        recolorTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            while model.isBusy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            syncedHex = newHex
            await model.recolor(profile, hex: newHex)
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .center, spacing: 16) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorDraft.gradient)
                    .frame(width: 56, height: 56)
                    .overlay(
                        Text(String(profile.name.prefix(1)).uppercased())
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    )
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name)
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        Text(profile.slug)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        if profile.isDesktop { Badge(text: "Desktop app", tint: .accentColor) }
                        if cliEnabled { Badge(text: "Claude Code CLI", tint: .purple) }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
            ActionRow(title: "Icon color",
                      caption: profile.isDesktop
                        ? "Tints the Dock icon of this profile's app and launcher in a few seconds. No rebuild."
                        : "Used to tell profiles apart in this window.",
                      systemImage: "paintpalette") {
                ColorPicker("Icon color", selection: $colorDraft, supportsOpacity: false)
                    .labelsHidden()
                    .disabled(model.isBusy)
            }
        }
    }

    private var actions: some View {
        Section("Actions") {
            if profile.isDesktop {
                ActionRow(title: "Open",
                          caption: "Starts this profile through its launcher, on its own data folder and sign-in.",
                          systemImage: "play.circle") {
                    Button("Open") {
                        if let launcher { SystemActions.openApplication(launcher) }
                    }
                    .disabled(launcher.map { !FileManager.default.fileExists(atPath: $0) } ?? true)
                }
                ActionRow(title: "Link sign-in",
                          caption: "Sends claude:// sign-in links to this profile for 15 minutes, so a browser login lands here instead of in Main Claude.",
                          systemImage: "link") {
                    HStack {
                        Button("Back to Main") {
                            Task { await model.run("Send links to Main Claude", ["link", "main"]) }
                        }
                        .help("Send claude:// links to the regular Claude app again")
                        Button("Link Sign-in") {
                            Task { await model.run("Link sign-in to \(profile.name)", ["link", profile.slug]) }
                        }
                    }
                    .disabled(model.isBusy)
                }
                if usesLegacyLayout {
                    ActionRow(title: "Move to new layout",
                              caption: "Hides the app copy from Spotlight/Raycast; the launcher becomes 'Claude \(profile.name)'",
                              systemImage: "eye.slash") {
                        Button("Move to New Layout") {
                            Task { await model.migrateLayout(profile) }
                        }
                        .disabled(model.isBusy)
                    }
                    if let blockers = model.layoutBlocks[profile.slug], !blockers.isEmpty {
                        layoutBlockNotice(blockers)
                    }
                }
                if details?.dockNeedsFix ?? false {
                    ActionRow(title: "Fix Dock",
                              caption: "Keeps only the launcher in the Dock; a pinned app copy would open on the wrong profile",
                              systemImage: "dock.rectangle") {
                        Button("Fix Dock") {
                            Task { await model.run("Fix the Dock for \(profile.name)", ["dock", profile.slug, "fix", "--yes"]) }
                        }
                        .disabled(model.isBusy)
                    }
                }
                ActionRow(title: "Rebuild",
                          caption: "Recreates the app copy and launcher from the current Claude.app. Sign-in and history are kept.",
                          systemImage: "arrow.triangle.2.circlepath") {
                    Button("Rebuild") {
                        Task { await model.run("Rebuild \(profile.name)", ["build", profile.slug]) }
                    }
                    .disabled(model.isBusy || !model.sourceAppPresent)
                }
            } else {
                ActionRow(title: "Use in Terminal",
                          caption: "Run claude-\(profile.slug) anywhere, or plain claude inside one of the folders below.",
                          systemImage: "terminal") {
                    Button("Copy Command") {
                        SystemActions.copyToPasteboard("claude-\(profile.slug)")
                    }
                }
            }
            ActionRow(title: "Check",
                      caption: "Verifies isolation, signature, auto-rebuild agent and version, and names the fix for any problem.",
                      systemImage: "stethoscope") {
                Button("Check") {
                    Task { await model.runCheck(profile) }
                }
                .disabled(model.isBusy)
            }
            ActionRow(title: "Remove",
                      caption: profile.isDesktop
                        ? "Deletes the app copy, launcher and profile entry. Data and history are kept unless you choose otherwise."
                        : "Removes the profile entry and its claude-\(profile.slug) command. History is kept unless you choose otherwise.",
                      systemImage: "trash") {
                Button("Remove…", role: .destructive) {
                    model.sheet = .remove(profile)
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func layoutBlockNotice(_ blockers: [LegacyAgent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Disable these old LaunchAgents first. They would recreate the copy at its old path.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
            ForEach(blockers) { agent in
                Text(agent.label)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            Button("Show Old LaunchAgents") {
                model.showLegacyAgents()
            }
        }
        .padding(.vertical, 2)
    }

    private var paths: some View {
        Section("Locations") {
            if profile.isDesktop {
                PathRow(title: "App", path: details?.value("app") ?? profile.app)
                PathRow(title: "Launcher", path: launcher)
                PathRow(title: "Data folder", path: details?.value("data_dir") ?? profile.dataDir)
            }
            PathRow(title: "Config folder", path: details?.value("config_dir") ?? profile.configDir)
            if let bundleID = details?.value("bundle_id"), profile.isDesktop {
                LabeledContent("Bundle ID") {
                    Text(bundleID)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var folders: some View {
        Section {
            let dirs = details?.dirs ?? []
            if dirs.isEmpty {
                Text("No folders yet. Without folders, use claude-\(profile.slug) to start this profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(dirs, id: \.self) { dir in
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(tildePath(dir))
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(dir)
                    Spacer()
                    Button {
                        Task { await model.run("Remove folder", ["dirs", profile.slug, "rm", dir]) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy)
                    .help("Stop using this profile in this folder")
                }
            }
            Button {
                let chosen = SystemActions.chooseFolders()
                guard !chosen.isEmpty else { return }
                Task {
                    for folder in chosen {
                        await model.run("Add folder", ["dirs", profile.slug, "add", folder], refreshAfter: folder == chosen.last)
                    }
                }
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .disabled(model.isBusy)
        } header: {
            Text("Folders")
        } footer: {
            Text("Running claude inside these folders (or any folder below them) uses this profile automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var projectsSection: some View {
        Section {
            if projects.isEmpty {
                Text("No Claude Code session history in this profile yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(projects) { project in
                HStack(spacing: 10) {
                    Image(systemName: project.isSymlink ? "link" : "folder.fill")
                        .foregroundStyle(project.isSymlink ? Color.accentColor : .secondary)
                        .frame(width: 16)
                        .help(project.isSymlink ? "Shared with another config folder (symlink)" : "Stored in this profile")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(tildePath(project.cwd))
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\(project.sessions) session\(project.sessions == 1 ? "" : "s") · last used \(relativeDate(project.lastUsed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if project.isSymlink { Badge(text: "Shared", tint: .accentColor) }
                }
            }
            ActionRow(title: "Add or migrate projects",
                      caption: "Bring session history from Main Claude or another profile into this one.",
                      systemImage: "square.and.arrow.down.on.square") {
                Button("Add Projects…") {
                    model.sheet = .addProjects(profile)
                }
                .disabled(model.isBusy)
            }
        } header: {
            Text("Claude Code projects")
        } footer: {
            Text("Session history stored in this profile's config folder, by project folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
