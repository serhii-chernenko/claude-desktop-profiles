import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel

    private static let periodicRefresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var showsRefreshProgress: Bool {
        model.isRefreshing && !model.isBusy
    }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                NoticeStack()
                DetailRouter()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .alert(SetupCopy.followUpTitle, isPresented: $model.showsSetupFollowUp) {
                        Button("Set Up…") {
                            Task { await model.startSetup() }
                        }
                        Button("Later", role: .cancel) {}
                    } message: {
                        Text(SetupCopy.explanation + "\n\n" + SetupCopy.passwordNote)
                    }
                LogPanel()
            }
        }
        .navigationTitle("Claude Profiles")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let version = updater.pendingUpdateVersion {
                    Button {
                        updater.showPendingUpdate()
                    } label: {
                        Label(updater.downloadedUpdateVersion != nil ? "Restart to Update" : "Update to \(version)",
                              systemImage: "arrow.down.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Claude Profiles \(version) is available")
                    .disabled(updater.downloadedUpdateVersion == nil && !updater.canCheckForUpdates)
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    if showsRefreshProgress {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing")
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .help(showsRefreshProgress ? "Refreshing" : "Reload profiles and status (⌘R)")
                .disabled(model.isBusy || model.isRefreshing)
                Button {
                    model.sheet = .create
                } label: {
                    Label("New Profile", systemImage: "plus")
                }
                .help("Create a profile (⌘N)")
                .disabled(model.isBusy || model.cliMissing)
            }
        }
        .sheet(item: $model.sheet) { sheet in
            SheetHost(sheet: sheet)
                .environmentObject(model)
        }
        .alert(model.failure?.title ?? "Command failed",
               isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
               presenting: model.failure) { _ in
            Button("Show Log") {
                model.logVisible = true
                model.failure = nil
            }
            Button("OK", role: .cancel) { model.failure = nil }
        } message: { failure in
            Text(failure.message)
        }
        .task {
            await model.refresh()
            await model.updateInstalledCLIIfStale()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.autoRefresh() }
        }
        .onReceive(Self.periodicRefresh) { _ in
            guard NSApplication.shared.occlusionState.contains(.visible) else { return }
            Task { await model.autoRefresh() }
        }
        .onChange(of: model.selection) { selection in
            if case .profile(let slug) = selection {
                Task { await model.loadDetails(for: slug) }
            }
        }
    }
}

struct SheetHost: View {
    let sheet: ActiveSheet

    var body: some View {
        switch sheet {
        case .create:
            CreateProfileSheet()
        case .adopt(let candidate):
            AdoptSheet(candidate: candidate)
        case .remove(let profile):
            RemoveSheet(profile: profile)
        case .check(let report):
            CheckSheet(report: report)
        case .addProjects(let profile):
            AddProjectsSheet(profile: profile)
        }
    }
}

struct DetailRouter: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.selection {
        case .home:
            HomeView()
        case .main:
            MainClaudeView()
        case .settings:
            SettingsView()
        case .profile(let slug):
            if let profile = model.profile(slug) {
                ProfileDetailView(profile: profile)
                    .id(profile.slug)
            } else {
                placeholder
            }
        case .none:
            HomeView()
        }
    }

    private var placeholder: some View {
        ProgressView("Loading profiles…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ProfileStackGlyph: View {
    private let colors: [Color] = [Color(hex: "#3a7bd5")!, Color(hex: "#2ecc71")!, Color(hex: "#e67e22")!]

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width * 0.62
            let step = (geometry.size.width - side) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    RoundedRectangle(cornerRadius: side * 0.24, style: .continuous)
                        .fill(color.gradient)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .offset(x: step * CGFloat(index), y: step * CGFloat(2 - index))
                }
            }
        }
    }
}

struct NoticeStack: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        VStack(spacing: 0) {
            if let version = updater.downloadedUpdateVersion {
                NoticeBar(systemImage: "arrow.down.circle.fill", tint: .accentColor,
                          title: "Claude Profiles \(version) is ready",
                          text: "Downloaded and verified. It installs when you quit Claude Profiles, or restart now to install it.") {
                    Button("Restart Now") { updater.installDownloadedUpdateNow() }
                        .buttonStyle(.borderedProminent)
                }
            } else if let version = updater.availableUpdateVersion {
                NoticeBar(systemImage: "arrow.down.circle.fill", tint: .accentColor,
                          title: "Claude Profiles \(version) is available",
                          text: "You have \(AppInfo.version). See what is new and install it.") {
                    Button("Update…") { updater.checkForUpdates() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!updater.canCheckForUpdates)
                }
            }
            if model.cliMissing {
                NoticeBar(systemImage: "exclamationmark.triangle.fill", tint: .red,
                          title: "The bundled command-line tool is missing",
                          text: "This copy of Claude Profiles is incomplete. Download it again from the releases page.")
            }
            if let error = model.loadError {
                NoticeBar(systemImage: "exclamationmark.triangle.fill", tint: .red,
                          title: "Could not read your profiles", text: error)
            }
            if model.hasLoaded && !model.sourceAppPresent {
                NoticeBar(systemImage: "info.circle.fill", tint: .orange,
                          title: "Claude.app was not found in Applications",
                          text: "Terminal-only profiles still work. Desktop profiles need Claude.app installed to build or rebuild.")
            }
        }
        .alert(updater.readyPromptVersion.map { "Claude Profiles \($0) is ready" } ?? "Update ready",
               isPresented: Binding(get: { updater.readyPromptVersion != nil }, set: { if !$0 { updater.readyPromptVersion = nil } })) {
            Button("Restart Now") { updater.installDownloadedUpdateNow() }
            Button("Later", role: .cancel) {}
        } message: {
            Text("The update is downloaded and verified. Restart now to install it, or it installs when you quit Claude Profiles.")
        }
    }
}

struct NoticeBar<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let text: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(text)
                }
                .layoutPriority(1)
                Spacer(minLength: 12)
                actions()
                    .fixedSize()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(tint.opacity(0.09))
            Divider()
        }
    }
}

extension NoticeBar where Actions == EmptyView {
    init(systemImage: String, tint: Color, title: String, text: String) {
        self.init(systemImage: systemImage, tint: tint, title: title, text: text) { EmptyView() }
    }
}
