// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

/// The drawer: the sidebar's column, with help and settings at its foot, over the screen.
struct DrawerView: View {
    let app: AppModel
    let model: DrawerModel
    let calendar: CalendarModel
    let contacts: ContactsModel

    var body: some View {
        SidebarColumn(app: app, model: model, calendar: calendar, contacts: contacts)
            .background(Theme.drawerBackground.ignoresSafeArea())
    }
}
