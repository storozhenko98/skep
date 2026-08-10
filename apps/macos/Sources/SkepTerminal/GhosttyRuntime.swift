import AppKit
import GhosttyKit

final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private(set) var errorMessage: String?

    private init() {
        let initialized = "Skep".withCString { program in
            var arguments: [UnsafeMutablePointer<CChar>?] = [
                UnsafeMutablePointer(mutating: program),
                nil,
            ]
            return arguments.withUnsafeMutableBufferPointer { buffer in
                ghostty_init(1, buffer.baseAddress)
            }
        }
        guard initialized == GHOSTTY_SUCCESS else {
            errorMessage = "Ghostty failed to initialize."
            return
        }
        guard let config = ghostty_config_new() else {
            errorMessage = "Ghostty could not create its terminal configuration."
            return
        }
        ghostty_config_finalize(config)
        self.config = config

        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyRuntime.wakeup(userdata) },
            action_cb: { app, target, action in
                guard let app else { return false }
                return GhosttyRuntime.action(app, target: target, action: action)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyRuntime.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, value, state, request in
                GhosttyRuntime.confirmReadClipboard(userdata, value: value, state: state, request: request)
            },
            write_clipboard_cb: { userdata, location, content, count, confirm in
                GhosttyRuntime.writeClipboard(userdata, location: location, content: content, count: count, confirm: confirm)
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyRuntime.closeSurface(userdata, processAlive: processAlive)
            }
        )
        guard let app = ghostty_app_new(&runtime, config) else {
            errorMessage = "Ghostty could not create its application runtime."
            return
        }
        self.app = app
        ghostty_app_set_focus(app, true)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let runtime = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            guard let app = runtime.app else { return }
            ghostty_app_tick(app)
        }
    }

    private static func action(
        _ app: ghostty_app_t,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        if action.tag == GHOSTTY_ACTION_QUIT {
            return false
        }
        if action.tag == GHOSTTY_ACTION_OPEN_URL {
            let value = action.action.open_url
            guard let pointer = value.url else { return false }
            let urlString = String(cString: pointer)
            guard let url = URL(string: urlString) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true
        }
        guard let viewAddress = terminalViewAddress(target: target) else {
            return action.tag == GHOSTTY_ACTION_RELOAD_CONFIG
        }
        DispatchQueue.main.async {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: viewAddress) else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(pointer).takeUnretainedValue()
            switch action.tag {
            case GHOSTTY_ACTION_SET_TITLE:
                if let pointer = action.action.set_title.title {
                    view.terminalTitle = String(cString: pointer)
                }
            case GHOSTTY_ACTION_PWD:
                if let pointer = action.action.pwd.pwd {
                    view.workingDirectory = String(cString: pointer)
                }
            case GHOSTTY_ACTION_MOUSE_SHAPE:
                view.setCursor(action.action.mouse_shape)
            case GHOSTTY_ACTION_MOUSE_VISIBILITY:
                view.setCursorVisible(action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE)
            case GHOSTTY_ACTION_RENDERER_HEALTH:
                view.rendererHealthy = action.action.renderer_health == GHOSTTY_RENDERER_HEALTH_HEALTHY
            case GHOSTTY_ACTION_CELL_SIZE:
                view.cellSize = CGSize(
                    width: Int(action.action.cell_size.width),
                    height: Int(action.action.cell_size.height)
                )
            case GHOSTTY_ACTION_RING_BELL:
                NSSound.beep()
            case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                view.markProcessExited()
            default:
                break
            }
        }
        return switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE,
             GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_MOUSE_SHAPE,
             GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_RENDERER_HEALTH,
             GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_RING_BELL,
             GHOSTTY_ACTION_SHOW_CHILD_EXITED,
             GHOSTTY_ACTION_SELECTION_CHANGED,
             GHOSTTY_ACTION_COMMAND_FINISHED,
             GHOSTTY_ACTION_PROGRESS_REPORT,
             GHOSTTY_ACTION_SCROLLBAR:
            true
        default:
            false
        }
    }

    private static func terminalViewAddress(target: ghostty_target_s) -> UInt? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface) else { return nil }
        return UInt(bitPattern: userdata)
    }

    private static func view(from userdata: UnsafeMutableRawPointer?) -> GhosttyTerminalNSView? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = view(from: userdata), let surface = view.surface else { return false }
        let value = MainActor.assumeIsolated {
            NSPasteboard.general.string(forType: .string)
        }
        guard let value else { return false }
        value.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface, pointer, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        value: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = view(from: userdata), let surface = view.surface else { return }
        let allow = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE
        let text = allow ? value : nil
        ghostty_surface_complete_clipboard_request(surface, text, state, allow)
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        count: Int,
        confirm: Bool
    ) {
        guard !confirm, let content else { return }
        var value: String?
        for index in 0..<count {
            guard let mime = content[index].mime,
                  String(cString: mime) == "text/plain",
                  let data = content[index].data else { continue }
            value = String(cString: data)
            break
        }
        guard let value else { return }
        MainActor.assumeIsolated {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
        guard let userdata else { return }
        let address = UInt(bitPattern: userdata)
        DispatchQueue.main.async {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(pointer).takeUnretainedValue()
            view.markProcessExited()
        }
    }
}
