import Foundation
import Security

public struct RunnerAgentSigningIdentity: Equatable, Sendable {
    public let requirement: String
    public let teamIdentifier: String?

    public var description: String {
        teamIdentifier.map { "Team \($0)" } ?? "Ad-hoc development signature"
    }
}

public enum RunnerAgentCodeSigning {
    /// Build a peer requirement tied to this process's signing team. Ad-hoc
    /// development builds can only require the fixed code identifier; production
    /// LaunchDaemon builds must have a Team ID and be notarized.
    public static func peerRequirement(identifier: String) -> RunnerAgentSigningIdentity {
        let teamIdentifier = currentTeamIdentifier()
        let quotedIdentifier = quote(identifier)
        if let teamIdentifier {
            let quotedTeam = quote(teamIdentifier)
            return RunnerAgentSigningIdentity(
                requirement: "anchor apple generic and identifier \(quotedIdentifier) and certificate leaf[subject.OU] = \(quotedTeam)",
                teamIdentifier: teamIdentifier
            )
        }
        return RunnerAgentSigningIdentity(
            requirement: "identifier \(quotedIdentifier)",
            teamIdentifier: nil
        )
    }

    public static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [CFString: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier] as? String
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
