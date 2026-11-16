// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation

/// Interface text from the module's String Catalog, in the language of a given locale (for
/// text built by the models, which take their calendar and locale as a parameter).
enum L10n {
    static func string(_ key: String, locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        if let path = Bundle.module.path(forResource: language, ofType: "lproj"),
            let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        return Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }

    /// In the interface's own language.
    static func string(_ key: String) -> String {
        Bundle.module.localizedString(forKey: key, value: key, table: nil)
    }
}
