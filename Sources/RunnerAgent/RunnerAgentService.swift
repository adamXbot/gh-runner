import Foundation
import Darwin
import RunnerAgentProtocol

final class RunnerAgentService: NSObject, RunnerAgentXPCProtocol {
    func health(withReply reply: @escaping (NSData) -> Void) {
        let userID = geteuid()
        let accountRecord = getpwuid(userID)
        let accountName = accountRecord.flatMap { $0.pointee.pw_name }
            .map { String(cString: $0) } ?? "unknown"
        let homeDirectory = accountRecord.flatMap { $0.pointee.pw_dir }
            .map { String(cString: $0) } ?? ""
        let signing = RunnerAgentCodeSigning.peerRequirement(
            identifier: RunnerAgentConstants.mainAppIdentifier
        )
        let health = RunnerAgentHealth(
            protocolVersion: RunnerAgentConstants.protocolVersion,
            agentVersion: "1.0",
            accountName: accountName,
            effectiveUserID: UInt32(userID),
            homeDirectory: homeDirectory,
            capabilities: ["health", "discover-runners"],
            signingIdentity: signing.description
        )
        reply(RunnerAgentWire.encode(.success(health)))
    }

    func discoverRunners(withReply reply: @escaping (NSData) -> Void) {
        let records = RunnerAgentDiscovery.discover()
        reply(RunnerAgentWire.encode(.success(records)))
    }
}

final class RunnerAgentListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = RunnerAgentService()

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // Declarative peer validation is evaluated by XPC for every message and
        // avoids PID-reuse races inherent in inspecting a process after connection.
        let signing = RunnerAgentCodeSigning.peerRequirement(
            identifier: RunnerAgentConstants.mainAppIdentifier
        )
        connection.setCodeSigningRequirement(signing.requirement)
        connection.exportedInterface = NSXPCInterface(with: RunnerAgentXPCProtocol.self)
        connection.exportedObject = service
        connection.activate()
        return true
    }
}
