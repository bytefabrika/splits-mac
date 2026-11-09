import SwiftData
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today", activities = "Activities", trends = "Trends"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .activities: "list.bullet.rectangle"
        case .trends: "chart.xyaxis.line"
        }
    }
}

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @State private var sync: Sync?
    @State private var section: SidebarItem? = .today
    @State private var hasKey = Keychain.readKey() != nil
    /// Set once the first sync screen has been seen.
    @AppStorage("welcomed") private var welcomed = false

    var body: some View {
        Group {
            if !hasKey {
                OnboardingView { key in
                    Keychain.saveKey(key)
                    hasKey = true
                    welcomed = false
                    Task { await sync?.run() }
                }
            } else if let sync, !welcomed {
                FirstSyncView(sync: sync, onDone: { welcomed = true }, onChangeKey: {
                    Keychain.deleteKey()
                    hasKey = false
                })
                .environment(\.format, Format(units: sync.units))
            } else if let sync {
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
                        .help("Get the latest from Garmin")
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            if sync == nil { sync = Sync(context: context) }
            // Data from before the welcome screen existed: nothing to count up, go straight in.
            if sync?.lastSync != nil && !(sync?.isRunning ?? false) { welcomed = true }
            // Sync on launch, at most once an hour.
            if hasKey, let sync, (sync.lastSync.map { Date().timeIntervalSince($0) > 3600 } ?? true) {
                Task { await sync.run() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .splitsKeyRemoved)) { _ in hasKey = false }
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

extension Notification.Name {
    static let splitsKeyRemoved = Notification.Name("splitsKeyRemoved")
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
