import CoreLocation
import SwiftUI
import UniformTypeIdentifiers

/// A picture of an activity to share: the route as a glowing line (no map underneath, so it doesn't show
/// where you live) and the main numbers. 1080 × 1350, Instagram's portrait size.
struct ShareCard: View {
    let activity: Activity
    let route: [CLLocationCoordinate2D]
    let format: Format

    static let size = CGSize(width: 540, height: 675)  // drawn at 2× → 1080 × 1350

    private var sport: Sport { activity.sport }
    private var title: String { activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.1), sport.color.opacity(0.55)],
                           startPoint: .top, endPoint: .bottomTrailing)
            Circle().fill(sport.color.opacity(0.35)).frame(width: 420).blur(radius: 90).offset(x: 180, y: -220)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: sport.symbol)
                    Text(Format.title(activity.typeKey).uppercased()).tracking(1.5)
                    Spacer()
                    Text(activity.start, format: .dateTime.day().month(.wide).year())
                }
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(.white.opacity(0.8))

                Text(title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.top, 10)

                RouteShape(route: route)
                    .stroke(sport.color, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .shadow(color: sport.color, radius: 10)
                    .overlay(RouteShape(route: route).stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)))
                    .padding(.vertical, 28)
                    .frame(maxHeight: .infinity)
                    .opacity(route.count > 1 ? 1 : 0)
                    .overlay {
                        if route.count < 2 {
                            Image(systemName: sport.symbol).font(.system(size: 140, weight: .bold)).foregroundStyle(.white.opacity(0.18))
                        }
                    }

                // Two by two: four big numbers in one row run into each other.
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                    ForEach(Array(stride(from: 0, to: stats.count, by: 2)), id: \.self) { i in
                        GridRow {
                            stat(stats[i])
                            if i + 1 < stats.count { stat(stats[i + 1]) } else { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                        }
                    }
                }
                .foregroundStyle(.white)

                HStack {
                    Spacer()
                    Label("Splits", systemImage: "figure.run.circle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 18)
            }
            .padding(36)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipped()
    }

    private func stat(_ item: (String, String)) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.1).font(.system(size: 34, weight: .heavy, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(item.0.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2).opacity(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stats: [(String, String)] {
        var items: [(String, String)] = []
        if activity.distance > 0 { items.append(("Distance", format.distance(activity.distance))) }
        items.append(("Time", Format.duration(activity.movingDuration)))
        if [.run, .walk, .hike].contains(sport), let pace = activity.paceSecondsPerKm {
            items.append(("Pace", format.pace(secondsPerKm: pace).replacingOccurrences(of: " ", with: "")))
        } else if let speed = activity.averageSpeed, speed > 0 {
            items.append(("Speed", format.speed(metresPerSecond: speed)))
        }
        if activity.elevationGain >= 10 && !Sport.isIndoor(activity.typeKey) {
            items.append(("Climb", format.elevation(activity.elevationGain)))
        } else if let hr = activity.averageHR {
            items.append(("Avg HR", "\(Int(hr))"))
        }
        return Array(items.prefix(4))
    }

    /// The card as PNG data at 1080 × 1350.
    @MainActor
    static func png(activity: Activity, route: [CLLocationCoordinate2D], format: Format) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(activity: activity, route: route, format: format))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

/// The route scaled to fit, keeping its shape (longitude shrinks with latitude).
struct RouteShape: Shape {
    let route: [CLLocationCoordinate2D]

    func path(in rect: CGRect) -> Path {
        guard route.count > 1 else { return Path() }
        let midLat = (route.map(\.latitude).min()! + route.map(\.latitude).max()!) / 2
        let k = cos(midLat * .pi / 180)
        let xs = route.map { $0.longitude * k }, ys = route.map { -$0.latitude }
        let minX = xs.min()!, maxX = xs.max()!, minY = ys.min()!, maxY = ys.max()!
        let scale = min(rect.width / max(maxX - minX, 1e-9), rect.height / max(maxY - minY, 1e-9))
        let offsetX = rect.minX + (rect.width - (maxX - minX) * scale) / 2
        let offsetY = rect.minY + (rect.height - (maxY - minY) * scale) / 2
        var path = Path()
        for i in route.indices {
            let p = CGPoint(x: offsetX + (xs[i] - minX) * scale, y: offsetY + (ys[i] - minY) * scale)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// Preview of the card with Share, Copy and Save.
struct ShareSheet: View {
    let activity: Activity
    let route: [CLLocationCoordinate2D]
    @Environment(\.format) private var format
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            ShareCard(activity: activity, route: route, format: format)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .scaleEffect(0.8)
                .frame(width: ShareCard.size.width * 0.8, height: ShareCard.size.height * 0.8)
            Text("The route is drawn without a map, so the picture doesn't show where it was.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let file {
                    ShareLink(item: file) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                }
                Button {
                    guard let png = ShareCard.png(activity: activity, route: route, format: format) else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setData(png, forType: .png)
                    copied = true
                } label: { Label(copied ? "Copied" : "Copy Image", systemImage: "doc.on.doc") }
                Button {
                    save()
                } label: { Label("Save…", systemImage: "arrow.down.circle") }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .onAppear { writeFile() }
    }

    private var fileName: String {
        let name = (activity.name.isEmpty ? Format.title(activity.typeKey) : activity.name)
            .replacingOccurrences(of: "/", with: "-")
        return "\(name) \(GarminDate.string(activity.start)).png"
    }

    /// A PNG in the temporary folder, for the share menu.
    private func writeFile() {
        guard let png = ShareCard.png(activity: activity, route: route, format: format) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try? png.write(to: url)
        file = url
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = fileName
        guard panel.runModal() == .OK, let url = panel.url,
              let png = ShareCard.png(activity: activity, route: route, format: format) else { return }
        try? png.write(to: url)
    }
}
