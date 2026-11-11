import SwiftData
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today", activities = "Activities", trends = "Trends", sleep = "Sleep", hrv = "HRV", records = "Records"
    case explorer = "Explorer"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .activities: "list.bullet.rectangle"
        case .trends: "chart.xyaxis.line"
        case .sleep: "moon.zzz"
        case .hrv: "waveform.path.ecg"
        case .records: "trophy"
        case .explorer: "globe.europe.africa"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    /// Owned by the app, so the menu bar and the morning briefing can sync with the window closed.
    let sync: Sync
    @State private var section: SidebarItem? = {
        #if DEBUG
        // `open Splits.app --args -page trends` opens straight on a page, for screenshots.
        if let page = UserDefaults.standard.string(forKey: "page"), let item = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == page }) { return item }
        #endif
        return .today
    }()
    #if DEBUG
    /// `-showWelcome YES` / `-showFirstSync YES`: those screens without removing the key.
    private let showWelcome = UserDefaults.standard.bool(forKey: "showWelcome")
    private let showFirstSync = UserDefaults.standard.bool(forKey: "showFirstSync")
    #else
    private let showWelcome = false
    private let showFirstSync = false
    #endif
    @Environment(\.openSettings) private var openSettings
    @State private var hasKey = Keychain.readKey() != nil
    /// Set once the first sync screen has been seen.
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        Group {
            if !hasKey || showWelcome {
                OnboardingView { key in
                    Keychain.saveKey(key)
                    hasKey = true
                    welcomed = false
                    Task { await sync.run() }
                }
            } else if !welcomed || showFirstSync {
                FirstSyncView(sync: sync, onDone: { welcomed = true }, onChangeKey: {
                    Keychain.deleteKey()
                    hasKey = false
                })
                .environment(\.format, Format(units: sync.units))
            } else {
                NavigationSplitView {
                    List(SidebarItem.allCases, selection: $section) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                    .navigationSplitViewColumnWidth(min: 170, ideal: 190)
                    .safeAreaInset(edge: .bottom) { SyncStatus(sync: sync).padding(10) }
                } detail: {
                    switch section ?? .today {
                    case .today: TodayView()
                    case .activities: ActivitiesView()
                    case .trends: TrendsView()
                    case .sleep: SleepView()
                    case .hrv: HRVView()
                    case .records: RecordsView()
                    case .explorer: ExplorerView()
                    }
                }
                .environment(\.format, Format(units: sync.units))
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await sync.run() }
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(sync.isRunning)
                        .help("Get your latest data (⌘R)")
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "showSettings") { openSettings() }
            #endif
            // Data from before the welcome screen existed: nothing to count up, go straight in.
            if sync.lastSync != nil && !sync.isRunning { welcomed = true }
            // Sync on launch, at most once an hour, or right away if start coordinates still need filling in.
            let needsBackfill = !UserDefaults.standard.bool(forKey: "coordinatesBackfilled")
            if hasKey, needsBackfill || (sync.lastSync.map { Date().timeIntervalSince($0) > 3600 } ?? true) {
                Task { await sync.run() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitsKeyRemoved)) { _ in hasKey = false }
        .onReceive(NotificationCenter.default.publisher(for: .splitsShowPage)) { note in
            if let page = (note.object as? String).flatMap(SidebarItem.init(rawValue:)) { section = page }
        }
    }
}

struct SyncStatus: View {
    let sync: Sync

    var body: some View {
        HStack(spacing: 6) {
            switch sync.state {
            case .running(let message):
                ProgressView().controlSize(.small)
                Text(message).lineLimit(2)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(3)
            case .idle:
                Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                if let last = sync.lastSync {
                    Text("Synced \(last, format: .relative(presentation: .named))")
                } else {
                    Text("Not synced yet")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// The menu bar's commands: every toolbar action and page is there too, with a shortcut.
struct SplitsCommands: Commands {
    let sync: Sync
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Sync Now") { Task { await sync.run() } }
                .keyboardShortcut("r")
                .disabled(sync.isRunning)
        }
        CommandMenu("Go") {
            ForEach(Array(SidebarItem.allCases.enumerated()), id: \.element) { i, item in
                Button(item.rawValue) { show(item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
    }

    private func show(_ item: SidebarItem) {
        // The page switches in the open window; with none open, one opens first.
        if !NSApp.windows.contains(where: { $0.isVisible && ($0.identifier?.rawValue.hasPrefix("main") ?? false) }) {
            openWindow(id: "main")
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: .splitsShowPage, object: item.rawValue) }
    }
}

extension Notification.Name {
    static let splitsKeyRemoved = Notification.Name("splitsKeyRemoved")
    /// A menu command picked a page.
    static let splitsShowPage = Notification.Name("splitsShowPage")
    /// A sync or the menu bar's live refresh finished: the widgets redraw.
    static let splitsDataChanged = Notification.Name("splitsDataChanged")
}

private struct FormatKey: EnvironmentKey {
    static let defaultValue = Format(units: "metric")
}

extension EnvironmentValues {
    var format: Format {
        get { self[FormatKey.self] }
        set { self[FormatKey.self] = newValue }
    }
}
