import MapKit
import SwiftData
import SwiftUI

/// Every route at once on a dark map, glowing brighter where you've been more often.
struct HeatmapView: View {
    enum SportFilter: String, CaseIterable, Identifiable {
        case all = "All", run = "Running", ride = "Cycling", foot = "Walking & hiking"
        var id: String { rawValue }
        func includes(_ sport: Sport) -> Bool {
            switch self {
            case .all: [.run, .ride, .walk, .hike].contains(sport)
            case .run: sport == .run
            case .ride: sport == .ride
            case .foot: sport == .walk || sport == .hike
            }
        }
    }

    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var filter: SportFilter = .run
    @State private var year: Int?
    @State private var overlay: HeatOverlay?
    @State private var fitRect: MKMapRect?
    @State private var fitToken = 0
    @State private var shownCount = 0
    @State private var shownDistance = 0.0
    private var builder: RouteBuilder { .shared }

    /// Outdoor GPS activities of the sports on this map, newest first.
    private var candidates: [Activity] {
        activities.filter { Sport.hasRoute($0) && SportFilter.all.includes($0.sport) }
    }

    private var years: [Int] {
        Array(Set(activities.map { Calendar.current.component(.year, from: $0.start) })).sorted(by: >)
    }

    var body: some View {
        ZStack(alignment: .top) {
            HeatMapRepresentable(overlay: overlay, fitRect: fitRect, fitToken: fitToken)
                .ignoresSafeArea()
            VStack(spacing: 10) {
                controls
                if !builder.finished { buildBanner }
            }
            .padding(14)
        }
        .navigationTitle("Heatmap")
        .task(id: "\(filter.rawValue)-\(year ?? 0)-\(builder.version)-\(activities.count)") { await reload() }
        .task(id: activities.count) { if !builder.running { await builder.refreshCounts(candidates.map(\.garminId)) } }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Sport", selection: $filter) {
                ForEach(SportFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 400)
            Picker("Year", selection: $year) {
                Text("All years").tag(Int?.none)
                ForEach(years, id: \.self) { Text(String($0)).tag(Int?.some($0)) }
            }
            .labelsHidden()
            .fixedSize()
            Spacer()
            Text("\(shownCount) activities · \(format.distance(shownDistance, decimals: 0))")
                .font(.callout.monospacedDigit().weight(.semibold))
            Button {
                fitRect = overlay?.boundingMapRect
                fitToken += 1
            } label: {
                Label("Fit all", systemImage: "arrow.up.left.and.arrow.down.right")
            }
        }
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var buildBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                if builder.running {
                    Text("Drawing your routes… \(builder.done) of \(builder.total)").fontWeight(.semibold)
                    ProgressView(value: builder.progress).frame(width: 260)
                } else if candidates.isEmpty {
                    Text("No outdoor activities to draw yet").fontWeight(.semibold)
                } else {
                    Text(builder.done == 0 ? "Draw your heatmap" : "\(builder.done) of \(builder.total) routes drawn").fontWeight(.semibold)
                    Text("Each route comes from the activity's file on Garmin: about a second each, once. Your Mac keeps a small copy.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem = builder.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if builder.running {
                Button("Pause") { builder.pause() }
            } else {
                Button(builder.done == 0 ? "Start" : "Continue") { builder.start(candidates.map(\.garminId)) }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(candidates.isEmpty)
            }
        }
        .padding(12)
        .frame(maxWidth: 640)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func reload() async {
        let calendar = Calendar.current
        let chosen = candidates.filter { filter.includes($0.sport) && (year == nil || calendar.component(.year, from: $0.start) == year) }
        let sports = Dictionary(uniqueKeysWithValues: chosen.map { ($0.garminId, $0.sport) })
        let routes = await RouteStore.shared.load(chosen.map(\.garminId))
        let drawn = chosen.filter { (routes[$0.garminId]?.count ?? 0) > 1 }
        shownCount = drawn.count
        shownDistance = drawn.reduce(0) { $0 + $1.distance }
        let newOverlay = HeatOverlay(routes: routes.compactMap { id, points in
            points.count > 1 ? HeatOverlay.Route(points: points.map(MKMapPoint.init), color: NSColor(sports[id]?.color ?? .orange)) : nil
        })
        let firstTime = fitRect == nil
        overlay = newOverlay
        // Start where most activities begin; without start coordinates yet, wherever the drawn routes are.
        if firstTime, let home = Self.home(chosen) ?? (newOverlay.boundingMapRect.isNull ? nil : newOverlay.boundingMapRect) {
            fitRect = home
            fitToken += 1
        }
    }

    /// Where most of the activities start: the busiest ~50 km cell, with room around it.
    static func home(_ activities: [Activity]) -> MKMapRect? {
        var cells: [String: [CLLocationCoordinate2D]] = [:]
        for a in activities {
            guard let lat = a.startLatitude, let lon = a.startLongitude else { continue }
            cells["\(Int((lat * 2).rounded())):\(Int((lon * 2).rounded()))", default: []].append(.init(latitude: lat, longitude: lon))
        }
        guard let busiest = cells.values.max(by: { $0.count < $1.count }), !busiest.isEmpty else { return nil }
        let lat = busiest.map(\.latitude).reduce(0, +) / Double(busiest.count)
        let lon = busiest.map(\.longitude).reduce(0, +) / Double(busiest.count)
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        let side = MKMapPointsPerMeterAtLatitude(lat) * 30_000
        return MKMapRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    }
}

/// All routes as one overlay, so MapKit draws them per tile instead of juggling thousands of polylines.
final class HeatOverlay: NSObject, MKOverlay {
    struct Route {
        let points: [MKMapPoint]
        let rect: MKMapRect
        let color: CGColor

        init(points: [MKMapPoint], color: NSColor) {
            self.points = points
            var rect = MKMapRect.null
            for p in points { rect = rect.union(MKMapRect(origin: p, size: MKMapSize(width: 0, height: 0))) }
            self.rect = rect
            self.color = color.withAlphaComponent(0.32).cgColor
        }
    }

    let routes: [Route]
    let boundingMapRect: MKMapRect
    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    init(routes: [Route]) {
        self.routes = routes
        boundingMapRect = routes.reduce(MKMapRect.null) { $0.union($1.rect) }
    }
}

/// Draws the routes that cross each tile with additive blending: overlapping routes glow brighter, toward white.
final class HeatRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let heat = overlay as? HeatOverlay else { return }
        let lineWidth = 2.2 / zoomScale
        let margin = lineWidth * 2
        let tile = mapRect.insetBy(dx: -margin, dy: -margin)
        // Far out, every point isn't needed: a few per screen pixel is plenty.
        let pointsPerPixel = 1 / zoomScale
        let step = max(1, Int(pointsPerPixel / (RouteStore.spacing * MKMapPointsPerMeterAtLatitude(45) * 1.5)))

        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setBlendMode(.plusLighter)
        for route in heat.routes where route.rect.intersects(tile) {
            let path = CGMutablePath()
            var i = 0
            path.move(to: point(for: route.points[0]))
            while i < route.points.count {
                path.addLine(to: point(for: route.points[i]))
                i += step
            }
            path.addLine(to: point(for: route.points[route.points.count - 1]))
            context.setStrokeColor(route.color)
            context.addPath(path)
            context.strokePath()
        }
    }
}

struct HeatMapRepresentable: NSViewRepresentable {
    let overlay: HeatOverlay?
    let fitRect: MKMapRect?
    let fitToken: Int

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.appearance = NSAppearance(named: .darkAqua)
        map.preferredConfiguration = MKStandardMapConfiguration(emphasisStyle: .muted)
        map.pointOfInterestFilter = .excludingAll
        map.showsZoomControls = true
        map.showsCompass = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        if let overlay, overlay !== context.coordinator.current {
            if let old = context.coordinator.current { map.removeOverlay(old) }
            map.addOverlay(overlay, level: .aboveRoads)
            context.coordinator.current = overlay
        }
        if fitToken != context.coordinator.fitToken, let fitRect, !fitRect.isNull {
            context.coordinator.fitToken = fitToken
            map.setVisibleMapRect(fitRect, edgePadding: NSEdgeInsets(top: 90, left: 40, bottom: 40, right: 40), animated: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var current: HeatOverlay?
        var fitToken = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            overlay is HeatOverlay ? HeatRenderer(overlay: overlay) : MKOverlayRenderer(overlay: overlay)
        }
    }
}
