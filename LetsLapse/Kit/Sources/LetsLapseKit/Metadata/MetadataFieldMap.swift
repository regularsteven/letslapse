import Foundation

/// The ONE mapping table: for every `MetadataField`, its XMP path(s), its
/// IPTC-IIM dataset, and the ImageIO property key that carries the same fact
/// (docs/data-model-scale-and-metadata-2026-09-12.md §4.1).
///
/// The reader walks this table and nothing else; the exporter will walk the
/// same table the other way. A field that is not here is a field the app
/// cannot import, and a spelling that is wrong here is wrong in exactly one
/// place.
public struct MetadataMapping: Sendable {

    /// How the raw value is turned into a `MetadataValue`.
    public enum Kind: Sendable, Equatable {
        /// A simple string; a lang-alt yields its `x-default`.
        case text
        /// An ordered list (`rdf:Seq` / `rdf:Bag`; an IIM repeated dataset).
        case list
        case integer
        /// A number that XMP may spell as a rational ("32/10").
        case number
        /// `xmpRights:Marked`: True → copyrighted, False → publicDomain.
        case rightsMarked
        /// A capture date: XMP ISO-8601 with offset, or Exif's
        /// `DateTimeOriginal` + `SubsecTimeOriginal` + `OffsetTimeOriginal`.
        case date
        /// A GPS coordinate: XMP "50,5.3833N", or ImageIO's magnitude plus
        /// the `…Ref` hemisphere key.
        case coordinate
        /// An altitude with its below-sea-level flag.
        case altitude
    }

    public let field: MetadataField
    /// XMP paths, most authoritative first. A struct member is
    /// `Struct/Member`; a lang-alt or array is addressed by its property.
    public let xmp: [String]
    /// The IIM dataset (record:dataset), for the record; ImageIO surfaces it
    /// under the `{IPTC}` key named in `imageIO`.
    public let iim: String?
    /// ImageIO property key paths, most authoritative first: `{IPTC}.ObjectName`,
    /// `{Exif}.ExposureTime`, `{GPS}.Latitude`, a bare key for the top level.
    public let imageIO: [String]
    public let kind: Kind

    init(_ field: MetadataField, xmp: [String], iim: String? = nil, imageIO: [String] = [], kind: Kind = .text) {
        self.field = field
        self.xmp = xmp
        self.iim = iim
        self.imageIO = imageIO
        self.kind = kind
    }
}

public enum MetadataFieldMap {

    public static let all: [MetadataMapping] = [
        // IPTC Core — descriptive.
        MetadataMapping(.title, xmp: ["dc:title"], iim: "2:05", imageIO: ["{IPTC}.ObjectName"]),
        MetadataMapping(.caption, xmp: ["dc:description"], iim: "2:120", imageIO: ["{IPTC}.Caption/Abstract", "{TIFF}.ImageDescription"]),
        MetadataMapping(.creator, xmp: ["dc:creator"], iim: "2:80", imageIO: ["{IPTC}.Byline", "{TIFF}.Artist"], kind: .list),
        MetadataMapping(.rights, xmp: ["dc:rights"], iim: "2:116", imageIO: ["{IPTC}.CopyrightNotice", "{TIFF}.Copyright"]),
        MetadataMapping(.rating, xmp: ["xmp:Rating"], imageIO: ["{IPTC}.StarRating"], kind: .integer),
        MetadataMapping(.rightsStatus, xmp: ["xmpRights:Marked"], kind: .rightsMarked),
        MetadataMapping(.rightsURL, xmp: ["xmpRights:WebStatement"]),
        MetadataMapping(.usageTerms, xmp: ["xmpRights:UsageTerms"], imageIO: ["{IPTC}.UsageTerms"]),
        // The creator's contact block — `Iptc4xmpCore:CreatorContactInfo`.
        MetadataMapping(.contactAddress, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrExtadr"], imageIO: ["{IPTC}.CreatorContactInfo.CiAdrExtadr"]),
        MetadataMapping(.contactCity, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCity"], imageIO: ["{IPTC}.CreatorContactInfo.CiAdrCity"]),
        MetadataMapping(.contactState, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrRegion"], imageIO: ["{IPTC}.CreatorContactInfo.CiAdrRegion"]),
        MetadataMapping(.contactPostcode, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrPcode"], imageIO: ["{IPTC}.CreatorContactInfo.CiAdrPcode"]),
        MetadataMapping(.contactCountry, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiAdrCtry"], imageIO: ["{IPTC}.CreatorContactInfo.CiAdrCtry"]),
        MetadataMapping(.contactPhone, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiTelWork"], imageIO: ["{IPTC}.CreatorContactInfo.CiTelWork"]),
        MetadataMapping(.contactEmail, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiEmailWork"], imageIO: ["{IPTC}.CreatorContactInfo.CiEmailWork"]),
        MetadataMapping(.contactWebsite, xmp: ["Iptc4xmpCore:CreatorContactInfo/Iptc4xmpCore:CiUrlWork"], imageIO: ["{IPTC}.CreatorContactInfo.CiUrlWork"]),
        // The image's location.
        MetadataMapping(.locationSublocation, xmp: ["Iptc4xmpCore:Location", "Iptc4xmpExt:LocationShown/Iptc4xmpExt:Sublocation"], iim: "2:92", imageIO: ["{IPTC}.SubLocation"]),
        MetadataMapping(.locationCity, xmp: ["photoshop:City", "Iptc4xmpExt:LocationShown/Iptc4xmpExt:City"], iim: "2:90", imageIO: ["{IPTC}.City"]),
        MetadataMapping(.locationState, xmp: ["photoshop:State", "Iptc4xmpExt:LocationShown/Iptc4xmpExt:ProvinceState"], iim: "2:95", imageIO: ["{IPTC}.Province/State"]),
        MetadataMapping(.locationCountry, xmp: ["photoshop:Country", "Iptc4xmpExt:LocationShown/Iptc4xmpExt:CountryName"], iim: "2:101", imageIO: ["{IPTC}.Country/PrimaryLocationName"]),
        MetadataMapping(.locationCountryCode, xmp: ["Iptc4xmpCore:CountryCode", "Iptc4xmpExt:LocationShown/Iptc4xmpExt:CountryCode"], iim: "2:100", imageIO: ["{IPTC}.Country/PrimaryLocationCode"]),
        MetadataMapping(.keywords, xmp: ["dc:subject"], iim: "2:25", imageIO: ["{IPTC}.Keywords"], kind: .list),
        // Technical — Exif, TIFF, aux.
        MetadataMapping(.captured, xmp: ["exif:DateTimeOriginal", "photoshop:DateCreated", "xmp:CreateDate"], imageIO: ["{Exif}.DateTimeOriginal"], kind: .date),
        MetadataMapping(.cameraMake, xmp: ["tiff:Make"], imageIO: ["{TIFF}.Make"]),
        MetadataMapping(.cameraModel, xmp: ["tiff:Model"], imageIO: ["{TIFF}.Model"]),
        // Exif's is the lens the body reported; aux's is Adobe's rewrite of
        // it — "Sony FE 28mm F4.5" for a Viltrox (measured on _WEX3518.ARW).
        MetadataMapping(.cameraLens, xmp: ["exifEX:LensModel", "aux:Lens"], imageIO: ["{Exif}.LensModel", "{ExifAux}.LensModel"]),
        MetadataMapping(.cameraSerial, xmp: ["exifEX:BodySerialNumber", "aux:SerialNumber"], imageIO: ["{Exif}.BodySerialNumber", "{ExifAux}.SerialNumber"]),
        MetadataMapping(.exposureSeconds, xmp: ["exif:ExposureTime"], imageIO: ["{Exif}.ExposureTime"], kind: .number),
        MetadataMapping(.exposureISO, xmp: ["exif:ISOSpeedRatings", "exifEX:PhotographicSensitivity"], imageIO: ["{Exif}.ISOSpeedRatings"], kind: .number),
        MetadataMapping(.exposureAperture, xmp: ["exif:FNumber"], imageIO: ["{Exif}.FNumber"], kind: .number),
        MetadataMapping(.exposureFocalLength, xmp: ["exif:FocalLength"], imageIO: ["{Exif}.FocalLength"], kind: .number),
        MetadataMapping(.exposureFocalLength35, xmp: ["exif:FocalLengthIn35mmFilm"], imageIO: ["{Exif}.FocalLenIn35mmFilm"], kind: .number),
        MetadataMapping(.gpsLatitude, xmp: ["exif:GPSLatitude"], imageIO: ["{GPS}.Latitude"], kind: .coordinate),
        MetadataMapping(.gpsLongitude, xmp: ["exif:GPSLongitude"], imageIO: ["{GPS}.Longitude"], kind: .coordinate),
        MetadataMapping(.gpsAltitude, xmp: ["exif:GPSAltitude"], imageIO: ["{GPS}.Altitude"], kind: .altitude),
        MetadataMapping(.gpsDirection, xmp: ["exif:GPSImgDirection"], imageIO: ["{GPS}.ImgDirection"], kind: .number),
        // A DNG's own size first: on iOS ImageIO's `PixelWidth` for a DNG is
        // the embedded PREVIEW (256 × 171 for the Part 2 DNG, measured on the
        // simulator 2026-09-13), while `{DNG}.DefaultCropSize` / `ActiveArea`
        // describe the picture. `[n]` indexes an array value.
        MetadataMapping(.width, xmp: ["exif:PixelXDimension", "tiff:ImageWidth"],
                        imageIO: ["{DNG}.DefaultCropSize[0]", "{DNG}.ActiveArea[3]", "{Exif}.PixelXDimension", "PixelWidth"], kind: .integer),
        MetadataMapping(.height, xmp: ["exif:PixelYDimension", "tiff:ImageLength"],
                        imageIO: ["{DNG}.DefaultCropSize[1]", "{DNG}.ActiveArea[2]", "{Exif}.PixelYDimension", "PixelHeight"], kind: .integer),
        MetadataMapping(.orientation, xmp: ["tiff:Orientation"], imageIO: ["Orientation", "{TIFF}.Orientation"], kind: .integer),
        MetadataMapping(.software, xmp: ["xmp:CreatorTool", "tiff:Software"], imageIO: ["{TIFF}.Software"]),
    ]

    public static func mapping(for field: MetadataField) -> MetadataMapping? {
        all.first { $0.field == field }
    }
}
