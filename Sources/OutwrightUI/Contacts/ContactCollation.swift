// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightModel
#if canImport(UIKit)
import UIKit
#endif

/// How contacts fall into the list's letter sections: the letters of the phone's language and the
/// section of each name. On iOS that is the system's collation (Å Ä Ö only where the language has
/// them); elsewhere (the unit tests on a Mac) `ContactsModel.alphabet`.
@MainActor
struct ContactCollation {
    /// Every section, in order.
    let titles: [String]
    /// The title of the section a contact stands in.
    let section: @MainActor (Contact) -> String

    static var phone: ContactCollation {
        #if canImport(UIKit)
        let collation = UILocalizedIndexedCollation.current()
        let titles = collation.sectionTitles
        guard let fallback = titles.last else { return swedish }
        return ContactCollation(titles: titles) { contact in
            let family = contact.details.familyName.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = CollationName(family.isEmpty ? contact.details.name : family)
            let index = collation.section(for: item, collationStringSelector: #selector(getter: CollationName.text))
            return titles.indices.contains(index) ? titles[index] : fallback
        }
        #else
        swedish
        #endif
    }

    static let swedish = ContactCollation(titles: ContactsModel.alphabet) { ContactsModel.letter(of: $0) }
}

#if canImport(UIKit)
/// A name as the collation asks for it (by selector).
private final class CollationName: NSObject {
    @objc let text: String
    init(_ text: String) { self.text = text }
}
#endif
