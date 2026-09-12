import Foundation

/// The descriptive and technical record of one asset — or of a whole project
/// — in the IPTC Core / XMP vocabulary the panel edits and every camera file
/// already speaks (docs/data-model-scale-and-metadata-2026-09-12.md §4.1).
///
/// Every field is optional and nothing is defaulted into existence: the value
/// of the record is that a reader can tell "the file did not say" from "the
/// file said this". JSON keys are the plain names below; the XMP, IPTC-IIM
/// and ImageIO spellings live in ONE place, `MetadataFieldMap`, which the
/// reader (and, later, the exporter) both walk.
///
/// Two layers of this type sit on every record: `imported` (what the file,
/// its sidecar or a catalogue said — re-derivable by re-reading) and a sparse
/// `edited` (what a person changed here). Display and export read
/// `edited ?? imported` per field — see `AssetMetadata.resolving(_:over:)`.
public struct AssetMetadata: Codable, Equatable, Sendable {

    public enum RightsStatus: String, Codable, Sendable, CaseIterable {
        case copyrighted
        case publicDomain
        case unknown
    }

    /// `Iptc4xmpCore:CreatorContactInfo` — the PHOTOGRAPHER's address, which
    /// is not where the picture was taken (that is `Location`).
    public struct CreatorContact: Codable, Equatable, Sendable {
        public var address: String?
        public var city: String?
        public var state: String?
        public var postcode: String?
        public var country: String?
        public var phone: String?
        public var email: String?
        public var website: String?
        public init() {}
        var isEmpty: Bool {
            address == nil && city == nil && state == nil && postcode == nil
                && country == nil && phone == nil && email == nil && website == nil
        }
    }

    /// Where the picture was taken — `Iptc4xmpCore:Location`, the
    /// `photoshop:` city/state/country and the ISO country code.
    public struct Location: Codable, Equatable, Sendable {
        public var sublocation: String?
        public var city: String?
        public var state: String?
        public var country: String?
        public var countryCode: String?
        public init() {}
        var isEmpty: Bool {
            sublocation == nil && city == nil && state == nil && country == nil && countryCode == nil
        }
    }

    public struct Camera: Codable, Equatable, Sendable {
        public var make: String?
        public var model: String?
        public var lens: String?
        public var serial: String?
        public init() {}
        var isEmpty: Bool { make == nil && model == nil && lens == nil && serial == nil }
    }

    public struct Exposure: Codable, Equatable, Sendable {
        /// Shutter, in seconds.
        public var seconds: Double?
        public var iso: Double?
        /// f-number.
        public var aperture: Double?
        /// Millimetres, as the lens reported.
        public var focalLength: Double?
        /// 35 mm-equivalent millimetres.
        public var focalLength35: Double?
        public init() {}
        var isEmpty: Bool {
            seconds == nil && iso == nil && aperture == nil && focalLength == nil && focalLength35 == nil
        }
    }

    public struct GPS: Codable, Equatable, Sendable {
        /// Signed decimal degrees; south and west negative.
        public var lat: Double?
        public var lon: Double?
        /// Metres; below sea level negative.
        public var altitude: Double?
        /// Degrees from north the camera faced.
        public var direction: Double?
        public init() {}
        var isEmpty: Bool { lat == nil && lon == nil && altitude == nil && direction == nil }
    }

    public struct Dimensions: Codable, Equatable, Sendable {
        public var width: Int?
        public var height: Int?
        public init() {}
        var isEmpty: Bool { width == nil && height == nil }
    }

    // Descriptive (IPTC Core).
    public var title: String?
    public var caption: String?
    /// A list because `dc:creator` is a sequence.
    public var creator: [String]?
    public var rights: String?
    /// 0…5; `xmp:Rating`.
    public var rating: Int?
    /// `xmpRights:Marked` — true → copyrighted, false → publicDomain; absent
    /// in the file stays absent here (the panel shows Unknown for both).
    public var rightsStatus: RightsStatus?
    /// `xmpRights:WebStatement`.
    public var rightsURL: String?
    /// `xmpRights:UsageTerms`.
    public var usageTerms: String?
    public var creatorContact: CreatorContact?
    public var location: Location?
    /// `dc:subject` — and where the app's tags live from Milestone 1 on.
    public var keywords: [String]?

    // Technical (Exif / TIFF / XMP).
    /// ISO-8601 **with the offset the file carried**, kept as text because a
    /// `Date` forgets the zone and "20:29 in Prague" is the fact.
    public var captured: String?
    public var camera: Camera?
    public var exposure: Exposure?
    public var gps: GPS?
    public var dimensions: Dimensions?
    /// EXIF orientation 1–8.
    public var orientation: Int?
    public var software: String?

    public init() {}

    /// True when no field carries a value — the record encodes as `{}`.
    public var isEmpty: Bool {
        MetadataField.allCases.allSatisfy { self[$0] == nil }
    }

    /// Drops nested structs that have emptied out, so a record never carries
    /// `"camera": {}`.
    public mutating func normalize() {
        if creatorContact?.isEmpty == true { creatorContact = nil }
        if location?.isEmpty == true { location = nil }
        if camera?.isEmpty == true { camera = nil }
        if exposure?.isEmpty == true { exposure = nil }
        if gps?.isEmpty == true { gps = nil }
        if dimensions?.isEmpty == true { dimensions = nil }
        if creator?.isEmpty == true { creator = nil }
        if keywords?.isEmpty == true { keywords = nil }
    }

    // MARK: - Field access

    /// Every leaf value the record can hold, by `MetadataField`, so the
    /// mapping table and the panel can walk the record without a switch of
    /// their own.
    public subscript(field: MetadataField) -> MetadataValue? {
        get {
            switch field {
            case .title: return title.map(MetadataValue.text)
            case .caption: return caption.map(MetadataValue.text)
            case .creator: return creator.map(MetadataValue.list)
            case .rights: return rights.map(MetadataValue.text)
            case .rating: return rating.map(MetadataValue.integer)
            case .rightsStatus: return rightsStatus.map { .text($0.rawValue) }
            case .rightsURL: return rightsURL.map(MetadataValue.text)
            case .usageTerms: return usageTerms.map(MetadataValue.text)
            case .contactAddress: return creatorContact?.address.map(MetadataValue.text)
            case .contactCity: return creatorContact?.city.map(MetadataValue.text)
            case .contactState: return creatorContact?.state.map(MetadataValue.text)
            case .contactPostcode: return creatorContact?.postcode.map(MetadataValue.text)
            case .contactCountry: return creatorContact?.country.map(MetadataValue.text)
            case .contactPhone: return creatorContact?.phone.map(MetadataValue.text)
            case .contactEmail: return creatorContact?.email.map(MetadataValue.text)
            case .contactWebsite: return creatorContact?.website.map(MetadataValue.text)
            case .locationSublocation: return location?.sublocation.map(MetadataValue.text)
            case .locationCity: return location?.city.map(MetadataValue.text)
            case .locationState: return location?.state.map(MetadataValue.text)
            case .locationCountry: return location?.country.map(MetadataValue.text)
            case .locationCountryCode: return location?.countryCode.map(MetadataValue.text)
            case .keywords: return keywords.map(MetadataValue.list)
            case .captured: return captured.map(MetadataValue.text)
            case .cameraMake: return camera?.make.map(MetadataValue.text)
            case .cameraModel: return camera?.model.map(MetadataValue.text)
            case .cameraLens: return camera?.lens.map(MetadataValue.text)
            case .cameraSerial: return camera?.serial.map(MetadataValue.text)
            case .exposureSeconds: return exposure?.seconds.map(MetadataValue.number)
            case .exposureISO: return exposure?.iso.map(MetadataValue.number)
            case .exposureAperture: return exposure?.aperture.map(MetadataValue.number)
            case .exposureFocalLength: return exposure?.focalLength.map(MetadataValue.number)
            case .exposureFocalLength35: return exposure?.focalLength35.map(MetadataValue.number)
            case .gpsLatitude: return gps?.lat.map(MetadataValue.number)
            case .gpsLongitude: return gps?.lon.map(MetadataValue.number)
            case .gpsAltitude: return gps?.altitude.map(MetadataValue.number)
            case .gpsDirection: return gps?.direction.map(MetadataValue.number)
            case .width: return dimensions?.width.map(MetadataValue.integer)
            case .height: return dimensions?.height.map(MetadataValue.integer)
            case .orientation: return orientation.map(MetadataValue.integer)
            case .software: return software.map(MetadataValue.text)
            }
        }
        set {
            switch field {
            case .title: title = newValue?.textValue
            case .caption: caption = newValue?.textValue
            case .creator: creator = newValue?.listValue
            case .rights: rights = newValue?.textValue
            case .rating: rating = newValue?.integerValue
            case .rightsStatus: rightsStatus = newValue?.textValue.flatMap(RightsStatus.init(rawValue:))
            case .rightsURL: rightsURL = newValue?.textValue
            case .usageTerms: usageTerms = newValue?.textValue
            case .contactAddress: withContact { $0.address = newValue?.textValue }
            case .contactCity: withContact { $0.city = newValue?.textValue }
            case .contactState: withContact { $0.state = newValue?.textValue }
            case .contactPostcode: withContact { $0.postcode = newValue?.textValue }
            case .contactCountry: withContact { $0.country = newValue?.textValue }
            case .contactPhone: withContact { $0.phone = newValue?.textValue }
            case .contactEmail: withContact { $0.email = newValue?.textValue }
            case .contactWebsite: withContact { $0.website = newValue?.textValue }
            case .locationSublocation: withLocation { $0.sublocation = newValue?.textValue }
            case .locationCity: withLocation { $0.city = newValue?.textValue }
            case .locationState: withLocation { $0.state = newValue?.textValue }
            case .locationCountry: withLocation { $0.country = newValue?.textValue }
            case .locationCountryCode: withLocation { $0.countryCode = newValue?.textValue }
            case .keywords: keywords = newValue?.listValue
            case .captured: captured = newValue?.textValue
            case .cameraMake: withCamera { $0.make = newValue?.textValue }
            case .cameraModel: withCamera { $0.model = newValue?.textValue }
            case .cameraLens: withCamera { $0.lens = newValue?.textValue }
            case .cameraSerial: withCamera { $0.serial = newValue?.textValue }
            case .exposureSeconds: withExposure { $0.seconds = newValue?.numberValue }
            case .exposureISO: withExposure { $0.iso = newValue?.numberValue }
            case .exposureAperture: withExposure { $0.aperture = newValue?.numberValue }
            case .exposureFocalLength: withExposure { $0.focalLength = newValue?.numberValue }
            case .exposureFocalLength35: withExposure { $0.focalLength35 = newValue?.numberValue }
            case .gpsLatitude: withGPS { $0.lat = newValue?.numberValue }
            case .gpsLongitude: withGPS { $0.lon = newValue?.numberValue }
            case .gpsAltitude: withGPS { $0.altitude = newValue?.numberValue }
            case .gpsDirection: withGPS { $0.direction = newValue?.numberValue }
            case .width: withDimensions { $0.width = newValue?.integerValue }
            case .height: withDimensions { $0.height = newValue?.integerValue }
            case .orientation: orientation = newValue?.integerValue
            case .software: software = newValue?.textValue
            }
            normalize()
        }
    }

    private mutating func withContact(_ edit: (inout CreatorContact) -> Void) {
        var value = creatorContact ?? CreatorContact()
        edit(&value)
        creatorContact = value
    }
    private mutating func withLocation(_ edit: (inout Location) -> Void) {
        var value = location ?? Location()
        edit(&value)
        location = value
    }
    private mutating func withCamera(_ edit: (inout Camera) -> Void) {
        var value = camera ?? Camera()
        edit(&value)
        camera = value
    }
    private mutating func withExposure(_ edit: (inout Exposure) -> Void) {
        var value = exposure ?? Exposure()
        edit(&value)
        exposure = value
    }
    private mutating func withGPS(_ edit: (inout GPS) -> Void) {
        var value = gps ?? GPS()
        edit(&value)
        gps = value
    }
    private mutating func withDimensions(_ edit: (inout Dimensions) -> Void) {
        var value = dimensions ?? Dimensions()
        edit(&value)
        dimensions = value
    }

    // MARK: - Layering

    /// `over` with every field `top` carries laid on top — `edited ?? imported`
    /// per field, or "sidecar over embedded" at read time. A field absent from
    /// `top` keeps the value underneath.
    public static func resolving(_ top: AssetMetadata?, over base: AssetMetadata?) -> AssetMetadata {
        var result = base ?? AssetMetadata()
        guard let top else { return result }
        for field in MetadataField.allCases {
            if let value = top[field] { result[field] = value }
        }
        return result
    }

    /// Resolves a chain, first entry on top: `[assetEdited, projectEdited,
    /// assetImported, projectImported]`.
    public static func resolving(_ layers: [AssetMetadata?]) -> AssetMetadata {
        var result = AssetMetadata()
        for layer in layers.reversed() {
            result = resolving(layer, over: result)
        }
        return result
    }

    /// The fields on which every record in `records` agrees — what a whole
    /// interval shoot can be said to carry (the camera, the photographer, the
    /// rights) without claiming one frame's five stars for all of them.
    /// `keywords` is the exception: a project's keyword bag is the union of
    /// its frames', because that is what a keyword on any frame means for the
    /// set that holds it.
    public static func common(across records: [AssetMetadata]) -> AssetMetadata {
        guard let first = records.first else { return AssetMetadata() }
        var result = AssetMetadata()
        for field in MetadataField.allCases where field != .keywords {
            guard let value = first[field] else { continue }
            if records.dropFirst().allSatisfy({ $0[field] == value }) { result[field] = value }
        }
        var bag: [String] = []
        for record in records {
            for keyword in record.keywords ?? [] where !bag.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
                bag.append(keyword)
            }
        }
        if !bag.isEmpty { result.keywords = bag }
        return result
    }

    /// The exposure line the panel shows: "3.2 s · f/4.5 · ISO 100 · 28 mm".
    public var exposureLine: String? {
        guard let exposure else { return nil }
        var parts: [String] = []
        if let seconds = exposure.seconds { parts.append(Self.shutterLabel(seconds)) }
        if let aperture = exposure.aperture { parts.append(String(format: "f/%g", aperture)) }
        if let iso = exposure.iso { parts.append("ISO \(Int(iso.rounded()))") }
        if let focal = exposure.focalLength {
            if let focal35 = exposure.focalLength35, abs(focal35 - focal) > 0.5 {
                parts.append(String(format: "%g mm (%g mm eq.)", focal, focal35))
            } else {
                parts.append(String(format: "%g mm", focal))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "3.2 s", "1/250 s", "30 s".
    public static func shutterLabel(_ seconds: Double) -> String {
        guard seconds > 0 else { return "0 s" }
        if seconds >= 0.3 { return String(format: seconds == seconds.rounded() ? "%.0f s" : "%.1f s", seconds) }
        let denominator = (1 / seconds).rounded()
        return "1/\(Int(denominator)) s"
    }

    /// "50.0897° N 14.4116° E · 2 m".
    public var gpsLine: String? {
        guard let gps, let lat = gps.lat, let lon = gps.lon else { return nil }
        var line = String(format: "%.4f° %@ %.4f° %@", abs(lat), lat >= 0 ? "N" : "S", abs(lon), lon >= 0 ? "E" : "W")
        if let altitude = gps.altitude { line += String(format: " · %.0f m", altitude) }
        return line
    }

    /// "SONY ILCE-7M4" — the model alone when it already names the maker.
    public var cameraLine: String? {
        guard let camera else { return nil }
        switch (camera.make, camera.model) {
        case let (make?, model?):
            return model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)"
        case let (make?, nil): return make
        case let (nil, model?): return model
        default: return nil
        }
    }

    /// `captured` as a `Date`, when it parses; the offset text is kept for
    /// display by the caller.
    public var capturedDate: Date? {
        guard let captured else { return nil }
        return Self.parseISO8601(captured)
    }

    public static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        // No zone at all: read in the current zone, as every photo tool does.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Every leaf field of `AssetMetadata`, named by its JSON key path.
public enum MetadataField: String, CaseIterable, Sendable, Codable {
    case title, caption, creator, rights, rating, rightsStatus, rightsURL, usageTerms
    case contactAddress = "creatorContact.address"
    case contactCity = "creatorContact.city"
    case contactState = "creatorContact.state"
    case contactPostcode = "creatorContact.postcode"
    case contactCountry = "creatorContact.country"
    case contactPhone = "creatorContact.phone"
    case contactEmail = "creatorContact.email"
    case contactWebsite = "creatorContact.website"
    case locationSublocation = "location.sublocation"
    case locationCity = "location.city"
    case locationState = "location.state"
    case locationCountry = "location.country"
    case locationCountryCode = "location.countryCode"
    case keywords
    case captured
    case cameraMake = "camera.make"
    case cameraModel = "camera.model"
    case cameraLens = "camera.lens"
    case cameraSerial = "camera.serial"
    case exposureSeconds = "exposure.seconds"
    case exposureISO = "exposure.iso"
    case exposureAperture = "exposure.aperture"
    case exposureFocalLength = "exposure.focalLength"
    case exposureFocalLength35 = "exposure.focalLength35"
    case gpsLatitude = "gps.lat"
    case gpsLongitude = "gps.lon"
    case gpsAltitude = "gps.altitude"
    case gpsDirection = "gps.direction"
    case width = "dimensions.width"
    case height = "dimensions.height"
    case orientation, software

    /// The fields a person edits in the panel, in the panel's order. The rest
    /// are the read-only Info group.
    public static let editable: [MetadataField] = [
        .title, .caption, .creator, .rights, .rating, .rightsStatus, .rightsURL, .usageTerms,
        .contactAddress, .contactCity, .contactState, .contactPostcode, .contactCountry,
        .contactPhone, .contactEmail, .contactWebsite,
        .locationSublocation, .locationCity, .locationState, .locationCountry, .locationCountryCode,
        .keywords,
    ]

    /// The read-only group.
    public static let informational: [MetadataField] = allCases.filter { !editable.contains($0) }

    /// The panel's label.
    public var label: String {
        switch self {
        case .title: return "Title"
        case .caption: return "Caption"
        case .creator: return "Creator"
        case .rights: return "Copyright"
        case .rating: return "Rating"
        case .rightsStatus: return "Copyright status"
        case .rightsURL: return "Copyright URL"
        case .usageTerms: return "Usage terms"
        case .contactAddress: return "Address"
        case .contactCity: return "City"
        case .contactState: return "State"
        case .contactPostcode: return "Postcode"
        case .contactCountry: return "Country"
        case .contactPhone: return "Phone"
        case .contactEmail: return "Email"
        case .contactWebsite: return "Website"
        case .locationSublocation: return "Sublocation"
        case .locationCity: return "City"
        case .locationState: return "State"
        case .locationCountry: return "Country"
        case .locationCountryCode: return "Country code"
        case .keywords: return "Keywords"
        case .captured: return "Captured"
        case .cameraMake: return "Make"
        case .cameraModel: return "Model"
        case .cameraLens: return "Lens"
        case .cameraSerial: return "Serial"
        case .exposureSeconds: return "Shutter"
        case .exposureISO: return "ISO"
        case .exposureAperture: return "Aperture"
        case .exposureFocalLength: return "Focal length"
        case .exposureFocalLength35: return "Focal length (35 mm)"
        case .gpsLatitude: return "Latitude"
        case .gpsLongitude: return "Longitude"
        case .gpsAltitude: return "Altitude"
        case .gpsDirection: return "Direction"
        case .width: return "Width"
        case .height: return "Height"
        case .orientation: return "Orientation"
        case .software: return "Software"
        }
    }
}

/// A leaf value, typed the way the record stores it.
public enum MetadataValue: Equatable, Sendable {
    case text(String)
    case list([String])
    case integer(Int)
    case number(Double)

    public var textValue: String? {
        switch self {
        case .text(let value): return value
        case .list(let values): return values.joined(separator: ", ")
        case .integer(let value): return String(value)
        case .number(let value): return String(value)
        }
    }

    public var listValue: [String]? {
        switch self {
        case .list(let values): return values
        case .text(let value):
            let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts
        default: return nil
        }
    }

    public var integerValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(value.rounded())
        case .text(let value): return Int(value.trimmingCharacters(in: .whitespaces))
        case .list: return nil
        }
    }

    public var numberValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        case .text(let value): return Double(value.trimmingCharacters(in: .whitespaces))
        case .list: return nil
        }
    }
}
