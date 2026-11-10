import Charts
import MapKit
import SwiftData
import SwiftUI

/// Every country you've been active in, coloured on a world map and joined up in the order you went,
/// with how many countries each year.
struct ExplorerView: View {
    enum SportFilter: String, CaseIterable, Identifiable {
        case run = "Running", ride = "Cycling", all = "Everything"
        var id: String { rawValue }
        func includes(_ sport: Sport) -> Bool {
            switch self {
            case .run: sport == .run
            case .ride: sport == .ride
            case .all: true
            }
        }
    }

    @Query(sort: \Activity.start, order: .reverse) private var activities: [Activity]
    @Environment(\.format) private var format
    @State private var filter: SportFilter = .run
    @State private var travels = Travels()
    @State private var loading = true
    /// A year picked in the list: the map shows only that year's countries and trips.
    @State private var year: Int?
    @State private var camera: MapCameraPosition = .automatic
    /// The tooltip and the camera change on every mouse move and every frame. They live in objects this view
    /// never reads in `body`, so moving around doesn't rebuild 450 country shapes and the whole panel each time.
    @State private var hover = HoverState()
    @State private var cameraBox = CameraBox()
    /// Only this flips the view, and only when crossing the zoom where city dots appear.
    @State private var zoomedIn = false
    @State private var wheel: Any?
    /// The shapes for the countries on the map, worked out when they change rather than on every frame.
    @State private var shapes: [[CLLocationCoordinate2D]] = []

    private var color: Color { filter == .ride ? Sport.ride.color : filter == .run ? Sport.run.color : .accentColor }

    private var shownCountries: [Country] {
        if let year, let y = travels.years.first(where: { $0.year == year }) { return y.countries }
        return travels.visits.map(\.country)
    }

    private var shownCities: [Travels.CityVisit] {
        guard let year, let y = travels.years.first(where: { $0.year == year }) else { return travels.cities }
        return travels.cities.filter { y.cityIDs.contains($0.city.id) }
    }

    /// City dots only once zoomed in to a region; at world scale they'd be a smudge under the flags.
    private var showCityDots: Bool { zoomedIn }

    /// Each pair of countries once, however often you went back and forth.
    private var shownLegs: [(from: Country, to: Country, date: Date)] {
        let legs = year.map { y in travels.legs.filter { Calendar.current.component(.year, from: $0.date) == y } } ?? travels.legs
        var seen = Set<String>()
        return legs.filter { seen.insert([$0.from.id, $0.to.id].sorted().joined(separator: "-")).inserted }
    }

    var body: some View {
        HStack(spacing: 0) {
            map
            Divider()
            panel.frame(width: 330)
        }
        .navigationTitle("Explorer")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Sport", selection: $filter) {
                    ForEach(SportFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        .task(id: "\(filter.rawValue)-\(activities.count)") { await reload() }
        .onChange(of: year) {
            shapes = shownCountries.flatMap(\.drawnRings)
            withAnimation { camera = .automatic }
        }
    }

    private func reload() async {
        let points = activities.compactMap { a -> Travels.Point? in
            guard filter.includes(a.sport), !Sport.isIndoor(a.typeKey),
                  let lat = a.startLatitude, let lon = a.startLongitude, lat != 0 || lon != 0 else { return nil }
            return Travels.Point(id: a.garminId, start: a.start, lat: lat, lon: lon, distance: a.distance)
        }
        let result = await Task.detached(priority: .userInitiated) { Travels(points: points) }.value
        travels = result
        shapes = shownCountries.flatMap(\.drawnRings)
        loading = false
        if let year, !result.years.contains(where: { $0.year == year }) { self.year = nil }
        camera = .automatic
    }

    // MARK: Map

    /// "🇳🇱 Netherlands · 1,101 runs · 8,240 km", or just the name for a country you haven't been to.
    private func describe(_ c: Country) -> String {
        guard let v = travels.visits.first(where: { $0.country == c }) else { return "\(c.flag) \(c.name)" }
        var text = "\(c.flag) \(c.name) · \(v.count) \(noun(v.count))"
        if v.distance > 0 { text += " · \(format.distance(v.distance, decimals: 0))" }
        return text
    }

    private func describe(_ v: Travels.CityVisit) -> String {
        var text = "\(v.country.flag) \(v.city.name) · \(v.count) \(noun(v.count))"
        if v.distance > 0 { text += " · \(format.distance(v.distance, decimals: 0))" }
        return text
    }

    private func noun(_ n: Int) -> String {
        switch filter {
        case .run: n == 1 ? "run" : "runs"
        case .ride: n == 1 ? "ride" : "rides"
        case .all: n == 1 ? "activity" : "activities"
        }
    }

    private var map: some View {
        MapReader { proxy in
        Map(position: $camera) {
            ForEach(shapes.indices, id: \.self) { i in
                MapPolygon(coordinates: shapes[i])
                    .foregroundStyle(color.opacity(0.45))
                    .stroke(color, lineWidth: 1)
            }
            ForEach(shownLegs.indices, id: \.self) { i in
                let leg = shownLegs[i]
                MapPolyline(MKGeodesicPolyline(coordinates: [leg.from.label, leg.to.label], count: 2))
                    .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4]))
            }
            if showCityDots {
                ForEach(shownCities) { v in
                    Annotation(v.city.name, coordinate: v.city.coordinate, anchor: .center) {
                        Circle()
                            .fill(.white)
                            .overlay(Circle().stroke(color, lineWidth: 2))
                            .frame(width: 8, height: 8)
                    }
                    .annotationTitles(.hidden)
                }
            }
            ForEach(shownCountries) { c in
                Annotation(c.name, coordinate: c.label, anchor: .center) {
                    Text(c.flag)
                        .font(.system(size: 22))
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.imagery(elevation: .flat))
        .mapControls {
            MapZoomStepper()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            cameraBox.camera = context.camera
            let zoomed = context.camera.distance < 5_000_000
            if zoomed != zoomedIn { zoomedIn = zoomed }
        }
        .onHover { cameraBox.hovering = $0 }
        .onContinuousHover { phase in
            guard case .active(let p) = phase else { hover.text = nil; return }
            // Over a city dot: the city. Otherwise the country under the pointer.
            if showCityDots, let v = shownCities.first(where: { v in
                proxy.convert(v.city.coordinate, to: .local).map { hypot($0.x - p.x, $0.y - p.y) < 9 } ?? false
            }) {
                hover.show(describe(v), at: p)
            } else if let c = proxy.convert(p, from: .local), let country = Atlas.shared.country(lat: c.latitude, lon: c.longitude) {
                hover.show(describe(country), at: p)
            } else {
                hover.text = nil
            }
        }
        .overlay(alignment: .topLeading) {
            HoverTooltip(state: hover)
        }
        .onAppear { startWheelZoom() }
        .onDisappear { if let wheel { NSEvent.removeMonitor(wheel) }; wheel = nil }
        .overlay {
            if !loading && travels.visits.isEmpty {
                ContentUnavailableView("No places yet", systemImage: "globe.europe.africa",
                                       description: Text("Outdoor activities with GPS show up here once they've synced."))
                    .padding(30)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        }
    }

    /// A mouse wheel zooms, like on a web map. A trackpad keeps its own gestures: pinch to zoom, two fingers to move.
    private func startWheelZoom() {
        guard wheel == nil else { return }
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard cameraBox.hovering, !event.hasPreciseScrollingDeltas, event.scrollingDeltaY != 0, let current = cameraBox.camera else { return event }
            // Wheel up zooms in, down zooms out. MapKit stops at the whole world by itself.
            let factor = pow(1.35, -max(-4, min(4, event.scrollingDeltaY)))
            let distance = min(40_000_000, max(500, current.distance * factor))
            camera = .camera(MapCamera(centerCoordinate: current.centerCoordinate, distance: distance,
                                       heading: current.heading, pitch: current.pitch))
            return nil
        }
    }

    // MARK: Panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !travels.years.isEmpty { perYearChart }
                yearsList
                if !travels.cities.isEmpty { topCities }
                if !travels.visits.isEmpty { allCountries }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(travels.visits.count)")
                    .font(.system(size: 56, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText())
                Text(travels.visits.count == 1 ? "country" : "countries").font(.title2.weight(.bold))
            }
            Text("\(travels.cities.count) \(travels.cities.count == 1 ? "city" : "cities") · \(travels.continents.count) \(travels.continents.count == 1 ? "continent" : "continents") · \(travels.legs.count) border crossings")
                .foregroundStyle(.secondary)
            if let first = travels.visits.first {
                Text("Started in \(first.country.flag) \(first.country.name), \(first.first.formatted(.dateTime.month(.wide).year()))")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var perYearChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Countries per year").font(.headline)
            Chart(travels.years) { y in
                BarMark(x: .value("Year", String(y.year)), y: .value("Countries", y.countries.count))
                    .foregroundStyle(year == nil || year == y.year ? color : color.opacity(0.3))
                    .annotation(position: .top) {
                        Text("\(y.countries.count)").font(.caption.bold()).monospacedDigit()
                    }
            }
            .chartXScale(domain: travels.years.map { String($0.year) }.reversed())
            .chartYAxis(.hidden)
            .frame(height: 140)
        }
    }

    private var yearsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("By year").font(.headline)
                Spacer()
                if year != nil { Button("Show all") { year = nil }.buttonStyle(.link) }
            }
            ForEach(travels.years) { y in
                Button {
                    year = year == y.year ? nil : y.year
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(String(y.year)).font(.title3.weight(.heavy)).monospacedDigit()
                            Spacer()
                            Text("\(y.countries.count) \(y.countries.count == 1 ? "country" : "countries") · \(y.cities) \(y.cities == 1 ? "city" : "cities")")
                                .font(.callout.weight(.semibold))
                            if !y.new.isEmpty {
                                Text("+\(y.new.count) new")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(color.opacity(0.25), in: Capsule())
                            }
                        }
                        Text(y.countries.map(\.flag).joined(separator: " "))
                            .font(.title3)
                            .lineLimit(3)
                            .help(y.countries.map(\.name).joined(separator: ", "))
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10)
                        .fill(year == y.year ? color.opacity(0.18) : Color.primary.opacity(0.04)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @State private var allCitiesShown = false

    private var topCities: some View {
        let sorted = shownCities.sorted { ($0.count, $0.distance) > ($1.count, $1.distance) }
        let list = allCitiesShown ? sorted : Array(sorted.prefix(10))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(year.map { "Cities in \($0)" } ?? "Cities, most \(noun(2)) first").font(.headline)
                Spacer()
                Text("\(sorted.count)").font(.headline).foregroundStyle(.secondary)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { i, v in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(v.country.flag)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(v.city.name).font(.callout.weight(.semibold))
                        Text("First \(v.first.formatted(.dateTime.day().month(.abbreviated).year()))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(v.count)×").font(.callout.monospacedDigit())
                        if v.distance > 0 {
                            Text(format.distance(v.distance, decimals: 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if sorted.count > 10 {
                Button(allCitiesShown ? "Show top 10" : "Show all \(sorted.count)") { allCitiesShown.toggle() }.buttonStyle(.link)
            }
            Text("City data © GeoNames (CC BY 4.0): towns of 15,000 people or more, within 25 km of where a run started.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var allCountries: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Every country, most \(noun(2)) first").font(.headline)
            ForEach(Array(travels.visits.sorted { ($0.count, $0.distance) > ($1.count, $1.distance) }.enumerated()), id: \.element.id) { i, v in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                    Text(v.country.flag)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(v.country.name).font(.callout.weight(.semibold))
                        Text("First \(v.first.formatted(.dateTime.day().month(.abbreviated).year()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(v.count)×").font(.callout.monospacedDigit())
                        let cities = travels.cities.filter { $0.country == v.country }.count
                        Text("\(cities) \(cities == 1 ? "city" : "cities")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct Tooltip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// What the pointer is over. Only `HoverTooltip` reads it, so only the tooltip redraws as the mouse moves.
@Observable
final class HoverState {
    var text: String?
    var point: CGPoint = .zero

    func show(_ text: String, at point: CGPoint) {
        if self.text != text { self.text = text }
        self.point = point
    }
}

/// The camera as it moves, for the mouse-wheel zoom. Not observed: writing it redraws nothing.
final class CameraBox {
    var camera: MapCamera?
    var hovering = false
}

struct HoverTooltip: View {
    let state: HoverState
    var body: some View {
        if let text = state.text {
            Tooltip(text: text).offset(x: state.point.x + 14, y: state.point.y + 10)
        }
    }
}
