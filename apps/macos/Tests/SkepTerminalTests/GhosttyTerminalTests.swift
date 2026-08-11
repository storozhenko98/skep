import AppKit
import GhosttyKit
import SkepCore
import Testing
@testable import SkepTerminal

@Test func workspaceTerminalUsesNarrowPrivilegedBridge() throws {
    let host = SSHHost(name: "test", hostname: "example.test", username: "operator")
    let session = TerminalSession(
        host: host,
        target: .workspace(id: "workspace-id", name: "Workspace")
    )
    let invocation = try session.invocation()
    #expect(invocation.arguments.suffix(5) == [
        "/usr/bin/sudo", "-n", "/usr/local/bin/skepctl", "workspace-shell", "workspace-id",
    ])
}

@Test func localWorkspaceTerminalUsesLocalControlPlane() throws {
    let session = TerminalSession(
        host: .local,
        target: .workspace(id: "workspace-local", name: "Local workspace")
    )
    let invocation = try session.invocation()
    #expect(invocation.executable.hasSuffix("/Skep/Local/bin/skepctl"))
    #expect(invocation.arguments.suffix(2) == ["workspace-shell", "workspace-local"])
    #expect(!invocation.arguments.contains("/usr/bin/sudo"))
}

@Test func builderTerminalUsesBuilderPresentationAndWorkspaceShell() throws {
    let host = SSHHost(name: "test", hostname: "example.test", username: "operator")
    let session = TerminalSession(
        host: host,
        target: .builder(id: "builder-id", name: "Base")
    )

    #expect(session.title == "Base — builder terminal")
    #expect(session.contextLabel == "BUILDER SHELL")
    #expect(session.workspaceID == "builder-id")
    let invocation = try session.invocation()
    #expect(invocation.arguments.suffix(5) == [
        "/usr/bin/sudo", "-n", "/usr/local/bin/skepctl", "workspace-shell", "builder-id",
    ])
}

@Test func preciseScrollMetadataPreservesTrackpadAndMomentumState() {
    #expect(ghosttyScrollModifiers(precise: false, momentumPhase: []) == 0)
    #expect(ghosttyScrollModifiers(precise: true, momentumPhase: []) == 1)
    #expect(
        ghosttyScrollModifiers(precise: true, momentumPhase: .changed)
            == 1 | (Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue) << 1)
    )
    #expect(
        ghosttyScrollModifiers(precise: false, momentumPhase: .ended)
            == Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue) << 1
    )
}

@Test func terminalLeavesNativeWindowAndApplicationShortcutsToAppKit() {
    for key in ["q", "w", "m", "h"] {
        #expect(
            terminalShortcutBelongsToAppKit(
                charactersIgnoringModifiers: key,
                modifiers: .command
            )
        )
    }
    #expect(
        terminalShortcutBelongsToAppKit(
            charactersIgnoringModifiers: "h",
            modifiers: [.command, .option]
        )
    )
    #expect(
        !terminalShortcutBelongsToAppKit(
            charactersIgnoringModifiers: "c",
            modifiers: .command
        )
    )
}

@Test func workspaceTerminalSessionHasStableResourceIdentity() {
    let host = SSHHost(name: "test", hostname: "example.test", username: "operator")
    let session = TerminalSession(
        host: host,
        target: .workspace(id: "workspace-id", name: "Workspace")
    )

    #expect(session.workspaceID == "workspace-id")
    #expect(session.matches(hostID: host.id, workspaceID: "workspace-id"))
    #expect(!session.matches(hostID: host.id, workspaceID: "other-workspace"))
    #expect(!session.matches(hostID: UUID(), workspaceID: "workspace-id"))

    let restarted = session.restarted()
    #expect(restarted.id != session.id)
    #expect(restarted.host == session.host)
    #expect(restarted.target == session.target)
    #expect(restarted.workspaceID == session.workspaceID)
}

@Test @MainActor func ghosttyCreatesRenderableMetalSurface() async throws {
    _ = NSApplication.shared
    let runtime = GhosttyRuntime.shared
    #expect(runtime.app != nil)
    #expect(runtime.errorMessage == nil)

    let marker: String
    let command: String
    if let hostname = ProcessInfo.processInfo.environment["SKEP_INTEGRATION_HOST"], !hostname.isEmpty {
        marker = "skep-ssh-terminal-ready"
        let username = ProcessInfo.processInfo.environment["SKEP_INTEGRATION_USER"] ?? "root"
        let host = SSHHost(name: "integration", hostname: hostname, username: username)
        command = try host.interactiveSSHArguments(
            remoteCommand: ["/bin/sh", "-lc", "printf \(marker); sleep 3"]
        ).shellCommand
    } else {
        marker = "skep-ghostty-ready"
        command = "/bin/sh -lc 'printf \(marker); sleep 3'"
    }
    var exitCount = 0
    let view = GhosttyTerminalNSView(
        runtime: runtime,
        command: command,
        onProcessExit: { exitCount += 1 }
    )
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(1500))

    let surface = try #require(view.surface)
    let size = ghostty_surface_size(surface)
    #expect(size.width_px > 0)
    #expect(size.height_px > 0)
    #expect(size.columns > 0)
    #expect(size.rows > 0)

    var text = ghostty_text_s()
    let selection = ghostty_selection_s(
        top_left: ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_TOP_LEFT,
            x: 0,
            y: 0
        ),
        bottom_right: ghostty_point_s(
            tag: GHOSTTY_POINT_SCREEN,
            coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
            x: 0,
            y: 0
        ),
        rectangle: false
    )
    #expect(ghostty_surface_read_text(surface, selection, &text))
    let visibleText = String(cString: text.text)
    ghostty_surface_free_text(surface, &text)
    #expect(visibleText.contains(marker))

    try await Task.sleep(for: .milliseconds(2500))
    #expect(view.processExited)
    #expect(exitCount == 1)
    view.markProcessExited()
    #expect(exitCount == 1)

    view.shutdown()
    window.close()
}
