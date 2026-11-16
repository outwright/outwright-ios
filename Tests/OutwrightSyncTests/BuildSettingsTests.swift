// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import Foundation
import OutwrightPush
import Testing

@testable import OutwrightSync

@Suite struct BuildSettingsTests {
    @Test func emptyValuesMeanMissing() {
        let settings = BuildSettings(info: [
            "OutwrightRelay": "", "OutwrightAppGroup": "$(OUTWRIGHT_APP_GROUP)", "OutwrightOther": "  ",
        ])
        #expect(settings.relay == nil)
        #expect(settings.appGroup == nil)
        #expect(settings.value("OutwrightOther") == nil)
    }

    @Test func relayMustBeHTTPS() {
        #expect(BuildSettings(info: ["OutwrightRelay": "http://relay.example.org/v1"]).relay == nil)
        #expect(BuildSettings(info: ["OutwrightRelay": "not a url"]).relay == nil)
    }

    @Test func apnsDefaultsToProduction() {
        #expect(BuildSettings(info: [:]).apnsEnvironment == .production)
        #expect(BuildSettings(info: ["OutwrightAPNsEnvironment": "sandbox"]).apnsEnvironment == .production)
        #expect(BuildSettings(info: ["OutwrightAPNsEnvironment": "development"]).apnsEnvironment == .development)
    }

    @Test func readsEveryValue() {
        let settings = BuildSettings(info: [
            "OutwrightRelay": "https://relay.example.org/v1", "OutwrightAppGroup": "group.org.example.outwright",
            "OutwrightAPNsEnvironment": "development", "OutwrightOther": "x", "NotOurs": "y",
        ])
        #expect(settings.relay == URL(string: "https://relay.example.org/v1"))
        #expect(settings.appGroup == "group.org.example.outwright")
        #expect(settings.apnsEnvironment == .development)
        #expect(settings.value("OutwrightOther") == "x")
        #expect(settings.value("NotOurs") == nil)
    }

    @Test func nonStringValuesAreIgnored() {
        let settings = BuildSettings(info: ["OutwrightRelay": 42, "OutwrightAppGroup": ["x"]])
        #expect(settings.relay == nil)
        #expect(settings.appGroup == nil)
    }

    @Test func launchHooksAreAListOfNames() {
        #expect(BuildSettings(info: [:]).launchHooks.isEmpty)
        #expect(BuildSettings(info: ["OutwrightLaunchHooks": "$(OUTWRIGHT_LAUNCH_HOOKS)"]).launchHooks.isEmpty)
        #expect(BuildSettings(info: ["OutwrightLaunchHooks": "A, B ,,C"]).launchHooks == ["A", "B", "C"])
    }
}
