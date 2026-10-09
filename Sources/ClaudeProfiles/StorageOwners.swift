import Foundation

enum StorageOwners {
    static let mainName = "Main Claude"

    static func displayName(_ profile: Profile) -> String {
        profile.isDefault ? mainName : profile.name
    }

    static func configOwner(of path: String, in profiles: [Profile]) -> String? {
        guard !path.isEmpty else { return nil }
        return profiles.first { normalized($0.configDir) == normalized(path) }.map(displayName)
    }

    static func dataOwner(of path: String, in profiles: [Profile]) -> String? {
        guard !path.isEmpty else { return nil }
        return profiles.first { $0.dataDir.map(normalized) == normalized(path) }.map(displayName)
    }

    static func configSharingWarning(path: String, in profiles: [Profile]) -> String? {
        configOwner(of: path, in: profiles).map {
            "Already used by \($0): both profiles will share Claude Code history, settings and sign-in."
        }
    }

    static func dataSharingWarning(path: String, in profiles: [Profile]) -> String? {
        dataOwner(of: path, in: profiles).map {
            "Already used by \($0): both profiles will share the desktop sign-in and chats."
        }
    }

    static func includedProjectsNote(folder: String, count: Int) -> String {
        let noun = count == 1 ? "project" : "projects"
        let verb = count == 1 ? "is" : "are"
        return "\(count) \(noun) in \(folder) \(verb) already part of this profile."
    }

    private static func normalized(_ path: String) -> String {
        (path as NSString).standardizingPath
    }
}
