import Foundation

/// Typed mirror of the JSON object stored in `items.metadata` on the
/// gostash side. The Go store keeps this as raw JSON, but the Mac
/// surfaces specific keys (currently camera EXIF + detected
/// language) in the detail view's Info table, so a typed struct
/// keeps the decode + display paths tidy.
///
/// All fields are optional — most items won't have most of them.
/// Future keys (e.g. AI-derived tags, image dimensions for non-EXIF
/// formats) can be added without touching call sites that don't
/// care.
struct ItemMetadata: Codable, Equatable, Hashable {
    /// Detected language code (e.g. "en", "zh-Hans"). Set by the
    /// snippet ingest path's langdetect pass.
    var language: String?
    /// Camera-EXIF subset surfaced as "Capture device" rows in the
    /// detail Info table. nil = no EXIF or non-image item.
    var camera: CameraInfo?

    struct CameraInfo: Codable, Equatable, Hashable {
        var make: String?
        var model: String?
        var lens: String?
        /// Aperture f-number (e.g. 2.8). Display formatted as
        /// "ƒ/2.8" or "ƒ/1.68".
        var fNumber: Double?
        /// Pre-formatted exposure-time string ("1/60", "5.0s") —
        /// the server already collapses EXIF's rational into the
        /// canonical display form so the Mac doesn't need to.
        var exposure: String?
        var focalLengthMm: Double?
        var iso: Int?
        var width: Int?
        var height: Int?

        enum CodingKeys: String, CodingKey {
            case make
            case model
            case lens
            case fNumber       = "f_number"
            case exposure
            case focalLengthMm = "focal_length_mm"
            case iso
            case width
            case height
        }

        /// True when any field is populated — used to decide
        /// whether to render a Capture-device row at all.
        var hasAny: Bool {
            !(make ?? "").isEmpty || !(model ?? "").isEmpty || !(lens ?? "").isEmpty
                || fNumber != nil || !(exposure ?? "").isEmpty
                || focalLengthMm != nil || iso != nil
                || width != nil || height != nil
        }

        /// Concatenates Make + Model into a single readable label
        /// ("Google Pixel 8 Pro"), with Model alone as a fallback
        /// when Make is repeated in Model (Apple's habit) or
        /// missing.
        var deviceLabel: String? {
            let m = (make ?? "").trimmingCharacters(in: .whitespaces)
            let mod = (model ?? "").trimmingCharacters(in: .whitespaces)
            if m.isEmpty { return mod.isEmpty ? nil : mod }
            if mod.isEmpty { return m }
            if mod.lowercased().hasPrefix(m.lowercased()) { return mod }
            return "\(m) \(mod)"
        }

        /// Compact one-line summary: "ƒ/1.68 · 1/54 · 6.9mm · ISO 26".
        /// Only the populated parts are included; nil fields drop
        /// out of the join.
        var settingsLine: String? {
            var parts: [String] = []
            if let f = fNumber {
                parts.append(String(format: "ƒ/%g", f))
            }
            if let exp = exposure, !exp.isEmpty {
                parts.append(exp)
            }
            if let fl = focalLengthMm {
                parts.append(String(format: "%gmm", fl))
            }
            if let iso {
                parts.append("ISO \(iso)")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// "3072 × 4080 (12.5 MP)" — surfaced as its own row.
        var dimensionsLine: String? {
            guard let w = width, let h = height, w > 0, h > 0 else { return nil }
            let mp = Double(w * h) / 1_000_000
            return String(format: "%d × %d (%.1f MP)", w, h, mp)
        }
    }
}
