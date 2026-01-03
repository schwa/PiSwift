import Darwin
import Foundation

public func runRpcMode(_ session: AgentSession) async {
    _ = session
    fputs("RPC mode is not yet implemented in the Swift port.\n", stderr)
    Darwin.exit(1)
}
