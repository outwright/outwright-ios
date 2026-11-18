// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// A device by the name it gave, or by the screens' own word when it gave none.
enum SetupDevice {
    static func name(_ device: String) -> String {
        device.isEmpty ? L10n.string("your other device") : device
    }
}

/// A step under way: a spinner, and what it is doing.
struct SetupWorking: View {
    let text: Text?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            if let text {
                text.foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Keeps the screen on while this view shows, as before once it goes.
    func keepsDeviceAwake() -> some View {
        modifier(KeepsDeviceAwake())
    }
}

private struct KeepsDeviceAwake: ViewModifier {
    @State private var before: Bool?

    func body(content: Content) -> some View {
        #if canImport(UIKit)
            content
                .onAppear {
                    before = UIApplication.shared.isIdleTimerDisabled
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    UIApplication.shared.isIdleTimerDisabled = before ?? false
                    before = nil
                }
        #else
            content
        #endif
    }
}
