import SwiftUI
import CoreLocation

struct FromTheWebSection: View {
    let item: StashItem
    @State private var resolvedQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("From the Web")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button {
                    var comps = URLComponents(string: "https://www.google.com/search")
                    comps?.queryItems = [URLQueryItem(name: "q", value: resolvedQuery.isEmpty ? item.title : resolvedQuery)]
                    if let url = comps?.url {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body)
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Search Google for this item")
            }
        }
        .task {
            // Build the search query with reverse geocoded location
            var q = item.title
            if let loc = item.location {
                let clLoc = CLLocation(latitude: loc.lat, longitude: loc.lon)
                if let placemarks = try? await CLGeocoder().reverseGeocodeLocation(clLoc),
                   let place = placemarks.first {
                    let parts = [place.administrativeArea, place.country].compactMap { $0 }
                    if !parts.isEmpty {
                        q += " " + parts.joined(separator: ", ")
                    } else {
                        q += " \(loc.lat), \(loc.lon)"
                    }
                } else {
                    q += " \(loc.lat), \(loc.lon)"
                }
            }
            self.resolvedQuery = q
        }
    }
}
