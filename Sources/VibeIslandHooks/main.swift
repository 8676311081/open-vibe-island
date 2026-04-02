import Foundation
import VibeIslandCore

@main
struct VibeIslandHooksCLI {
    static func main() {
        do {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard !input.isEmpty else {
                return
            }

            let decoder = JSONDecoder()
            let payload = try decoder.decode(CodexHookPayload.self, from: input)

            let client = BridgeCommandClient(socketURL: BridgeSocketLocation.currentURL())
            guard let response = try? client.send(.processCodexHook(payload)) else {
                return
            }

            if let output = try CodexHookOutputEncoder.standardOutput(for: response) {
                FileHandle.standardOutput.write(output)
            }
        } catch {
            // Hooks should fail open so the CLI continues working even if the bridge is unavailable.
        }
    }
}
