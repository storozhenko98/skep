import SkepCore
import SwiftUI

public struct TerminalView: NSViewRepresentable {
    public let session: TerminalSession
    public let isActive: Bool
    public let onProcessExit: () -> Void

    public init(
        session: TerminalSession,
        isActive: Bool = true,
        onProcessExit: @escaping () -> Void = {}
    ) {
        self.session = session
        self.isActive = isActive
        self.onProcessExit = onProcessExit
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
    @Environment(\.dismiss) private var dismiss
    public let session: TerminalSession
    @State private var renderedSession: TerminalSession
    @State private var disconnected = false

    public init(session: TerminalSession) {
        self.session = session
        _renderedSession = State(initialValue: session)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                Text(renderedSession.title).fontWeight(.semibold)
                Spacer()
                if disconnected {
                    Text("CONNECTION LOST")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Reconnect", action: reconnect)
                }
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.bar)
            TerminalView(
                session: renderedSession,
                onProcessExit: {
                    Task { @MainActor in disconnected = true }
                }
            )
                .id(renderedSession.id)
                .background(Color.black)
        }
        .frame(minWidth: 820, minHeight: 520)
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
