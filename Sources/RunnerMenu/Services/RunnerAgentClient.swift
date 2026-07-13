import Foundation
import RunnerAgentProtocol

enum RunnerAgentClientError: LocalizedError {
    case unavailable
    case timedOut
    case incompatibleProtocol(expected: Int, received: Int)
    case wrongAccount(expected: String, received: String)
    case rootAgent

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Runner Agent is unavailable. Check its approval in System Settings."
        case .timedOut:
            return "Runner Agent did not respond within five seconds."
        case .incompatibleProtocol(let expected, let received):
            return "Runner Agent protocol \(received) is incompatible with this app (expected \(expected))."
        case .wrongAccount(let expected, let received):
            return "Runner Agent is running as ‘\(received)’, not the required ‘\(expected)’ account."
        case .rootAgent:
            return "Runner Agent refused: it is running as root instead of the standard runner account."
        }
    }
}

struct RunnerAgentClient: Sendable {
    func health() async throws -> RunnerAgentHealth {
        try await request { proxy, reply in proxy.health(withReply: reply) }
    }

    func discoverRunners() async throws -> [RunnerAgentRunnerRecord] {
        try await request { proxy, reply in proxy.discoverRunners(withReply: reply) }
    }

    private func request<Payload>(
        _ invoke: @escaping (RunnerAgentXPCProtocol, @escaping (NSData) -> Void) -> Void
    ) async throws -> Payload where Payload: Codable & Sendable {
        try await withCheckedThrowingContinuation { continuation in
            let gate = RunnerAgentReplyGate(continuation)
            let connection = NSXPCConnection(
                machServiceName: RunnerAgentConstants.machServiceName,
                options: .privileged
            )
            let connectionBox = RunnerAgentConnectionBox(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: RunnerAgentXPCProtocol.self)
            let signing = RunnerAgentCodeSigning.peerRequirement(
                identifier: RunnerAgentConstants.agentCodeIdentifier
            )
            connection.setCodeSigningRequirement(signing.requirement)
            connection.invalidationHandler = {
                _ = gate.resume(.failure(RunnerAgentClientError.unavailable))
            }
            connection.activate()

            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                if gate.resume(.failure(error)) { connection.invalidate() }
            }
            guard let proxy = remote as? RunnerAgentXPCProtocol else {
                _ = gate.resume(.failure(RunnerAgentClientError.unavailable))
                connection.invalidate()
                return
            }

            invoke(proxy) { data in
                do {
                    let payload = try RunnerAgentWire.decode(Payload.self, from: data)
                    if gate.resume(.success(payload)) { connection.invalidate() }
                } catch {
                    if gate.resume(.failure(error)) { connection.invalidate() }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                if gate.resume(.failure(RunnerAgentClientError.timedOut)) {
                    connectionBox.connection.invalidate()
                }
            }
        }
    }
}

private final class RunnerAgentConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}

private final class RunnerAgentReplyGate<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ result: Result<Value, Error>) -> Bool {
        lock.lock()
        guard let continuation else { lock.unlock(); return false }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
        return true
    }
}
