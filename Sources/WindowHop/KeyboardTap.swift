import AppKit

enum SwitcherShortcut: String, CaseIterable {
    case option, command
    var title: String { self == .option ? "Option+Tab" : "Command+Tab" }
    var symbol: String { self == .option ? "⌥" : "⌘" }
    var modifier: CGEventFlags { self == .option ? .maskAlternate : .maskCommand }
    var excludedModifier: CGEventFlags { self == .option ? .maskCommand : .maskAlternate }
    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: "switcherShortcut") ?? "") ?? .option
    }
    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: "switcherShortcut") }
}

final class KeyboardTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = false
    private var swallowedKeys = Set<Int64>()
    var shortcut: SwitcherShortcut = .option { didSet { if oldValue != shortcut { cancel() } } }
    var onStep: ((Bool) -> Bool)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var pointerIsInside: ((CGPoint) -> Bool)?
    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); return isRunning }
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return Unmanaged<KeyboardTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        cancel()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; swallowedKeys.removeAll()
    }

    func cancel() { gesture = false; onCancel?() }
    func beginPreview() { gesture = true }
    func endGesture() { gesture = false }

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            cancel()
            swallowedKeys.removeAll()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = event.getIntegerValueField(.keyboardEventKeycode)
        let modifierHeld = event.flags.contains(shortcut.modifier)
        if gesture, type == .leftMouseDown || type == .rightMouseDown {
            if pointerIsInside?(event.location) != true { cancel() }
        }
        if type == .keyUp, swallowedKeys.remove(key) != nil { return nil }
        if type == .flagsChanged, gesture, !modifierHeld {
            gesture = false
            onCommit?()
        }
        if type == .keyDown {
            if key == 48, modifierHeld, !event.flags.contains(shortcut.excludedModifier), !event.flags.contains(.maskControl) {
                if onStep?(event.flags.contains(.maskShift)) == true {
                    gesture = true; swallowedKeys.insert(key); return nil
                }
            }
            if gesture, key == 53 { cancel(); swallowedKeys.insert(key); return nil }
            if gesture, key == 36 {
                gesture = false; onCommit?(); swallowedKeys.insert(key); return nil
            }
            if gesture, [123, 124, 125, 126].contains(key) {
                _ = onStep?(key == 123 || key == 126)
                swallowedKeys.insert(key); return nil
            }
            // Typing elsewhere dismisses the picker and reaches the intended app.
            if gesture { cancel() }
        }
        return Unmanaged.passUnretained(event)
    }
}
