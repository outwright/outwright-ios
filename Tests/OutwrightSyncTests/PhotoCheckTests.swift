// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightFakes
import OutwrightSync
import Testing

@Suite struct PhotoCheckTests {
    @Test func photoWithASidePastTheCapIsDropped() {
        #expect(ContactPhoto.safe(SyntheticImage.png(width: 8_001, height: 1)) == nil)
        #expect(ContactPhoto.safe(SyntheticImage.png(width: 1, height: 8_001)) == nil)
    }

    @Test func ordinaryPhotoIsKept() {
        let photo = SyntheticImage.png(width: 8_000, height: 2)
        #expect(ContactPhoto.safe(photo) == photo)
    }

    @Test func unreadableBytesAreDropped() {
        #expect(ContactPhoto.safe(Data(repeating: 7, count: 64)) == nil)
        #expect(ContactPhoto.safe(nil) == nil)
    }
}
