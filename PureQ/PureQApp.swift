//
//  PureQApp.swift
//  PureQ
//

import AppKit
import AppIntents
import SwiftUI

@MainActor
private enum PureQAppStore {
    static let model = EqualizerModel()
}

@MainActor
final class PureQWindowController: NSObject, NSWindowDelegate {
    static let shared = PureQWindowController()

    private var model: EqualizerModel?
    private var window: NSWindow?

    static var hasVisibleMainWindow: Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible && window.title == "PureQ" && window.canBecomeKey
        }
    }

    func configure(model: EqualizerModel) {
        self.model = model
    }

    func showMainWindow() {
        guard let model else { return }
        NSApplication.shared.setActivationPolicy(.regular)

        if let existingWindow = existingMainWindows.first {
            window = existingWindow
            existingWindow.deminiaturize(nil)
            existingWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PureQ"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 880, height: 700)
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(model)
                .environmentObject(model.telemetryStore)
        )
        window.delegate = self
        window.center()

        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var existingMainWindows: [NSWindow] {
        NSApplication.shared.windows.filter { window in
            window.title == "PureQ" && window.canBecomeKey
        }
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            window = nil
        }
    }
}

@MainActor
final class PureQAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !PureQWindowController.hasVisibleMainWindow {
                PureQWindowController.shared.showMainWindow()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !PureQWindowController.hasVisibleMainWindow {
            Task { @MainActor in
                PureQWindowController.shared.showMainWindow()
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PureQAppStore.model.flushPersistedState()
    }
}

@main
struct PureQApp: App {
    @NSApplicationDelegateAdaptor(PureQAppDelegate.self) private var appDelegate
    @StateObject private var model: EqualizerModel

    @MainActor
    init() {
        let sharedModel = PureQAppStore.model
        _model = StateObject(wrappedValue: sharedModel)
        PureQWindowController.shared.configure(model: sharedModel)
    }

    var body: some Scene {
        WindowGroup("PureQ", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.telemetryStore)
        }
        .defaultSize(width: 1_120, height: 840)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.telemetryStore)
        } label: {
            Image(systemName: model.menuBarSystemImage)
        }
        .menuBarExtraStyle(.window)
    }
}
