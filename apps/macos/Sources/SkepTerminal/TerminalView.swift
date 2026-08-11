import SkepCore
import SwiftUI

@MainActor
final class TerminalController: ObservableObject {
    private weak var terminalView: GhosttyTerminalNSView?

    func attach(_ view: GhosttyTerminalNSView) {
        terminalView = view
    }

    func detach(_ view: GhosttyTerminalNSView) {
        guard terminalView === view else { return }
        terminalView = nil
    }

    func copySelection() {
        terminalView?.copy(nil)
        focus()
    }

    func paste() {
        terminalView?.paste(nil)
        focus()
    }

    func selectAll() {
        terminalView?.selectAll(nil)
        focus()
    }

    func focus() {
        guard let terminalView else { return }
        terminalView.window?.makeFirstResponder(terminalView)
    }
}

public struct TerminalView: NSViewRepresentable {
    public let session: TerminalSession
    public let isActive: Bool
    public let onProcessExit: () -> Void
    private let terminalController: TerminalController?

    public init(
        session: TerminalSession,
        isActive: Bool = true,
        onProcessExit: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isActive = isActive
        self.onProcessExit = onProcessExit
        terminalController = nil
    }

    init(
        session: TerminalSession,
        isActive: Bool = true,
        terminalController: TerminalController,
        onProcessExit: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isActive = isActive
        self.onProcessExit = onProcessExit
        self.terminalController = terminalController
    }

    public func makeNSView(context: Context) -> NSView {
        let runtime = GhosttyRuntime.shared
        guard runtime.app != nil else {
            return ErrorView(message: runtime.errorMessage ?? "Ghostty is unavailable.")
        }
        do {
            let invocation = try session.invocation()
            return GhosttyTerminalNSView(
                runtime: runtime,
                command: invocation.shellCommand,
                terminalController: terminalController,
                onProcessExit: onProcessExit
            )
        } catch {
            return ErrorView(message: error.localizedDescription)
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard isActive, nsView is GhosttyTerminalNSView else { return }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? GhosttyTerminalNSView)?.shutdown()
    }
}

public struct TerminalPanel: View {
    public let session: TerminalSession
    @State private var renderedSession: TerminalSession
    @State private var disconnected = false
    @StateObject private var terminalController = TerminalController()

    public init(session: TerminalSession) {
        self.session = session
        _renderedSession = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(renderedSession.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(renderedSession.contextLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if disconnected {
                    Text("CONNECTION LOST")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Reconnect", action: reconnect)
                }
                Button {
                    terminalController.copySelection()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: .command)
                Button {
                    terminalController.paste()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .keyboardShortcut("v", modifiers: .command)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(.bar)
            TerminalView(
                session: renderedSession,
                terminalController: terminalController,
                onProcessExit: {
                    Task { @MainActor in disconnected = true }
                }
            )
                .id(renderedSession.id)
                .background(Color.black)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear { terminalController.focus() }
    }

    private func reconnect() {
        renderedSession = renderedSession.restarted()
        disconnected = false
    }
}

private final class ErrorView: NSView {
    init(message: String) {
        super.init(frame: .zero)
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
