import CoreLocation
import MapKit
import SwiftUI

struct PatternCoordinatesView: View {
    let latitude: Double
    let longitude: Double

    @State private var address: String?

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var label: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if CLLocationCoordinate2DIsValid(coordinate) {
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 5000, longitudinalMeters: 5000))) {
                    Marker(label, coordinate: coordinate)
                }
                .frame(width: 500, height: 300)
            }
            Text(label)
                .textSelection(.enabled)
            if let address {
                Text(address)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .task {
            await lookUpAddress()
        }
    }

    private func lookUpAddress() async {
        guard CLLocationCoordinate2DIsValid(coordinate),
            let placemark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: latitude, longitude: longitude)).first
        else { return }
        let parts = [placemark.name, placemark.locality, placemark.administrativeArea, placemark.country].compactMap { $0 }
        address = parts.reduce(into: [String]()) { unique, part in
            if !unique.contains(part) { unique.append(part) }
        }.joined(separator: ", ")
    }
}
