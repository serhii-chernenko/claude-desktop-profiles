import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private static let periodicRefresh = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            VStack(spacing: 0) {
                NoticeStack()
                DetailRouter()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                LogPanel()
            }
        }
        .navigationTitle("Claude Profiles")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isRefreshing && !model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload profiles and status (⌘R)")
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

    var body: some View {
        VStack(spacing: 0) {
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
                          text: "Claude Code (CLI) profiles still work. Desktop profiles need Claude.app installed to build or rebuild.")
            }
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
