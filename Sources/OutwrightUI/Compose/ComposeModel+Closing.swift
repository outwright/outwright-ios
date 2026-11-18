// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

extension ComposeModel {
    /// What ✕ does: close at once, or ask whether to delete or save the draft.
    public enum CloseChoice: Sendable, Equatable {
        case close, ask
    }

    /// With changes ✕ asks (Delete draft, Save draft, Cancel); without, it just closes.
    public var closeChoice: CloseChoice { hasChanges && !isFinished ? .ask : .close }

    /// Delete draft: the copy kept in Drafts (a draft opened again, or one kept on the way to the
    /// background) is deleted; a message never saved just closes. Nothing more is saved. When the
    /// delete is refused it throws and the message stays open.
    public func discardDraft() async throws(ComposeError) {
        if let id = draftID {
            do {
                try store.apply(.delete(id))
            } catch {
                throw .store
            }
            draftID = nil
        }
        isFinished = true
    }
}
