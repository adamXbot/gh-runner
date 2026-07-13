import Foundation
import Testing
import RunnerAgentProtocol

struct RunnerAgentProtocolTests {
    @Test func healthEnvelopeRoundTrips() throws {
        let health = RunnerAgentHealth(
            protocolVersion: RunnerAgentConstants.protocolVersion,
            agentVersion: "1.0",
            accountName: "runner",
            effectiveUserID: 502,
            homeDirectory: "/Users/runner",
            capabilities: ["health", "discover-runners"],
            signingIdentity: "Team EXAMPLE"
        )

        let data = RunnerAgentWire.encode(RunnerAgentEnvelope.success(health))
        let decoded = try RunnerAgentWire.decode(RunnerAgentHealth.self, from: data)

        #expect(decoded == health)
    }

    @Test func remoteErrorEnvelopeThrows() {
        let envelope: RunnerAgentEnvelope<RunnerAgentHealth> = .failure("not available")
        let data = RunnerAgentWire.encode(envelope)

        #expect(throws: RunnerAgentWireError.remote("not available")) {
            _ = try RunnerAgentWire.decode(RunnerAgentHealth.self, from: data)
        }
    }

    @Test func signingRequirementUsesFixedPeerIdentifier() {
        let identity = RunnerAgentCodeSigning.peerRequirement(
            identifier: RunnerAgentConstants.agentCodeIdentifier
        )

        #expect(identity.requirement.contains("identifier \"com.kostarelas.RunnerMenu.agent\""))
        #expect(!identity.description.isEmpty)
    }
}
