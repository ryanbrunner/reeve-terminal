import Foundation
import ReeveKit

/// Where the app keeps what it remembers between launches: the standard
/// defaults, or a domain of their own for a Reeve on other data, so a smoke
/// test never changes what your Reeve remembers.
enum Preferences {
    static let store: UserDefaults = DataDirectory.preferencesSuite().flatMap(UserDefaults.init(suiteName:)) ?? .standard
}
