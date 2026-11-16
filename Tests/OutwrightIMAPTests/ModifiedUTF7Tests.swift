// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Testing
@testable import OutwrightIMAP

@Suite struct ModifiedUTF7Tests {
    @Test func decodesSwedishFolderNames() {
        #expect(ModifiedUTF7.decode("Skr&AOQ-ppost") == "Skräppost")
        #expect(ModifiedUTF7.decode("Borttaget") == "Borttaget")
        #expect(ModifiedUTF7.decode("A&-B") == "A&B")
        #expect(ModifiedUTF7.encode("Skräppost") == "Skr&AOQ-ppost")
        for name in ["Skräppost", "Ärenden/Över", "日本語", "A&B", "Tom 😀 mapp", "plain"] {
            #expect(ModifiedUTF7.decode(ModifiedUTF7.encode(name)) == name)
        }
    }

    @Test func rejectsMalformedSequences() {
        #expect(ModifiedUTF7.decode("Bad&AOQ") == nil)
        #expect(ModifiedUTF7.decode("Bad&!!!-") == nil)
        #expect(ModifiedUTF7.decode("Raw\u{00E4}") == nil)
    }
}
