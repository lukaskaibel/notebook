import Foundation
import MapKit
#if os(iOS)
import ContactsUI
#endif

/// Home and Work, to choose for a reminder's place at a tap, as Reminders has them. Apple Maps and Reminders take them
/// from your card in Contacts, which apps can't read on an iPhone or iPad, so you choose them once: an address on your
/// card, where you are, or one you search for. They are kept in iCloud's key-value store, which takes them to your other
/// devices, and in the app's settings, which is all a build without the iCloud entitlement has; as hidden folders are.
@MainActor
@Observable
final class SavedPlaces {
    static let shared = SavedPlaces()

    enum Kind: String, CaseIterable, Identifiable {
        case home, work

        var id: Self { self }
        var name: String { self == .home ? "Home" : "Work" }
        var symbol: String { self == .home ? "house.fill" : "briefcase.fill" }
    }

    /// Where it is, and its address to show under its name.
    struct Saved: Codable, Equatable {
        var latitude: Double
        var longitude: Double
        var address: String
    }

    private(set) var saved: [Kind: Saved] = [:]
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let cloud: NSUbiquitousKeyValueStore?
    @ObservationIgnored private var observer: NSObjectProtocol?

    private static let uploadedKey = "savedPlacesInICloud"

    /// With no defaults and no cloud they are kept for this run only (tests).
    init(defaults: UserDefaults? = .standard, cloud: NSUbiquitousKeyValueStore? = .default) {
        self.defaults = defaults
        // Without the entitlement the store keeps nothing, and says so here.
        self.cloud = cloud?.synchronize() == true ? cloud : nil
        for kind in Kind.allCases { saved[kind] = Self.decode(defaults?.data(forKey: Self.key(kind))) }
        guard let cloud = self.cloud else { return }
        // Places chosen before iCloud was there go up once; from then on iCloud has the last word.
        if defaults?.bool(forKey: Self.uploadedKey) != true {
            for (kind, place) in saved { cloud.set(Self.encode(place), forKey: Self.key(kind)) }
            defaults?.set(true, forKey: Self.uploadedKey)
        }
        read(cloud)
        observer = NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let cloud = self.cloud else { return }
                self.read(cloud)
            }
        }
    }

    /// Home or Work as a reminder's place: named so, as Reminders names it.
    func place(_ kind: Kind, leaving: Bool = false) -> TodoPlace? {
        saved[kind].map { TodoPlace(name: kind.name, latitude: $0.latitude, longitude: $0.longitude, leaving: leaving) }
    }

    func set(_ kind: Kind, to place: Saved?) {
        saved[kind] = place
        let data = place.map(Self.encode)
        defaults?.set(data, forKey: Self.key(kind))
        if let data { cloud?.set(data, forKey: Self.key(kind)) } else { cloud?.removeObject(forKey: Self.key(kind)) }
    }

    /// A place found or located, kept as Home or Work: it comes back named so, to remind there.
    func set(_ kind: Kind, to place: TodoPlace, address: String) -> TodoPlace? {
        guard let latitude = place.latitude, let longitude = place.longitude else { return nil }
        set(kind, to: Saved(latitude: latitude, longitude: longitude, address: address.isEmpty ? place.name : address))
        return self.place(kind, leaving: place.leaving)
    }

    /// Whether a place is Home or Work as kept now. A note has its coordinates to six places.
    func isPlace(_ place: TodoPlace?, _ kind: Kind) -> Bool {
        guard let place, let saved = saved[kind], place.name == kind.name, let latitude = place.latitude, let longitude = place.longitude else {
            return false
        }
        return abs(latitude - saved.latitude) < 0.00001 && abs(longitude - saved.longitude) < 0.00001
    }

    /// Whether a place is Home or Work, so it isn't offered a second time among the places chosen last.
    func isSaved(_ place: TodoPlace) -> Bool {
        Kind.allCases.contains { $0.name == place.name && saved[$0] != nil }
    }

    private func read(_ cloud: NSUbiquitousKeyValueStore) {
        for kind in Kind.allCases {
            let fresh = Self.decode(cloud.data(forKey: Self.key(kind)))
            guard fresh != saved[kind] else { continue }
            saved[kind] = fresh
            defaults?.set(fresh.map(Self.encode), forKey: Self.key(kind))
        }
    }

    private static func key(_ kind: Kind) -> String { "savedPlace." + kind.rawValue }

    private static func encode(_ place: Saved) -> Data {
        (try? JSONEncoder().encode(place)) ?? Data()
    }

    private static func decode(_ data: Data?) -> Saved? {
        data.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    /// Where an address is, from Apple Maps.
    static func locate(_ address: String) async -> (place: TodoPlace, address: String)? {
        guard let request = MKGeocodingRequest(addressString: address),
              let item = try? await request.mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        let short = item.address?.shortAddress ?? address
        return (TodoPlace(name: item.name ?? short, latitude: coordinate.latitude, longitude: coordinate.longitude), short)
    }
}

#if os(iOS)
/// An address tapped on a card in Contacts' own picker: Notebook sees only that address and needs no access to your
/// contacts. Your own card has the Home and Work that Apple Maps shows.
@MainActor
final class ContactAddressPicker: NSObject, CNContactPickerDelegate {
    static let shared = ContactAddressPicker()
    private var waiting: CheckedContinuation<String?, Never>?

    /// The address tapped, on one line; nothing when the picker was cancelled.
    func chooseAddress() async -> String? {
        guard waiting == nil, let presenter = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first?.topmostPresented else { return nil }
        let picker = CNContactPickerViewController()
        picker.delegate = self
        picker.displayedPropertyKeys = [CNContactPostalAddressesKey]
        picker.predicateForEnablingContact = NSPredicate(format: "postalAddresses.@count > 0")
        // A card opens to tap one of its addresses.
        picker.predicateForSelectionOfContact = NSPredicate(value: false)
        picker.predicateForSelectionOfProperty = NSPredicate(format: "key == 'postalAddresses'")
        return await withCheckedContinuation { continuation in
            waiting = continuation
            presenter.present(picker, animated: true)
        }
    }

    nonisolated func contactPicker(_ picker: CNContactPickerViewController, didSelect contactProperty: CNContactProperty) {
        let address = (contactProperty.value as? CNPostalAddress).map {
            CNPostalAddressFormatter.string(from: $0, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
        }
        MainActor.assumeIsolated { finish(address) }
    }

    nonisolated func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
        MainActor.assumeIsolated { finish(nil) }
    }

    private func finish(_ address: String?) {
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: address)
    }
}
#endif
