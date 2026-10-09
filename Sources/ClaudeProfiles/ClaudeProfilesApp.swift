import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updater: UpdaterModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Claude Profiles") {
                AboutWindowController.shared.show(updater: updater)
            }
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Profile…") {
                model.sheet = .create
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model.isBusy || model.cliMissing)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                model.selection = .settings
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") {
                Task { await model.refresh() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isBusy || model.isRefreshing)
            Button(model.logVisible ? "Hide Log" : "Show Log") {
                model.logVisible.toggle()
            }
            .keyboardShortcut("l", modifiers: .command)
            Divider()
        }
    }
}

struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        Window("Claude Profiles", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            AppCommands(model: model, updater: updater)
        }
    }
}
