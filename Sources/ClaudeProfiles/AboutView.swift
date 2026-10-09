import AppKit
import SwiftUI

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show(updater: UpdaterModel) {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView().environmentObject(updater))
            let aboutWindow = NSWindow(contentViewController: controller)
            aboutWindow.title = "About Claude Profiles"
            aboutWindow.styleMask = [.titled, .closable]
            aboutWindow.isReleasedWhenClosed = false
            aboutWindow.center()
            window = aboutWindow
        }
        window?.makeKeyAndOrderFront(nil)
        if #available(macOS 14, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct AboutView: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            VStack(spacing: 3) {
                Text("Claude Profiles")
                    .font(.title.weight(.semibold))
                Text("Version \(AppInfo.versionDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text(AppInfo.summary)
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
            VStack(spacing: 6) {
                Link(destination: AppInfo.repositoryURL) {
                    Label("GitHub repository", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: AppInfo.issuesURL) {
                    Label("Report an issue", systemImage: "exclamationmark.bubble")
                }
                Link(destination: AppInfo.licenseURL) {
                    Label("MIT License", systemImage: "doc.text")
                }
            }
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            Text("Not affiliated with Anthropic")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(width: 380)
        .fixedSize()
    }
}
