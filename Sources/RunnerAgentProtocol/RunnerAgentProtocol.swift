import Foundation

public enum RunnerAgentConstants {
    public static let protocolVersion = 1
    public static let accountName = "runner"
    public static let mainAppIdentifier = "com.kostarelas.RunnerMenu"
    public static let agentCodeIdentifier = "com.kostarelas.RunnerMenu.agent"
    public static let machServiceName = "com.kostarelas.RunnerMenu.agent"
    public static let launchDaemonPlistName = "com.kostarelas.RunnerMenu.agent.plist"
}

public struct RunnerAgentHealth: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let agentVersion: String
    public let accountName: String
    public let effectiveUserID: UInt32
    public let homeDirectory: String
    public let capabilities: [String]
    public let signingIdentity: String

    public init(
        protocolVersion: Int,
        agentVersion: String,
        accountName: String,
        effectiveUserID: UInt32,
        homeDirectory: String,
        capabilities: [String],
        signingIdentity: String
    ) {
        self.protocolVersion = protocolVersion
        self.agentVersion = agentVersion
        self.accountName = accountName
        self.effectiveUserID = effectiveUserID
        self.homeDirectory = homeDirectory
        self.capabilities = capabilities
        self.signingIdentity = signingIdentity
    }
}

public struct RunnerAgentRunnerRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let directoryPath: String
    public let displayName: String
    public let scopeLabel: String?
    public let configured: Bool
    public let ownerUserID: UInt32

    public init(
        id: String,
        directoryPath: String,
        displayName: String,
        scopeLabel: String?,
        configured: Bool,
        ownerUserID: UInt32
    ) {
        self.id = id
        self.directoryPath = directoryPath
        self.displayName = displayName
        self.scopeLabel = scopeLabel
        self.configured = configured
        self.ownerUserID = ownerUserID
    }
}

public struct RunnerAgentEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let payload: Payload?
    public let error: String?

    public static func success(_ payload: Payload) -> Self {
        Self(payload: payload, error: nil)
    }

    public static func failure(_ error: String) -> Self {
        Self(payload: nil, error: error)
    }
}

public enum RunnerAgentWire {
    public static func encode<Payload>(_ envelope: RunnerAgentEnvelope<Payload>) -> NSData
    where Payload: Codable & Sendable {
        // The wire models contain only JSON-compatible Foundation values. Keep a
        // deterministic error envelope as a last resort rather than crashing the daemon.
        if let data = try? JSONEncoder().encode(envelope) { return data as NSData }
        return Data(#"{"payload":null,"error":"Unable to encode Runner Agent reply"}"#.utf8) as NSData
    }

    public static func decode<Payload>(_ type: Payload.Type, from data: NSData) throws -> Payload
    where Payload: Codable & Sendable {
        let envelope = try JSONDecoder().decode(
            RunnerAgentEnvelope<Payload>.self,
            from: data as Data
        )
        if let error = envelope.error { throw RunnerAgentWireError.remote(error) }
        guard let payload = envelope.payload else { throw RunnerAgentWireError.missingPayload }
        return payload
    }
}

public enum RunnerAgentWireError: LocalizedError, Equatable {
    case remote(String)
    case missingPayload

    public var errorDescription: String? {
        switch self {
        case .remote(let message): return message
        case .missingPayload: return "Runner Agent returned an empty response."
        }
    }
}

/// Versioned, read-only Phase 2 surface. Lifecycle and file mutation are
/// intentionally absent until the agent boundary has been exercised.
@objc public protocol RunnerAgentXPCProtocol {
    func health(withReply reply: @escaping (NSData) -> Void)
    func discoverRunners(withReply reply: @escaping (NSData) -> Void)
}
