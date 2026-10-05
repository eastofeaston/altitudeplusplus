import CoreLocation
import Foundation

struct ResolvedLocation: Equatable {
    /// Whether Altitude+ placed us from the Apple TV's coordinates or from the IP address.
    enum Source {
        case coordinates
        case ipAddress
    }

    var latitude: Double?
    var longitude: Double?
    var postalCode: String?
    var source: Source
}

/// Supplies the coordinates Altitude+ uses for its territory check.
///
/// Apple TV has no GPS, but Core Location returns a Wi-Fi based fix that is
/// accurate enough for zip-level territory checks. Without permission we fall
/// back to the server's IP lookup, which is what the official TV apps do.
@MainActor
final class LocationService: NSObject {
    private let manager = CLLocationManager()
    private let client = ViewLiftClient()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var fixWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var cachedFix: CLLocation?

    private(set) var lastResolved: ResolvedLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    var permissionDescription: String {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return "Allowed"
        case .denied, .restricted: return "Off (using IP address)"
        case .notDetermined: return "Not asked yet"
        @unknown default: return "Unknown"
        }
    }

    /// Coordinates to send with entitlement requests, or nil to let the server use IP.
    func coordinates() async -> CLLocationCoordinate2D? {
        if let fix = cachedFix, fix.timestamp.timeIntervalSinceNow > -15 * 60 {
            return fix.coordinate
        }
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else {
            return nil
        }
        let fix = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
            fixWaiters.append(continuation)
            if fixWaiters.count == 1 {
                manager.requestLocation()
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.finishFix(nil)
                }
            }
        }
        if let fix { cachedFix = fix }
        return fix?.coordinate ?? cachedFix?.coordinate
    }

    /// Asks Altitude+ where it thinks we are (city and zip) for display.
    @discardableResult
    func resolve(token: String?) async -> ResolvedLocation? {
        let coordinate = await coordinates()
        var query: [String: String?] = [:]
        if let coordinate {
            query["latitude"] = String(coordinate.latitude)
            query["longitude"] = String(coordinate.longitude)
        }
        guard let json = try? await client.get("geolocation", query: query, token: token) else {
            return lastResolved
        }
        let resolved = ResolvedLocation(
            latitude: coordinate?.latitude ?? json["latitude"]?.double,
            longitude: coordinate?.longitude ?? json["longitude"]?.double,
            postalCode: json["postalcode"]?.string,
            source: coordinate == nil ? .ipAddress : .coordinates
        )
        lastResolved = resolved
        return resolved
    }

    func invalidate() {
        cachedFix = nil
    }

    private func finishFix(_ location: CLLocation?) {
        let waiters = fixWaiters
        fixWaiters.removeAll()
        waiters.forEach { $0.resume(returning: location) }
    }

    private func finishAuthorization() {
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            if manager.authorizationStatus != .notDetermined {
                self.finishAuthorization()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.finishFix(latest) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finishFix(nil) }
    }
}
