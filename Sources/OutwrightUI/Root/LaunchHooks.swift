// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

public import Foundation
public import OutwrightStore

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
    /// Before the app's own store opens in `folder`: a hook may clear what an earlier run left.
    func prepare(storeFolder folder: URL)
    /// The app's own store is open and nothing has read it yet: a hook may add to it (a test's
    /// accounts).
    func storeOpened(_ store: MailStore)
}

extension LaunchHooks {
    public var clockOffset: TimeInterval { 0 }
    public var startsSample: Bool { false }
    public func sampleModel() -> AppModel? { nil }
    public func providers(_ providers: [any AccountProvider]) -> [any AccountProvider] { providers }
    public func sampleStarted(_ model: AppModel) {}
    public func prepare(storeFolder folder: URL) {}
    public func storeOpened(_ store: MailStore) {}
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

    public func prepare(storeFolder folder: URL) {
        for hook in hooks { hook.prepare(storeFolder: folder) }
    }

    public func storeOpened(_ store: MailStore) {
        for hook in hooks { hook.storeOpened(store) }
    }
}
