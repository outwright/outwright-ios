// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing

@testable import OutwrightUI

@Suite struct PaneSelectionTests {
    @Test func keepsTheSelectionWhileItIsInTheList() {
        #expect(PaneSelection.following(2, old: [1, 2, 3], new: [1, 2, 3, 4]) == 2)
    }

    @Test func movesToTheNextWhenTheSelectionLeaves() {
        #expect(PaneSelection.following(2, old: [1, 2, 3], new: [1, 3]) == 3)
    }

    @Test func skipsNeighboursThatLeftWithIt() {
        #expect(PaneSelection.following(2, old: [1, 2, 3, 4], new: [1, 4]) == 4)
    }

    @Test func movesToThePreviousWhenTheLastLeaves() {
        #expect(PaneSelection.following(3, old: [1, 2, 3], new: [1, 2]) == 2)
    }

    @Test func clearsWhenTheListEmpties() {
        #expect(PaneSelection.following(1, old: [1], new: [Int]()) == nil)
    }

    @Test func keepsASelectionOpenedFromOutsideTheList() {
        #expect(PaneSelection.following(9, old: [1, 2], new: [1, 2, 3]) == 9)
    }

    @Test func nothingSelectedStaysNothing() {
        #expect(PaneSelection.following(nil as Int?, old: [1, 2], new: [1]) == nil)
    }

    @Test func turningWideSelectsTheOpenItem() {
        let carried = PaneSelection.carry(path: [7], selected: nil as Int?, wide: true)
        #expect(carried.path.isEmpty)
        #expect(carried.selected == 7)
    }

    @Test func turningWideAfterClosingTheMessageSelectsNothing() {
        let carried = PaneSelection.carry(path: [Int](), selected: 7, wide: true)
        #expect(carried.selected == nil)
    }

    @Test func turningNarrowOpensTheSelection() {
        let carried = PaneSelection.carry(path: [Int](), selected: 7, wide: false)
        #expect(carried.path == [7])
        // In one column the open item is the path; a selection left behind would keep its row pinned.
        #expect(carried.selected == nil)
    }

    @Test func turningNarrowWithNothingSelectedShowsTheList() {
        let carried = PaneSelection.carry(path: [Int](), selected: nil as Int?, wide: false)
        #expect(carried.path.isEmpty)
    }
}
