import Foundation

/// A Lightroom Classic catalogue (`.lrcat`), read and never written.
///
/// Opened `immutable` and read-only (`SQLiteDatabase(readingImmutable:)`),
/// so no lock is taken and no journal is created beside the file — the
/// catalogue's bytes are exactly what they were. What is read is the part
/// of Lightroom's schema that carries a photographer's own statements about
/// a picture (Part 2 §2, §6): the rating, pick and capture time on
/// `Adobe_images`; caption and copyright in `AgLibraryIPTC`; the interned
/// creator, city, state, country, country code and location in
/// `AgHarvestedIptcMetadata`; keywords through `AgLibraryKeywordImage`; the
/// harvested camera, lens, exposure and GPS; and the collections. Tables a
/// catalogue does not have (older or newer versions) are simply skipped.
///
/// Title, the rights URLs and the creator's contact block are NOT in these
/// tables — Lightroom keeps them only in the XMP it writes into or beside
/// the file — so the migration reads those from the file itself.
public final class LightroomCatalogue {

    public struct RootFolder: Equatable, Sendable {
        public var id: Int64
        public var absolutePath: String
        public var name: String
    }

    public struct Image: Equatable, Sendable {
        public var id: Int64
        public var rootFolderID: Int64
        /// The root folder's absolute path plus the folder's path from it.
        public var folderPath: String
        /// `idx_filename` — the name on disk.
        public var fileName: String
        public var fileFormat: String?
        public var captureTime: String?
        public var rating: Int?
        public var pick: Int?
        public var colorLabel: String?
        public var caption: String?
        public var copyright: String?
        public var creator: String?
        public var city: String?
        public var state: String?
        public var country: String?
        public var countryCode: String?
        public var location: String?
        public var copyrightState: Int?
        public var keywords: [String] = []
        public var cameraModel: String?
        public var lens: String?
        /// APEX Av, as Lightroom stores it: f = 2^(Av/2).
        public var apertureAPEX: Double?
        /// APEX Tv: seconds = 2^(−Tv).
        public var shutterAPEX: Double?
        public var iso: Double?
        public var focalLength: Double?
        public var gpsLatitude: Double?
        public var gpsLongitude: Double?
        public var width: Int?
        public var height: Int?

        public var path: String { (folderPath as NSString).appendingPathComponent(fileName) }
        public var aperture: Double? { apertureAPEX.map { pow(2, $0 / 2) } }
        public var shutterSeconds: Double? { shutterAPEX.map { pow(2, -$0) } }
    }

    public struct Collection: Equatable, Sendable {
        public var id: Int64
        public var name: String
        public var imageIDs: [Int64]
    }

    public let url: URL
    private let db: SQLiteDatabase

    public init(at url: URL) throws {
        self.url = url
        db = try SQLiteDatabase(readingImmutable: url)
        guard db.hasTable("Adobe_images"), db.hasTable("AgLibraryFile"), db.hasTable("AgLibraryFolder"),
              db.hasTable("AgLibraryRootFolder") else {
            throw SQLiteDatabase.Failure(message: "not a Lightroom catalogue (no Adobe_images / AgLibraryFile tables)", code: 0)
        }
    }

    public func imageCount() throws -> Int {
        Int(try db.scalar("SELECT COUNT(*) FROM Adobe_images") ?? 0)
    }

    public func rootFolders() throws -> [RootFolder] {
        try db.query("SELECT id_local, absolutePath, name FROM AgLibraryRootFolder ORDER BY id_local") {
            RootFolder(id: $0.int(0) ?? 0, absolutePath: $0.text(1) ?? "", name: $0.text(2) ?? "")
        }
    }

    /// Every image with everything the catalogue's tables say about it.
    public func images() throws -> [Image] {
        let hasIPTC = db.hasTable("AgLibraryIPTC")
        let hasHarvestedIPTC = db.hasTable("AgHarvestedIptcMetadata")
        let hasExif = db.hasTable("AgHarvestedExifMetadata")
        func interned(_ table: String, _ alias: String, _ ref: String) -> (join: String, column: String) {
            guard db.hasTable(table) else { return ("", "NULL") }
            return ("LEFT JOIN \(table) \(alias) ON \(alias).id_local = h.\(ref)", "\(alias).value")
        }
        let creator = interned("AgInternedIptcCreator", "ic", "creatorRef")
        let city = interned("AgInternedIptcCity", "icy", "cityRef")
        let state = interned("AgInternedIptcState", "ist", "stateRef")
        let country = interned("AgInternedIptcCountry", "ico", "countryRef")
        let code = interned("AgInternedIptcIsoCountryCode", "icc", "isoCountryCodeRef")
        let location = interned("AgInternedIptcLocation", "ilo", "locationRef")
        let cameraJoin = db.hasTable("AgInternedExifCameraModel") ? "LEFT JOIN AgInternedExifCameraModel cam ON cam.id_local = e.cameraModelRef" : ""
        let lensJoin = db.hasTable("AgInternedExifLens") ? "LEFT JOIN AgInternedExifLens len ON len.id_local = e.lensRef" : ""
        let imageColumns = Set(db.columns(of: "Adobe_images"))
        let widthColumn = imageColumns.contains("fileWidth") ? "i.fileWidth" : "NULL"
        let heightColumn = imageColumns.contains("fileHeight") ? "i.fileHeight" : "NULL"
        let formatColumn = imageColumns.contains("fileFormat") ? "i.fileFormat" : "NULL"
        let labelColumn = imageColumns.contains("colorLabels") ? "i.colorLabels" : "NULL"
        let sql = """
            SELECT i.id_local, rf.id_local, rf.absolutePath, fo.pathFromRoot, f.idx_filename,
                   \(formatColumn), i.captureTime, i.rating, i.pick, \(labelColumn),
                   \(hasIPTC ? "p.caption, p.copyright" : "NULL, NULL"),
                   \(hasHarvestedIPTC ? "\(creator.column), \(city.column), \(state.column), \(country.column), \(code.column), \(location.column), h.copyrightState" : "NULL, NULL, NULL, NULL, NULL, NULL, NULL"),
                   \(hasExif ? "\(cameraJoin.isEmpty ? "NULL" : "cam.value"), \(lensJoin.isEmpty ? "NULL" : "len.value"), e.aperture, e.shutterSpeed, e.isoSpeedRating, e.focalLength, e.gpsLatitude, e.gpsLongitude, e.hasGPS" : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"),
                   \(widthColumn), \(heightColumn)
            FROM Adobe_images i
            JOIN AgLibraryFile f ON f.id_local = i.rootFile
            JOIN AgLibraryFolder fo ON fo.id_local = f.folder
            JOIN AgLibraryRootFolder rf ON rf.id_local = fo.rootFolder
            \(hasIPTC ? "LEFT JOIN AgLibraryIPTC p ON p.image = i.id_local" : "")
            \(hasHarvestedIPTC ? "LEFT JOIN AgHarvestedIptcMetadata h ON h.image = i.id_local \(creator.join) \(city.join) \(state.join) \(country.join) \(code.join) \(location.join)" : "")
            \(hasExif ? "LEFT JOIN AgHarvestedExifMetadata e ON e.image = i.id_local \(cameraJoin) \(lensJoin)" : "")
            ORDER BY i.id_local
            """
        var images = try db.query(sql) { c -> Image in
            var image = Image(
                id: c.int(0) ?? 0, rootFolderID: c.int(1) ?? 0,
                folderPath: ((c.text(2) ?? "") as NSString).appendingPathComponent(c.text(3) ?? ""),
                fileName: c.text(4) ?? "")
            image.fileFormat = c.text(5)
            image.captureTime = c.text(6)
            image.rating = c.int(7).map(Int.init)
            image.pick = c.int(8).map(Int.init)
            image.colorLabel = c.text(9)
            image.caption = c.text(10)
            image.copyright = c.text(11)
            image.creator = c.text(12)
            image.city = c.text(13)
            image.state = c.text(14)
            image.country = c.text(15)
            image.countryCode = c.text(16)
            image.location = c.text(17)
            image.copyrightState = c.int(18).map(Int.init)
            image.cameraModel = c.text(19)
            image.lens = c.text(20)
            image.apertureAPEX = c.real(21)
            image.shutterAPEX = c.real(22)
            image.iso = c.real(23)
            image.focalLength = c.real(24)
            if (c.int(27) ?? 0) != 0 {
                image.gpsLatitude = c.real(25)
                image.gpsLongitude = c.real(26)
            }
            image.width = c.int(28).map(Int.init)
            image.height = c.int(29).map(Int.init)
            return image
        }
        // Keywords, grouped by image. Lightroom's own keyword table is a
        // tree; the leaf's name is the keyword.
        if db.hasTable("AgLibraryKeywordImage"), db.hasTable("AgLibraryKeyword") {
            var byImage: [Int64: [String]] = [:]
            for (image, name) in try db.query("""
                SELECT ki.image, k.name FROM AgLibraryKeywordImage ki JOIN AgLibraryKeyword k ON k.id_local = ki.tag
                WHERE k.name IS NOT NULL ORDER BY ki.image, k.lc_name
                """, [], { ($0.int(0) ?? 0, $0.text(1) ?? "") }) where !name.isEmpty {
                byImage[image, default: []].append(name)
            }
            for index in images.indices {
                images[index].keywords = byImage[images[index].id] ?? []
            }
        }
        return images
    }

    public func collections() throws -> [Collection] {
        guard db.hasTable("AgLibraryCollection"), db.hasTable("AgLibraryCollectionImage") else { return [] }
        var byID: [Int64: Collection] = [:]
        for (id, name) in try db.query("SELECT id_local, name FROM AgLibraryCollection WHERE name IS NOT NULL ORDER BY id_local", [], { ($0.int(0) ?? 0, $0.text(1) ?? "") }) {
            byID[id] = Collection(id: id, name: name, imageIDs: [])
        }
        for (collection, image) in try db.query("SELECT collection, image FROM AgLibraryCollectionImage ORDER BY collection, image", [], { ($0.int(0) ?? 0, $0.int(1) ?? 0) }) {
            byID[collection]?.imageIDs.append(image)
        }
        return byID.values.sorted { $0.id < $1.id }
    }
}
