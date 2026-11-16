// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation

/// What a test build hooks into the app at launch: a clock that runs ahead, a sample in place of
/// the real model, providers pointed at fake servers. A shipped build has none: hooks are classes
/// only the end-to-end build compiles, named in its Info.plist (`OutwrightLaunchHooks`), so the
/// app never names them.
@MainActor
public protocol LaunchHooks: AnyObject {
    /// How far the app's clock runs ahead of (or behind) the phone's, in seconds.
    var clockOffset: TimeInterval { get }
    /// Whether the app starts on a sample instead of its own store.
    var startsSample: Bool { get }
    /// The sample's model, in place of the app's own; nil to start normally.
    func sampleModel() -> AppModel?
    /// The build's providers, as the test wants them (on fake servers).
    func providers(_ providers: [any AccountProvider]) -> [any AccountProvider]
    /// The sample model is made: a hook may add to it (a provider's sample account).
    func sampleStarted(_ model: AppModel)
}

extension LaunchHooks {
    public var clockOffset: TimeInterval { 0 }
    public var startsSample: Bool { false }
    public func sampleModel() -> AppModel? { nil }
    public func providers(_ providers: [any AccountProvider]) -> [any AccountProvider] { providers }
    public func sampleStarted(_ model: AppModel) {}
}

/// The hooks a build names, found by their Objective-C class names; a name that is no hook is
/// ignored.
@MainActor
public struct LaunchHookSet {
    public let hooks: [any LaunchHooks]

    public init(named names: [String]) {
        hooks = names.compactMap { name in
            (NSClassFromString(name) as? NSObject.Type)?.init() as? any LaunchHooks
        }
    }

    public var clockOffset: TimeInterval {
        hooks.lazy.map(\.clockOffset).first { $0 != 0 } ?? 0
    }

    public var startsSample: Bool {
        hooks.contains { $0.startsSample }
    }

    /// The sample's model, once every hook has added to it.
    public func sampleModel() -> AppModel? {
        guard let model = hooks.lazy.compactMap({ $0.sampleModel() }).first else { return nil }
        for hook in hooks {
            hook.sampleStarted(model)
        }
        return model
    }

    public func providers(_ providers: [any AccountProvider]) -> [any AccountProvider] {
        hooks.reduce(providers) { $1.providers($0) }
    }
}
