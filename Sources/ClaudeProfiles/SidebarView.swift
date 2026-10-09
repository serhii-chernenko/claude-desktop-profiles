import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selection) {
            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    ProfileSidebarRow(profile: profile, cli: model.details[profile.slug]?.flag("cli"))
                        .tag(SidebarItem.profile(profile.slug))
                }
                if model.hasLoaded && model.profiles.isEmpty {
                    Text("No profiles yet")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            Section("Built-in") {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Main Claude")
                        Text("Default · read-only")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "house")
                }
                .tag(SidebarItem.main)
                Label("Setup & Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                Button {
                    model.sheet = .create
                } label: {
                    Label("New Profile", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .disabled(model.isBusy || model.cliMissing)
                .help("Create a profile (⌘N)")
            }
        }
    }
}

struct ProfileSidebarRow: View {
    let profile: Profile
    let cli: Bool?

    var body: some View {
        HStack(spacing: 9) {
            ColorDot(hex: profile.color, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .lineLimit(1)
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private var kind: String {
        switch (profile.isDesktop, cli) {
        case (true, .some(false)): return "Desktop app"
        case (true, _): return "Desktop app + CLI"
        default: return "Claude Code (CLI) only"
        }
    }
}
