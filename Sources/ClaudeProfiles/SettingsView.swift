import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var agentToDisable: LegacyAgent?

    private var status: StatusSummary? { model.status }

    var body: some View {
        Form {
            if !model.statusAvailable {
                Section {
                    Label("The bundled command-line tool does not report status. Reinstall Claude Profiles to get the latest version.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            commandLineSection
            shellSection
            rebuildSection
            legacySection
            aboutSection
        }
        .formStyle(.grouped)
        .confirmationDialog("Disable \(agentToDisable?.label ?? "agent")?",
                            isPresented: Binding(get: { agentToDisable != nil }, set: { if !$0 { agentToDisable = nil } }),
                            presenting: agentToDisable) { agent in
            Button("Disable Agent", role: .destructive) {
                Task { await model.run("Disable \(agent.label)", ["legacy-agents", "disable", agent.label, "--yes"]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { agent in
            Text("It is unloaded and its file is renamed to \((agent.plist as NSString).lastPathComponent).disabled. Nothing is deleted; rename it back to restore it.")
        }
    }

    private var commandLineSection: some View {
        Section {
            ActionRow(title: "claude-profiles command",
                      caption: "Copies the tool bundled in this app to ~/.local/share/claude-profiles and links it into ~/.local/bin, for Terminal and the auto-rebuild agent.",
                      systemImage: "terminal") {
                Button(status?.cliInstalled == true ? "Update" : "Install") {
                    Task { await model.installCLI() }
                }
                .disabled(model.isBusy || model.cliMissing)
            }
            LabeledContent("Status") {
                StatusLabel(ok: status?.cliInstalled,
                            text: status?.cliInstalled == true ? "Installed at \(tildePath(status?.cliPath ?? ""))" : "Not installed")
            }
        } header: {
            Text("Command-line tool")
        }
    }

    private var shellSection: some View {
        Section {
            ActionRow(title: "Pick the profile automatically in Terminal",
                      caption: "Adds one marked eval line to \(tildePath(model.shell?.rcFile ?? "~/.zshrc")) that defines claude, claude-default and claude-<profile>. The command-line tool is installed first if needed. A backup is kept.",
                      systemImage: "chevron.left.forwardslash.chevron.right") {
                Toggle("Shell integration", isOn: Binding(
                    get: { model.shell?.installed ?? false },
                    set: { enabled in Task { await model.setShellIntegration(enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(model.isBusy || model.shell == nil)
            }
            if let conflicts = model.shell?.conflicts, !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Other definitions of claude may override the profile switch:", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                    ForEach(conflicts, id: \.self) { conflict in
                        Text(conflict)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Text("Remove or rename them in your shell files if `claude` does not pick the right profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Shell integration")
        }
    }

    private var rebuildSection: some View {
        Section {
            LabeledContent("Signing identity") {
                StatusLabel(ok: identityOK, text: identityText)
            }
            LabeledContent("Auto-rebuild agent") {
                StatusLabel(ok: status?.agentLoaded, text: status?.agentLoaded == true ? "Loaded" : "Not installed")
            }
            LabeledContent("Claude.app") {
                StatusLabel(ok: model.sourceAppPresent ? status?.sourceTeamOK : false, text: sourceText)
            }
            ActionRow(title: "Set up auto-rebuild & stable signing",
                      caption: "Opens Terminal to run setup once. It asks for your login password there; this app never sees it.",
                      systemImage: "lock.shield") {
                Button("Set Up…") {
                    Task { await model.startSetup() }
                }
                .disabled(model.isBusy || model.cliMissing)
            }
        } header: {
            Text("Updates and signing")
        } footer: {
            Text("When Claude updates, the agent rebuilds every profile that is not running. A stable signing identity stops Keychain from asking again after each rebuild.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var identityOK: Bool? {
        guard let present = status?.identityPresent else { return nil }
        return present && (status?.identityUsable ?? false)
    }

    private var identityText: String {
        let name = status?.identityName ?? "Claude Profiles Signing"
        switch (status?.identityPresent, status?.identityUsable) {
        case (.some(true), .some(true)): return "“\(name)” ready"
        case (.some(true), _): return "“\(name)” found, needs setup"
        case (.some(false), _): return "Not set up (ad-hoc signing)"
        default: return "Unknown"
        }
    }

    private var sourceText: String {
        guard model.sourceAppPresent else { return "Not installed" }
        var text = status?.sourceVersion.map { "Version \($0)" } ?? "Installed"
        if status?.sourceTeamOK == false { text += ", unexpected signer" }
        return text
    }

    private var legacySection: some View {
        Section {
            if model.legacyAgents.isEmpty {
                Text("None found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.legacyAgents) { agent in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.label)
                                .font(.system(.callout, design: .monospaced))
                            Badge(text: agent.loaded ? "Loaded" : "Not loaded", tint: agent.loaded ? .orange : .secondary)
                        }
                        if let program = agent.program {
                            Text(program)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(program)
                        }
                    }
                    Spacer()
                    Button("Disable…") { agentToDisable = agent }
                        .disabled(model.isBusy)
                }
            }
        } header: {
            Text("Old LaunchAgents")
        } footer: {
            Text("Agents from earlier hand-made setups that also watch Claude.app can rebuild or quit copies behind your back. Disabling unloads one and renames its file; nothing is deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            PathRow(title: "Settings folder", path: status?.home)
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")
        }
    }
}
