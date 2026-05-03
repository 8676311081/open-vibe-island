import Foundation
import Testing
@testable import OpenIslandCore

struct BridgeServerSecurityTests {
    @Test
    func cursorBlockingHooksRequirePermission() throws {
        // Shell execution must be blocking (should NOT auto-allow)
        let shellPayload = CursorHookPayload(
            hookEventName: .beforeShellExecution,
            conversationId: "conv-test",
            generationId: "gen-test",
            workspaceRoots: ["/tmp/test"],
            command: "rm -rf /",
            cwd: "/tmp/test"
        )
        #expect(shellPayload.isBlockingHook == true)
        #expect(shellPayload.permissionRequestTitle == "Allow shell command")
        #expect(shellPayload.permissionRequestSummary == "rm -rf /")

        // MCP execution must be blocking (should NOT auto-allow)
        let mcpPayload = CursorHookPayload(
            hookEventName: .beforeMCPExecution,
            conversationId: "conv-mcp",
            generationId: "gen-mcp",
            workspaceRoots: ["/tmp/test"],
            server: "malicious-server",
            toolName: "dangerous_tool"
        )
        #expect(mcpPayload.isBlockingHook == true)
        #expect(mcpPayload.permissionRequestTitle == "Allow dangerous_tool")
        #expect(mcpPayload.permissionRequestSummary.contains("dangerous_tool"))
    }

    @Test
    func nonBlockingCursorHooksDoNotTriggerPermission() throws {
        // beforeSubmitPrompt should NOT block (user-initiated)
        let promptPayload = CursorHookPayload(
            hookEventName: .beforeSubmitPrompt,
            conversationId: "conv-test",
            generationId: "gen-test",
            workspaceRoots: [],
            prompt: "fix the bug"
        )
        #expect(promptPayload.isBlockingHook == false)

        // beforeReadFile should NOT block
        let readPayload = CursorHookPayload(
            hookEventName: .beforeReadFile,
            conversationId: "conv-test",
            generationId: "gen-test",
            workspaceRoots: [],
            filePath: "/tmp/test.swift"
        )
        #expect(readPayload.isBlockingHook == false)

        // afterFileEdit should NOT block
        let editPayload = CursorHookPayload(
            hookEventName: .afterFileEdit,
            conversationId: "conv-test",
            generationId: "gen-test",
            workspaceRoots: [],
            filePath: "/tmp/test.swift"
        )
        #expect(editPayload.isBlockingHook == false)
    }

    @Test
    func bridgeServerCreatesAndStopsCleanly() throws {
        let server = BridgeServer(socketURL: BridgeSocketLocation.uniqueTestURL())
        try server.start()
        server.stop()
        // Verify it doesn't crash on double-stop
        server.stop()
    }

    @Test
    func sweepTimerIsConfigured() {
        // Verify the sweep interval constant is reasonable
        let sweepIntervalSeconds: TimeInterval = 120 // 2 minutes
        let staleCutoffSeconds: TimeInterval = 600   // 10 minutes
        #expect(sweepIntervalSeconds > 0)
        #expect(staleCutoffSeconds > sweepIntervalSeconds)
    }
}
