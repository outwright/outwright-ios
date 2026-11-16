// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

extension Text {
    /// Interface text from this module's String Catalog.
    init(ui key: LocalizedStringKey) {
        self.init(key, bundle: .module)
    }
}

/// A label whose title comes from this module's String Catalog.
struct ModuleLabel: View {
    let key: LocalizedStringKey
    let systemImage: String

    init(_ key: LocalizedStringKey, systemImage: String) {
        self.key = key
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(ui: key)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
