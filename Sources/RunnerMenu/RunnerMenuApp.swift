import SwiftUI
import AppKit

@main
struct RunnerMenuApp: App {
    /// Identifier for the main runners window (opened from the menu-bar panel).
    static let windowID = "runner-window"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RunnerStore()
    @State private var appUpdater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(store)
                .environment(appUpdater)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Runner Menu", id: Self.windowID) {
            RunnerWindowView()
                .environment(store)
                .environment(appUpdater)
        }
        .defaultSize(width: 940, height: 580)
        .commands { RunnerCommands() }

        Settings {
            SettingsView()
                .environment(store)
                .environment(appUpdater)
                .frame(width: 480)
        }
    }
}

/// App menu-bar commands (available when the app is active with a window).
struct RunnerCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Runner Menu Window") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: RunnerMenuApp.windowID)
            }
            .keyboardShortcut("0", modifiers: .command)
        }
    }
}

/// Keeps the app as a menu-bar accessory (no Dock icon) and kicks off polling.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dev affordance: set RUNNERMENU_DOCK=1 to show a Dock icon (useful for
        // screenshots / debugging). Ships as a pure menu-bar accessory otherwise.
        if ProcessInfo.processInfo.environment["RUNNERMENU_DOCK"] == "1" {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
