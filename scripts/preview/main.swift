import AppKit
import SwiftUI

// A separate documentation preview: the production picker with public example titles.
// It never enumerates the user's windows or installs a keyboard tap.
final class PreviewDelegate: NSObject, NSApplicationDelegate {
    let model = SwitcherModel()
    var panel: SwitcherPanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let examples = [
            ("com.apple.finder", "Finder", "Projects", false),
            ("com.apple.Safari", "Safari", "Swift — Apple Developer", false),
            ("com.apple.Terminal", "Terminal", "WindowHop — swift build", false),
            ("com.apple.TextEdit", "TextEdit", "Release notes.txt", false),
            ("com.apple.Notes", "Notes", "Weekend ideas", false),
            ("com.apple.Safari", "Safari", "GitHub — WindowHop", true)
        ]
        model.windows = examples.map { bundle, app, title, minimized in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
            return WindowRecord(id: UUID(), pid: getpid(), element: AXUIElementCreateApplication(getpid()),
                appName: app, title: title, minimized: minimized, hidden: false, icon: icon, lastUsed: 0)
        }
        model.shortcut = .command
        model.selected = model.windows[1].id
        panel = SwitcherPanel(model: model)
        panel.present(count: model.windows.count)
        if let index = CommandLine.arguments.firstIndex(of: "--export"),
           CommandLine.arguments.indices.contains(index + 1) {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try self.export(SwitcherView(model: self.model).frame(width: 590, height: 568),
                                    to: folder.appendingPathComponent("switcher.png"))
                    let settings = SetupModel()
                    settings.shortcut = .command
                    settings.trusted = true
                    settings.keyboardReady = true
                    settings.count = 12
                    try self.export(SetupView(model: settings)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, .light),
                        to: folder.appendingPathComponent("settings.png"))
                    NSApp.terminate(nil)
                } catch {
                    fputs("Preview export failed: \(error)\n", stderr)
                    exit(1)
                }
            }
        }
    }

    @MainActor private func export<V: View>(_ view: V, to url: URL) throws {
        let logicalSize = NSHostingView(rootView: view).fittingSize
        let host = NSHostingView(rootView: view
            .frame(width: logicalSize.width, height: logicalSize.height)
            .scaleEffect(3, anchor: .topLeading)
            .frame(width: logicalSize.width * 3, height: logicalSize.height * 3, alignment: .topLeading)
            .environment(\.displayScale, 3))
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        // Let AppKit-backed controls and SwiftUI's lazy list complete native layout.
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        let image = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.size = size
        host.cacheDisplay(in: host.bounds, to: image)
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WindowHopPreview", code: 1)
        }
        try data.write(to: url)
        print("\(url.lastPathComponent): \(image.pixelsWide) × \(image.pixelsHigh)")
        window.orderOut(nil)
    }
}

let app = NSApplication.shared
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
