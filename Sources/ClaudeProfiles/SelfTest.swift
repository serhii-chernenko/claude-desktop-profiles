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
        updateMenuChecks()
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
            try liveVersionChecks(root: root)
        } catch {
            failures.append("live version fixture failed: \(error)")
        }
        do {
            try relaunchGuardChecks(root: root)
        } catch {
            failures.append("relaunch guard fixture failed: \(error)")
        }
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

    private static func relaunchGuardChecks(root: String) throws {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        func runGuard(waitingFor pid: Int32? = nil, processName: String, marker: String) -> Bool {
            let arguments = RelaunchGuard.arguments(waitingFor: pid ?? finished.processIdentifier, quitWaitLimit: 0, installerLabel: "",
                                                    settleDelay: 0, processName: processName,
                                                    opener: "/usr/bin/touch", target: marker)
            guard let process = RelaunchGuard.start(arguments) else { return false }
            process.waitUntilExit()
            return FileManager.default.fileExists(atPath: marker)
        }
        expect(runGuard(processName: "claude-profiles-no-such-process", marker: root + "/relaunch-missing"), "the relaunch guard reopens the app when nothing relaunched it after the update")
        expect(!runGuard(processName: ProcessInfo.processInfo.processName, marker: root + "/relaunch-running"), "the relaunch guard leaves the app alone when the update already relaunched it")
        expect(!runGuard(waitingFor: ProcessInfo.processInfo.processIdentifier, processName: "claude-profiles-no-such-process", marker: root + "/relaunch-never-quit"), "the relaunch guard gives up without reopening when the app never quits")
    }

    private static func updateMenuChecks() {
        let matching = ["Check for Updates…", "Check for updates...", "Check For Update", "check for updates", "  Check for Updates…  ", "CHECK FOR UPDATES…"]
        for name in matching {
            expect(ClaudeUpdateCheck.isUpdateMenuItem(name), "update menu matcher accepts \"\(name)\"")
        }
        let rejected = ["", "About Claude", "Checking for Updates…", "Check for Claude Updates", "Updates", "Settings…", "Quit Claude"]
        for name in rejected {
            expect(!ClaudeUpdateCheck.isUpdateMenuItem(name), "update menu matcher rejects \"\(name)\"")
        }
        let launch = Date(timeIntervalSince1970: 1_000_000)
        expect(UpdatePromptPolicy.promptsWhenReady(launchedAt: launch, now: launch.addingTimeInterval(20), alreadyPrompted: false), "an update that is ready right after launch is announced with a prompt")
        expect(!UpdatePromptPolicy.promptsWhenReady(launchedAt: launch, now: launch.addingTimeInterval(20), alreadyPrompted: true), "the ready-update prompt is shown at most once per launch")
        expect(!UpdatePromptPolicy.promptsWhenReady(launchedAt: launch, now: launch.addingTimeInterval(UpdatePromptPolicy.launchWindow + 1), alreadyPrompted: false), "an update that becomes ready later in the session only shows the banner")
        let output = "2\tClaude\t1\tAbout Claude\n2\tClaude\t2\tCheck for Updates…\n3\tFile\t1\tCheck for Update\nbroken line\nx\tFile\t1\tNope\n"
        let entries = ClaudeUpdateCheck.parseMenuEntries(output)
        expect(entries.count == 3 && entries[1] == MenuEntry(menuIndex: 2, menuName: "Claude", itemIndex: 2, itemName: "Check for Updates…"), "menu entry parser keeps well-formed rows and drops malformed ones")
        expect(ClaudeUpdateCheck.updateMenuItem(in: entries)?.itemIndex == 2 && ClaudeUpdateCheck.updateMenuItem(in: entries)?.menuIndex == 2, "update item is found in the first menu")
        let laterOnly = [MenuEntry(menuIndex: 2, menuName: "Claude", itemIndex: 1, itemName: "About Claude"), MenuEntry(menuIndex: 5, menuName: "Help", itemIndex: 3, itemName: "Check for updates...")]
        expect(ClaudeUpdateCheck.updateMenuItem(in: laterOnly)?.menuName == "Help", "update item falls back to the other menus")
        expect(ClaudeUpdateCheck.updateMenuItem(in: [MenuEntry(menuIndex: 2, menuName: "Claude", itemIndex: 1, itemName: "About Claude")]) == nil && ClaudeUpdateCheck.updateMenuItem(in: []) == nil, "no update item is reported when none matches")
        expect(ClaudeUpdateCheck.accessibilityPaneName(majorVersion: 26).hasPrefix("Accessibility") && ClaudeUpdateCheck.accessibilityPaneName(majorVersion: 27).hasPrefix("Device Control and Data Access") && ClaudeUpdateCheck.accessibilityPaneName(majorVersion: 26).contains("Device Control and Data Access"), "the Accessibility pane is named for the OS version and mentions both names")
        expect(ClaudeUpdateCheck.isPermissionFailure("execution error: Not authorized to send Apple events to System Events. (-1743)") && ClaudeUpdateCheck.isPermissionFailure("osascript is not allowed assistive access. (-25211)") && !ClaudeUpdateCheck.isPermissionFailure("Can’t get application process. (-1728)"), "permission failures are told apart from a missing process")
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
        ownerChecks()
        homeChecks()
        worktreeChecks()
    }

    private static func worktreeChecks() {
        let listing = PlainParser.worktrees("""
        profile\tmain\tClaude\t/Users/example/Library/Application Support/Claude\t0\t1
        worktree\tmain\tbrave-otter\t/Users/example/.claude/worktrees/brave-otter\t/Users/example/dev/app\tclaude/brave-otter\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t20480\t1\t-\tFix the login flow
        worktree\tmain\tquiet-fern\t/Users/example/.claude/worktrees/quiet-fern\t/Users/example/dev/app\tclaude/quiet-fern\tkept\t2026-10-20T10:00:00+0200\t16\t1\t-\t0\tdirty\t-
        profile\twork\tWork\t/Users/example/Library/Application Support/Claude-Work\t1\t1
        worktree\twork\tspare-1\t/Users/example/.claude/worktrees/spare-1\t-\t-\tpool\t-\t0\t-\t-\t0\trecent\t-\textra\tcolumns
        worktree\twork\told-one\t/Users/example/.claude/worktrees/old-one\t/Users/example/dev/api\tmain\tfuturestate\t2026-10-30T10:00:00+0100\t6\t0\t512\t1
        worktree\twork\tshort\t/Users/example/x
        mystery\trow\there
        profile\tempty\tEmpty\t-\t0\t0
        """)
        expect(listing.profiles.count == 3 && listing.entries.count == 4, "worktrees parser keeps every profile and worktree row and drops short and unknown ones")
        expect(listing.profiles[0].id == "main" && listing.profiles[0].name == "Claude" && !listing.profiles[0].isRunning && listing.profiles[0].hasRegistry, "worktrees parser reads the main profile row")
        expect(listing.profiles[1].isRunning && listing.profiles[2].dataDir == nil && !listing.profiles[2].hasRegistry, "worktrees parser reads running, registry and a - data dir")
        let first = listing.entries[0]
        expect(first.profileID == "main" && first.name == "brave-otter" && first.repoName == "app" && first.branch == "claude/brave-otter" && first.state == .archived, "worktrees parser reads the identity columns")
        expect(first.lastActive != nil && first.idleDays == 65 && first.isDirty == false && first.sizeKB == 20480 && first.isEligible && first.reason == nil && first.sessionTitle == "Fix the login flow", "worktrees parser reads the age, size, eligibility and title columns")
        let kept = listing.entries[1]
        expect(kept.state == .kept && kept.isDirty == true && kept.sizeKB == nil && !kept.isEligible && kept.reason == "dirty" && kept.sessionTitle == nil, "worktrees parser maps - to nil and keeps the first failing reason")
        let spare = listing.entries[2]
        expect(spare.state == .pool && spare.repo == nil && spare.branch == nil && spare.lastActive == nil && spare.isDirty == nil && spare.reason == "recent", "worktrees parser tolerates - in every optional column and extra columns")
        expect(listing.entries[3].state == .unknown && listing.entries[3].reason == nil && listing.entries[3].sessionTitle == nil, "worktrees parser falls back to the unknown state and tolerates missing trailing columns")
        expect(Set(listing.entries.map(\.id)).count == listing.entries.count, "worktrees parser gives every row a unique id")
        let twice = PlainParser.worktrees("worktree\tmain\ta\t/Users/example/dev/app/.claude/worktrees/a\t/Users/example/dev/app\tb\tactive\t2026-09-01T10:00:00+0200\t65\t0\t10\t0\tduplicate\t-\nworktree\tmain\ta\t/Users/example/dev/app/.claude/worktrees/a\t/Users/example/dev/app\tb\tactive\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\t-")
        expect(twice.entries.count == 2 && twice.entries[0].id != twice.entries[1].id && twice.entries[0].reason == "duplicate", "worktrees parser keeps duplicate rows with distinct ids")
        let reasons = ["bad_path", "outside", "duplicate", "detached", "no_timestamp"]
        let reasonRows = reasons.map { "worktree\tmain\tw\t/Users/example/w\t/Users/example/dev/app\tb\tactive\t2026-09-01T10:00:00+0200\t65\t0\t10\t0\t\($0)\t-" }.joined(separator: "\n")
        let parsedReasons = PlainParser.worktrees(reasonRows).entries.compactMap(\.reason)
        expect(parsedReasons == reasons, "worktrees parser reads the newer eligibility reasons")
        expect(parsedReasons.allSatisfy { WorktreeCopy.reasonText($0, days: 30) != $0 }, "every known eligibility reason has plain wording")
        expect(WorktreeCopy.reasonText("recent", days: 7) == "Used in the last 7 days" && WorktreeCopy.reasonText("future_reason", days: 7) == "future_reason" && WorktreeCopy.reasonText(nil, days: 7) == nil, "worktree reason wording keeps unknown reasons as they are")
        expect(PlainParser.worktrees("").entries.isEmpty && PlainParser.worktrees("worktree\tmain").entries.isEmpty, "worktrees parser handles empty and truncated output")

        let clean = PlainParser.worktreeClean("""
        blocked\twork\trunning
        removed\tmain\t/Users/example/.claude/worktrees/brave-otter\t20480
        would_remove\tmain\t/Users/example/.claude/worktrees/quiet-fern\t-
        failed\tmain\t/Users/example/.claude/worktrees/stuck\tfatal: cannot remove a locked working tree
        removed\tmain
        summary\t1\t20480\t1\t1\textra
        mystery\trow
        """)
        expect(clean.rows(.blocked).count == 1 && clean.rows(.blocked)[0].profileID == "work" && clean.rows(.blocked)[0].message == "running", "worktree clean parser reads blocked rows")
        expect(clean.rows(.removed).count == 1 && clean.rows(.removed)[0].sizeKB == 20480 && clean.rows(.wouldRemove).count == 1 && clean.rows(.wouldRemove)[0].sizeKB == nil, "worktree clean parser reads removed and would_remove rows")
        expect(clean.rows(.failed).count == 1 && clean.rows(.failed)[0].message == "fatal: cannot remove a locked working tree", "worktree clean parser reads failed rows")
        expect(clean.summary == WorktreeCleanSummary(removed: 1, freedKB: 20480, failed: 1, blocked: 1), "worktree clean parser reads the summary row")
        expect(PlainParser.worktreeClean("noise").summary == nil && PlainParser.worktreeClean("").rows.isEmpty, "worktree clean parser handles output without a summary")
        let skipped = PlainParser.worktreeClean("skipped\tmain\t/Users/example/dev/app/.claude/worktrees/a\tdirty\nskipped\t-\t/Users/example/gone\tnot_found\nskipped\tmain")
        expect(skipped.rows(.skipped).map(\.message) == ["dirty", "not_found"] && skipped.rows(.skipped)[1].profileID == "-", "worktree clean parser reads skipped rows and drops short ones")
        expect(WorktreeCopy.reasonText("not_found", days: 30) == "No longer listed", "skipped reasons have plain wording")
        expect(listing.entries[0].isSelectable && spare.isSelectable && !kept.isSelectable, "eligible and only-too-recent worktrees can be selected, blocked ones cannot")
        expect(listing.entries[0].selectionKey != twice.entries[0].selectionKey && twice.entries[0].selectionKey == twice.entries[1].selectionKey, "a worktree's selection key is its profile and path")

        let caches = PlainParser.caches("""
        profile\tmain\tClaude\t/Users/example/Library/Application Support/Claude\t1
        cache\tmain\tCode Cache\tweb\t402216
        cache\tmain\tPartitions/preview/Cache\tpane\t-
        cache\tmain\tclaude-code/2.1.9\tversion\t269476
        cache\tmain\tclaude-code-vm/2.1.9\tversion\t1
        cache\tmain\tSomething\tfuture\t10
        cache\tmain\t\tweb\t10
        cache\tmain
        """)
        expect(caches.profiles.count == 1 && caches.profiles[0].isRunning && caches.items.count == 5, "caches parser reads profiles and drops short or empty rows")
        expect(caches.items[1].sizeKB == nil && caches.items[4].kind == .unknown && caches.items[0].id == "main:Code Cache", "caches parser maps - sizes, unknown kinds and ids")
        expect(WorktreeCopy.cacheTitle(caches.items[0]) == "App · Script cache" && WorktreeCopy.cacheTitle(caches.items[1]) == "Browser pane preview · Web cache", "cache titles name app and browser pane caches")
        expect(WorktreeCopy.cacheTitle(caches.items[2]) == "Claude Code 2.1.9 (older version)" && WorktreeCopy.cacheTitle(caches.items[3]) == "Claude Code for the VM 2.1.9 (older version)" && WorktreeCopy.cacheTitle(caches.items[4]) == "Something", "cache titles name old versions and fall back to the path")
        storageChecks(oldListing: listing)
    }

    private static func storageChecks(oldListing: WorktreeList) {
        expect(oldListing.entries.allSatisfy { $0.branchState == .unknown && !$0.canChooseBranchDeletion }, "old 13-column worktree rows still parse and offer no branch deletion")

        let branches = PlainParser.worktrees("""
        worktree\tmain\ta\t/Users/example/w/a\t/Users/example/dev/app\tclaude/a\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\tTitle A\tsaved\tclaude/a
        worktree\tmain\tb\t/Users/example/w/b\t/Users/example/dev/app\tclaude/b\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\t-\tunsaved:3\tclaude/b
        worktree\tmain\tc\t/Users/example/w/c\t/Users/example/dev/app\t-\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\t-\tnone\t-
        worktree\tmain\td\t/Users/example/w/d\t/Users/example/dev/app\tclaude/d\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\t-\t-\t-
        worktree\tmain\te\t/Users/example/w/e\t/Users/example/dev/app\tclaude/e\tarchived\t2026-09-01T10:00:00+0200\t65\t0\t10\t1\t-\t-\tunsaved:0\tclaude/e\textra
        """).entries
        expect(branches.count == 5 && branches[0].sessionTitle == "Title A" && branches[1].sessionTitle == nil, "worktree rows keep the title at column 13 next to the branch columns")
        expect(branches[0].branchState == .saved && branches[0].branchName == "claude/a", "worktree branch state saved is parsed with the branch name")
        expect(branches[1].branchState == .unsaved(3) && branches[1].branchState.unsavedCommits == 3 && branches[1].branchName == "claude/b", "worktree branch state unsaved:3 parses to 3 commits")
        expect(branches[2].branchState == .noBranch && branches[2].branchName == nil && branches[3].branchState == .unknown, "worktree branch states none and - are parsed")
        expect(branches[4].branchState == .unknown, "an unsaved count of zero is not a valid branch state")
        expect(branches[0].deletesBranchByDefault && !branches[1].deletesBranchByDefault && !branches[2].deletesBranchByDefault && !branches[3].deletesBranchByDefault, "branch deletion defaults to on for saved branches only")
        expect(branches[0].canChooseBranchDeletion && branches[1].canChooseBranchDeletion && !branches[2].canChooseBranchDeletion && !branches[3].canChooseBranchDeletion, "branch deletion can be chosen for saved and unsaved branches only")

        let clean = PlainParser.worktreeClean("""
        removed\tmain\t/Users/example/w/a\t100
        branch_deleted\tmain\t/Users/example/w/a\tclaude/a\t0
        removed\tmain\t/Users/example/w/b\t200
        branch_kept\tmain\t/Users/example/w/b\tclaude/b\tunsaved\t3
        would_delete_branch\tmain\t/Users/example/w/c\tclaude/c\t2
        would_keep_branch\tmain\t/Users/example/w/d\tclaude/d\tchecked_out\t0
        branch_kept\tmain\t/Users/example/w/e\tclaude/e\tfailed:cannot lock ref\t0
        branch_deleted\tmain
        summary\t2\t300\t0\t0\t1\t2
        """)
        expect(clean.rows(.branchDeleted).count == 1 && clean.rows(.branchDeleted)[0].branch == "claude/a" && clean.rows(.branchDeleted)[0].unsavedCommits == 0, "worktree clean parser reads branch_deleted rows")
        expect(clean.rows(.branchKept).count == 2 && clean.rows(.branchKept)[0].message == "unsaved" && clean.rows(.branchKept)[0].unsavedCommits == 3 && clean.rows(.branchKept)[1].message == "failed:cannot lock ref", "worktree clean parser reads branch_kept rows with their reason")
        expect(clean.rows(.wouldDeleteBranch).first?.unsavedCommits == 2 && clean.rows(.wouldKeepBranch).first?.message == "checked_out" && clean.rows(.wouldKeepBranch).first?.branch == "claude/d", "worktree clean parser reads the dry-run branch rows")
        expect(clean.summary?.branchesDeleted == 1 && clean.summary?.branchesKept == 2 && clean.branchesDeleted == 1 && clean.branchesKept == 2, "worktree clean summary reads the optional branch columns")
        let withoutBranchColumns = PlainParser.worktreeClean("removed\tmain\t/x\t1\nsummary\t1\t1\t0\t0")
        expect(withoutBranchColumns.summary?.branchesDeleted == nil && withoutBranchColumns.branchesDeleted == 0 && withoutBranchColumns.branchesKept == 0, "worktree clean summary without branch columns still parses")
        let outcome = WorktreeCopy.outcome(for: CommandResult(status: 0, stdout: "removed\tmain\t/Users/example/w/b\t200\nbranch_kept\tmain\t/Users/example/w/b\tclaude/b\tunsaved\t3\nsummary\t1\t200\t0\t0\t0\t1", stderr: "", timedOut: false),
                                           names: ["main": "Claude"], noun: "worktree") { $0 }
        expect(outcome.text.contains("Branches: 0 deleted, 1 kept.") && outcome.details == ["Branch claude/b: kept, 3 commits found nowhere else"] && !outcome.isProblem, "the worktree outcome counts branches and explains kept ones")
        expect(WorktreeCopy.branchKeptText("protected", unsavedCommits: 0) == "Default branch, kept", "a protected branch reads as the default branch being kept")
        expect(WorktreeCopy.branchKeptText("checked_out", unsavedCommits: 0) == "kept, still checked out in another worktree" && WorktreeCopy.branchKeptText("kept_by_flag", unsavedCommits: nil) == "kept as requested" && WorktreeCopy.branchKeptText("unsaved", unsavedCommits: 2) == "kept, 2 commits found nowhere else" && WorktreeCopy.branchKeptText("failed: cannot lock ref", unsavedCommits: 0) == "could not be deleted: cannot lock ref", "every branch_kept reason has a display text")
        let protectedOutcome = WorktreeCopy.outcome(for: CommandResult(status: 0, stdout: "removed\tmain\t/Users/example/w/p\t10\nbranch_kept\tmain\t/Users/example/w/p\tdevelop\tprotected\t1\nsummary\t1\t10\t0\t0\t0\t1", stderr: "", timedOut: false),
                                                    names: ["main": "Claude"], noun: "worktree") { $0 }
        expect(protectedOutcome.details == ["Branch develop: Default branch, kept"] && !protectedOutcome.isProblem, "the worktree outcome explains a protected branch without flagging a problem")

        let chosenForArguments = Array(branches[0...3])
        let switchedOn: Set<String> = [branches[1].path]
        let choice: (WorktreeEntry) -> Bool = { switchedOn.contains($0.path) || $0.deletesBranchByDefault }
        let mixedArguments = WorktreeCopy.worktreeCleanArguments(target: "all", entries: chosenForArguments, keepsAllBranches: false, includeUncommitted: true, deletesBranch: choice)
        expect(mixedArguments == ["worktrees", "--all", "clean", "--path", "/Users/example/w/a", "--path", "/Users/example/w/b", "--path", "/Users/example/w/c", "--path", "/Users/example/w/d", "--delete-branch", "/Users/example/w/b", "--include-uncommitted", "--yes", "--plain"], "clean arguments delete-branch only for unsaved rows switched on and skip rows without a branch choice")
        let defaultArguments = WorktreeCopy.worktreeCleanArguments(target: "main", entries: Array(branches[0...1]), keepsAllBranches: false, includeUncommitted: false) { $0.deletesBranchByDefault }
        expect(defaultArguments == ["worktrees", "main", "clean", "--path", "/Users/example/w/a", "--path", "/Users/example/w/b", "--keep-branch", "/Users/example/w/b", "--yes", "--plain"], "clean arguments keep an unsaved branch by default and pass nothing for a saved one")
        let savedOff = WorktreeCopy.worktreeCleanArguments(target: "work", entries: [branches[0]], keepsAllBranches: false, includeUncommitted: false) { _ in false }
        expect(savedOff == ["worktrees", "work", "clean", "--path", "/Users/example/w/a", "--keep-branch", "/Users/example/w/a", "--yes", "--plain"], "clean arguments pass --keep-branch for a saved branch switched off")
        let keepAll = WorktreeCopy.worktreeCleanArguments(target: "all", entries: Array(branches[0...1]), keepsAllBranches: true, includeUncommitted: false) { _ in true }
        expect(keepAll == ["worktrees", "--all", "clean", "--path", "/Users/example/w/a", "--path", "/Users/example/w/b", "--keep-branches", "--yes", "--plain"], "keeping all branches passes --keep-branches and no per-path flags")

        let cacheListing = PlainParser.caches("cache\tmain\tCode Cache\tweb\t100\ncache\tmain\tvm_bundles/claudevm.bundle/rootfs.img\tvm\t9000000")
        expect(cacheListing.items.count == 2 && cacheListing.items[1].kind == .vm && WorktreeCopy.cacheTitle(cacheListing.items[1]) == "Cowork VM disk", "caches parser reads the vm kind")
        expect(cacheListing.items.filter(\.isPreselectedForCleanup).map(\.kind) == [.web], "the Cowork VM disk is not preselected for cleanup")
        let unsortedCaches = PlainParser.caches("cache\tmain\tA\tweb\t-\ncache\tmain\tB\tweb\t5\ncache\tmain\tC\tversion\t900\ncache\tmain\tD\tpane\t40")
        expect(unsortedCaches.items.sorted(by: CacheItem.biggestFirst).map(\.relativePath) == ["C", "D", "B", "A"], "lists sort biggest first, unknown sizes last")

        let storage = PlainParser.storage("""
        profile\tmain\tClaude\t/Users/example/Library/Application Support/Claude\t/Users/example/.claude\t1
        area\tmain\tdata\tCache\tcache\t402216\tcaches
        area\tmain\tdata\tvm_bundles\tvm\t9000000\tcaches
        area\tmain\tconfig\tprojects\thistory\t5000\thistory
        area\tmain\tconfig\tsettings.json\tother\t-\t-
        area\tmain\tworktrees\t-\tworktrees\t300\tworktrees\textra
        area\tmain\tdata\tWeird\tfuture\t4
        area\tmain\tdata
        total\tmain\t9407520
        profile\tci\tCi\t-\t/Users/example/.claude-ci\t0
        shared\tci\t/Users/example/.claude-ci\tmain
        total\tci\tnope
        noise
        """)
        expect(storage.profiles.count == 2 && storage.profiles[0].isRunning && storage.profiles[0].configDir == "/Users/example/.claude" && storage.profiles[1].dataDir == nil && !storage.profiles[1].isRunning, "storage parser reads profile rows with data and config dirs")
        expect(storage.areas.count == 6 && storage.areas[0].location == .data && storage.areas[0].kind == .cache && storage.areas[0].tool == .caches && storage.areas[1].kind == .vm, "storage parser reads area rows")
        expect(storage.areas[2].kind == .history && storage.areas[2].tool == .history && storage.areas[3].sizeKB == nil && storage.areas[3].tool == .nothing, "storage parser maps history areas, - sizes and the - tool")
        expect(storage.areas[4].location == .worktrees && storage.areas[4].entry == "-" && storage.areas[4].tool == .worktrees && storage.areas[5].kind == .other && storage.areas[5].tool == .nothing, "storage parser reads the worktrees area, extra columns and unknown kinds")
        expect(storage.totals == ["main": 9407520] && storage.totalKB(of: "main") == 9407520 && storage.totalKB(of: "ci") == 0 && storage.grandTotalKB == 9407520, "storage parser reads totals and ignores unparsable ones")
        expect(storage.shared == [SharedConfig(profileID: "ci", configDir: "/Users/example/.claude-ci", ownerID: "main")], "storage parser reads shared config rows")
        expect(storage.areas(of: "main").count == 6 && Set(storage.areas.map(\.id)).count == storage.areas.count, "storage areas have unique ids")
        expect(PlainParser.storage("").profiles.isEmpty && PlainParser.storage("area\tmain").areas.isEmpty, "storage parser handles empty and truncated output")

        let history = PlainParser.history("""
        profile\tmain\tClaude\t/Users/example/.claude\t0
        project\tmain\t-Users-example-dev-app\t/Users/example/dev/app\t12\t4096\t3
        project\tmain\t-Users-example-gone\t-\t1\t-\t-
        project\tmain\t\t/x\t1\t1\t1
        project\tmain\tshort
        profile\tci\tCi\t/Users/example/.claude-ci\t1
        shared\tdup\t/Users/example/.claude\tmain
        noise
        """)
        expect(history.profiles.count == 2 && history.profiles[0].configDir == "/Users/example/.claude" && history.profiles[1].isRunning && history.profiles[0].dataDir == nil, "history parser reads profile rows")
        expect(history.projects.count == 2 && history.projects[0].cwd == "/Users/example/dev/app" && history.projects[0].sessions == 12 && history.projects[0].sizeKB == 4096 && history.projects[0].lastDays == 3, "history parser reads project rows")
        expect(history.projects[1].cwd == nil && history.projects[1].sizeKB == nil && history.projects[1].lastDays == nil && history.projects[1].id == "main:-Users-example-gone", "history parser maps - columns and builds ID:NAME ids")
        expect(history.shared == [SharedConfig(profileID: "dup", configDir: "/Users/example/.claude", ownerID: "main")], "history parser reads shared rows")
        expect(WorktreeCopy.lastUsedText(days: 0) == "used today" && WorktreeCopy.lastUsedText(days: 1) == "used yesterday" && WorktreeCopy.lastUsedText(days: 5) == "used 5 days ago" && WorktreeCopy.lastUsedText(days: nil) == "last used unknown", "history last-used wording")

        let historyClean = PlainParser.worktreeClean("""
        removed\tmain\t-Users-example-a\t4096
        would_remove\tmain\t-Users-example-b\t10
        failed\tmain\t-Users-example-c\trm failed
        skipped\tmain\t-Users-example-d\tcurrent
        skipped\t-\t-Users-example-e\tnot_found
        blocked\tci\trunning
        summary\t1\t4096\t1\t1
        """)
        expect(historyClean.rows(.removed).first?.sizeKB == 4096 && historyClean.rows(.wouldRemove).count == 1 && historyClean.rows(.failed).first?.message == "rm failed" && historyClean.rows(.blocked).first?.profileID == "ci", "history clean rows parse with the shared clean parser")
        expect(historyClean.rows(.skipped).map(\.message) == ["current", "not_found"] && WorktreeCopy.reasonText("current", days: 30) == "In use here", "history clean skips the current project with plain wording")
        expect(historyClean.summary == WorktreeCleanSummary(removed: 1, freedKB: 4096, failed: 1, blocked: 1), "history clean summary has no branch columns")
    }

    private static func ownerChecks() {
        let main = Profile(slug: "default", name: "Claude", color: nil, isDesktop: true, app: "/A/Claude.app", configDir: "/h/.claude", dataDir: "/h/data")
        let work = Profile(slug: "work", name: "Work", color: nil, isDesktop: true, app: "/A/Claude Work.app", configDir: "/h/.claude-work", dataDir: "/h/data-work")
        let cliOnly = Profile(slug: "ci", name: "Ci", color: nil, isDesktop: false, app: nil, configDir: "/h/.claude-ci", dataDir: nil)
        let all = [main, work, cliOnly]
        expect(StorageOwners.configOwner(of: "/h/.claude", in: all) == "Main Claude", "config owner of the main folder is Main Claude")
        expect(StorageOwners.configOwner(of: "/h/.claude-work/", in: all) == "Work", "config owner ignores a trailing slash")
        expect(StorageOwners.configOwner(of: "/h/.claude-other", in: all) == nil && StorageOwners.configOwner(of: "", in: all) == nil, "config owner is nil for unknown or empty paths")
        expect(StorageOwners.dataOwner(of: "/h/data", in: all) == "Main Claude" && StorageOwners.dataOwner(of: "/h/data-work", in: all) == "Work", "data owner resolves the main and profile data folders")
        expect(StorageOwners.dataOwner(of: "/h/nope", in: all) == nil && StorageOwners.dataOwner(of: "", in: [cliOnly]) == nil, "data owner is nil without a match")
        expect(StorageOwners.configSharingWarning(path: "/h/.claude-work", in: all) == "Already used by Work: both profiles will share Claude Code history, settings and sign-in.", "config sharing warning text")
        expect(StorageOwners.dataSharingWarning(path: "/h/data", in: all) == "Already used by Main Claude: both profiles will share the desktop sign-in and chats.", "data sharing warning text")
        expect(StorageOwners.includedProjectsNote(folder: "~/.x", count: 3) == "3 projects in ~/.x are already part of this profile." && StorageOwners.includedProjectsNote(folder: "~/.x", count: 1) == "1 project in ~/.x is already part of this profile.", "included projects note pluralizes")
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
        expect(cards[0].checksClaudeUpdates && !cards[1].checksClaudeUpdates && !cards[3].checksClaudeUpdates, "only the main card offers the Claude update check")
        expect(cards[0].chips.map(\.text) == ["Running"] && cards[0].kind == "Your regular Claude · 1.0" && cards[0].action == .open("/Applications/Claude.app"), "main card shows running state, version in its subtitle, and opens Claude.app")
        expect(cards[1].kind == "Desktop app + Terminal" && cards[1].glyph == "W" && cards[1].chips.map(\.text) == ["Running", "Up to date", "Self mode"] && cards[1].action == .open("/A/Claude Work.app"), "self-mode card is running, up to date and opens its app")
        let sameBuild = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0 (1)", environment: environment)
        let newerBuild = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0 (2)", environment: environment)
        expect(sameBuild.chips.map(\.text).contains("Up to date") && newerBuild.chips.map(\.text).contains("Rebuild needed"), "versions compare as the full short (build) string")
        expect(HomeCards.main(sourcePath: "/Applications/Claude.app", sourceVersion: "1.0 (7)", environment: environment).kind == "Your regular Claude · 1.0", "versions display without the build suffix")
        let loading = HomeCards.card(for: desktopSelf, details: nil, sourceVersion: "1.0 (1)", environment: environment)
        expect(loading.action == .loading && loading.chips.map(\.text) == ["Loading…"], "a desktop profile whose details are still loading shows a loading state, not a disabled Open")
        expect(HomeCards.card(for: cliOnly, details: nil, sourceVersion: nil, environment: environment).action == .copyCommand("claude-ci"), "a CLI-only profile can copy its command before its details load")
        expect(cards[2].kind == "Desktop app" && cards[2].chips.map(\.text) == ["Rebuild needed", "Launcher mode"] && cards[2].action == .unavailable, "launcher card is outdated and cannot open a missing launcher")
        expect(cards[3].kind == "Terminal only" && cards[3].chips.map(\.text) == ["2 folders"] && cards[3].action == .copyCommand("claude-ci"), "CLI-only card copies its command and counts folders")
        let missingApp = HomeCards.card(for: desktopSelf, details: details["work"], sourceVersion: "1.0", environment: HomeEnvironment(isRunning: { _ in false }, appVersion: { _ in nil }, fileExists: { _ in false }))
        expect(missingApp.chips.first?.text == "Not built" && missingApp.action == .unavailable, "a profile whose app is missing reads as not built")
        expect(HomeCards.main(sourcePath: "/x/Claude.app", sourceVersion: nil, environment: HomeEnvironment(isRunning: { _ in false }, appVersion: { _ in nil }, fileExists: { _ in false })).chips.map(\.text) == ["Not installed"], "main card reports a missing Claude.app")
        expect(!HomeCards.main(sourcePath: "/x/Claude.app", sourceVersion: nil, environment: HomeEnvironment(isRunning: { _ in false }, appVersion: { _ in nil }, fileExists: { _ in false })).checksClaudeUpdates, "main card hides the update check when Claude is missing")

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
        setupCompletionChecks(good: good, stale: stale)
    }

    private static func setupCompletionChecks(good: StatusSummary, stale: StatusSummary) {
        func status(_ rows: String) -> StatusSummary { PlainParser.status(rows) }
        let agentOnly = status("agent\tlabel\t1")
        let unusableIdentity = status("identity\tSigning\t1\t0\nagent\tlabel\t1")
        let absentIdentity = status("identity\tSigning\t0\t0\nagent\tlabel\t1")
        let unloadedAgent = status("identity\tSigning\t1\t1\nagent\tlabel\t0")
        let identityOnly = status("identity\tSigning\t1\t1")
        expect(SetupStatus.completion(good) == .complete && !SetupStatus.needsSetup(good), "setup is complete when the agent is loaded and the identity is present and usable")
        expect(SetupStatus.completion(unloadedAgent) == .incomplete && SetupStatus.needsSetup(unloadedAgent), "setup is incomplete when the agent is not loaded")
        expect(SetupStatus.completion(unusableIdentity) == .incomplete, "setup is incomplete when the identity is present but not usable")
        expect(SetupStatus.completion(absentIdentity) == .incomplete, "setup is incomplete when the identity is absent")
        expect(SetupStatus.completion(stale) == .incomplete, "setup is incomplete when both pieces are missing")
        expect(SetupStatus.completion(nil) == .unknown && !SetupStatus.needsSetup(nil), "setup stays unknown before the first refresh and shows no banner")
        expect(SetupStatus.completion(agentOnly) == .unknown && SetupStatus.completion(identityOnly) == .unknown, "setup stays unknown while one of the two rows is missing")
        expect(SetupStatus.completion(status("identity\tSigning\t0\t0")) == .incomplete, "a known-missing piece makes setup incomplete even when the other row is missing")

        let doneSteps = HowItWorks.steps(status: good)
        expect(doneSteps.map(\.number) == [1, 2, 3, 4] && doneSteps[1].title == "One-time setup" && doneSteps[3].title == "Optional: Terminal", "how it works has four steps with the setup as step two")
        expect(doneSteps.map(\.mark) == [.neutral, .done, .neutral, .neutral], "step two shows a green check once setup is done")
        expect(HowItWorks.steps(status: stale).map(\.mark) == [.neutral, .pending, .neutral, .neutral], "step two shows an orange dot while setup is missing")
        expect(HowItWorks.steps(status: nil).allSatisfy { $0.mark == .neutral }, "no step is marked before the first refresh")
        expect(SetupCopy.bannerBody(hasProfiles: true) == SetupCopy.explanation, "the banner body is the plain explanation when profiles exist")
        expect(SetupCopy.bannerBody(hasProfiles: false).hasSuffix(SetupCopy.firstProfileNudge) && SetupCopy.bannerBody(hasProfiles: false).hasPrefix(SetupCopy.explanation), "the banner body adds the first-profile nudge when there are no profiles")
        let model = MainActor.assumeIsolated { AppModel(runner: nil) }
        expect(MainActor.assumeIsolated { !model.setupNeeded && !model.showsSetupFollowUp }, "a model without status does not ask for setup")
        MainActor.assumeIsolated { model.status = stale }
        expect(MainActor.assumeIsolated { model.setupNeeded }, "a model with a missing agent and identity asks for setup")
        MainActor.assumeIsolated { model.status = good }
        expect(MainActor.assumeIsolated { !model.setupNeeded }, "a model with everything set up stops asking")
    }

    private static func liveVersionChecks(root: String) throws {
        let fileManager = FileManager.default
        func makeApp(_ path: String, version: String) throws {
            try fileManager.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
            let info: NSDictionary = ["CFBundleShortVersionString": version, "CFBundleVersion": version]
            try info.write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
        }
        let app = root + "/swap/Claude Swap.app"
        let staged = root + "/swap/Claude Swap.staged.app"
        try makeApp(app, version: "1.0")
        try makeApp(staged, version: "2.0")
        let environment = HomeEnvironment.live(runningPaths: [])
        expect(environment.appVersion(app) == "1.0 (1.0)", "the live version reader reads short and build versions from Info.plist")
        try fileManager.removeItem(atPath: app)
        try fileManager.moveItem(atPath: staged, toPath: app)
        expect(environment.appVersion(app) == "2.0 (2.0)", "the live version reader sees a rebuilt app swapped in at the same path")
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
