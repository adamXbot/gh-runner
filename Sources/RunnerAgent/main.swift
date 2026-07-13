import Foundation
import RunnerAgentProtocol

let delegate = RunnerAgentListenerDelegate()
let listener = NSXPCListener(machServiceName: RunnerAgentConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
