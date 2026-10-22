import CoreLocation
import MapKit
import SwiftUI

/// Choosing where a reminder comes: a place found by searching Apple Maps, where you are now, or one of the places you
/// chose last; then whether it is for arriving there or for leaving, on a little map with the circle you have to step
/// into or out of.
struct PlacePicker: View {
    @Binding var place: TodoPlace?
    @State private var search = PlaceSearch()
    @State private var isLocating = false
    @State private var problem: String?

    var body: some View {
        if let current = place {
            chosen(current)
        } else {
            searching
        }
    }

    // MARK: - A place chosen

    @ViewBuilder
    private func chosen(_ current: TodoPlace) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
            Text(current.name)
                .lineLimit(2)
            Spacer()
            Button {
                withAnimation(Theme.quick) { place = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Choose Another Place")
            .accessibilityLabel("Choose Another Place")
        }
        Picker("When", selection: Binding(get: { current.leaving }, set: { place?.leaving = $0 })) {
            Text("Arriving").tag(false)
            Text("Leaving").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        if let latitude = current.latitude, let longitude = current.longitude {
            PlaceMap(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
                .frame(height: 120)
                .clipShape(.rect(cornerRadius: 8))
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
        }
    }

    // MARK: - Finding one

    @ViewBuilder
    private var searching: some View {
        TextField("Search for a Place", text: $search.query)
            .textFieldStyle(.plain)
            #if os(iOS)
            .textInputAutocapitalization(.words)
            #endif
            .autocorrectionDisabled()
        if search.query.isEmpty {
            row("Current Location", detail: problem, symbol: "location.fill", busy: isLocating) { locate() }
            ForEach(PlaceHistory.recent, id: \.self) { recent in
                row(recent.name, symbol: "clock") { place = recent }
            }
        } else {
            ForEach(search.results.prefix(6), id: \.self) { result in
                row(result.title, detail: result.subtitle.isEmpty ? nil : result.subtitle, symbol: "mappin") {
                    Task {
                        if let found = await search.place(for: result) { place = found }
                    }
                }
            }
        }
    }

    private func row(_ title: String, detail: String? = nil, symbol: String, busy: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(Color.primary).lineLimit(1)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Current Location: where you are, named by its address.
    private func locate() {
        guard !isLocating else { return }
        isLocating = true
        problem = nil
        Task {
            defer { isLocating = false }
            guard let location = await PlaceAccess.shared.currentLocation() else {
                problem = PlaceAccess.shared.isDenied ? "Location access is turned off for Notebook." : "Your location couldn’t be found."
                return
            }
            let name = await PlaceSearch.name(of: location) ?? "Current Location"
            place = TodoPlace(name: name, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        }
    }
}

/// The place on a map, with the circle around it a reminder watches.
struct PlaceMap: View {
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: TodoPlace.radius * 5, longitudinalMeters: TodoPlace.radius * 5)), interactionModes: []) {
            MapCircle(center: coordinate, radius: TodoPlace.radius)
                .foregroundStyle(Color.accentColor.opacity(0.18))
                .stroke(Color.accentColor, lineWidth: 1.5)
            Marker("", coordinate: coordinate)
        }
        .mapControlVisibility(.hidden)
        .id("\(coordinate.latitude),\(coordinate.longitude)")
    }
}

/// Places found as you type, from Apple Maps.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet { completer.queryFragment = query }
    }

    private(set) var results: [MKLocalSearchCompletion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated { results = completer.results }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        MainActor.assumeIsolated { results = [] }
    }

    /// The place a result is, with its coordinates.
    func place(for result: MKLocalSearchCompletion) async -> TodoPlace? {
        guard let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: result)).start(),
              let item = response.mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        return TodoPlace(name: item.name ?? result.title, latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// A short name for where you are: the street and number, or the place's name.
    static func name(of location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else { return nil }
        return item.address?.shortAddress?.components(separatedBy: ",").first ?? item.name
    }
}

/// The places chosen last, to choose again at a tap: kept on this device.
@MainActor
enum PlaceHistory {
    private static let key = "recentPlaces"
    private static let limit = 4

    static var recent: [TodoPlace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([TodoPlace].self, from: data)) ?? []
    }

    static func add(_ place: TodoPlace) {
        guard place.hasCoordinates else { return }
        var places = recent.filter { $0.name != place.name }
        var kept = place
        kept.leaving = false
        places.insert(kept, at: 0)
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(places.prefix(limit))), forKey: key)
    }
}

/// Where you are, and whether Notebook may know it: asked for "While Using the App" the first time a reminder gets a
/// place, which is all iPhone and iPad need to remind you there.
@MainActor
final class PlaceAccess: NSObject, CLLocationManagerDelegate {
    static let shared = PlaceAccess()

    private let manager = CLLocationManager()
    private var asking: [CheckedContinuation<Void, Never>] = []
    private var locating: [CheckedContinuation<CLLocation?, Never>] = []

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAllowed: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways: true
        #if os(iOS)
        case .authorizedWhenInUse: true
        #endif
        default: false
        }
    }

    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    /// Asks once, the first time; says whether Notebook may use your location.
    @discardableResult
    func requestAccess() async -> Bool {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                asking.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        return isAllowed
    }

    func currentLocation() async -> CLLocation? {
        guard await requestAccess() else { return nil }
        return await withCheckedContinuation { continuation in
            locating.append(continuation)
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiting = asking
            asking = []
            waiting.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        MainActor.assumeIsolated { finishLocating(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { finishLocating(nil) }
    }

    private func finishLocating(_ location: CLLocation?) {
        let waiting = locating
        locating = []
        waiting.forEach { $0.resume(returning: location) }
    }
}
