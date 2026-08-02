import Foundation

/// Localized string lookup. Keys are the English source text; en.lproj is
/// an identity table. Every user-facing GUI string must go through L() —
/// tests enforce en/ja key-set parity.
@inline(__always)
func L(_ key: String) -> String {
    Bundle.appResources.localizedString(forKey: key, value: key, table: nil)
}

/// Exposes the app target's resource bundle to the test target.
enum L10nResources {
    static var bundle: Bundle { Bundle.appResources }
}
