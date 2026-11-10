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

    /// The rings worth drawing on a world map: islets too small to see are left out (the largest ring always stays).
    var drawnRings: [[CLLocationCoordinate2D]] {
        let areas = rings.indices.map(ringArea)
        let largest = areas.max() ?? 0
        return rings.indices.filter { areas[$0] >= 0.02 || areas[$0] == largest }.map { rings[$0] }
    }

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

    func ringArea(_ i: Int) -> Double {
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

/// A city or town of 15,000 people or more, from GeoNames (CC BY 4.0, geonames.org), bundled like the borders.
struct City: Identifiable, Hashable {
    let id: Int
    let name: String
    /// ISO country code, to match a `Country`.
    let iso: String
    let coordinate: CLLocationCoordinate2D
    let population: Int
    /// The province or state, as GeoNames codes it within the country.
    let admin1: String
    /// The capital of its province or of the country.
    let capital: Bool

    static func == (a: City, b: City) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

final class CityAtlas: @unchecked Sendable {
    static let shared = CityAtlas()
    let cities: [City]
    /// Capitals of 3 million or more: their districts (Esenyurt, Hachiōji) count as the city itself.
    private(set) var megacities: [City] = []
    /// Cities by whole degree of latitude and longitude, so a lookup only looks nearby.
    private var grid: [Int: [Int]] = [:]

    /// Further than this from any town of 15,000, a run doesn't count for a city (a trail run in the mountains).
    static let maxKm = 25.0

    init(data: Data? = Bundle.main.url(forResource: "cities", withExtension: "json").flatMap { try? Data(contentsOf: $0) }) {
        // Each row: [name, country code, lat, lon, population, admin1 code, 1 if a capital].
        let rows = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[Any]] }) ?? []
        cities = rows.enumerated().compactMap { i, r in
            guard r.count == 7, let name = r[0] as? String, let iso = r[1] as? String,
                  let lat = (r[2] as? NSNumber)?.doubleValue, let lon = (r[3] as? NSNumber)?.doubleValue,
                  let pop = (r[4] as? NSNumber)?.intValue, let admin1 = r[5] as? String,
                  let capital = (r[6] as? NSNumber)?.boolValue else { return nil }
            return City(id: i, name: name, iso: iso, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                        population: pop, admin1: admin1, capital: capital)
        }
        megacities = cities.filter { $0.capital && $0.population >= 3_000_000 }
        for (i, c) in cities.enumerated() { grid[Self.cell(c.coordinate.latitude, c.coordinate.longitude), default: []].append(i) }
    }

    private static func cell(_ lat: Double, _ lon: Double) -> Int {
        Int(floor(lat + 90)) * 1000 + Int(floor(lon + 180)) % 360
    }

    /// The city a run started in, in the same country (so a run in Istria isn't in Slovenia's Koper).
    /// Inside a big city's reach (a few km for a town, up to 12 km for a million people) the biggest one wins,
    /// so De Meern counts as Utrecht. Otherwise the nearest, with bigger towns reaching a little further.
    func city(lat: Double, lon: Double, iso: String? = nil) -> City? {
        guard let found = nearest(lat: lat, lon: lon, iso: iso) else { return nil }
        let k = cos(lat * .pi / 180)
        let mega = megacities.first { m in
            m.iso == found.iso && m.admin1 == found.admin1 && m != found
                && hypot(m.coordinate.latitude - lat, (m.coordinate.longitude - lon) * k) * 111.2 <= 60
        }
        return mega ?? found
    }

    private func nearest(lat: Double, lon: Double, iso: String?) -> City? {
        let k = cos(lat * .pi / 180)
        var nearby: [(City, Double)] = []
        for dLat in -1...1 {
            for dLon in -1...1 {
                for i in grid[Self.cell(lat + Double(dLat), lon + Double(dLon))] ?? [] {
                    let c = cities[i]
                    if let iso, iso.count == 2, c.iso != iso { continue }
                    let km = hypot(c.coordinate.latitude - lat, (c.coordinate.longitude - lon) * k) * 111.2
                    if km <= Self.maxKm { nearby.append((c, km)) }
                }
            }
        }
        if let biggest = nearby.filter({ $0.1 <= Self.reach($0.0) }).max(by: { $0.0.population < $1.0.population }) {
            return biggest.0
        }
        return nearby.min { $0.1 / pow(Double(max($0.0.population, 15_000)), 0.3) < $1.1 / pow(Double(max($1.0.population, 15_000)), 0.3) }?.0
    }

    /// How far a city reaches from its centre: 5 km at 100,000 people, growing with the square root, at most 12 km.
    static func reach(_ c: City) -> Double {
        min(12, 5 * (Double(c.population) / 100_000).squareRoot())
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

    struct CityVisit: Identifiable {
        let city: City
        let country: Country
        var first: Date
        var count: Int
        var distance: Double
        var id: Int { city.id }
    }

    struct Year: Identifiable {
        let year: Int
        /// In the order first visited that year.
        let countries: [Country]
        let cityIDs: Set<Int>
        let newCities: Int
        var cities: Int { cityIDs.count }
        /// Countries visited for the first time ever that year.
        let new: Set<Country>
        var id: Int { year }
    }

    /// Every country, in the order first visited.
    var visits: [Visit] = []
    /// Each time you crossed into another country, in order: the line on the map.
    var legs: [(from: Country, to: Country, date: Date)] = []
    var years: [Year] = []
    /// Every city, in the order first visited.
    var cities: [CityVisit] = []

    /// How many and how far, for one place in one year.
    struct Tally { var count = 0; var distance = 0.0 }
    /// Year → country id → that year's activities there. For the map and lists when a year is picked.
    var countryYears: [Int: [String: Tally]] = [:]
    /// Year → city id → that year's activities there.
    var cityYears: [Int: [Int: Tally]] = [:]
    var located = 0

    var continents: Set<String> { Set(visits.map(\.country.continent)) }

    init() {}

    init(points: [Point], atlas: Atlas = .shared, cityAtlas: CityAtlas = .shared) {
        let calendar = Calendar.current
        var cityByID: [Int: CityVisit] = [:]
        var cityOrder: [Int] = []
        var citiesPerYear: [Int: Set<Int>] = [:]
        var cityFirstYear: [Int: Int] = [:]
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
            countryYears[y, default: [:]][c.id, default: Tally()].count += 1
            countryYears[y, default: [:]][c.id, default: Tally()].distance += p.distance
            if firstYear[c.id] == nil { firstYear[c.id] = y }

            if let city = cityAtlas.city(lat: p.lat, lon: p.lon, iso: c.iso) {
                if var v = cityByID[city.id] {
                    v.count += 1; v.distance += p.distance
                    cityByID[city.id] = v
                } else {
                    cityByID[city.id] = CityVisit(city: city, country: c, first: p.start, count: 1, distance: p.distance)
                    cityOrder.append(city.id)
                    cityFirstYear[city.id] = y
                }
                citiesPerYear[y, default: []].insert(city.id)
                cityYears[y, default: [:]][city.id, default: Tally()].count += 1
                cityYears[y, default: [:]][city.id, default: Tally()].distance += p.distance
            }
        }
        cities = cityOrder.compactMap { cityByID[$0] }
        visits = order.compactMap { byID[$0] }
        years = perYear.keys.sorted(by: >).map { y in
            let list = perYear[y]!
            let yearCities = citiesPerYear[y] ?? []
            return Year(year: y, countries: list, cityIDs: yearCities,
                        newCities: yearCities.filter { cityFirstYear[$0] == y }.count,
                        new: Set(list.filter { firstYear[$0.id] == y }))
        }
    }
}
