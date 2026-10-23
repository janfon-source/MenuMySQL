import Foundation

/// A connection kept under a name of one's own: the server, how to reach it, the account and the
/// database to open. Its password is kept with the account's (Passwords), like any connection's.
struct Favorite: Equatable {
    var id = UUID()
    var name: String
    var location: ServerLocation

    /// The server and database, as the list shows them under the name.
    var summary: String {
        "\(location.user)@\(location.serverName)" + (location.database.map { " / \($0)" } ?? "")
    }
}

/// The saved favorites, in the order they were added, kept in the app's defaults.
enum Favorites {
    private static let key = "menumysql.favorites"

    static var all: [Favorite] {
        get {
            (UserDefaults.standard.array(forKey: key) as? [[String: String]] ?? []).compactMap { entry in
                guard let name = entry["name"], let location = entry["location"].flatMap(ServerLocation.init(key:)) else { return nil }
                return Favorite(id: entry["id"].flatMap(UUID.init(uuidString:)) ?? UUID(), name: name, location: location)
            }
        }
        set {
            UserDefaults.standard.set(newValue.map { ["id": $0.id.uuidString, "name": $0.name, "location": $0.location.key] }, forKey: key)
        }
    }

    /// The favorite for exactly this server, account and database, if there is one.
    static func matching(_ location: ServerLocation) -> Favorite? {
        all.first { $0.location.key == location.key }
    }

    /// A name to start from: the database, and the server it's on.
    static func suggestedName(for location: ServerLocation) -> String {
        location.database.map { "\($0) — \(location.host)" } ?? location.host
    }
}
