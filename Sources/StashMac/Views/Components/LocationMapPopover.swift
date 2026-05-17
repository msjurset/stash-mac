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
struct LocationMapPopover: View {
    let lat: Double
    let lon: Double

    @State private var position: MapCameraPosition

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        _position = State(
            initialValue: .region(
                MKCoordinateRegion(
                    center: coord,
                    // ~500 m on a side — enough context that the user
                    // recognises the neighborhood, tight enough to
                    // confirm "yes that's where I was."
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                )
            )
        )
    }

    var body: some View {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        VStack(spacing: 8) {
            Map(position: $position) {
                Marker("", coordinate: coord)
            }
            .frame(width: 360, height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 12) {
                Text(String(format: "%.6f, %.6f", lat, lon))
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                Spacer()
                if let appleURL = URL(string: "https://maps.apple.com/?q=\(lat),\(lon)") {
                    Link("Apple Maps", destination: appleURL)
                        .font(.caption)
                }
                if let googleURL = URL(string: "https://www.google.com/maps?q=\(lat),\(lon)") {
                    Link("Google Maps", destination: googleURL)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(8)
    }
}
