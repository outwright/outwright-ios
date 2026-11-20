# Standards

What Outwright speaks, and by which specification. Everything is written from the public
specs; anything not listed here is not supported yet.

## Finding the servers

From the address alone, by the DNS standards. DNS is asked over HTTPS (Cloudflare), and only
the address's own domain is looked up.

| Spec | What Outwright does |
|---|---|
| RFC 6186, RFC 8314 | IMAP from `_imaps._tcp.<domain>`; submission from `_submissions._tcp.<domain>` (implicit TLS), else `_submission._tcp.<domain>` (STARTTLS). With no record: `imap.<domain>:993` and `smtp.<domain>:465`, both implicit TLS. Plain `_imap._tcp` is never used. |
| RFC 6764 | Calendars and contacts: the target of `_caldavs._tcp.<domain>` or `_carddavs._tcp.<domain>`, else the domain, else the IMAP host, each asked at `/.well-known/caldav` or `/.well-known/carddav` without credentials. |
| RFC 2782 | SRV records: the lowest priority wins; a target of `.` means the service is not offered. |

A server outside the address's domain (a hosting company's, or someone who took over the
records) is shown to the owner before a password goes there.

Not read: RFC 6764's TXT `path=` records, Mozilla's autoconfig XML, Microsoft's Autodiscover.

## Transport

| Spec | What Outwright does |
|---|---|
| RFC 8314 | Implicit TLS preferred, for IMAP (993) and submission (465). |
| RFC 3207, RFC 3501 › STARTTLS | STARTTLS when the account asks for it, and then required: a server that does not offer it gets no credentials. |

## Mail: IMAP

| Spec | What Outwright does |
|---|---|
| RFC 3501 | IMAP4rev1; sign-in with LOGIN (refused when the server says LOGINDISABLED). |
| RFC 3501 › 5.1.3 | Folder names in modified UTF-7. |
| RFC 3501 › 6.3.3–6.3.7 | The owner's folders made, renamed, moved and deleted (CREATE, RENAME, DELETE), deepest first, and kept subscribed (SUBSCRIBE, UNSUBSCRIBE). |
| RFC 3501 › 6.3.9 | LSUB: which folders are subscribed, so a rename carries their subscriptions along. |
| RFC 3501 › 6.3.10 | STATUS: how many messages a folder holds, told before it is deleted. |
| RFC 2342 | NAMESPACE: where the owner's folders live and their separator. |
| RFC 6154 | SPECIAL-USE: which folder is Drafts, Sent, Trash, Junk; by name when the flags are missing. |
| RFC 5161 | ENABLE, to turn on QRESYNC or CONDSTORE. |
| RFC 7162 | CONDSTORE and QRESYNC: folders synced by mod-sequence, expunges learnt with VANISHED. |
| RFC 6851 | MOVE; without it, COPY, `\Deleted` and (with UIDPLUS) UID EXPUNGE. |
| RFC 4315 | UIDPLUS: APPENDUID, COPYUID and UID EXPUNGE. |
| RFC 2177 | IDLE on the Inbox, on a connection of its own. |
| RFC 5530 | `[ALREADYEXISTS]`: creating a folder that exists is no failure; `[NONEXISTENT]`: deleting one already gone is none either. |

## Mail: sending

| Spec | What Outwright does |
|---|---|
| RFC 5321 | Submission of one message per session. |
| RFC 4954 | AUTH PLAIN, else AUTH LOGIN. |
| RFC 6409 | Message submission on 587 (STARTTLS) or 465 (implicit TLS, RFC 8314). |
| RFC 5890, RFC 3492 | A domain with non-ASCII characters goes as its A-labels (`xn--`, Punycode), in the envelope and the headers. |
| RFC 6531, RFC 6532 | SMTPUTF8: a message with non-ASCII characters before an address's `@` (in the envelope or a header) goes with `SMTPUTF8` where the server offers it, and is refused before sending where it does not. |

## Mail: messages

| Spec | What Outwright does |
|---|---|
| RFC 5322 | Headers, address lists (groups flattened), dates; lines kept under 998 octets. CR, LF and NUL are stripped from every header value written. |
| RFC 2045, RFC 2046 | MIME: multipart reading; outgoing text as quoted-printable, attachments as base64, text with HTML as `multipart/alternative`. |
| RFC 2047 | Encoded words in headers, read and written. |
| RFC 2231 | Parameter continuations and charsets, such as non-ASCII attachment names. |
| IANA charsets | Any charset the system knows; text is never refused for its charset. |
| RFC 5322 › 3.6.4 | Threads from References and In-Reply-To, else a reply's subject. |

## Calendars

| Spec | What Outwright does |
|---|---|
| RFC 5545 | iCalendar events, read and written; RRULE expansion (SECONDLY and MINUTELY refused). Show as is TRANSP, with the vendor property `X-MICROSOFT-CDO-BUSYSTATUS` for tentative and away; Private is `CLASS:PRIVATE`. A published calendar (one file) subscribed to, read-only. |
| RFC 7529 | RSCALE and SKIP in recurrence rules. |
| RFC 4791 | CalDAV: calendar-query, multiget, writes with preconditions. |
| RFC 6578 | WebDAV sync-collection, for calendars and address books. |
| RFC 4918 | WebDAV multistatus. |
| RFC 6638 | CalDAV scheduling: `calendar-auto-schedule`, `Schedule-Tag`, `Schedule-Reply`, `SCHEDULE-AGENT`. A server that says it schedules sends the owner's answer; the app mails it when the server does not schedule, or the copy's ORGANIZER says `SCHEDULE-AGENT=CLIENT` (set when an answer goes without a response). The owner's own meetings likewise: the app mails their invitations and cancellations to the guests the server does not schedule for. The organiser's update or cancellation that came by mail is written to the owner's copy (› 3.2.2.2); a server that refuses it (› 3.2.2.1) keeps its copy and the phone shows the update. |
| RFC 5546 | iTIP: REQUEST, ADD, CANCEL and REPLY are acted on; any other method is an ordinary attachment. A REPLY carries the owner's comment as COMMENT. |
| RFC 6047 | iMIP: invitations read from mail and answers sent as mail; where the server does not schedule, the owner's invitations and cancellations sent as mail and guests' answers by mail written to the owner's meeting. |
| RFC 9110 › 13 | Subscribed calendars: fetched with `If-None-Match` / `If-Modified-Since` when the last answer gave an ETag or Last-Modified; 304 keeps what is held. |
| `webcal` (IANA provisional URI scheme) | A pasted `webcal://` address is read as `https://`. |
| Unicode CLDR `windowsZones` | Windows time zone names (as Outlook and Exchange write them) mapped to IANA zones. |

## Contacts

| Spec | What Outwright does |
|---|---|
| RFC 6352 | CardDAV: sync-collection, else the CalendarServer `getctag` and ETags. |
| RFC 6350, RFC 2426 | vCard 4.0 and 3.0, read and written in the version they came in. |
| RFC 6868 | Caret escapes in parameter values. |

## Push

| Spec | What Outwright does |
|---|---|
| RFC 8620 › 7.2, RFC 8621 | JMAP push subscriptions of type `EmailDelivery`, through Outwright's push relay. The session comes from `/.well-known/jmap`. |
| RFC 8291, RFC 8188 | Web Push message encryption (`aes128gcm`), decrypted on the phone. |

## Setup file

The file that carries the owner's accounts and keys between devices, and the direct transfer between two devices at hand ([SETUP_FILE.md](SETUP_FILE.md)).

| Spec | What Outwright does |
|---|---|
| RFC 9580 | The file is one OpenPGP message encrypted with a passphrase: a version 6 SKESK packet (§5.3.2) and a version 2 SEIPD packet (§5.13.2), AES-256 with GCM, holding a Literal Data packet. Keys inside it are armored transferable keys (§6, §10). |
| RFC 9106 | Argon2id, the string-to-key of the SKESK packet (3 passes, 4 lanes, 64 MiB; a file's own parameters are read, within limits). |
| RFC 7693 | BLAKE2b, which Argon2 is built on. |
| RFC 5869 | HKDF with SHA-256: the key that wraps the session key, and the message keys. |
| Noise Protocol Framework, revision 34 | The direct transfer: `Noise_NNpsk0_25519_ChaChaPoly_SHA256`, keyed by the secret in the pairing code, with the code as its prologue. |
| RFC 7748 | X25519, the Noise handshake's key agreement. |
| RFC 8439 | ChaCha20-Poly1305, which seals each message of the direct transfer. |
| RFC 2104 | HMAC (with SHA-256), inside the Noise handshake's HKDF. |
| RFC 6763 | DNS-SD: the device that shows the pairing code advertises `_outwright-setup._tcp` under the code's service name, and the scanning device browses for it. |
| RFC 4648 | Base64, for a part's content inside the bundle. |
| EFF large word list | The six-word passphrase is chosen from it (CC BY 3.0 US, see `ATTRIBUTION.md`). |

## Not yet

- Microsoft 365 and Outlook.com: OAuth 2.0 sign-in (RFC 6749, 7636, 8252), Microsoft Graph,
  and XOAUTH2 for IMAP and SMTP.
- Tasks (VTODO).

## Deliberately not supported

- **POP3 (RFC 1939), for security reasons.** It downloads mail to the phone, usually removing
  it from the server, so a lost or stolen phone takes the only copy with it. Its sign-in
  sends the password itself (USER/PASS) or rests on APOP's broken MD5, and nothing on the server stays in
  step with what was read, moved or deleted. Outwright uses IMAP instead, which keeps the mail on
  the server. A server or a discovery answer that offers POP3 is not followed.
- **Other sign-in methods and servers that need no sign-in.** The password goes only inside
  TLS, so IMAP LOGIN and SMTP AUTH PLAIN or LOGIN are all Outwright uses; no AUTHENTICATE,
  CRAM-MD5 or SCRAM, and no SMTP relay without AUTH. Certificates must be trusted by the
  iPhone.
- **IMAP4rev2-only servers (RFC 9051).** IMAP4rev1 is required.
