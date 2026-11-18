// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI
import Testing

@testable import OutwrightUI

@Suite struct WideLayoutTests {
    @Test func layoutFollowsTheSizeClasses() {
        #expect(WideLayout.of(width: .compact, height: .regular) == .column)
        #expect(WideLayout.of(width: nil, height: nil) == .column)
        #expect(WideLayout.of(width: .regular, height: .compact) == .panes)
        #expect(WideLayout.of(width: .regular, height: .regular) == .sidebar)
    }

    @Test func aWideWindowShowsAllThreeColumns() {
        #expect(SidebarState().visibility(.sidebar, width: 1366) == .all)
        #expect(SidebarState().visibility(.sidebar, width: 1100) == .all)
    }

    @Test func aNarrowerWindowHidesTheSidebar() {
        #expect(SidebarState().visibility(.sidebar, width: 1032) == .doubleColumn)
    }

    @Test func theOwnersChoiceWins() {
        #expect(SidebarState(choice: true).visibility(.sidebar, width: 1032) == .all)
        #expect(SidebarState(choice: false).visibility(.sidebar, width: 1366) == .doubleColumn)
    }

    @Test func thePhoneOnItsSideNeverShowsTheSidebar() {
        for choice in [nil, true, false] as [Bool?] {
            #expect(SidebarState(choice: choice).visibility(.panes, width: 932) == .doubleColumn)
        }
    }

    @Test func expandingGivesTheMessageTheWidth() {
        let state = SidebarState(isExpanded: true)
        #expect(state.visibility(.panes, width: 932) == .detailOnly)
        #expect(state.visibility(.sidebar, width: 1366) == .detailOnly)
    }

    @Test func expandedHoldsAcrossAResize() {
        let state = SidebarState(isExpanded: true)
        #expect(state.visibility(.sidebar, width: 1032) == .detailOnly)
        #expect(state.visibility(.sidebar, width: 1366) == .detailOnly)
    }

    @Test func theSystemButtonIsRemembered() {
        var state = SidebarState(isExpanded: true)
        state.apply(.all, layout: .sidebar, width: 1032)
        #expect(state.choice == true)
        #expect(!state.isExpanded)
        state.apply(.doubleColumn, layout: .sidebar, width: 1366)
        #expect(state.choice == false)
        state.apply(.detailOnly, layout: .sidebar, width: 1366)
        #expect(state.isExpanded)
    }

    @Test func choosingAFolderClosesAnOverlaidSidebar() {
        var state = SidebarState(choice: true)
        state.folderChosen(width: 1032)
        #expect(state.visibility(.sidebar, width: 1032) == .doubleColumn)
    }

    @Test func choosingAFolderKeepsAPinnedSidebar() {
        var state = SidebarState()
        state.folderChosen(width: 1366)
        #expect(state.visibility(.sidebar, width: 1366) == .all)
    }

    @Test func aNewSizeClassForgetsTheChoice() {
        var state = SidebarState(choice: false, isExpanded: true)
        state.layoutChanged()
        #expect(state.choice == nil)
        #expect(!state.isExpanded)
    }

    @Test func theAvatarShowsAHiddenSidebar() {
        var state = SidebarState()
        state.toggle(.sidebar, width: 1032)
        #expect(state.visibility(.sidebar, width: 1032) == .all)
    }

    @Test func theAvatarHidesAShownSidebar() {
        var state = SidebarState()
        state.toggle(.sidebar, width: 1366)
        #expect(state.visibility(.sidebar, width: 1366) == .doubleColumn)
    }

    @Test func theAvatarBringsBackAnExpandedMessagesColumns() {
        var state = SidebarState(isExpanded: true)
        state.toggle(.sidebar, width: 1366)
        #expect(state.visibility(.sidebar, width: 1366) == .all)
    }

    @Test func twoColumnsShowTheSidebarWhereThreeWould() {
        #expect(SidebarState().twoColumnVisibility(.sidebar, width: 1366) == .all)
        #expect(SidebarState().twoColumnVisibility(.sidebar, width: 1032) == .detailOnly)
        #expect(SidebarState(choice: true).twoColumnVisibility(.sidebar, width: 1032) == .all)
    }

    @Test func twoColumnsIgnoreTheExpandedMessage() {
        #expect(SidebarState(isExpanded: true).twoColumnVisibility(.sidebar, width: 1366) == .all)
    }

    @Test func hidingTheSidebarOfTwoColumnsIsRemembered() {
        var state = SidebarState(isExpanded: true)
        state.applyTwoColumn(.detailOnly, width: 1366)
        #expect(state.choice == false)
        #expect(state.isExpanded)
        state.applyTwoColumn(.all, width: 1032)
        #expect(state.choice == true)
    }

    @Test func theAvatarHidesTheCalendarsSidebarWhileMailIsExpanded() {
        var state = SidebarState(isExpanded: true)
        state.toggle(.sidebar, width: 1366, twoColumns: true)
        #expect(state.twoColumnVisibility(.sidebar, width: 1366) == .detailOnly)
    }

    /// Tapping beside a sidebar shown over the list closes it, which is no lasting choice: turned to
    /// landscape the iPad shows all three columns.
    @Test func dismissingAnOverlaidSidebarLeavesTheWidthToDecide() {
        var state = SidebarState(choice: true)
        state.apply(.doubleColumn, layout: .sidebar, width: 1032)
        #expect(state.choice == nil)
        #expect(state.visibility(.sidebar, width: 1366) == .all)
    }

    @Test func dismissingAnOverlaidCalendarSidebarLeavesTheWidthToDecide() {
        var state = SidebarState(choice: true)
        state.applyTwoColumn(.detailOnly, width: 1032)
        #expect(state.twoColumnVisibility(.sidebar, width: 1366) == .all)
    }

    /// Mail's expand button is Mail's: Contacts keeps its list.
    @Test func contactsIgnoreTheExpandedMessage() {
        let state = SidebarState(isExpanded: true)
        #expect(state.visibility(.panes, width: 932, expands: false) == .doubleColumn)
        #expect(state.visibility(.sidebar, width: 1366, expands: false) == .all)
    }

    @Test func contactsNeverExpandMail() {
        var state = SidebarState()
        state.apply(.detailOnly, layout: .sidebar, width: 1366, expands: false)
        #expect(!state.isExpanded)
    }
}
