import SwiftUI
import AppKit

@main
struct RunnerMenuApp: App {
    /// Identifier for the main runners window (opened from the menu-bar panel).
    static let windowID = "runner-window"

    @Environment(\.openWindow) private var openWindow
    @State private var store = RunnerStore()
    @StateObject private var updates: SurfaceUpdates
    @StateObject private var menuBar = SurfaceMenuBarPreference(defaultIcon: MenuBarGlyph.default.id)

    private let app = RunnerMenuSurface.app
    /// Owns Sparkle's updater for the life of the app.
    private let appUpdater: AppUpdater

    init() {
        let appUpdater = AppUpdater()
        self.appUpdater = appUpdater
        _updates = StateObject(wrappedValue: SurfaceUpdates(
            driver: appUpdater.updater,
            releaseNotes: RunnerMenuSurface.releaseNotes
        ))
        // A menu bar utility: in the Dock, with a main menu, only while one of
        // its windows is open. LSUIElement keeps it out of the Dock at launch.
        SurfaceActivation.shared.start()
    }

    var body: some Scene {
        // The menu bar item comes first: SwiftUI opens the first scene at
        // launch, and a utility must not start with a window.
        MenuBarExtra {
            MenuContentView()
                .environment(store)
        } label: {
            MenuBarLabel(store: store, menuBar: menuBar)
        }
        .menuBarExtraStyle(.window)

        Window("Runner Menu", id: Self.windowID) {
            RunnerWindowView()
                .environment(store)
        }
        .defaultSize(width: 940, height: 580)
        .commands {
            SurfaceCommands(app: app, help: help, updates: updates)
            RunnerCommands()
        }

        Settings {
            SurfaceSettings(app: app, panes: panes)
                .environment(store)
        }

        SurfaceAboutWindow(app: app, help: help)
        SurfaceManualWindow(app: app, folder: RunnerMenuSurface.manualFolder)
        SurfaceShortcutsWindow(groups: RunnerMenuSurface.shortcuts(for: app))
    }

    /// The manual and shortcut windows are the shared ones; the welcome is the
    /// first-run setup, replayed in the main window.
    private var help: SurfaceHelp {
        SurfaceHelp(replayWelcome: { replayWelcome() })
    }

    private func replayWelcome() {
        store.reviewOnboarding()
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: Self.windowID)
    }

    /// General first, Updates last; the scaffold adds the About button to General.
    private var panes: [SurfacePane] {
        [
            SurfacePane("General", systemImage: "gearshape") {
                GeneralSettingsPane(app: app, menuBar: menuBar)
            },
            SurfacePane("Runners", systemImage: "shippingbox") {
                RunnerSettingsPane()
            },
            SurfacePane("Accounts", systemImage: "person.crop.circle") {
                AccountSettingsPane()
            },
            .updates(updates),
        ]
    }
}

/// The app's own addition to the main menu: a way back to the main window
/// from the Window menu, as Mail's Message Viewer is.
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
