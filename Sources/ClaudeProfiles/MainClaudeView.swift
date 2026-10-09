import SwiftUI

struct MainClaudeView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 56, height: 56)
                        .overlay(Image(systemName: "person.crop.circle.fill").font(.system(size: 24)).foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Main Claude")
                            .font(.title2.weight(.semibold))
                        Text("Your regular Claude app and ~/.claude. Profiles run next to it and never change it.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            Section("Locations") {
                PathRow(title: "App", path: model.sourceAppPresent ? model.sourceAppPath : nil, missingText: "Not installed")
                if let version = model.status?.sourceVersion {
                    LabeledContent("Version", value: version)
                }
                PathRow(title: "Data folder", path: model.defaultProfile?.dataDir)
                PathRow(title: "Config folder", path: model.defaultProfile?.configDir)
            }
            Section("Actions") {
                ActionRow(title: "Open Claude",
                          caption: "Starts the regular Claude app with your main account.",
                          systemImage: "play.circle") {
                    Button("Open") { SystemActions.openApplication(model.sourceAppPath) }
                        .disabled(!model.sourceAppPresent)
                }
                ActionRow(title: "Send sign-in links here",
                          caption: "Makes claude:// links open Main Claude again, for example after signing in to a profile.",
                          systemImage: "link") {
                    Button("Link to Main") {
                        Task { await model.run("Send links to Main Claude", ["link", "main"]) }
                    }
                    .disabled(model.isBusy || !model.sourceAppPresent)
                }
                if let scheme = model.status?.handlerScheme, let handler = model.status?.handlerBundleID {
                    LabeledContent("\(scheme):// links open") {
                        Text(handler)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
