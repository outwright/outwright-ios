// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import OutwrightModel

/// The wide layouts' part of the app's state: search over the screen on a phone and in the list
/// column on an iPad, and the iPad's sidebar.
extension AppModel {
    /// The search button: in the columns search belongs to Mail's list, so another tab gives way.
    func startSearch() {
        if searchInColumns { selectedTab = .mail }
        isSearching = true
    }

    /// A message chosen among the results: beside search in the columns, else in place of the cover.
    func openSearchResult(_ id: MessageID) {
        if searchInColumns {
            searchSelection = id
        } else {
            isSearching = false
            messageToOpen = id
        }
    }

    /// An event or a person chosen among the results, waiting in `pendingEvent` or `pendingPerson`:
    /// its sheet opens over search in the columns; the cover closes first, and it opens as it goes.
    func searchHandedOver() {
        if searchInColumns { openPending() } else { isSearching = false }
    }

    /// The window narrowed: the result open beside search opens in place of the cover.
    func searchColumnsChanged(from wasInColumns: Bool) {
        guard wasInColumns, !searchInColumns, let open = searchSelection else { return }
        searchSelection = nil
        messageToOpen = open
    }

    /// The avatar in a tab's header, where a sidebar stands beside the list instead of the drawer.
    func toggleSidebar() { sidebarToggles &+= 1 }

    /// Search opened or closed: its model is made with what search starts with, and when search
    /// closes it is closed (what the servers brought in goes) with what it had open beside it.
    func searchChanged() {
        if isSearching {
            guard search == nil else { return }
            let model = SearchModel(store: store, sync: sync, staged: pendingMail)
            model.query = searchText
            search = model
        } else {
            search?.close()
            search = nil
            searchSelection = nil
            searchText = ""
        }
    }

    /// A message opened from outside search (a notification, a person card) is shown in the list's
    /// place, so search in the columns gives way to it.
    func messageOpening() {
        if searchInColumns, isSearching { isSearching = false }
    }

}

/// Choosing what the list shows.
extension AppModel {
    public func open(_ folder: FolderID) {
        scope = .folder(folder)
        openedFolder()
    }

    public func openAllInboxes() {
        scope = .allAccounts
        openedFolder()
    }

    /// A folder was chosen (the one shown, too): Mail shows it, in place of search in the columns, and
    /// a sidebar over the list closes.
    private func openedFolder() {
        scopeBeforeDrafts = nil
        selectedTab = .mail
        isDrawerOpen = false
        if searchInColumns { isSearching = false }
        foldersChosen &+= 1
    }
}
