import AppKit
import ImageIO
import UniformTypeIdentifiers
import CoreLocation

/// Stateless image-resize + JPEG-encode helpers used by
/// `ThumbnailService` to produce canonical thumbnails. Phase 1 keeps
/// the pipeline minimal: ImageIO thumbnail extraction (which applies
/// EXIF orientation and supports HEIC/WebP/AVIF natively), JPEG
/// encode at q85. Saliency-aware cropping is deferred to Phase 4
/// (grid view) where target aspect matters.
enum ImageProcessor {
    /// Long-edge cap for the canonical stored thumbnail. The detail
    /// view, list rows, and a future grid all derive their visible
    /// size from this.
    static let canonicalMaxDim: CGFloat = 512

    /// JPEG-encode a thumbnail from raw source bytes (any format
    /// CGImageSource decodes — JPEG, PNG, HEIC, WebP, AVIF, GIF, …).
    /// Returns nil if decode fails.
    static func makeThumbnailData(
        from sourceData: Data,
        maxDim: CGFloat = canonicalMaxDim
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return encodeJPEG(cg, quality: 0.85)
    }

    /// Convenience overload for callers holding an NSImage (e.g.
    /// QuickLook output, AVAssetImageGenerator frames).
    static func makeThumbnailData(
        from image: NSImage,
        maxDim: CGFloat = canonicalMaxDim
    ) -> Data? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return makeThumbnailData(from: tiff, maxDim: maxDim)
    }

    /// Convenience overload for callers holding a CGImage.
    static func makeThumbnailData(
        from cgImage: CGImage,
        maxDim: CGFloat = canonicalMaxDim
    ) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let tiff = rep.tiffRepresentation else { return nil }
        return makeThumbnailData(from: tiff, maxDim: maxDim)
    }

    /// JPEG-encode an already-sized CGImage at the given quality.
    static func encodeJPEG(_ cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(dest, cgImage, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Extract GPS coordinates from the given file URL, if available.
    static func extractLocation(from url: URL) -> CLLocationCoordinate2D? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        guard let gps = props[kCGImagePropertyGPSDictionary as String] as? [String: Any] else { return nil }
        
        guard let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
              let latVal = gps[kCGImagePropertyGPSLatitude as String] as? Double,
              let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
              let lonVal = gps[kCGImagePropertyGPSLongitude as String] as? Double else {
            return nil
        }
        
        let lat = latRef == "S" ? -latVal : latVal
        let lon = lonRef == "W" ? -lonVal : lonVal
        
        if lat == 0.0 && lon == 0.0 {
            return nil
        }
        
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
