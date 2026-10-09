import AppKit
import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var runningPaths: Set<String> = HomeView.currentRunningPaths()

    private static let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16, alignment: .top)]

    private static func currentRunningPaths() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { HomeEnvironment.standardizedPath($0.path) } })
    }

    private var cards: [ProfileCardModel] {
        HomeCards.cards(
            sourcePath: model.sourceAppPath,
            status: model.status,
            profiles: model.profiles,
            details: model.details,
            environment: .live(runningPaths: runningPaths)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                welcome
                adoptBanners
                howItWorks
                profilesSection
                setupStatus
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: 940)
            .frame(maxWidth: .infinity)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            runningPaths = Self.currentRunningPaths()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            runningPaths = Self.currentRunningPaths()
        }
        .onAppear { runningPaths = Self.currentRunningPaths() }
    }

    private var welcome: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude Profiles")
                    .font(.system(size: 32, weight: .bold))
                Text(AppInfo.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var adoptBanners: some View {
        if !model.visibleCandidates.isEmpty {
            VStack(spacing: 10) {
                ForEach(model.visibleCandidates) { candidate in
                    AdoptBanner(candidate: candidate)
                }
            }
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("How it works")
            HStack(alignment: .top, spacing: 16) {
                StepCard(number: 1, title: "Create a profile", text: "Give it a name and a color.")
                StepCard(number: 2, title: "Open it like any app", text: "Start it from the Dock or Spotlight and sign in.")
                StepCard(number: 3, title: "Optional: Terminal", text: "Turn on Terminal integration so `claude` picks the profile by folder.")
            }
        }
    }

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Your profiles")
            if !model.hasLoaded {
                ProgressView("Loading profiles…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if model.profiles.isEmpty {
                InvitationCard()
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                    ForEach(cards) { card in
                        ProfileCard(card: card)
                    }
                }
            } else {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 16) {
                    ForEach(cards) { card in
                        ProfileCard(card: card)
                    }
                    NewProfileCard()
                }
            }
        }
    }

    private var setupStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle("Setup status")
            HStack(spacing: 0) {
                ForEach(Array(SetupStatus.items(status: model.status, shell: model.shell).enumerated()), id: \.element.id) { index, item in
                    if index > 0 {
                        Divider().padding(.vertical, 6)
                    }
                    SetupItemButton(item: item)
                }
            }
            .padding(6)
            .cardBackground(cornerRadius: 12)
        }
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title3.weight(.semibold))
    }
}

struct StepCard: View {
    let number: Int
    let title: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor.gradient))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .cardBackground(cornerRadius: 12)
    }
}

struct ProfileCard: View {
    @EnvironmentObject var model: AppModel
    let card: ProfileCardModel
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ColorTile(hex: card.colorHex, glyph: card.glyph, usesSymbol: card.usesSymbolGlyph, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(card.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            FlowLayout(spacing: 6) {
                ForEach(card.chips, id: \.self) { chip in
                    ChipView(chip: chip)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            HStack {
                Spacer(minLength: 0)
                actionButton
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .cardBackground(cornerRadius: 12, highlighted: hovering)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture { model.selection = card.item }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .help("Show details for \(card.name)")
    }

    @ViewBuilder
    private var actionButton: some View {
        switch card.action {
        case .open(let path):
            Button {
                SystemActions.openApplication(path)
            } label: {
                Label("Open", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        case .copyCommand(let command):
            Button {
                SystemActions.copyToPasteboard(command)
            } label: {
                Label("Copy Command", systemImage: "doc.on.doc")
            }
            .controlSize(.regular)
            .help("Copies \(command) to the clipboard")
        case .unavailable, .loading:
            Button {} label: {
                Label("Open", systemImage: "play.fill")
            }
            .controlSize(.regular)
            .disabled(true)
        }
    }
}

struct NewProfileCard: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    private var disabled: Bool { model.isBusy || model.cliMissing }

    var body: some View {
        Button {
            model.sheet = .create
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Color.accentColor.opacity(0.12)))
                Text("New profile")
                    .font(.headline)
                Text("A name and a color is all it takes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 124)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(hovering ? 0.08 : 0.03)))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.7 : 0.4), style: StrokeStyle(lineWidth: 1.2, dash: [6, 4]))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .onHover { hovering = $0 }
        .help("Create a profile (⌘N)")
    }
}

struct InvitationCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            ProfileStackGlyph()
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 10) {
                Text("Create your first profile")
                    .font(.title2.weight(.semibold))
                Text("A profile is a second Claude account on this Mac. It runs side by side with your regular Claude, with its own sign-in. Nothing is shared between them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        model.sheet = .create
                    } label: {
                        Label("New Profile", systemImage: "plus")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy || model.cliMissing)
                    Text("or press ⌘N")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

struct AdoptBanner: View {
    @EnvironmentObject var model: AppModel
    let candidate: Candidate

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Found existing copy “\(candidate.appDisplayName)”")
                    .font(.callout.weight(.semibold))
                Text("It was made by hand earlier. Adopt it to manage it here without rebuilding or changing it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("Not Now") {
                model.dismissedCandidates.insert(candidate.id)
            }
            .buttonStyle(.borderless)
            Button("Adopt…") {
                model.sheet = .adopt(candidate)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.25)))
    }
}

struct SetupItemButton: View {
    @EnvironmentObject var model: AppModel
    let item: SetupItem

    var body: some View {
        Button {
            model.settingsScrollTarget = item.anchor
            model.selection = .settings
        } label: {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(item.state == .ok ? Color.secondary : tint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(item.title): \(item.detail). Open Setup & Settings")
    }

    private var symbol: String {
        switch item.state {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch item.state {
        case .ok: return .green
        case .warning: return .orange
        case .unknown: return .secondary
        }
    }
}

struct ColorTile: View {
    let hex: String?
    let glyph: String
    var usesSymbol = false
    var size: CGFloat = 46

    var body: some View {
        let base = Color(hex: hex) ?? Color.secondary
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(hex == nil ? AnyShapeStyle(base.opacity(0.22)) : AnyShapeStyle(base.gradient))
            .frame(width: size, height: size)
            .overlay(
                Group {
                    if usesSymbol {
                        Image(systemName: glyph)
                            .font(.system(size: size * 0.5))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(glyph)
                            .font(.system(size: size * 0.46, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
            )
            .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
    }
}

struct ChipView: View {
    let chip: StatusChip

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(chip.text)
                .font(.caption.weight(.medium))
                .foregroundStyle(chip.tone == .neutral ? Color.secondary : tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private var tint: Color {
        switch chip.tone {
        case .positive: return .green
        case .warning: return .orange
        case .neutral: return .secondary
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat, highlighted: Bool = false) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.primary.opacity(highlighted ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(highlighted ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08)))
    }
}
