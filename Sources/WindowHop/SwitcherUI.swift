import AppKit
import SwiftUI

final class SwitcherModel: ObservableObject {
    @Published var windows: [WindowRecord] = []
    @Published var selected: UUID?
    @Published var shortcut: SwitcherShortcut = .option
    var choose: ((UUID) -> Void)?
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.cyan)
                Text("WindowHop").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("\(model.windows.count) windows").foregroundStyle(.secondary)
            }.padding(.horizontal, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.windows) { window in
                            Button { model.choose?(window.id) } label: {
                                HStack(spacing: 14) {
                                    if let icon = window.icon {
                                        Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(window.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                                        Text(window.appName).font(.system(size: 12)).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 4)
                                    if window.minimized || window.hidden {
                                        Text(window.minimized ? "Minimized" : "Hidden")
                                            .font(.system(size: 11)).foregroundStyle(.secondary)
                                    }
                                    if model.selected == window.id {
                                        Image(systemName: "return").foregroundStyle(.cyan)
                                    }
                                }
                                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(model.selected == window.id ? Color.cyan.opacity(0.16) : Color.white.opacity(0.035))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selected == window.id ? Color.cyan.opacity(0.6) : .clear))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(window.id)
                            .accessibilityLabel("\(window.appName), \(window.title)\(window.minimized ? ", minimized" : "")")
                            .accessibilityAddTraits(model.selected == window.id ? .isSelected : [])
                        }
                    }.padding(2)
                }
                .onChange(of: model.selected) { id in if let id { proxy.scrollTo(id, anchor: .center) } }
                .onAppear { if let id = model.selected { proxy.scrollTo(id, anchor: .center) } }
            }
            HStack {
                Text("\(model.shortcut.symbol) Tab  Next"); Text("⇧  Reverse")
                Spacer()
                Text("Release \(model.shortcut.symbol) to switch").foregroundStyle(.primary)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 8)
        }
        .padding(20)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.085, alpha: 0.98)))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
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

    func present(count: Int) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        let size = NSSize(width: min(590, area.width - 40), height: min(CGFloat(count * 76 + 112), area.height - 80, 650))
        setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }
}

final class SetupModel: ObservableObject {
    @Published var shortcut = SwitcherShortcut.load()
    var shortcutChanged: ((SwitcherShortcut) -> Void)?
    @Published var trusted = false
    @Published var keyboardReady = false
    @Published var count = 0
    @Published var message = ""
    var openSettings: (() -> Void)?
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
            VStack(alignment: .leading, spacing: 12) {
                Label(model.trusted ? "Accessibility enabled" : "Enable Accessibility to find and focus windows",
                      systemImage: model.trusted ? "checkmark.circle.fill" : "lock.shield")
                Label(model.keyboardReady ? "\(model.shortcut.title) is ready" : "Keyboard shortcut is waiting for permission",
                      systemImage: model.keyboardReady ? "checkmark.circle.fill" : "keyboard")
                Text("WindowHop reads window titles and keyboard shortcuts locally. It does not record your screen or save keystrokes.")
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
