# Outwright

**Simple Digital Independence.** Your mail server, on your iPhone and iPad, with nothing in between.

Outwright is a free, open-source mail, calendar and contacts app for iPhone and iPad that talks straight
to your mail server. It follows a familiar Outlook-style workflow, without sending your mail
through anyone else's servers.
Website: [outwright.app](https://outwright.app).

**Alpha.** To join, sign up on [outwright.app](https://outwright.app/#join) and install it
straight away with TestFlight. It is an alpha: expect rough edges, and keep another way to
reach your mail while you try it. What each release brings is in
[RELEASE_NOTES.md](RELEASE_NOTES.md).

## What works in the alpha

- **Accounts:** as many as you have, each with its own inbox, and All inboxes for all of them
  at once.
- **Microsoft 365 and Outlook.com:** mail, calendar and contacts, the app talking to Microsoft
  directly, without passing through our servers. In the TestFlight and App Store app only, for
  now; a build of your own does not have it yet.
- **Mail:** [IMAP and SMTP](STANDARDS.md#mail-imap): read, write, search, folders, and older
  mail fetched as you scroll.
- **Calendar:** [CalDAV](STANDARDS.md#calendars): agenda, day, three-day and month views;
  events created, edited and deleted on your server. You can also subscribe to a published
  calendar (an ICS link, `webcal:` too), shown beside your own.
- **Invitations:** respond to invitations directly from the message, and the meeting appears in
  your calendar. Meeting invitations are sent to your guests, by mail when your server does not
  send them.
- **Contacts:** [CardDAV](STANDARDS.md#contacts): your address books, edited on your server,
  and suggestions as you write.
- **Encrypted mail:** OpenPGP, signed and encrypted, with Proton Mail users and anyone else
  with a key. In the TestFlight and App Store app only (see below).
- **New mail:** notifications, if you turn them on: [as mail arrives](STANDARDS.md#push) on
  Stalwart, on Dovecot with [our script](https://outwright.app/push/dovecot), on Microsoft
  accounts, and on any other IMAP server through [a small program of your own](https://outwright.app/push/worker);
  otherwise when iOS lets the app check, which can be late.

## Why Outwright exists

Outlook always goes through Microsoft. Outwright goes straight to your server.

Even when you add an account on your own mail server, Outlook for iOS does not talk to that
server itself: it hands the account to Microsoft's cloud, which logs in to your server with
your password and keeps a copy of your mail on Microsoft's servers. If you run your own server
to keep your mail to yourself, that defeats the point.

Outwright keeps the familiar workflow and drops the detour: the app logs in to your server
itself, and your password stays in the iPhone's keychain.

It is part of a bigger idea: your mail identity should be yours. Your own domain and address,
on your own server or with a provider you choose, and the freedom to change either without
losing who you are. Outwright starts with the app, and everything it does follows open
standards, so nothing ties you to us.

No AI assistant: Outwright does mail, calendar and contacts, and does them well.

## Who it is for

- Self-hosters, who run their own mail server and want an iPhone and iPad app that talks to it directly.
- Anyone with email from their internet provider or a mail host. Most of them offer IMAP, so
  Outwright talks to their server directly, as it does to your own.
- Anyone who cares about privacy and wants their mail, calendar and contacts kept out of other
  companies' clouds.

Keep your accounts together in Outwright: your own domain, a work address, an old one or two.
Each has its own inbox, All inboxes shows them together, and calendars and contacts stay in
sync with each server.

## Coming next

Gmail, with the app talking to Google directly.

## Servers

Supported today:

- **[Stalwart](https://stalw.art) 1.1.** It has every protocol Outwright uses in one server and
  sends Web Push, which is how new-mail notifications reach the phone.
- **[Dovecot](https://www.dovecot.org) 2.4, with Postfix 3.10 and Radicale 3.5,** as Debian 13
  ships them. Radicale does not send invitations itself, so Outwright mails them to your guests.
  Instant new-mail notifications need [our push script](https://outwright.app/push/dovecot). For addresses with letters such as å before
  the `@`, Dovecot needs `mail_utf8_extensions = yes`; without it Postfix bounces them.
- **Any other IMAP server that follows the standards,** which is what most internet providers
  and mail hosts run. IDLE, MOVE, CONDSTORE and SPECIAL-USE are used where the server has them,
  and not needed where it does not.

Every build is tested against Stalwart and Dovecot before it goes out; [TESTING.md](TESTING.md)
says how.

### What a server needs

A few things are required, all of them on purpose:

- **A certificate the iPhone trusts.** For your own CA, install it on the phone as a
  configuration profile.
- **SMTP authentication.** A server that relays by IP address, or after an IMAP login, is not
  used.
- **Passwords only inside TLS,** with IMAP LOGIN and SMTP AUTH PLAIN or LOGIN. A server that
  offers only CRAM-MD5 or SCRAM, or refuses LOGIN even over TLS, cannot be signed in to.
- **IMAP over TLS:** no POP3 and no unencrypted connections
  ([STANDARDS.md](STANDARDS.md#deliberately-not-supported) says why).
- **IMAP4rev1 announced.** Servers that speak IMAP4rev2 announce it too in practice.
- **Automatic setup** reads [DNS SRV records](STANDARDS.md#finding-the-servers), then tries
  `imap.<domain>` and `smtp.<domain>`. Anything else is entered by hand.

Depending on your server: addresses with letters such as å, ä or ö before the `@` go only
through a server that offers SMTPUTF8 (RFC 6531); with another, the message is not sent and
says why. Such letters in the domain always work.

If you try another server, tell us how it goes in an
[issue](https://github.com/outwright/outwright-ios/issues).

## Private by design

Your mail, calendar and contacts never pass through our servers. Passwords live only in the
iPhone's keychain, and every connection is encrypted.

Optional new-mail notifications use our push relay. iOS does not let an app keep a connection
to your server open in the background; Apple has built it that way. The only way to wake the app
is Apple's push service, and only the app's developer can send through it.

Our push relay is that sender. Your server sends it an encrypted ping, and the relay asks Apple
to wake your phone. The relay sees none of your mail: no message, sender, recipient, subject or
address. The app then fetches the new mail from your server itself. Without the relay,
Outwright works the same, except that it tells you about new mail only when iOS lets it check,
which can be late.

Mail is treated as hostile: nothing in a message runs, and nothing is fetched from the internet
unless you ask for its pictures. Read our [privacy policy](https://outwright.app/privacy). Every
specification Outwright follows is listed in [STANDARDS.md](STANDARDS.md).

## Free and open source

The alpha is free. Outwright will be available in free and paid versions, with different levels
of support. Both versions connect directly to your servers. The core is open source, in this
repository, so you can also build it yourself. OpenPGP encryption is in the App Store app only,
where it is free; a build of your own does not have it.

## Building

You need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[SwiftLint](https://github.com/realm/SwiftLint). Everything runs through `make`:

- `make build`: the Swift package, and the iOS app for the simulator; it also writes
  `App/Outwright.xcodeproj` to open in Xcode (run it after every pull).
- `make test`: `make build`, then every unit test and SwiftLint; run it before you open a pull
  request.

## Contributing

Issues are welcome. Until the beta is done we are very restrictive with pull requests: open an
issue first and ask before you start on a change. Read [AGENTS.md](AGENTS.md) first: it holds the rules
every change follows, for people and coding agents alike. [TESTING.md](TESTING.md) says how
changes are tested, and [ATTRIBUTION.md](ATTRIBUTION.md) lists where every asset comes from.

Outwright is developed in a private repository and published here. A pull request is not
merged on GitHub: the maintainer brings it home, runs the integration tests on it, and lands it
with you as the commit's author. It appears here with the next release, and the pull request is
closed with a link to its commit.

By opening a pull request you license your contribution under the same terms as the project
(MIT OR Apache-2.0). There is no contributor agreement to sign and no sign-off line to add.

## Licence

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
