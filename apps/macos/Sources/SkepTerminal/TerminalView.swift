import SkepCore
import SwiftUI

public struct TerminalView: NSViewRepresentable {
    public let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> NSView {
        let runtime = GhosttyRuntime.shared
        guard runtime.app != nil else {
            return ErrorView(message: runtime.errorMessage ?? "Ghostty is unavailable.")
        }
        do {
            let invocation = try session.invocation()
            return GhosttyTerminalNSView(runtime: runtime, command: invocation.shellCommand)
        } catch {
            return ErrorView(message: error.localizedDescription)
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {}

    public static func dismantleNSView(_ nsView: NSView, coordinator: Void) {
        (nsView as? GhosttyTerminalNSView)?.shutdown()
    }
}

public struct TerminalPanel: View {
    @Environment(\.dismiss) private var dismiss
    public let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                Text(session.title).fontWeight(.semibold)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.bar)
            TerminalView(session: session)
                .background(Color.black)
        }
        .frame(minWidth: 820, minHeight: 520)
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
