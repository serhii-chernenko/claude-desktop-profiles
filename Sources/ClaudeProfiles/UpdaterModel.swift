import Combine
import Foundation
import Sparkle

@MainActor
final class UpdaterModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var downloadedUpdateVersion: String?

    private let delegate = UpdaterDelegate()
    private let controller: SPUStandardUpdaterController
    private var installDownloadedUpdate: (() -> Void)?
    private var subscriptions = Set<AnyCancellable>()

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
        delegate.onUpdateDownloaded = { [weak self] version, install in
            self?.downloadedUpdateVersion = version
            self?.installDownloadedUpdate = install
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
        installDownloadedUpdate?()
    }

    func setAutomaticallyChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
        automaticallyChecks = enabled
    }

    func setAutomaticallyDownloads(_ enabled: Bool) {
        controller.updater.automaticallyDownloadsUpdates = enabled
        automaticallyDownloads = enabled
    }
}

final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateDownloaded: (@MainActor (String, @escaping () -> Void) -> Void)?

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard let onUpdateDownloaded else { return false }
            onUpdateDownloaded(item.displayVersionString, immediateInstallHandler)
            return true
        }
    }
}
