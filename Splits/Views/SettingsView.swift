import ServiceManagement
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var newKey = ""
    @State private var confirmRemove = false
    @State private var message: String?
    @AppStorage(Mornings.notifyKey) private var morningNotification = true
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Personal API key") {
                LabeledContent("Status", value: Keychain.readKey() == nil ? "Not set" : "Saved in your keychain")
                SecureField("Replace with a new key", text: $newKey)
                HStack {
                    Button("Save New Key") {
                        Keychain.saveKey(newKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        newKey = ""
                        message = "Saved. The next sync uses the new key."
                    }
                    .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Link("Manage keys in Garmin Connect", destination: URL(string: "https://connect.garmin.com/app/settings/personalApiToken")!)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }

            Section("In the background") {
                Toggle("Open Splits at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                                                             set: setOpenAtLogin))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve Splits in Login Items to finish.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle("Send the morning briefing as a notification", isOn: $morningNotification)
                Text("Once last night's sleep has synced, Splits writes the day's briefing on this Mac and sends its headline. The briefing, the widgets and the menu bar stay up to date while Splits is running, even with its window closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                Text("An independent app by Bytefabrika. Works with Garmin Connect; not affiliated with or endorsed by Garmin. Not a medical device. See Legal for the full notices.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Your data") {
                Text("Everything Splits downloads stays on this Mac. Removing it deletes the key from your keychain and all downloaded data. Your online account isn't touched.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Remove Key and Data…", role: .destructive) { confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .frame(width: 480, height: 680)  // tall enough that "Remove Key and Data…" isn't cut off
        .confirmationDialog("Remove your key and everything Splits downloaded?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Keychain.deleteKey()
                try? context.delete(model: Activity.self)
                try? context.delete(model: Day.self)
                try? context.save()
                UserDefaults.standard.removeObject(forKey: "lastSync")
                UserDefaults.standard.removeObject(forKey: "welcomed")
                Task { await Tracks.shared.removeAll(); await RecordStore.shared.removeAll() }
                UserDefaults.standard.removeObject(forKey: "coordinatesBackfilled")
                NotificationCenter.default.post(name: .splitsKeyRemoved, object: nil)
            }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
