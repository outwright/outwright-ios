// SPDX-FileCopyrightText: Outwright contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

// A fake Microsoft for the end-to-end tests: the sign-in and token endpoints, Graph, and IMAP
// and SMTP with XOAUTH2, on 127.0.0.1, with synthetic example.org data. The same fakes the unit
// tests use. Writes where they are to the file named by its one argument, then serves until it
// is stopped.

import Foundation
import OutwrightFakes

// The client id and redirect URI the app under test was built with (the e2e script
// passes them); made-up ones otherwise.
let environment = ProcessInfo.processInfo.environment
let clientID = environment["OUTWRIGHT_FAKE_MICROSOFT_CLIENT_ID"] ?? "00000000-0000-0000-0000-000000000000"
let redirectURI = environment["OUTWRIGHT_FAKE_MICROSOFT_REDIRECT"] ?? "outwright-test://auth"
let envPath = CommandLine.arguments.dropFirst().first ?? "microsoft.env"

let oauth = FakeOAuthServer(
    clientID: clientID, redirectURI: redirectURI, address: FakeIMAPServer.user, name: "Ellen Example")
let authority = try await oauth.start()

let graph = FakeGraphServer()
let graphBase = try await graph.start()
await graph.put(Data(#"""
    {"givenName":"Gus","surname":"Graph","emailAddresses":[{"address":"gus@example.org"}],
     "mobilePhone":"+46 70 000 00 01","companyName":"Graph AB"}
    """#.utf8))

// A calendar relative to today (UTC): lunch today; a daily stand-up from yesterday, five times,
// today's cancelled and tomorrow's moved two hours later.
let calendar = await graph.addCalendar("Calendar", color: "#2e9e6b", isDefault: true)
let day: TimeInterval = 86_400
let today = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / day).rounded(.down) * day)
func stamp(_ date: Date) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return format.string(from: date)
}
func event(_ subject: String, _ start: Date, minutes: Double, _ more: String = "") -> Data {
    Data(#"""
        {"subject":"\#(subject)","start":{"dateTime":"\#(stamp(start))","timeZone":"UTC"},
         "end":{"dateTime":"\#(stamp(start.addingTimeInterval(minutes * 60)))","timeZone":"UTC"},
         "originalStartTimeZone":"W. Europe Standard Time","originalEndTimeZone":"W. Europe Standard Time",
         "isReminderOn":false\#(more)}
        """#.utf8)
}
await graph.putEvent(event("Fake Microsoft: lunch", today.addingTimeInterval(11 * 3600), minutes: 60), in: calendar)
let firstStandup = today.addingTimeInterval(-day + 7 * 3600)
let standup = await graph.putEvent(event("Fake Microsoft: stand-up", firstStandup, minutes: 15, #"""
    ,"recurrence":{"pattern":{"type":"daily","interval":1},
     "range":{"type":"numbered","startDate":"\#(stamp(firstStandup).prefix(10))","numberOfOccurrences":5}}
    """#), in: calendar)
await graph.cancelOccurrence(of: standup, on: String(stamp(today).prefix(10)))
let movedStart = today.addingTimeInterval(day + 9 * 3600)
await graph.addException(of: standup, at: today.addingTimeInterval(day + 7 * 3600), Data(#"""
    {"subject":"Fake Microsoft: stand-up, moved","start":{"dateTime":"\#(stamp(movedStart))","timeZone":"UTC"},
     "end":{"dateTime":"\#(stamp(movedStart.addingTimeInterval(900)))","timeZone":"UTC"}}
    """#.utf8))

let imap = FakeIMAPServer()
await imap.addFolder("Sent", specialUse: "\\Sent")
await imap.addFolder("Drafts", specialUse: "\\Drafts")
await imap.addFolder("Trash", specialUse: "\\Trash")
let welcome = [
    "From: Gus Graph <gus@example.org>", "To: \(FakeIMAPServer.user)", "Subject: Fake Microsoft: welcome",
    "Date: \(Date().formatted(.iso8601))", "", "Mail over XOAUTH2 from the fake Microsoft.", ""
].joined(separator: "\r\n")
_ = await imap.deliver(Data(welcome.utf8), to: "INBOX")
let imapPort = try await imap.start()
let smtp = FakeSMTPServer()
let smtpPort = try await smtp.start()

/// The tests' handle on the fakes: `GET /contacts` and `GET /events` (Graph's contacts and events as
/// JSON objects) and
/// `POST /fail?status=N` (Graph answers N to its next request) and `GET /requests` (what Graph
/// was asked, one `METHOD path` a line).
let control = FakeHTTPServer { request in
    if request.method == "GET", request.path == "/requests" {
        let lines = await graph.requests.map { "\($0.method) \($0.path)" }.joined(separator: "\n")
        return FakeHTTPResponse(status: 200, body: Data(lines.utf8))
    }
    if request.method == "GET", request.path == "/events" {
        let objects = await graph.allEventsJSON().compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let body = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
        return FakeHTTPResponse(status: 200, body: body, headers: ["Content-Type": "application/json"])
    }
    if request.method == "GET", request.path == "/contacts" {
        let objects = await graph.contactsJSON().compactMap { try? JSONSerialization.jsonObject(with: $0) }
        let body = (try? JSONSerialization.data(withJSONObject: objects)) ?? Data("[]".utf8)
        return FakeHTTPResponse(status: 200, body: body, headers: ["Content-Type": "application/json"])
    }
    if request.method == "POST", request.path.hasPrefix("/fail?status="),
        let status = Int(request.path.dropFirst("/fail?status=".count)) {
        await graph.failNext(status: status)
        return FakeHTTPResponse(status: 204)
    }
    return FakeHTTPResponse(status: 404)
}
let controlPort = try await control.start()

let launch = [
    "AUTHORITY=\(authority.absoluteString)", "GRAPH=\(graphBase.absoluteString)", "IMAP=127.0.0.1:\(imapPort)",
    "SMTP=127.0.0.1:\(smtpPort)"
].joined(separator: ";")
let env = "launch=\(launch)\ncontrol=http://127.0.0.1:\(controlPort)/\naddress=\(FakeIMAPServer.user)\n"
try env.write(toFile: envPath, atomically: true, encoding: .utf8)
print(envPath)

// The mail fakes take every access token the fake sign-in issues.
var accepted = 0
while true {
    let issued = await oauth.issued
    for token in issued.dropFirst(accepted) {
        await imap.acceptToken(token)
        await smtp.acceptToken(token)
    }
    accepted = issued.count
    try await Task.sleep(for: .milliseconds(200))
}
