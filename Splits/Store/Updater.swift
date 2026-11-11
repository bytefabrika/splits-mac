import AppKit
import Combine
import Sparkle
import SwiftUI

/// Updates for copies downloaded from GitHub, through Sparkle: it reads `appcast.xml` from the repo, and only
/// installs a version signed with our EdDSA key. Never runs in Debug builds.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    @Published private(set) var canCheck = false

    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
    }

    /// From the app's init, so Sparkle is up before launching finishes.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        #endif
    }

    func check() {
        #if !DEBUG
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
        #endif
    }

    static var isAvailable: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }
}

/// "Check for Updates…" under the app menu's About item.
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck || !Updater.isAvailable)
    }
}
