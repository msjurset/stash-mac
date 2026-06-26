import SwiftUI
import MapKit

/// Compact map preview shown by the crosshair button next to a
/// lat/lon display. Used in both the detail-pane Location row and
/// the Edit dialog so the user can sanity-check a coordinate
/// without launching an external map app.
///
/// Uses MapKit (native, no API key, instant render). Footer links
/// jump out to Apple Maps or Google Maps when the user wants the
/// full experience.
struct LocationPoint: Identifiable, Hashable {
    let id: String
    let coord: CLLocationCoordinate2D
    var url: URL?

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(coord.latitude)
        hasher.combine(coord.longitude)
    }

    static func == (lhs: LocationPoint, rhs: LocationPoint) -> Bool {
        return lhs.id == rhs.id && lhs.coord.latitude == rhs.coord.latitude && lhs.coord.longitude == rhs.coord.longitude
    }
}

struct LocationMapPopover: View {
    let points: [LocationPoint]
    let primaryLat: Double
    let primaryLon: Double

    @State private var position: MapCameraPosition

    var onPresentViewer: (() -> Void)? = nil

    init(lat: Double, lon: Double, primaryURL: URL? = nil, additionalPoints: [LocationPoint] = [], onPresentViewer: (() -> Void)? = nil) {
        self.primaryLat = lat
        self.primaryLon = lon
        self.onPresentViewer = onPresentViewer
        
        var seenCoords = Set<String>()
        
        func jitter(_ coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            var c = coord
            while seenCoords.contains("\(c.latitude),\(c.longitude)") {
                c.latitude += 0.00003
                c.longitude += 0.00003
            }
            seenCoords.insert("\(c.latitude),\(c.longitude)")
            return c
        }
        
        var pts: [LocationPoint] = []
        pts.append(LocationPoint(id: "primary", coord: jitter(CLLocationCoordinate2D(latitude: lat, longitude: lon)), url: primaryURL))
        for pt in additionalPoints {
            pts.append(LocationPoint(id: pt.id, coord: jitter(pt.coord), url: pt.url))
        }
        self.points = pts
        
        let coord = pts[0].coord
        if additionalPoints.isEmpty {
            _position = State(
                initialValue: .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                    )
                )
            )
        } else {
            var minLat = lat
            var maxLat = lat
            var minLon = lon
            var maxLon = lon
            
            for pt in pts {
                minLat = min(minLat, pt.coord.latitude)
                maxLat = max(maxLat, pt.coord.latitude)
                minLon = min(minLon, pt.coord.longitude)
                maxLon = max(maxLon, pt.coord.longitude)
            }
            
            let centerLat = (minLat + maxLat) / 2
            let centerLon = (minLon + maxLon) / 2
            
            let spanLat = max((maxLat - minLat) * 1.5, 0.0001)
            let spanLon = max((maxLon - minLon) * 1.5, 0.0001)
            
            _position = State(
                initialValue: .region(
                    MKCoordinateRegion(
                        center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
                        span: MKCoordinateSpan(latitudeDelta: spanLat, longitudeDelta: spanLon)
                    )
                )
            )
        }
    }

    @State private var selectedPointID: String? = nil

    var body: some View {
        VStack(spacing: 8) {
            Map(position: $position, selection: $selectedPointID) {
                ForEach(points) { pt in
                    Marker(pt.id == "primary" ? "Primary" : pt.id, coordinate: pt.coord)
                        .tint(pt.id == "primary" ? .red : .blue)
                        .tag(pt.id)
                }
            }
            .frame(width: 440, height: 340)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(points) { pt in
                        if let url = pt.url {
                            LocationThumbnail(fileURL: url)
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .contentShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(selectedPointID == pt.id ? Color.accentColor : Color.clear, lineWidth: 3)
                                )
                                .onTapGesture {
                                    onPresentViewer?()
                                    let urls = points.compactMap { $0.url }
                                    let index = urls.firstIndex(of: url) ?? 0
                                    ImagePreviewPresenter.present(urls: urls, initialIndex: index)
                                }
                                .onHover { hovering in
                                    if hovering {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                                .help(pt.id == "primary" ? "Primary Image" : pt.id)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 4)
            
            HStack(spacing: 12) {
                Text(String(format: "%.6f, %.6f", primaryLat, primaryLon))
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                Spacer()
                if let appleURL = URL(string: "https://maps.apple.com/?q=\(primaryLat),\(primaryLon)") {
                    Link("Apple Maps", destination: appleURL)
                        .font(.caption)
                }
                if let googleURL = URL(string: "https://www.google.com/maps?q=\(primaryLat),\(primaryLon)") {
                    Link("Google Maps", destination: googleURL)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
    }
}

private struct LocationThumbnail: View {
    let fileURL: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.15)
            }
        }
        .task(id: fileURL) {
            let img = await Task.detached(priority: .userInitiated) {
                ThumbnailCache.loadOriented(from: fileURL)
            }.value
            await MainActor.run { image = img }
        }
    }
}
