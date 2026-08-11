import AppKit
import GhosttyKit
import QuartzCore

final class GhosttyTerminalNSView: NSView {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private let command: String
    private let onProcessExit: () -> Void
    private weak var terminalController: TerminalController?
    private var trackingArea: NSTrackingArea?
    private var isShuttingDown = false

    var terminalTitle = ""
    var workingDirectory: String?
    var rendererHealthy = true
    private(set) var processExited = false
    var cellSize: CGSize = .zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(
        runtime: GhosttyRuntime,
        command: String,
        terminalController: TerminalController? = nil,
        onProcessExit: @escaping () -> Void = {}
    ) {
        self.command = command
        self.terminalController = terminalController
        self.onProcessExit = onProcessExit
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        autoresizingMask = [.width, .height]
        initializeSurface(runtime: runtime)
        terminalController?.attach(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.framebufferOnly = true
        layer.pixelFormat = .bgra8Unorm
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        return layer
    }

    private func initializeSurface(runtime: GhosttyRuntime) {
        guard let app = runtime.app else { return }
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        config.wait_after_command = true
        let environment = [
            ("TERM", "xterm-256color"),
            ("COLORTERM", "truecolor"),
            ("TERM_PROGRAM", "Skep"),
        ]
        command.withCString { commandPointer in
            config.command = commandPointer
            withEnvironment(environment) { variables in
                config.env_vars = variables.baseAddress
                config.env_var_count = variables.count
                surface = ghostty_surface_new(app, &config)
            }
        }
    }

    func shutdown() {
        isShuttingDown = true
        terminalController?.detach(self)
        guard let surface else { return }
        ghostty_surface_free(surface)
        self.surface = nil
    }

    func markProcessExited() {
        guard !isShuttingDown, !processExited else { return }
        processExited = true
        onProcessExit()
    }

    override func layout() {
        super.layout()
        updateSurfaceGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateSurfaceGeometry()
        if window != nil {
            window?.makeFirstResponder(self)
            setFocused(true)
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceGeometry()
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    private func updateSurfaceGeometry() {
        guard let surface, bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        let backing = convertToBacking(bounds.size)
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
        if let screenNumber = window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, screenNumber.uint32Value)
        }
        ghostty_surface_refresh(surface)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if terminalShortcutBelongsToAppKit(
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            return false
        }
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                copy(nil)
                return true
            case "v":
                paste(nil)
                return true
            case "a":
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
    }

    @IBAction func copy(_ sender: Any?) {
        performBindingAction("copy_to_clipboard")
    }

    @IBAction func paste(_ sender: Any?) {
        performBindingAction("paste_from_clipboard")
    }

    @IBAction override func selectAll(_ sender: Any?) {
        performBindingAction("select_all")
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { pointer in
            ghostty_surface_binding_action(surface, pointer, UInt(action.utf8.count))
        }
    }

    @discardableResult
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyModifiers(event.modifierFlags)
        key.consumed_mods = ghosttyModifiers(event.modifierFlags.subtracting([.command, .control]))
        key.composing = false
        if let characters = event.charactersIgnoringModifiers,
           let scalar = characters.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        let text = eventText(event)
        if let text {
            return text.withCString { pointer in
                key.text = pointer
                return ghostty_surface_key(surface, key)
            }
        }
        return ghostty_surface_key(surface, key)
    }

    private func eventText(_ event: NSEvent) -> String? {
        guard let characters = event.characters else { return nil }
        if characters.count == 1, let scalar = characters.unicodeScalars.first {
            if scalar.value < 0x20 || (0xF700...0xF8FF).contains(scalar.value) {
                return nil
            }
        }
        return characters
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        if !sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT) {
            super.rightMouseDown(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        if !sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT) {
            super.rightMouseUp(with: event)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMousePosition(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePosition(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func rightMouseDragged(with event: NSEvent) { sendMousePosition(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePosition(event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, ghosttyModifiers(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_scroll(
            surface,
            event.scrollingDeltaX,
            event.scrollingDeltaY,
            ghosttyScrollModifiers(
                precise: event.hasPreciseScrollingDeltas,
                momentumPhase: event.momentumPhase
            )
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        if let surface, ghostty_surface_has_selection(surface) {
            menu.addItem(terminalMenuItem("Copy", action: #selector(copy(_:))))
        }
        menu.addItem(terminalMenuItem("Paste", action: #selector(paste(_:))))
        menu.addItem(.separator())
        menu.addItem(terminalMenuItem("Select All", action: #selector(selectAll(_:))))
        return menu
    }

    private func terminalMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func sendMousePosition(_ event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(
            surface,
            point.x,
            point.y,
            ghosttyModifiers(event.modifierFlags)
        )
    }

    @discardableResult
    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, ghosttyModifiers(event.modifierFlags))
    }

    func setCursor(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
        case GHOSTTY_MOUSE_SHAPE_GRAB: NSCursor.openHand.set()
        case GHOSTTY_MOUSE_SHAPE_GRABBING: NSCursor.closedHand.set()
        default: NSCursor.iBeam.set()
        }
    }

    func setCursorVisible(_ visible: Bool) {
        if visible { NSCursor.unhide() } else { NSCursor.hide() }
    }
}

func terminalShortcutBelongsToAppKit(
    charactersIgnoringModifiers: String?,
    modifiers: NSEvent.ModifierFlags
) -> Bool {
    let key = charactersIgnoringModifiers?.lowercased()
    if modifiers == .command {
        return key == "q" || key == "w" || key == "m" || key == "h"
    }
    return modifiers == [.command, .option] && key == "h"
}

func ghosttyScrollModifiers(
    precise: Bool,
    momentumPhase: NSEvent.Phase
) -> ghostty_input_scroll_mods_t {
    var modifiers: Int32 = precise ? 1 : 0
    let momentum: ghostty_input_mouse_momentum_e = switch momentumPhase {
    case .began: GHOSTTY_MOUSE_MOMENTUM_BEGAN
    case .stationary: GHOSTTY_MOUSE_MOMENTUM_STATIONARY
    case .changed: GHOSTTY_MOUSE_MOMENTUM_CHANGED
    case .ended: GHOSTTY_MOUSE_MOMENTUM_ENDED
    case .cancelled: GHOSTTY_MOUSE_MOMENTUM_CANCELLED
    case .mayBegin: GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN
    default: GHOSTTY_MOUSE_MOMENTUM_NONE
    }
    modifiers |= Int32(momentum.rawValue) << 1
    return modifiers
}

private func ghosttyModifiers(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var raw: UInt32 = GHOSTTY_MODS_NONE.rawValue
    if flags.contains(.shift) { raw |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control) { raw |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option) { raw |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command) { raw |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { raw |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(raw)
}

private func withEnvironment<T>(
    _ environment: [(String, String)],
    body: (UnsafeMutableBufferPointer<ghostty_env_var_s>) -> T
) -> T {
    func recurse(
        _ index: Int,
        keys: [UnsafePointer<CChar>],
        values: [UnsafePointer<CChar>]
    ) -> T {
        guard index < environment.count else {
            var variables = zip(keys, values).map { ghostty_env_var_s(key: $0.0, value: $0.1) }
            return variables.withUnsafeMutableBufferPointer { buffer in
                body(buffer)
            }
        }
        return environment[index].0.withCString { key in
            environment[index].1.withCString { value in
                recurse(index + 1, keys: keys + [key], values: values + [value])
            }
        }
    }
    return recurse(0, keys: [], values: [])
}
