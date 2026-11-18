// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightModel

/// Pictures a message's HTML fetches from elsewhere, and whether they may be.
extension MessageContent {
    public var hasRemotePictures: Bool {
        html.map(RemoteContent.mentionsRemote) ?? false
    }

    /// Whether Download pictures is offered: there are remote pictures and the content may fetch
    /// them (`ProtectionFacts.allowsRemoteContent`: decrypted content that may have been changed on
    /// the way never does).
    public var offersRemotePictures: Bool {
        hasRemotePictures && (facts?.allowsRemoteContent ?? true)
    }
}
