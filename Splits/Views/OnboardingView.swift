import SwiftUI

/// First run: paste the Personal API key from Garmin Connect.
struct OnboardingView: View {
    let onSave: (String) -> Void
    @State private var key = ""
    @Environment(\.openURL) private var openURL

    private var cleaned: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Your Garmin data, on your Mac").font(.largeTitle.bold())
            Text("Splits reads your activities, sleep, HRV and Body Battery with Garmin's Personal API, and keeps them here on this Mac. Nothing goes anywhere but between your Mac and Garmin.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Open the Personal API Key page in Garmin Connect and sign in.")
                step(2, "Click Create Key, accept the terms, pick how long it should last (a year is easiest), and copy the key.")
                step(3, "Paste it below. It's stored in your Mac's keychain.")
            }

            Button("Open Garmin Connect") {
                openURL(URL(string: "https://connect.garmin.com/app/settings/personalApiToken")!)
            }

            SecureField("Personal API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !cleaned.isEmpty { onSave(cleaned) } }

            HStack {
                Button("Save and Sync") { onSave(cleaned) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                Spacer()
                Text("Garmin's terms: the key is yours alone. Don't share it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .frame(maxWidth: 560)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 22, height: 22)
                .background(.tint.opacity(0.15), in: Circle())
            Text(text)
        }
    }
}
