import Foundation

/// A GraphQL `nodes` list as heed reads it. GitHub answers a null in place of a node it withholds (an organisation's
/// SAML enforcement, a repository the token cannot see) and the rest of the page is still good: cast the list as
/// `[[String: Any]]` and one null makes the whole cast fail, so a page of 99 items reads as none. This keeps every
/// object and says how many were not.
enum GraphQLNodes {
    /// The objects in `value`, nulls and anything that is not an object left out; nil when `value` is not a list.
    static func objects(_ value: Any?) -> [[String: Any]]? {
        (value as? [Any])?.compactMap { $0 as? [String: Any] }
    }

    /// How many entries of the list are not objects (null): what GitHub withheld from this page.
    static func withheld(_ value: Any?) -> Int {
        guard let list = value as? [Any] else { return 0 }
        return list.count { !($0 is [String: Any]) }
    }
}
