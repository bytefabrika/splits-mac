import CoreLocation
import Foundation

/// A country's border, from Natural Earth's 1:50m admin-0 countries (public domain), bundled so finding the
/// country of an activity never leaves the Mac.
struct Country: Identifiable, Hashable {
    let iso: String
    let name: String
    let continent: String
    let label: CLLocationCoordinate2D
    /// Outer rings only, as lon/lat pairs.
    let rings: [[CLLocationCoordinate2D]]
    let boxes: [(minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)]

    var id: String { iso == "-99" ? name : iso }

    /// 🇳🇱 from "NL"; a globe for places without a code.
    var flag: String {
        guard iso.count == 2 else { return "🏳️" }
        return String(String.UnicodeScalarView(iso.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    static func == (a: Country, b: Country) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    func contains(lat: Double, lon: Double) -> Int? {
        for (i, box) in boxes.enumerated()
        where lat >= box.minLat && lat <= box.maxLat && lon >= box.minLon && lon <= box.maxLon {
            if Self.inside(rings[i], lat: lat, lon: lon) { return i }
        }
        return nil
    }

    private static func inside(_ ring: [CLLocationCoordinate2D], lat: Double, lon: Double) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.latitude > lat) != (b.latitude > lat),
               lon < (b.longitude - a.longitude) * (lat - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    fileprivate func ringArea(_ i: Int) -> Double {
        let b = boxes[i]
        return (b.maxLat - b.minLat) * (b.maxLon - b.minLon)
    }
}

final class Atlas: @unchecked Sendable {
    static let shared = Atlas()
    let countries: [Country]

    init(data: Data? = Bundle.main.url(forResource: "countries", withExtension: "json").flatMap { try? Data(contentsOf: $0) }) {
        struct Raw: Decodable { let iso, name, continent: String; let label: [Double]; let rings: [[Double]] }
        let raw = (data.flatMap { try? JSONDecoder().decode([Raw].self, from: $0) }) ?? []
        countries = raw.map { r in
            let rings = r.rings.map { flat in
                stride(from: 0, to: flat.count - 1, by: 2).map { CLLocationCoordinate2D(latitude: flat[$0 + 1], longitude: flat[$0]) }
            }
            let boxes = rings.map { ring in
                (minLat: ring.map(\.latitude).min()!, maxLat: ring.map(\.latitude).max()!,
                 minLon: ring.map(\.longitude).min()!, maxLon: ring.map(\.longitude).max()!)
            }
            return Country(iso: r.iso, name: r.name, continent: r.continent,
                           label: CLLocationCoordinate2D(latitude: r.label[1], longitude: r.label[0]), rings: rings, boxes: boxes)
        }
    }

    /// The country a point is in. Borders at this scale are coarse, so a run along a beach or on a small
    /// island can fall just outside; then the nearest border within about 25 km counts.
    func country(lat: Double, lon: Double) -> Country? {
        var best: (Country, Double)?
        for c in countries {
            // Lesotho sits inside South Africa: the smaller ring wins.
            if let i = c.contains(lat: lat, lon: lon), best.map({ c.ringArea(i) < $0.1 }) ?? true { best = (c, c.ringArea(i)) }
        }
        if let best { return best.0 }

        let k = cos(lat * .pi / 180)
        var nearest: (Country, Double)?
        let margin = 0.25
        for c in countries {
            for (i, box) in c.boxes.enumerated()
            where lat >= box.minLat - margin && lat <= box.maxLat + margin && lon >= box.minLon - margin / k && lon <= box.maxLon + margin / k {
                for p in c.rings[i] {
                    let d = pow(p.latitude - lat, 2) + pow((p.longitude - lon) * k, 2)
                    if d < (nearest?.1 ?? .infinity) { nearest = (c, d) }
                }
            }
        }
        // 0.225° ≈ 25 km.
        if let nearest, nearest.1 < 0.225 * 0.225 { return nearest.0 }
        return nil
    }
}

/// Where you've been: which countries, when first, and in what order.
struct Travels {
    struct Point: Sendable {
        let id: Int64
        let start: Date
        let lat: Double
        let lon: Double
        let distance: Double
    }

    struct Visit: Identifiable {
        let country: Country
        var first: Date
        var last: Date
        var count: Int
        var distance: Double
        var id: String { country.id }
    }

    struct Year: Identifiable {
        let year: Int
        /// In the order first visited that year.
        let countries: [Country]
        /// Countries visited for the first time ever that year.
        let new: Set<Country>
        var id: Int { year }
    }

    /// Every country, in the order first visited.
    var visits: [Visit] = []
    /// Each time you crossed into another country, in order: the line on the map.
    var legs: [(from: Country, to: Country, date: Date)] = []
    var years: [Year] = []
    var located = 0

    var continents: Set<String> { Set(visits.map(\.country.continent)) }

    init() {}

    init(points: [Point], atlas: Atlas = .shared) {
        let calendar = Calendar.current
        var byID: [String: Visit] = [:]
        var order: [String] = []
        var previous: Country?
        var perYear: [Int: [Country]] = [:]
        var firstYear: [String: Int] = [:]

        for p in points.sorted(by: { $0.start < $1.start }) {
            guard let c = atlas.country(lat: p.lat, lon: p.lon) else { continue }
            located += 1
            if var v = byID[c.id] {
                v.last = p.start; v.count += 1; v.distance += p.distance
                byID[c.id] = v
            } else {
                byID[c.id] = Visit(country: c, first: p.start, last: p.start, count: 1, distance: p.distance)
                order.append(c.id)
            }
            if let previous, previous != c { legs.append((previous, c, p.start)) }
            previous = c
            let y = calendar.component(.year, from: p.start)
            if !(perYear[y]?.contains(c) ?? false) { perYear[y, default: []].append(c) }
            if firstYear[c.id] == nil { firstYear[c.id] = y }
        }
        visits = order.compactMap { byID[$0] }
        years = perYear.keys.sorted(by: >).map { y in
            let list = perYear[y]!
            return Year(year: y, countries: list, new: Set(list.filter { firstYear[$0.id] == y }))
        }
    }
}
