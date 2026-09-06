import AppKit

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
    }
}

let app = NSApplication.shared
let delegate = PreviewDelegate()
app.delegate = delegate
app.run()
