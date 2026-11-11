import SwiftUI

/// Slowly drifting colour blobs and floating sport symbols, behind the welcome and first-sync screens.
struct LivelyBackground: View {
    private let blobs: [(Color, Double, Double)] = [
        (Sport.run.color, 0.0, 0.9), (Sport.ride.color, 2.1, 0.7), (Sport.swim.color, 4.2, 0.8),
        (Color.purple, 1.3, 0.6), (Sport.walk.color, 3.4, 0.75),
    ]
    /// With Reduce Motion on, the background holds still (motion.md: motion is optional).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let symbols = ["figure.run", "figure.outdoor.cycle", "figure.pool.swim", "heart.fill", "bed.double.fill",
                           "bolt.heart.fill", "figure.hiking", "mountain.2.fill", "stopwatch.fill", "flame.fill"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    ForEach(Array(blobs.enumerated()), id: \.offset) { i, blob in
                        Circle()
                            .fill(blob.0.opacity(0.55))
                            .frame(width: geo.size.width * blob.2 * 0.6)
                            .position(x: geo.size.width * (0.5 + 0.35 * cos(t / 7 + blob.1)),
                                      y: geo.size.height * (0.5 + 0.35 * sin(t / 9 + blob.1 * 1.3)))
                            .blur(radius: 70)
                    }
                    ForEach(Array(symbols.enumerated()), id: \.offset) { i, name in
                        let speed = 18 + Double(i % 4) * 6
                        let progress = ((t + Double(i) * 7.3).truncatingRemainder(dividingBy: speed)) / speed
                        Image(systemName: name)
                            .font(.system(size: 22 + CGFloat(i % 3) * 10))
                            .foregroundStyle(.white.opacity(0.35))
                            .rotationEffect(.degrees(sin(t / 2 + Double(i)) * 12))
                            .position(x: geo.size.width * (0.06 + Double(i) * 0.098) + sin(t / 3 + Double(i)) * 18,
                                      y: geo.size.height * (1.1 - progress * 1.25))
                    }
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// First run: paste the Personal API key from Garmin Connect.
struct OnboardingView: View {
    let onSave: (String) -> Void
    @State private var key = ""
    @State private var bounce = 0
    @State private var showLegal = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var cleaned: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            LivelyBackground()
            VStack(spacing: 22) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 76))
                    .foregroundStyle(.white, Sport.run.color)
                    .symbolEffect(.bounce, value: bounce)
                    .accessibilityHidden(true)
                    // Ends with the view, unlike a timer; skipped with Reduce Motion.
                    .task {
                        guard !reduceMotion else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(2.6))
                            bounce += 1
                        }
                    }
                VStack(spacing: 8) {
                    Text("Every run, ride and night of sleep.")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Your watch's data, fast and beautiful, right here on your Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    StepCard(number: 1, symbol: "safari", text: "Open Personal API Key in Garmin Connect")
                    StepCard(number: 2, symbol: "key.fill", text: "Create a key and copy it")
                    StepCard(number: 3, symbol: "doc.on.clipboard", text: "Paste it here")
                }
                // Equal heights, so the numbered badges line up.
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button {
                            openURL(URL(string: "https://connect.garmin.com/app/settings/personalApiToken")!)
                        } label: {
                            Label("Open Garmin Connect", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.large)
                        SecureField("Paste your Personal API key", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .frame(width: 320)
                            .onSubmit { if !cleaned.isEmpty { onSave(cleaned) } }
                        Button {
                            onSave(cleaned)
                        } label: {
                            Label("Let's go", systemImage: "arrow.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(cleaned.isEmpty)
                    }
                    HStack(spacing: 8) {
                        PrivacyChip(symbol: "lock.fill", text: "Key stays in your keychain")
                        PrivacyChip(symbol: "person.crop.circle.badge.xmark", text: "No account")
                        PrivacyChip(symbol: "server.rack", text: "No server in between")
                    }
                    Text("Works with Garmin Connect; not affiliated with Garmin. Not medical advice. Adding your key means you accept the [legal notices](splits-legal:).")
                        // The link opens the notices here rather than in a browser.
                        .environment(\.openURL, OpenURLAction { _ in showLegal = true; return .handled })
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
            }
            .padding(40)
            .sheet(isPresented: $showLegal) {
                VStack(spacing: 0) {
                    LegalView()
                    Divider()
                    HStack { Spacer(); Button("Done") { showLegal = false }.keyboardShortcut(.defaultAction) }.padding(12)
                }
                .frame(width: 560, height: 560)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            .padding(40)
        }
    }
}

private struct StepCard: View {
    let number: Int
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: symbol).font(.title2).frame(width: 44, height: 44)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                Text("\(number)").font(.caption2.bold()).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(.tint, in: Circle()).offset(x: 6, y: -6)
            }
            Text(text).font(.callout).multilineTextAlignment(.center).frame(width: 150)
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(text)")
    }
}

private struct PrivacyChip: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.background.opacity(0.6), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

/// The first sync: your history counting up as it arrives.
struct FirstSyncView: View {
    let sync: Sync
    let onDone: () -> Void
    let onChangeKey: () -> Void
    @Environment(\.format) private var format

    private var done: Bool { sync.state == .idle && sync.lastSync != nil }

    var body: some View {
        ZStack {
            LivelyBackground()
            VStack(spacing: 26) {
                Text(done ? "Here's your history" : "Fetching your history…")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                if let oldest = sync.found.oldest {
                    Text("All the way back to \(oldest, format: .dateTime.month(.wide).year())")
                        .font(.title3).foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                HStack(spacing: 16) {
                    Counter(value: sync.found.activities, label: "activities", symbol: "figure.mixed.cardio", tint: Sport.run.color)
                    Counter(value: Int(format.distanceValue(sync.found.metres)), label: format.distanceUnit, symbol: "map.fill", tint: Sport.ride.color)
                    Counter(value: Int(sync.found.seconds / 3600), label: "hours moving", symbol: "stopwatch.fill", tint: Sport.swim.color)
                    Counter(value: sync.found.nights, label: "nights of sleep", symbol: "moon.stars.fill", tint: .purple)
                }

                FlowChips(sports: sync.found.sports)

                switch sync.state {
                case .running(let message):
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message).foregroundStyle(.secondary) }
                case .failed(let message):
                    VStack(spacing: 10) {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        HStack {
                            Button("Try Again") { Task { await sync.run() } }
                            Button("Use a Different Key", action: onChangeKey)
                        }
                    }
                case .idle:
                    if done {
                        Button(action: onDone) {
                            Label("Let's go", systemImage: "arrow.right").padding(.horizontal, 20)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.15), radius: 30, y: 10)
            .animation(.spring(duration: 0.5), value: sync.found)
            .padding(40)
        }
    }
}

private struct Counter: View {
    let value: Int
    let label: String
    let symbol: String
    let tint: Color
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(tint)
            Text(value.formatted())
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 150, height: 130)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct FlowChips: View {
    let sports: [Sport: Int]
    var body: some View {
        HStack(spacing: 8) {
            ForEach(sports.sorted { $0.value > $1.value }.prefix(7), id: \.key) { sport, count in
                Label("\(sport.label) \(count)", systemImage: sport.symbol)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(sport.color.opacity(0.22), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(minHeight: 32)
    }
}
