import Combine
import Foundation
import Sparkle

enum UpdatePromptPolicy {
    static let launchWindow: TimeInterval = 300

    static func promptsWhenReady(launchedAt: Date, now: Date, alreadyPrompted: Bool) -> Bool {
        !alreadyPrompted && now.timeIntervalSince(launchedAt) < launchWindow
    }
}

enum RelaunchGuard {
    static let quitWaitLimit = 60
    static let installerWaitLimit = 120
    static let settleDelay = 5
    static let opener = "/usr/bin/open"

    static let script = """
    waited=0
    while /bin/kill -0 "$1" 2>/dev/null; do
        [ "$waited" -ge "$2" ] && exit 0
        /bin/sleep 1
        waited=$((waited + 1))
    done
    waited=0
    while [ -n "$3" ] && [ "$waited" -lt "$4" ] && /bin/launchctl list "$3" >/dev/null 2>&1; do /bin/sleep 1; waited=$((waited + 1)); done
    /bin/sleep "$5"
    /usr/bin/pgrep -qx -U "$(/usr/bin/id -u)" "$6" || "$7" "$8"
    """

    static func arguments(waitingFor pid: Int32, quitWaitLimit: Int = quitWaitLimit, installerLabel: String, settleDelay: Int, processName: String, opener: String, target: String) -> [String] {
        ["-c", script, "relaunch-guard", String(pid), String(quitWaitLimit), installerLabel, String(installerWaitLimit), String(settleDelay), processName, opener, target]
    }

    @discardableResult
    static func start(_ arguments: [String]) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            return nil
        }
    }

    @MainActor private static var pending: Process?

    @MainActor
    static func arm() {
        if pending?.isRunning == true { return }
        let bundle = Bundle.main
        let installerLabel = bundle.bundleIdentifier.map { "\($0)-sparkle-updater" } ?? ""
        pending = start(arguments(waitingFor: ProcessInfo.processInfo.processIdentifier,
                        installerLabel: installerLabel,
                        settleDelay: settleDelay,
                        processName: ProcessInfo.processInfo.processName,
                        opener: opener,
                        target: bundle.bundlePath))
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var availableUpdateVersion: String?
    @Published private(set) var downloadedUpdateVersion: String?
    @Published var readyPromptVersion: String?

    var pendingUpdateVersion: String? {
        downloadedUpdateVersion ?? availableUpdateVersion
    }

    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController
    private let launchedAt = Date()
    private var promptedForReadyUpdate = false
    private var installDownloadedUpdate: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        delegate.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
        }
        delegate.onNoUpdateFound = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        delegate.onUpdateSkipped = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        delegate.onUpdateDownloaded = { [weak self] version, install in
            self?.updateDownloaded(version: version, install: install)
        }
        controller.startUpdater()
        let updater = controller.updater
        if updater.automaticallyChecksForUpdates {
            updater.checkForUpdatesInBackground()
        }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        automaticallyChecks = updater.automaticallyChecksForUpdates
        automaticallyDownloads = updater.automaticallyDownloadsUpdates
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheckDate = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyChecks = $0 }
            .store(in: &subscriptions)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.automaticallyDownloads = $0 }
            .store(in: &subscriptions)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func installDownloadedUpdateNow() {
        guard let installDownloadedUpdate else { return }
        RelaunchGuard.arm()
        installDownloadedUpdate()
    }

    func showPendingUpdate() {
        if downloadedUpdateVersion != nil {
            installDownloadedUpdateNow()
        } else {
            checkForUpdates()
        }
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloads = enabled
    }

    private func updateDownloaded(version: String, install: @escaping () -> Void) {
        downloadedUpdateVersion = version
        installDownloadedUpdate = install
        guard UpdatePromptPolicy.promptsWhenReady(launchedAt: launchedAt, now: Date(), alreadyPrompted: promptedForReadyUpdate) else { return }
        promptedForReadyUpdate = true
        readyPromptVersion = version
    }
}

final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: (@MainActor (String) -> Void)?
    var onNoUpdateFound: (@MainActor () -> Void)?
    var onUpdateSkipped: (@MainActor () -> Void)?
    var onUpdateDownloaded: (@MainActor (String, @escaping () -> Void) -> Void)?

    @objc(updater:didFindValidUpdate:)
    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            onUpdateFound?(version)
        }
    }

    @objc(updaterDidNotFindUpdate:)
    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated {
            onNoUpdateFound?()
        }
    }

    @objc(updater:userDidMakeChoice:forUpdate:state:)
    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated {
            onUpdateSkipped?()
        }
    }

    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard let onUpdateDownloaded else { return false }
            onUpdateDownloaded(item.displayVersionString, immediateInstallHandler)
            return true
        }
    }
}
