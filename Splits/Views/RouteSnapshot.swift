import MapKit
import SwiftUI

/// The route on a still map image: MapKit draws the map once, and the route and the chart cursor's marker are
/// drawn on top with our own projection. Cheap to scroll past, unlike a live map.
struct RouteSnapshot: View {
    let analysis: TrackAnalysis
    let sport: Sport
    var selectedKm: Double?
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var mapRect: MKMapRect?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                if let image {
                    Image(nsImage: image).resizable()
                } else {
                    Rectangle().fill(.quaternary.opacity(0.4))
                    ProgressView().controlSize(.small)
                }
                if let mapRect {
                    let segments = RouteMap.segments(analysis)
                    Canvas { context, canvasSize in
                        for segment in segments where segment.coordinates.count > 1 {
                            var path = Path()
                            path.addLines(segment.coordinates.map { project($0, in: mapRect, size: canvasSize) })
                            context.stroke(path, with: .color(.white.opacity(0.85)),
                                           style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                            context.stroke(path, with: .color(segment.color),
                                           style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .drawingGroup()
                    if let first = analysis.route.first {
                        Circle().fill(.green).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 2)
                            .position(project(first, in: mapRect, size: size))
                    }
                    if let last = analysis.route.last {
                        Image(systemName: "flag.checkered.circle.fill").font(.title).foregroundStyle(.white, .black).shadow(radius: 2)
                            .position(project(last, in: mapRect, size: size))
                    }
                    if let km = selectedKm,
                       let coordinate = analysis.samples.filter({ $0.coordinate != nil }).min(by: { abs($0.km - km) < abs($1.km - km) })?.coordinate {
                        ZStack {
                            Circle().fill(sport.color.opacity(0.3)).frame(width: 34, height: 34)
                            Circle().fill(sport.color).frame(width: 16, height: 16).overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                        .shadow(radius: 4)
                        .position(project(coordinate, in: mapRect, size: size))
                    }
                }
            }
            .task(id: "\(Int(size.width))x\(Int(size.height))-\(colorScheme)") { await snapshot(size: size) }
        }
    }

    /// Web Mercator, which is what MapKit draws: MKMapPoint grows right and down, like view coordinates.
    private func project(_ c: CLLocationCoordinate2D, in rect: MKMapRect, size: CGSize) -> CGPoint {
        let p = MKMapPoint(c)
        return CGPoint(x: (p.x - rect.minX) / rect.width * size.width, y: (p.y - rect.minY) / rect.height * size.height)
    }

    /// The route's bounds with some room, stretched to the view's shape so MapKit doesn't adjust it.
    static func fittedRect(_ route: [CLLocationCoordinate2D], size: CGSize) -> MKMapRect? {
        guard let first = route.first, size.width > 0, size.height > 0 else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first), size: MKMapSize(width: 0, height: 0))
        for c in route { rect = rect.union(MKMapRect(origin: MKMapPoint(c), size: MKMapSize(width: 0, height: 0))) }
        let minSide = MKMapPointsPerMeterAtLatitude(first.latitude) * 300  // at least ~300 m across
        var width = max(rect.width, minSide) * 1.25, height = max(rect.height, minSide) * 1.25
        let aspect = size.width / size.height
        if width / height < aspect { width = height * aspect } else { height = width / aspect }
        return MKMapRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    private func snapshot(size: CGSize) async {
        guard let rect = Self.fittedRect(analysis.route, size: size) else { return }
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = size
        options.pointOfInterestFilter = .excludingAll
        options.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        do {
            let shot = try await MKMapSnapshotter(options: options).start()
            image = shot.image
            mapRect = rect
        } catch {
            // No map tiles (offline): still draw the route on a plain background.
            mapRect = rect
        }
    }
}
