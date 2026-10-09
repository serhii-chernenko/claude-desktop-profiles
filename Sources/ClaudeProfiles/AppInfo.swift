import Foundation

enum AppInfo {
    static let repositoryURL = URL(string: "https://github.com/serhii-chernenko/claude-desktop-profiles")!
    static let issuesURL = URL(string: "https://github.com/serhii-chernenko/claude-desktop-profiles/issues")!
    static let licenseURL = URL(string: "https://github.com/serhii-chernenko/claude-desktop-profiles/blob/main/LICENSE")!
    static let summary = "Run several Claude accounts side by side — each with its own app, sign-in and Claude Code history"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    static var versionDescription: String {
        guard let build, build != version else { return version }
        return "\(version) (build \(build))"
    }
}
