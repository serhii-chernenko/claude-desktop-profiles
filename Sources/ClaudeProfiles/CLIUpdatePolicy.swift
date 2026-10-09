import Foundation

struct SemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ text: String) {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 3, let major = parts[0], let minor = parts[1], let patch = parts[2] else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum CLIUpdatePolicy {
    struct Decision: Equatable {
        let shouldInstall: Bool
        let message: String
    }

    static func decide(bundled: String?, installed: String?) -> Decision {
        guard let bundled, let bundledVersion = SemanticVersion(bundled) else {
            return Decision(shouldInstall: false, message: "Left the installed command-line tool alone: the bundled version is unknown.")
        }
        guard let installed, let installedVersion = SemanticVersion(installed) else {
            return Decision(shouldInstall: true, message: "The installed command-line tool has no readable version; updating it to \(bundled).")
        }
        if bundledVersion < installedVersion {
            return Decision(shouldInstall: false, message: "Left the installed command-line tool (\(installed)) alone: this app bundles an older version (\(bundled)).")
        }
        return Decision(shouldInstall: true, message: "Updating the installed command-line tool from \(installed) to \(bundled).")
    }
}
