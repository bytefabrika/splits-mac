import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @State private var newKey = ""
    @State private var confirmRemove = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Garmin Personal API key") {
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

            Section("Your data") {
                Text("Everything Splits downloads stays on this Mac. Removing it deletes the key from your keychain and all downloaded data. Your Garmin account isn't touched.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Remove Key and Data…", role: .destructive) { confirmRemove = true }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .confirmationDialog("Remove your key and everything Splits downloaded?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) {
                Keychain.deleteKey()
                try? context.delete(model: Activity.self)
                try? context.delete(model: Day.self)
                try? context.save()
                UserDefaults.standard.removeObject(forKey: "lastSync")
                UserDefaults.standard.removeObject(forKey: "welcomed")
                Task { await Tracks.shared.removeAll() }
                NotificationCenter.default.post(name: .splitsKeyRemoved, object: nil)
            }
        }
    }
}
