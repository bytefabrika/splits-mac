import SwiftUI

/// Behind the welcome and first-sync screens: an athletics track in hairlines, with one runner lapping the
/// outside lane past the split marks. The one moving thing on the screen; with Reduce Motion it stands still.
struct TrackBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Seconds a lap.
    private let lap = 26.0
    private let lanes = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let progress = reduceMotion ? 0.62 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: lap) / lap
            Canvas { canvas, size in
                // A standard track's proportions: straights about as long as the bends are wide.
                let height = min(size.height * 0.78, size.width * 0.5)
                let width = min(size.width * 0.86, height * 1.9)
                let lane = height * 0.035
                let rect = CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
                let line = GraphicsContext.Shading.color(.primary.opacity(0.07))
                for i in 0...lanes {
                    canvas.stroke(Self.track(rect.insetBy(dx: CGFloat(i) * lane, dy: CGFloat(i) * lane)), with: line, lineWidth: 1)
                }
                // The runner's lane, between the outer two lines.
                let path = Self.track(rect.insetBy(dx: lane / 2, dy: lane / 2))
                // Split marks where the straights meet the bends, straight across the lanes, as on a real track.
                // Every lane's bend has the same centre, so the marks share an x.
                let radius = height / 2 - lane / 2
                let straight = width - height
                let perimeter = 2 * straight + 2 * .pi * radius
                let joints: [(x: CGFloat, top: Bool, t: Double)] = [
                    (rect.minX + height / 2, false, 0),
                    (rect.maxX - height / 2, false, straight / perimeter),
                    (rect.maxX - height / 2, true, (straight + .pi * radius) / perimeter),
                    (rect.minX + height / 2, true, (2 * straight + .pi * radius) / perimeter),
                ]
                for joint in joints {
                    var mark = Path()
                    let outerY = joint.top ? rect.minY : rect.maxY
                    let innerY = joint.top ? rect.minY + CGFloat(lanes) * lane : rect.maxY - CGFloat(lanes) * lane
                    mark.move(to: CGPoint(x: joint.x, y: outerY))
                    mark.addLine(to: CGPoint(x: joint.x, y: innerY))
                    let passed = (progress - joint.t + 1).truncatingRemainder(dividingBy: 1) < 0.06
                    canvas.stroke(mark, with: .color(passed ? Sport.run.color.opacity(0.6) : .primary.opacity(0.12)), lineWidth: passed ? 2 : 1)
                }
                // A short fading trail behind the runner.
                let trail = 0.12
                let steps = 24
                for s in 0..<steps {
                    // Each piece overlaps the next a little, so the trail reads as one line.
                    let a = progress - trail * Double(s + 1) / Double(steps), b = progress - trail * Double(s) / Double(steps) + 0.003
                    let segment = a < 0 ? path.trimmedPath(from: a + 1, to: min(b + 1, 1)) : path.trimmedPath(from: a, to: min(b, 1))
                    canvas.stroke(segment, with: .color(Sport.run.color.opacity(0.55 * (1 - Double(s) / Double(steps)))),
                                  style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                }
                if let point = Self.point(path, progress) {
                    let dot = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
                    canvas.fill(Path(ellipseIn: dot.insetBy(dx: -6, dy: -6)), with: .color(Sport.run.color.opacity(0.15)))
                    canvas.fill(Path(ellipseIn: dot), with: .color(Sport.run.color))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private static func point(_ path: Path, _ t: Double) -> CGPoint? {
        path.trimmedPath(from: 0, to: max(min(t, 1), 0.0001)).currentPoint
    }

    /// A stadium: two straights joined by half circles, starting at the bottom of the left bend and running anticlockwise.
    static func track(_ r: CGRect) -> Path {
        let radius = r.height / 2
        var p = Path()
        p.move(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        p.addArc(center: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(-90), clockwise: true)
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
        p.addArc(center: CGPoint(x: r.minX + radius, y: r.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        return p
    }
}

/// The app icon, as the Finder shows it.
private struct AppIcon: View {
    var size: CGFloat = 96
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .accessibilityHidden(true)
    }
}

/// First run, in two steps: what Splits is, then the Personal API key.
struct OnboardingView: View {
    let onSave: (String) -> Void
    @State private var step = 0
    @State private var key = ""
    @State private var showLegal = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var keyFocused: Bool

    private var cleaned: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ZStack {
            TrackBackground()
            Group {
                if step == 0 {
                    intro.transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                } else {
                    connect.transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: 520)
            .padding(40)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: step)
        .sheet(isPresented: $showLegal) {
            VStack(spacing: 0) {
                LegalView()
                Divider()
                HStack { Spacer(); Button("Done") { showLegal = false }.keyboardShortcut(.defaultAction) }.padding(12)
            }
            .frame(width: 560, height: 560)
        }
        #if DEBUG
        // `-welcomeStep 1`: the key step, for screenshots.
        .onAppear { step = UserDefaults.standard.integer(forKey: "welcomeStep") }
        #endif
    }

    // MARK: Step 1

    private var intro: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                AppIcon()
                Text("Welcome to Splits")
                    .font(.system(size: 34, weight: .bold))
                Text("Your training, sleep and recovery, on your Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 18) {
                Feature(symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: Sport.run.color,
                        title: "Every activity, in detail", text: "Routes, splits, heart rate and records, from all your years.")
                Feature(symbol: "moon.zzz.fill", tint: .indigo,
                        title: "Sleep and recovery", text: "HRV and sleep, read against your own normal.")
                Feature(symbol: "lock.fill", tint: .secondary,
                        title: "Private by design", text: "No account, no server. Your data stays on this Mac.")
            }
            .frame(maxWidth: 400, alignment: .leading)

            Button {
                step = 1
            } label: {
                Text("Continue").frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .tint(Sport.run.color)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Step 2

    private var connect: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "key.horizontal.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Sport.run.color)
                    .accessibilityHidden(true)
                Text("Connect your watch")
                    .font(.system(size: 30, weight: .bold))
                Text("Splits reads your data with a Personal API key that only you can create.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 14) {
                Instruction(number: 1) {
                    HStack(spacing: 8) {
                        Text("Open **Personal API Key** in Garmin Connect.")
                        Button("Open") {
                            openURL(URL(string: "https://connect.garmin.com/app/settings/personalApiToken")!)
                        }
                        .controlSize(.small)
                    }
                }
                Instruction(number: 2) { Text("Create a key and copy it.") }
                Instruction(number: 3) { Text("Paste it here.") }
            }
            .frame(maxWidth: 400, alignment: .leading)

            VStack(spacing: 12) {
                SecureField("Personal API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .frame(width: 400)
                    .focused($keyFocused)
                    .onSubmit { if !cleaned.isEmpty { onSave(cleaned) } }
                HStack(spacing: 12) {
                    Button("Back") { step = 0 }
                        .controlSize(.extraLarge)
                    Button {
                        onSave(cleaned)
                    } label: {
                        Text("Connect").frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Sport.run.color)
                    .controlSize(.extraLarge)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                }
                Label("The key stays in your keychain and is only used to fetch your own data.", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("Works with Garmin Connect; not affiliated with Garmin. Not medical advice. Connecting means you accept the [legal notices](splits-legal:).")
                // The link opens the notices here rather than in a browser.
                .environment(\.openURL, OpenURLAction { _ in showLegal = true; return .handled })
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .onAppear { keyFocused = true }
    }
}

private struct Feature: View {
    let symbol: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Instruction<Content: View>: View {
    let number: Int
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.separator))
            content
        }
        .accessibilityElement(children: .combine)
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
            TrackBackground()
            VStack(spacing: 30) {
                VStack(spacing: 10) {
                    AppIcon(size: 72)
                    Text(done ? "Here's your history" : "Fetching your history…")
                        .font(.system(size: 30, weight: .bold))
                    Text(sync.found.oldest.map { "All the way back to \($0.formatted(.dateTime.month(.wide).year()))" } ?? " ")
                        .font(.title3).foregroundStyle(.secondary)
                }

                HStack(spacing: 0) {
                    Counter(value: sync.found.activities, label: "activities", symbol: "figure.mixed.cardio", tint: Sport.run.color)
                    Divider().frame(height: 60)
                    Counter(value: Int(format.distanceValue(sync.found.metres)), label: format.distanceUnit,
                            symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: Sport.ride.color)
                    Divider().frame(height: 60)
                    Counter(value: Int(sync.found.seconds / 3600), label: "hours moving", symbol: "stopwatch", tint: Sport.swim.color)
                    Divider().frame(height: 60)
                    Counter(value: sync.found.nights, label: "nights of sleep", symbol: "moon.zzz.fill", tint: .indigo)
                }

                SportList(sports: sync.found.sports)

                Group {
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
                            Button(action: onDone) { Text("Start Exploring").frame(minWidth: 220) }
                                .buttonStyle(.borderedProminent)
                                .tint(Sport.run.color)
                                .controlSize(.extraLarge)
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                }
                .frame(minHeight: 44)
            }
            .animation(.smooth(duration: 0.5), value: sync.found)
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
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint)
            Text(value.formatted())
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .accessibilityElement(children: .combine)
    }
}

/// The sports found so far, most first: symbols in their colour, words neutral.
private struct SportList: View {
    let sports: [Sport: Int]
    var body: some View {
        HStack(spacing: 18) {
            ForEach(sports.sorted { $0.value > $1.value }.prefix(6), id: \.key) { sport, count in
                Label {
                    Text("\(sport.label) ") + Text(count.formatted()).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: sport.symbol).foregroundStyle(sport.color)
                }
                .font(.callout)
                .transition(.opacity)
            }
        }
        .frame(minHeight: 24)
    }
}
