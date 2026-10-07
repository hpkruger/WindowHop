import AppKit
import SwiftUI

enum WindowPreviewPreference {
    static let key = "showWindowPreviews"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowRecord] = []
    @Published var selected: UUID?
    @Published var shortcut: SwitcherShortcut = .option
    @Published var previews: [UUID: NSImage] = [:]
    @Published var showPreviews = WindowPreviewPreference.load()
    var choose: ((UUID) -> Void)?
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.cyan)
                Text("WindowHop").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(model.windows.count) windows").foregroundStyle(.secondary)
            }.padding(.horizontal, 6)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(model.windows) { window in
                            Button { model.choose?(window.id) } label: {
                                WindowCard(window: window, preview: model.previews[window.id],
                                           selected: model.selected == window.id, showPreview: model.showPreviews)
                                    .frame(width: model.showPreviews ? 224 : 184)
                                    .padding(9)
                                    .background(model.selected == window.id ? Color.cyan.opacity(0.16) : Color.white.opacity(0.035))
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                    .overlay(RoundedRectangle(cornerRadius: 13)
                                        .stroke(model.selected == window.id ? Color.cyan.opacity(0.75) : Color.white.opacity(0.08), lineWidth: 1))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(window.id)
                            .accessibilityLabel("\(window.appName), \(window.title)\(window.minimized ? ", minimized" : "")")
                            .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                        }
                    }.padding(2)
                }
                .frame(height: model.showPreviews ? 220 : 106)
                .onChange(of: model.selected) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onAppear { if let id = model.selected { proxy.scrollTo(id, anchor: .center) } }
            }
            HStack {
                Text("\(model.shortcut.symbol) Tab  Next"); Text("⇧  Reverse")
                Spacer()
                if model.showPreviews {
                    Text("Previews on").foregroundStyle(.secondary)
                }
                Text("Release \(model.shortcut.symbol) to switch").foregroundStyle(.primary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 6)
        }
        .padding(20)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.085, alpha: 0.98)))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
    }
}

private struct WindowCard: View {
    let window: WindowRecord
    let preview: NSImage?
    let selected: Bool
    let showPreview: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPreview {
                ZStack(alignment: .bottomLeading) {
                    if let preview {
                        Image(nsImage: preview)
                            .resizable().aspectRatio(contentMode: .fill)
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: window.minimized || window.hidden ? "eye.slash" : "rectangle.on.rectangle")
                                .font(.system(size: 24)).foregroundStyle(.secondary)
                            Text(window.minimized || window.hidden ? "No live preview" : "Preview unavailable")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if window.minimized || window.hidden {
                        Text(window.minimized ? "Minimized" : "Hidden")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.68))
                            .clipShape(Capsule())
                    }
                }
                .frame(height: 148)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .clipped()
            } else {
                HStack(spacing: 8) {
                    appIcon
                    Image(systemName: window.minimized || window.hidden ? "eye.slash" : "rectangle")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(height: 48)
            }

            HStack(spacing: 7) {
                if showPreview { appIcon }
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(window.appName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder private var appIcon: some View {
        if let icon = window.icon {
            Image(nsImage: icon).resizable().frame(width: 25, height: 25)
        } else {
            Image(systemName: "app.dashed").frame(width: 25, height: 25).foregroundStyle(.secondary)
        }
    }
}

final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(model: SwitcherModel) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "WindowHop Switcher"
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: SwitcherView(model: model))
    }

    func present(showPreviews: Bool) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let designSize = showPreviews ? NSSize(width: 1320, height: 330) : NSSize(width: 980, height: 216)
        let aspectRatio = designSize.width / designSize.height
        var width = area.width * 0.80
        var height = width / aspectRatio
        let maximumHeight = max(160, area.height - 64)
        if height > maximumHeight {
            height = maximumHeight
            width = height * aspectRatio
        }
        let size = NSSize(width: width, height: height)
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

final class SetupModel: ObservableObject {
    @Published var shortcut = SwitcherShortcut.load()
    @Published var scope = WindowScope.load()
    var scopeChanged: ((WindowScope) -> Void)?
    @Published var showPreviews = WindowPreviewPreference.load()
    var shortcutChanged: ((SwitcherShortcut) -> Void)?
    var previewsChanged: ((Bool) -> Void)?
    @Published var trusted = false
    @Published var keyboardReady = false
    @Published var count = 0
    @Published var message = ""
    var openSettings: (() -> Void)?
    var openScreenRecordingSettings: (() -> Void)?
    var retry: (() -> Void)?
    var preview: (() -> Void)?
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "rectangle.on.rectangle").font(.system(size: 38)).foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your windows. One shortcut.").font(.system(size: 27, weight: .bold))
                Text("Switch between individual windows with \(model.shortcut.title), including minimized windows.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Switching shortcut").font(.headline)
                Picker("Switching shortcut", selection: $model.shortcut) {
                    ForEach(SwitcherShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                    .onChange(of: model.shortcut) { model.shortcutChanged?($0) }
                Text(model.shortcut == .command
                     ? "Replaces the macOS app switcher while WindowHop is active. Pause or quit WindowHop to restore it."
                     : "Command+Tab continues to open the macOS app switcher.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Windows to include").font(.headline)
                Picker("Windows to include", selection: $model.scope) {
                    ForEach(WindowScope.allCases, id: \.self) { scope in Text(scope.title).tag(scope) }
                }.pickerStyle(.segmented).labelsHidden()
                    .onChange(of: model.scope) { model.scopeChanged?($0) }
                Text("Current Space includes windows on your visible desktops. Minimized, hidden, and unidentifiable windows remain available because macOS cannot reliably report their Space.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Show window previews", isOn: $model.showPreviews)
                    .onChange(of: model.showPreviews) { model.previewsChanged?($0) }
                Text("Shows a live thumbnail for each visible window in the horizontal switcher. Turn this off for a compact title-and-icon view.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Screen Recording Settings") { model.openScreenRecordingSettings?() }
            }
            VStack(alignment: .leading, spacing: 12) {
                Label(model.trusted ? "Accessibility enabled" : "Enable Accessibility to find and focus windows",
                      systemImage: model.trusted ? "checkmark.circle.fill" : "lock.shield")
                Label(model.keyboardReady ? "\(model.shortcut.title) is ready" : "Keyboard shortcut is waiting for permission",
                      systemImage: model.keyboardReady ? "checkmark.circle.fill" : "keyboard")
                Text("WindowHop reads window titles and keyboard shortcuts locally. When previews are enabled, macOS provides thumbnails of visible windows; WindowHop does not save them or record keystrokes.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack {
                Button("Open Accessibility Settings") { model.openSettings?() }
                Button("Check Again") { model.retry?() }
            }
            Text("In System Settings, enable WindowHop. If it is missing, use + to add this app. If the shortcut still cannot start, quit and reopen WindowHop.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("\(model.count) windows available").foregroundStyle(.secondary)
                Spacer()
                Button("Show Windows") { model.preview?() }.disabled(!model.trusted || model.count == 0)
            }
            if !model.message.isEmpty { Text(model.message).font(.system(size: 12)).foregroundStyle(.orange) }
            Text("Hold \(model.shortcut.symbol) and tap Tab • ⇧ reverses • Esc cancels\nWindowHop stays in the menu bar when you close this window.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(30).frame(width: 510).fixedSize(horizontal: false, vertical: true)
    }
}
