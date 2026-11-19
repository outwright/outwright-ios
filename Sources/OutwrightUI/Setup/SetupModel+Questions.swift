// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import OutwrightSync

/// Before a restore: a switch per account, and after the button each difference asked in turn.
extension SetupModel {
    /// Whether the account (by address) is brought here.
    public func isIncluded(_ address: String) -> Bool { !leavingOff.contains(address.lowercased()) }

    /// Brings the account (by address) here, or leaves it off this device.
    public func setIncluded(_ address: String, _ included: Bool) {
        guard case .preview = state, question == nil else { return }
        if included {
            leavingOff.remove(address.lowercased())
        } else {
            leavingOff.insert(address.lowercased())
        }
    }

    /// The owner's answer to `question`: take the other side's, or keep this device's.
    public func answer(useOther: Bool) {
        guard question != nil, let answering else { return }
        self.answering = nil
        question = nil
        answering.resume(returning: useOther)
    }

    /// Asks each difference of the preview, for an account brought here, in turn. False when the
    /// questions ended unanswered (the preview was replaced, or the other device left).
    func askQuestions() async -> Bool {
        guard case .preview(let preview) = state, question == nil else { return false }
        replacing = []
        for difference in preview.differences where isIncluded(difference.label) {
            question = difference
            let answer = await withCheckedContinuation { answering = $0 }
            guard let answer else { return false }
            if answer { replacing.insert(difference) }
        }
        question = nil
        return true
    }

    /// Ends any question unanswered; nothing is added for it.
    func endQuestions() {
        question = nil
        let waiting = answering
        answering = nil
        waiting?.resume(returning: nil)
    }

}
