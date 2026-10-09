import Foundation
import SwiftUI

/// Exercises the CLI invocation and `--plain` parsing against an isolated temporary home. Never launches apps.
enum SelfTest {
    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutLines = 0
        func add() { lock.lock(); stdoutLines += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return stdoutLines }
    }

    private static var failures: [String] = []
    private static var passed = 0
    private static var skipped: [String] = []

    private static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passed += 1
        } else {
            failures.append(message)
            print("FAIL  \(message)")
        }
    }

    private static func call(_ runner: CLIRunner, _ arguments: [String], counter: Counter? = nil) -> CommandResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<CommandResult>()
        Task.detached {
            box.value = await runner.run(arguments, timeout: 180) { _, isError in
                if !isError { counter?.add() }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? CommandResult(status: -1, stdout: "", stderr: "no result", timedOut: false)
    }

    private static func optionalCommand(_ name: String, _ result: CommandResult) -> Bool {
        if result.isUnknownCommand {
            skipped.append(name)
            print("SKIP  \(name): not available in this CLI")
            return false
        }
        expect(result.succeeded, "\(name) exited \(result.status): \(result.failureSummary)")
        return result.succeeded
    }

    static func run() -> Int32 {
        parserChecks()
        guard let script = CLILocator.bundledCLI() else {
            print("FAIL  bundled CLI not found (Contents/Resources/cli/bin/claude-profiles or $\(CLILocator.overrideVariable))")
            return 1
        }
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("claude-profiles-selftest-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            print("FAIL  could not create a temporary directory: \(error)")
            return 1
        }
        defer { try? fileManager.removeItem(at: base) }
        let root = base.resolvingSymlinksInPath().path
        let home = root + "/home"
        let settings = root + "/settings"
        do {
            try integrationChecks(script: script, root: root, home: home, settings: settings)
        } catch {
            failures.append("fixture setup failed: \(error)")
        }
        if failures.isEmpty {
            let skipNote = skipped.isEmpty ? "" : ", skipped: \(skipped.joined(separator: ", "))"
            print("Self-test passed (\(passed) checks\(skipNote))")
            return 0
        }
        print("Self-test failed: \(failures.count) of \(passed + failures.count) checks")
        return 1
    }

    private static func parserChecks() {
        let list = PlainParser.profiles("default\tClaude\t-\t1\t/Applications/Claude.app\t/h/.claude\t/h/data\nwork\tWork\t#3a7bd5\t0\t-\t/h/.claude-work\t-\textra\nbogus\n")
        expect(list.count == 2, "list parser keeps two rows and drops short ones")
        expect(list.last?.color == "#3a7bd5" && list.last?.isDesktop == false && list.last?.dataDir == nil, "list parser maps - to nil")

        let scan = PlainParser.scan("""
        config\t/h/.claude\t41
        data\t/h/Library/Application Support/Claude-Work
        project\t/h/.claude\t/h/dev/app\t5\t2026-10-09T11:45:10+0200\t-
        candidate\t/Applications/Claude Work.app\t/Applications/Claude Work Launcher.app\tcom.example.work\t/h/data\t-\tWork\tWork Signing\tfuture
        mystery\tcolumn
        candidate\t/Applications/Claude Two.app\t-\tcom.example.two
        """)
        expect(scan.configs.first?.projectCount == 41, "scan parser reads config rows")
        expect(scan.dataDirs.count == 1, "scan parser reads data rows")
        expect(scan.projects.first?.sessions == 5 && scan.projects.first?.lastUsed != nil && scan.projects.first?.owner == nil, "scan parser reads project rows")
        expect(scan.candidates.count == 2, "scan parser reads candidate rows and ignores unknown types")
        expect(scan.candidates.first?.configDir == nil && scan.candidates.first?.name == "Work", "candidate parser maps - and names")
        expect(scan.candidates.last?.name == "Two" && scan.candidates.last?.launcher == nil, "candidate parser tolerates missing columns")
        expect(scan.candidates.first?.identity == "Work Signing" && scan.candidates.last?.identity == nil, "candidate parser reads the signing identity column")

        let show = PlainParser.profileDetails("slug\twork\ncli\t1\napp\t-\ndir\t/h/dev\ndir\t/h/other\nnew_key\tvalue\textra")
        expect(show.value("slug") == "work" && show.flag("cli") == true && show.value("app") == nil, "show parser reads fields")
        expect(show.dirs == ["/h/dev", "/h/other"], "show parser collects dir rows")
        let layout = PlainParser.profileDetails("slug\twork\nlayout\tlegacy\nlauncher\t/A/Claude Work Launcher.app")
        expect(layout.usesLegacyLayout && PlainParser.profileDetails("layout\thidden").usesLegacyLayout == false && PlainParser.profileDetails("layout\t-").value("layout") == nil, "show parser reads the layout row")
        let selfMode = PlainParser.profileDetails("slug\twork\nlauncher\t-\nlayout\tself\nmode\tself\ndock\tnot_pinned")
        expect(selfMode.isSelfMode && !selfMode.canMoveToSelfMode && selfMode.value("launcher") == nil && !selfMode.dockNeedsFix, "show parser reads self mode")
        let launcherMode = PlainParser.profileDetails("slug\twork\nlayout\thidden\nmode\tlauncher")
        expect(!launcherMode.isSelfMode && launcherMode.canMoveToSelfMode, "show parser offers the move to self mode for a launcher profile")
        expect(PlainParser.profileDetails("slug\twork\nlayout\tlegacy").canMoveToSelfMode && !PlainParser.profileDetails("slug\twork\nlayout\thidden").canMoveToSelfMode && PlainParser.profileDetails("mode\t-").mode == nil, "show parser tolerates a CLI without the mode row")
        let dock = PlainParser.profileDetails("slug\twork\ndock\tcopy_pinned")
        expect(dock.dockNeedsFix && PlainParser.profileDetails("dock\told_launcher_pinned").dockNeedsFix, "show parser flags a pinned app copy or a dead launcher pin")
        expect(!PlainParser.profileDetails("dock\tok").dockNeedsFix && !PlainParser.profileDetails("dock\tlauncher_missing").dockNeedsFix && !PlainParser.profileDetails("dock\t-").dockNeedsFix && !PlainParser.profileDetails("slug\twork").dockNeedsFix, "show parser leaves the Dock alone in the other states")
        let blockers = PlainParser.legacyAgents("agent\tcom.example.rebuild\t/h/Library/LaunchAgents/com.example.rebuild.plist\t0\t/bin/zsh /h/x.sh")
        expect(blockers.count == 1 && blockers[0].label == "com.example.rebuild", "migrate-layout blocker rows use the legacy-agents format")
        let human = PlainParser.profileDetails("slug        work\ncolor       #3a7bd5 (hue shift 10, saturation x1)\napp         /A/Claude Work.app (built, 1.0)\ndirs        /a, /b")
        expect(human.value("color") == "#3a7bd5" && human.value("app") == "/A/Claude Work.app" && human.dirs == ["/a", "/b"], "show parser falls back to the human format")

        let status = PlainParser.status("cli_installed\t1\t/h/.local/bin/claude-profiles\ncli_current\t0\nidentity\tClaude Profiles Signing\t1\t0\nagent\tlabel\t1\nsource\t/Applications/Claude.app\t1.0\t1\nhandler\tclaude\tcom.example\nhome\t/h/.config/claude-profiles\nlater\tx")
        expect(status.cliInstalled == true && status.cliCurrent == false && status.identityUsable == false && status.agentLoaded == true && status.sourceTeamOK == true && status.home != nil, "status parser")

        let reorderedStatus = PlainParser.status("home\t/h/.config/claude-profiles\nfuture_row\tnew\tvalues\nhandler\tclaude\tcom.example\textra\nsource\t/Applications/Claude.app\t1.0\t1\textra\nagent\tlabel\t1\textra\ncli_probe\t1\nidentity\tClaude Profiles Signing\t1\t0\t9\ncli_current\t0\textra\nanother_unknown\ncli_installed\t1\t/h/.local/bin/claude-profiles\textra")
        expect(reorderedStatus.cliInstalled == true && reorderedStatus.cliPath == "/h/.local/bin/claude-profiles" && reorderedStatus.cliCurrent == false, "status parser reads the command-line tool rows by key, in any order")
        expect(reorderedStatus.identityName == "Claude Profiles Signing" && reorderedStatus.identityPresent == true && reorderedStatus.identityUsable == false, "status parser reads the identity row by key among unknown rows")
        expect(reorderedStatus.agentLabel == "label" && reorderedStatus.agentLoaded == true && reorderedStatus.sourceTeamOK == true && reorderedStatus.handlerBundleID == "com.example" && reorderedStatus.home == "/h/.config/claude-profiles", "status parser ignores unknown rows and extra columns")
        let legacyStatus = PlainParser.status("cli_installed\t1\t/h/.local/bin/claude-profiles\nidentity\tClaude Profiles Signing\t1\t1\nagent\tlabel\t1")
        expect(legacyStatus.cliCurrent == nil && legacyStatus.identityUsable == true && legacyStatus.agentLoaded == true, "status parser tolerates a CLI without the cli_current row")
        let reorderedShell = PlainParser.shellStatus("future\tx\nconflict\t~/.zshrc:3: alias claude=x\textra\ninstalled\t1\t/h/.zshrc\textra")
        expect(reorderedShell.installed && reorderedShell.rcFile == "/h/.zshrc" && reorderedShell.conflicts == ["~/.zshrc:3: alias claude=x extra"], "shell-init status parser reads rows by key in any order")
        let reorderedScan = PlainParser.scan("future\tx\ndata\t/h/data\textra\nproject\t/h/.claude\t/h/dev/app\t2\t-\t-\textra\nconfig\t/h/.claude\t1\textra\nnoise")
        expect(reorderedScan.configs.count == 1 && reorderedScan.dataDirs == ["/h/data"] && reorderedScan.projects.first?.sessions == 2, "scan parser reads rows by key among unknown rows")

        let shell = PlainParser.shellStatus("installed\t1\t/h/.zshrc\nconflict\t~/.zshrc:3: alias claude=x")
        expect(shell.installed && shell.conflicts == ["~/.zshrc:3: alias claude=x"], "shell-init status parser")

        let agents = PlainParser.legacyAgents("agent\tcom.example.rebuild\t/h/Library/LaunchAgents/com.example.rebuild.plist\t1\t/bin/zsh /h/x.sh auto\nnoise")
        expect(agents.count == 1 && agents[0].loaded && agents[0].program == "/bin/zsh /h/x.sh auto", "legacy-agents parser")

        let projects = PlainParser.profileProjects("project\t/h/dev/app\t3\t2026-10-09T11:45:10+0200\tsymlink\nproject\t/h/dev/b\t1\t-\tdir")
        expect(projects.count == 2 && projects[0].isSymlink && !projects[1].isSymlink && projects[1].lastUsed == nil, "projects list parser")

        let check = PlainParser.checkLines("work (Work)\nOK    config dir exists\nWARN  agent missing\nFAIL  wrong data dir\nINFO  note\n  entitlement.key")
        expect(check.heading == "work (Work)" && check.lines.map(\.level) == [.ok, .warn, .fail, .info, .detail], "check parser")

        expect(PlainParser.created("Created profile\ncreated\twork\t-")?.slug == "work", "created row parser")
        expect(PlainParser.slugify("  My Work Profile! ") == "my-work-profile", "slugify matches the CLI")
        expect(PlainParser.isValidName("Work") && !PlainParser.isValidName(" Work") && !PlainParser.isValidName("a/b"), "name validation")
        expect(Color(hex: "#3a7bd5")?.hexString == "#3a7bd5", "hex color round trip")
        homeChecks()
    }

    private static func homeChecks() {
        expect(MainActor.assumeIsolated { AppModel(runner: nil).selection } == .home, "the app opens on Home")

        let desktopSelf = Profile(slug: "work", name: "Work", color: "#3a7bd5", isDesktop: true, app: "/A/Claude Work.app", configDir: "/h/.claude-work", dataDir: "/h/d")
        let hidden = Profile(slug: "side", name: "Side", color: nil, isDesktop: true, app: "/A/.hidden/Claude Side.app", configDir: "/h/.claude-side", dataDir: "/h/s")
        let cliOnly = Profile(slug: "ci", name: "Ci", color: "#2ecc71", isDesktop: false, app: nil, configDir: "/h/.claude-ci", dataDir: nil)
        let environment = HomeEnvironment(
            isRunning: { $0 == "/A/Claude Work.app" || $0 == "/Applications/Claude.app" },
            appVersion: { $0 == "/A/Claude Work.app" ? "1.0 (1)" : "0.9 (1)" },
            fileExists: { $0 != "/A/Launcher Side.app" }
        )
        let details = [
            "work": PlainParser.profileDetails("slug\twork\ncli\t1\napp\t/A/Claude Work.app\nlauncher\t-\nmode\tself"),
            "side": PlainParser.profileDetails("slug\tside\ncli\t0\napp\t/A/.hidden/Claude Side.app\nlauncher\t/A/Launcher Side.app\nmode\tlauncher"),
            "ci": PlainParser.profileDetails("slug\tci\ncli\t1\napp\t-\ndir\t/h/dev\ndir\t/h/other"),
        ]
        let status = PlainParser.status("source\t/Applications/Claude.app\t1.0 (1)\t1")
        let cards = HomeCards.cards(sourcePath: "/Applications/Claude.app", status: status, profiles: [desktopSelf, hidden, cliOnly], details: details, environment: environment)
        expect(cards.count == 4 && cards.first?.item == .main && cards.map(\.name) == ["Main Claude", "Work", "Side", "Ci"], "home cards list Main Claude first, then every profile")
        expect(cards[0].chips.map(\.text) == ["Running", "Version 1.0"] && cards[0].action == .open("/Applications/Claude.app"), "main card shows running state and opens Claude.app")
        expect(cards[1].kind == "Desktop app + Terminal" && cards[1].glyph == "W" && cards[1].chips.map(\.text) == ["Running", "Up to date", "Self mode"] && cards[1].action == .open("/A/Claude Work.app"), "self-mode card is running, up to date and opens its app")
        let sameBuild = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0 (1)", environment: environment)
        let newerBuild = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0 (2)", environment: environment)
        expect(sameBuild.chips.map(\.text).contains("Up to date") && newerBuild.chips.map(\.text).contains("Rebuild needed"), "versions compare as the full short (build) string")
        expect(HomeCards.main(sourcePath: "/Applications/Claude.app", sourceVersion: "1.0 (7)", environment: environment).chips.last?.text == "Version 1.0", "versions display without the build suffix")
        let loading = HomeCards.card(for: desktopSelf, details: nil, sourceVersion: "1.0 (1)", environment: environment)
        expect(loading.action == .loading && loading.chips.map(\.text) == ["Loading…"], "a desktop profile whose details are still loading shows a loading state, not a disabled Open")
        expect(HomeCards.card(for: cliOnly, details: nil, sourceVersion: nil, environment: environment).action == .copyCommand("claude-ci"), "a CLI-only profile can copy its command before its details load")
        expect(cards[2].kind == "Desktop app" && cards[2].chips.map(\.text) == ["Rebuild needed", "Launcher mode"] && cards[2].action == .unavailable, "launcher card is outdated and cannot open a missing launcher")
        expect(cards[3].kind == "Terminal only" && cards[3].chips.map(\.text) == ["2 folders"] && cards[3].action == .copyCommand("claude-ci"), "CLI-only card copies its command and counts folders")
        let missingApp = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0", environment: HomeEnvironment(isRunning: { _ in false }, appVersion: { _ in nil }, fileExists: { _ in false }))
        expect(missingApp.chips.first?.text == "Not built" && missingApp.action == .unavailable, "a profile whose app is missing reads as not built")
        expect(HomeCards.main(sourcePath: "/x/Claude.app", sourceVersion: nil, environment: HomeEnvironment(isRunning: { _ in false }, appVersion: { _ in nil }, fileExists: { _ in false })).chips.map(\.text) == ["Not installed"], "main card reports a missing Claude.app")

        let good = PlainParser.status("cli_installed\t1\t/h/.local/bin/claude-profiles\ncli_current\t1\nidentity\tSigning\t1\t1\nagent\tlabel\t1")
        let goodItems = SetupStatus.items(status: good, shell: ShellStatus(installed: true, rcFile: nil, conflicts: []))
        expect(goodItems.map(\.title) == ["Auto-rebuild agent", "Signing identity", "Command-line tool", "Shell integration"] && goodItems.allSatisfy { $0.state == .ok }, "setup status shows four checkmarks when everything is set up")
        let stale = PlainParser.status("cli_installed\t1\t/h/.local/bin/claude-profiles\ncli_current\t0\nidentity\tSigning\t1\t0\nagent\tlabel\t0")
        let staleItems = SetupStatus.items(status: stale, shell: ShellStatus(installed: false, rcFile: nil, conflicts: []))
        expect(staleItems.map(\.state) == [.warning, .warning, .warning, .warning] && staleItems[2].detail == "Out of date" && staleItems[1].detail == "Needs setup", "setup status warns about each missing piece")
        expect(SetupStatus.items(status: nil, shell: nil).allSatisfy { $0.state == .unknown }, "setup status stays neutral before the first refresh")
        expect(CLIUpdatePolicy.decide(bundled: "0.1.0", installed: "0.2.0").shouldInstall == false, "an older app never downgrades a newer installed command-line tool")
        expect(CLIUpdatePolicy.decide(bundled: "0.2.0", installed: "0.1.9").shouldInstall && CLIUpdatePolicy.decide(bundled: "0.1.0", installed: "0.1.0").shouldInstall, "the installed command-line tool is refreshed when the app is newer or the same version")
        expect(CLIUpdatePolicy.decide(bundled: "0.10.0", installed: "0.9.0").shouldInstall && !CLIUpdatePolicy.decide(bundled: "0.9.0", installed: "0.10.0").shouldInstall, "command-line tool versions compare numerically")
        expect(CLIUpdatePolicy.decide(bundled: "0.1.0", installed: nil).shouldInstall && !CLIUpdatePolicy.decide(bundled: nil, installed: "0.1.0").shouldInstall && !CLIUpdatePolicy.decide(bundled: "dev", installed: "0.1.0").shouldInstall, "a missing installed version is updated, an unknown bundled version is left alone")
        expect(Set(goodItems.map(\.anchor)).count == 3, "setup items link to the command-line, shell and rebuild settings sections")
    }

    private static func integrationChecks(script: URL, root: String, home: String, settings: String) throws {
        let fileManager = FileManager.default
        let altConfig = home + "/.claude-alt"
        let project = home + "/dev/project"
        let encoded = altConfig + "/projects/-dev-project"
        for directory in [home, settings, encoded, project, root + "/apps", root + "/launchers", root + "/agents"] {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let sourceApp = ProcessInfo.processInfo.environment["CLAUDE_PROFILES_SELFTEST_SOURCE_APP"] ?? root + "/missing/Claude.app"
        try "SOURCE_APP=\"\(sourceApp)\"\nSIGN_IDENTITY=\"-\"\n".write(toFile: settings + "/config.env", atomically: true, encoding: .utf8)
        try "{}\n".write(toFile: altConfig + "/settings.json", atomically: true, encoding: .utf8)
        try "{\"type\":\"user\",\"cwd\":\"\(project)\"}\n".write(toFile: encoded + "/session.jsonl", atomically: true, encoding: .utf8)

        let runner = CLIRunner(script: script, environmentOverrides: [
            "HOME": home,
            "CLAUDE_PROFILES_HOME": settings,
            "CLAUDE_PROFILES_LOG": root + "/claude-profiles.log",
            "CLAUDE_PROFILES_NO_URL_SET": "1",
            "CLAUDE_PROFILES_AGENTS_DIR": root + "/agents",
            "CLAUDE_PROFILES_APPS_DIR": root + "/apps",
            "CLAUDE_PROFILES_LAUNCHER_DIR": root + "/launchers",
            "SIGN_IDENTITY": "-",
            "SHELL": "/bin/zsh",
        ])

        let counter = Counter()
        let version = call(runner, ["version"], counter: counter)
        expect(version.succeeded && version.stdout.contains("claude-profiles"), "version runs: \(version.failureSummary)")
        expect(counter.count == 1, "stdout lines are streamed (got \(counter.count))")

        let usage = call(runner, ["no-such-command"])
        expect(usage.status == 2 && usage.isUnknownCommand, "unknown commands exit 2")

        let initialList = call(runner, ["list", "--plain"])
        let initialProfiles = PlainParser.profiles(initialList.stdout)
        expect(initialList.succeeded && initialProfiles.count == 1 && initialProfiles.first?.isDefault == true, "list shows only the default profile")
        expect(initialProfiles.first?.configDir == home + "/.claude", "list uses the isolated HOME")

        let scanResult = call(runner, ["scan", "--plain"])
        let scan = PlainParser.scan(scanResult.stdout)
        expect(scanResult.succeeded, "scan runs: \(scanResult.failureSummary)")
        expect(scan.configs.contains { $0.path == altConfig && $0.projectCount == 1 }, "scan finds the fixture config dir")
        expect(scan.projects.contains { $0.cwd == project && $0.sessions == 1 && $0.configDir == altConfig }, "scan finds the fixture project")
        expect(scan.candidates.isEmpty, "scan finds no candidates in an empty apps dir")

        let created = call(runner, ["new", "--name", "Self Test", "--color", "#3a7bd5", "--no-desktop", "--cli",
                                    "--config-dir", home + "/.claude-selftest", "--dir", project, "--yes", "--plain"])
        expect(created.succeeded, "new (CLI-only) succeeds: \(created.failureSummary)")
        expect(PlainParser.created(created.stdout)?.slug == "self-test" && PlainParser.created(created.stdout)?.launcher == nil, "new prints the created row")

        let listed = PlainParser.profiles(call(runner, ["list", "--plain"]).stdout)
        let profile = listed.first { $0.slug == "self-test" }
        expect(listed.count == 2 && profile?.name == "Self Test" && profile?.isDesktop == false && profile?.color == "#3a7bd5", "list shows the new profile")

        let added = call(runner, ["dirs", "self-test", "add", home + "/dev"])
        expect(added.succeeded, "dirs add succeeds: \(added.failureSummary)")
        let dirs = call(runner, ["dirs", "self-test", "list"]).stdout
        expect(dirs.contains(project) && dirs.contains(home + "/dev"), "dirs list shows both folders")
        expect(call(runner, ["dirs", "self-test", "rm", home + "/dev"]).succeeded, "dirs rm succeeds")

        let recolor = call(runner, ["recolor", "self-test", "--color", "#e67e22"])
        expect(recolor.succeeded, "recolor of a CLI-only profile succeeds: \(recolor.failureSummary)")
        expect(PlainParser.profiles(call(runner, ["list", "--plain"]).stdout).first { $0.slug == "self-test" }?.color == "#e67e22", "recolor is stored")

        let show = call(runner, ["show", "self-test", "--plain"])
        if show.succeeded {
            let details = PlainParser.profileDetails(show.stdout)
            expect(details.value("slug") == "self-test" && details.flag("cli") == true && details.value("app") == nil, "show --plain fields")
            expect(details.value("layout") == nil && !details.usesLegacyLayout, "show --plain has no layout for a CLI-only profile")
            expect(details.fields["mode"] == "-" && details.mode == nil && !details.isSelfMode && !details.canMoveToSelfMode, "show --plain prints mode - for a CLI-only profile")
            expect(details.dirs == [project], "show --plain dir rows")
        } else {
            expect(false, "show exited \(show.status): \(show.failureSummary)")
        }

        let migrate = call(runner, ["migrate-layout", "self-test", "--yes"])
        expect(migrate.status == 1 && migrate.stderr.contains("no desktop app"), "migrate-layout refuses a CLI-only profile")

        let projectsBefore = call(runner, ["projects", "self-test", "list", "--plain"])
        if optionalCommand("projects list", projectsBefore) {
            expect(PlainParser.profileProjects(projectsBefore.stdout).isEmpty, "a new profile has no projects")
            let copied = call(runner, ["projects", "self-test", "add", "--mode", "copy", "--no-dir", project])
            expect(copied.succeeded, "projects add --mode copy succeeds: \(copied.failureSummary)")
            let after = PlainParser.profileProjects(call(runner, ["projects", "self-test", "list", "--plain"]).stdout)
            expect(after.count == 1 && after.first?.cwd == project && after.first?.isSymlink == false && after.first?.sessions == 1, "projects list shows the copied project")
        }

        let status = call(runner, ["status", "--plain"])
        if optionalCommand("status", status) {
            let summary = PlainParser.status(status.stdout)
            expect(summary.home == settings, "status reports the isolated settings folder")
            expect(summary.cliInstalled == false, "status reports the CLI as not installed")
            expect(summary.agentLoaded != nil && summary.identityPresent != nil, "status reports the agent and identity")
            if !FileManager.default.fileExists(atPath: sourceApp) {
                expect(summary.sourceApp == sourceApp && summary.sourceVersion == nil && summary.sourceTeamOK == false, "status reports a missing source app with empty values")
            }
        }

        let shell = call(runner, ["shell-init", "status", "--plain"])
        if optionalCommand("shell-init status", shell) {
            expect(PlainParser.shellStatus(shell.stdout).installed == false, "shell integration is not installed in the isolated home")
        }

        let agents = call(runner, ["legacy-agents", "--plain"])
        if optionalCommand("legacy-agents", agents) {
            expect(PlainParser.legacyAgents(agents.stdout).isEmpty, "no legacy agents in the isolated agents dir")
        }

        let cliRoot = script.deletingLastPathComponent().deletingLastPathComponent().path
        let install = call(runner, ["install-cli", "--from", cliRoot])
        if optionalCommand("install-cli", install) {
            let installed = home + "/.local/share/claude-profiles/bin/claude-profiles"
            expect(fileManager.fileExists(atPath: installed), "install-cli copies the tool into the isolated home")
            let after = PlainParser.status(call(runner, ["status", "--plain"]).stdout)
            expect(after.cliInstalled == true && after.cliCurrent == true, "status reports the CLI as installed and current after install-cli")
        }

        let removed = call(runner, ["remove", "self-test", "--delete-config", "--yes"])
        expect(removed.succeeded, "remove succeeds: \(removed.failureSummary)")
        expect(PlainParser.profiles(call(runner, ["list", "--plain"]).stdout).count == 1, "list is back to the default profile")
        expect(!fileManager.fileExists(atPath: home + "/.claude-selftest"), "remove --delete-config deletes the profile config dir")
    }
}
