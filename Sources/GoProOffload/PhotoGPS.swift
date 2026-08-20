import CoreLocation
import Foundation
import ImageIO

/// Where a photo was taken, from its EXIF GPS block.
///
/// Videos carry position in their telemetry track (see `MP4`); photos carry a
/// single fix in EXIF, so the two sources meet at the same one-place answer.
enum PhotoGPS {
    /// GoPro writes the GPS block after the EXIF thumbnail, so the first 64 KB
    /// of the file isn't enough to reach it — 128 KB was, on the photos to
    /// hand. This asks for double that, still a rounding error against a
    /// 7 MB JPEG we'd otherwise pull off the camera whole.
    static let headerBytes = 256 * 1024

    /// From the front of a file, as a ranged read off the camera returns it.
    static func location(fromHeader data: Data) -> (coordinate: CLLocationCoordinate2D, altitude: Double?)? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)   // false: more may follow
        return location(in: source)
    }

    /// From a photo already on this Mac.
    static func location(fileURL: URL) -> (coordinate: CLLocationCoordinate2D, altitude: Double?)? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return location(in: source)
    }

    /// The capture settings a photo's EXIF carries, for the inspector's Photo
    /// section. Everything is optional: what the camera didn't write simply
    /// doesn't get a row.
    struct Details {
        var width: Int?
        var height: Int?
        var fNumber: Double?
        var exposureSeconds: Double?
        var iso: Int?
        var focalMM: Double?
        var focal35MM: Int?
        var exposureBias: Double?
        var whiteBalanceAuto: Bool?
        var metering: String?
        var colorProfile: String?

        var isEmpty: Bool { width == nil && fNumber == nil && exposureSeconds == nil && iso == nil }
    }

    /// From the front of a file, as a ranged read off the camera returns it.
    static func details(fromHeader data: Data) -> Details? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, false)
        return details(in: source)
    }

    /// From a photo already on this Mac.
    static func details(fileURL: URL) -> Details? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        return details(in: source)
    }

    private static func details(in source: CGImageSource) -> Details? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var d = Details()
        // Pixel size sits at the top level once ImageIO has reached the frame
        // header; the EXIF block's own copy is the fallback for a header read
        // cut short.
        d.width = props[kCGImagePropertyPixelWidth] as? Int
            ?? exif[kCGImagePropertyExifPixelXDimension] as? Int
        d.height = props[kCGImagePropertyPixelHeight] as? Int
            ?? exif[kCGImagePropertyExifPixelYDimension] as? Int
        d.fNumber = exif[kCGImagePropertyExifFNumber] as? Double
        d.exposureSeconds = exif[kCGImagePropertyExifExposureTime] as? Double
        d.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        d.focalMM = exif[kCGImagePropertyExifFocalLength] as? Double
        d.focal35MM = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
        d.exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
        d.whiteBalanceAuto = (exif[kCGImagePropertyExifWhiteBalance] as? Int).map { $0 == 0 }
        d.metering = (exif[kCGImagePropertyExifMeteringMode] as? Int).flatMap { code in
            // EXIF 2.3 table 24; GoPro sends 1 or 5.
            switch code {
            case 1: "Average"
            case 2: "Center-weighted"
            case 3: "Spot"
            case 4: "Multi-spot"
            case 5: "Multi-zone"
            case 6: "Partial"
            default: nil
            }
        }
        d.colorProfile = props[kCGImagePropertyProfileName] as? String
        return d.isEmpty ? nil : d
    }

    private static func location(in source: CGImageSource) -> (coordinate: CLLocationCoordinate2D, altitude: Double?)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              let lon = gps[kCGImagePropertyGPSLongitude] as? Double else { return nil }
        // EXIF stores the magnitude and the hemisphere separately.
        let signedLat = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
        let signedLon = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        guard abs(signedLat) <= 90, abs(signedLon) <= 180,
              !(signedLat == 0 && signedLon == 0) else { return nil }

        var altitude = gps[kCGImagePropertyGPSAltitude] as? Double
        // Reference 1 means below sea level, which is how a dive comes back.
        if let a = altitude, (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1 { altitude = -a }
        return (CLLocationCoordinate2D(latitude: signedLat, longitude: signedLon), altitude)
    }
}
