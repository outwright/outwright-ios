# The setup file

A setup file carries the owner's accounts, their passwords and sign-in tokens, their subscribed
calendars and their keys from one device to another. How the app is set up (its settings) stays
on each device. It is made by the owner on purpose, from
the app's settings, and it is encrypted with a passphrase the app shows once when the file is
made. This page describes the format, so the owner can always get their keys out of it with
other software, and so another app can read or write the file. The last section describes the
other way to move a setup, straight from one device to another with nothing in between, so
another app can take part in that too.

## What it is

The file is one OpenPGP message (RFC 9580), binary, no ASCII armor. It holds a JSON document,
the bundle, encrypted with a passphrase. Nothing in the file is readable without the
passphrase: not the accounts, not the device name, not even how many parts it has.

Secrets are in the bundle. The accounts part holds each account's password or refresh token,
the subscriptions part holds each calendar's address (which often contains a token), and the
openpgp part holds the secret keys. They are protected by the file's encryption and by
nothing else, so the file is as secret as the passphrase and the place it is kept. The app
never stores access tokens, and none is in the file.

The file has its own type: the identifier `app.outwright.setup`, conforming to `public.data`,
with the file name extension `outwright-setup`.

## The passphrase

Six words from the EFF large word list (7 776 words), chosen at random, about 77 bits. The four
hyphenated words of the list (`drop-down`, `felt-tip`, `t-shirt`, `yo-yo`) are never chosen,
because the hyphen separates the words. The passphrase is written as the words in lower case
joined by single hyphens, for example `abacus-abdomen-abdominal-abide-abiding-ability`, and
those UTF-8 bytes are the passphrase the encryption uses. When reading, the app accepts any
case and spaces or hyphens between the words, and refuses a word that is not on the list. Another
reader should pass the hyphen-joined form to the OpenPGP software.

## The encryption

Two packets, in this order, with OpenPGP-format headers (RFC 9580 section 4):

1. A version 6 Symmetric Key Encrypted Session Key packet (type 3, section 5.3.2).
   - Symmetric algorithm AES-256, AEAD mode GCM.
   - String-to-key: Argon2 (section 3.7.1.4, RFC 9106, Argon2id), a random 16-octet salt,
     3 passes, 4 lanes, memory 2^16 KiB (64 MiB). The three numbers are in the packet, so a
     reader uses whatever the file says. The app's reader refuses more than 10 passes, 8
     lanes or 2^18 KiB (256 MiB).
   - The session key is a random 32-octet value, wrapped as the section describes: the
     Argon2 output is the input to HKDF (SHA-256), the result encrypts the session key with
     AES-256-GCM.
2. A version 2 Symmetrically Encrypted and Integrity Protected Data packet (type 18,
   section 5.13.2).
   - AES-256, GCM, chunk size octet 16 (chunks of 4 MiB), a random 32-octet salt.
   - The plaintext is one Literal Data packet (type 11): binary format `b`, empty file name,
     zero date, and the bundle's JSON as its data.

The app writes exactly this. When reading it also takes AES-128 and AES-192, the iterated and
salted S2K (SHA-256, SHA-384 or SHA-512) in place of Argon2, and a message padded with
Padding packets (section 5.14). It does not take other AEAD modes, version 4 SKESK packets,
version 1 SEIPD packets, more than one SKESK packet, compressed data, public-key encrypted
messages or signatures; a file like that is reported as one this version cannot read. The
largest file is 16 MiB.

## Opening a file with other software

These are version 6 packets, which not everything reads.

- **GnuPG cannot read the file.** It does not read version 6 packets.
- ProtonMail's go-crypto (`github.com/ProtonMail/go-crypto/openpgp/v2`) was tested against a
  real file made by the app, and opens it.
- Sequoia (`sq decrypt`), GopenPGP version 3 and OpenPGP.js implement version 6 SKESK and
  version 2 SEIPD packets from RFC 9580, so they are expected to read it, but this has not
  been tested. With `sq`, the passphrase is the hyphen-joined words; whether its password
  file wants a trailing newline is unconfirmed.

The result is the bundle's JSON, below. A file made by the app was opened with go-crypto
this way: read the message with a password prompt that returns the passphrase bytes, and read
`UnverifiedBody`. There is no signature to verify; the message is authenticated by the AEAD.

## The bundle

A JSON object, written with sorted keys:

| Field | Type | Meaning |
|---|---|---|
| `version` | number | The bundle's format version, 1. A reader refuses a larger one. |
| `created` | string | When the file was made, RFC 3339 (`2026-11-17T08:00:00Z`). The app writes whole seconds in UTC, and reads fractional seconds and an offset too. |
| `device` | string | The name of the device that made it. |
| `parts` | object | The parts, by name: at most 64. |

Each part is an object `{"version": 1, "title": "Accounts", "content": "<base64>"}`.
`content` is the part's own JSON document, UTF-8, encoded in standard base64 (RFC 4648
section 4), at most 8 MiB before encoding. `version` is the part's own format version; a
reader that does not know a part's version, or its name, leaves it alone and says so.
`title` is the part's name for the owner, in the language of the device that wrote it; a
reader shows it for a part it leaves alone. It is optional: a reader uses the part's name in
its place when it is missing, empty, longer than 256 UTF-8 octets or holds a control or
format character, and a word of its own when the name is empty or holds one too.

Parts are independent. A part whose content cannot be read (its JSON does not decode as this
page describes, such as a field of the wrong type where the part's section below does not say
otherwise, or it is over a limit) is listed as one that cannot be read and left out, and the
other parts are restored.

The parts the app writes are `accounts`, `subscriptions`, `openpgp` and `smime`. Each
one a build carries is written every time, with empty lists when there is nothing in it. Files
made by earlier versions may hold a `settings` part with the app's settings: it is no longer
read, and passed over without a word.

Restoring adds what the receiving device does not have and leaves what it has as it is. One
thing is filled in: a device restored from an iCloud or Finder backup of a phone has its
accounts, calendars and keys but not their secrets, which stay in the old phone's keychain.
When an item is already there without its secret, the secret is taken from the file and
nothing else about the item changes. Each part below says when an item counts as already
there.

Some of what is already there can differ from the file: an account's password or sign-in, its
servers, its signature, the current own key for an address. The app asks the owner about each,
one at a time, before it restores anything; the device's stays unless the owner chooses the
file's. Each part below says what it asks about. The owner may also leave an account off the
device: nothing of it is added (its own keys, certificates and settings neither), and one already
there is left as it is.

A setup is brought more than once to keep devices alike, so the app remembers, in the keychain,
what the owner kept and which accounts they left off. A difference the owner kept is not asked
again until either side of it changes; an account left off stays off until they switch it on.
Nothing is ever removed from the receiving device.

## The accounts part

```json
{"accounts": [
  {
    "account": {
      "id": {"raw": "11111111-2222-3333-4444-555555555555"},
      "displayName": "Sam", "email": "sam@example.org", "user": "sam@example.org",
      "colorIndex": 1, "sortOrder": 0, "signature": "",
      "imap": {"host": "imap.example.org", "port": 993, "security": "tls"},
      "smtp": {"host": "smtp.example.org", "port": 465, "security": "tls"},
      "auth": "password", "provider": "own-server",
      "calendarVia": "calDAV", "contactsVia": "cardDAV",
      "calDAVOff": false, "cardDAVOff": false, "savesContactsToPhone": false
    },
    "password": "the password",
    "notifies": true
  }
]}
```

An entry is the account as the app keeps it, plus its secret:

- `account`: `id` (an object holding the account's UUID as `raw`), `displayName`, `email`,
  `user` (the sign-in name), `colorIndex`, `sortOrder`, `signature`, `imap` and `smtp` (each
  `host`, `port`, `security`), `auth`, `provider`, `calendarVia` (`calDAV` or `graph`),
  `contactsVia` (`cardDAV` or `graph`), `calDAVOff`, `cardDAVOff`, `savesContactsToPhone`.
  When set, also `calDAV`, `calDAVUnconfirmed`, `cardDAV` and `cardDAVUnconfirmed` (addresses).
- `auth` is `password` or `oauth`. `provider` names who the account is with (`own-server`
  for the owner's own server); a provider the receiving app does not carry is skipped.
- `password`: the account's password, for `auth` `password`.
- `refreshToken` and `clientID`: for `auth` `oauth`, the refresh token and the client id it
  was issued to. A receiving app that signs in with another client id cannot use the token
  and asks the owner to sign in again.
- `notifies`: whether the owner's Notifications switch was on.

At most 1 024 entries, and no secret longer than 16 384 octets. An account with the same
`id` as one on the receiving device is already there: its password or refresh token is filled
in when the device has none (a refresh token only under the same client id), and nothing else
changes. Another account with the same `email` is already there too. When an account here with
the same `email` (and the same provider and kind of sign-in) has another password than the file,
the owner is asked, and the file's replaces it only when they choose so. A refresh token rotates
as it is used, so another one than the file's is no difference by itself: the owner is asked
about it only when the device's sign-in for the account does not work (the server refused it, or
it needs signing in again). When its servers or user name (`imap`, `smtp`, `user`) differ from
the file's, the owner is asked too, and only those three change when they take the file's; a host
name is compared in any case, a user name as typed.

The app's default signature ("Sent from Outwright for iOS", in any language it shipped in) is
each device's own: an account that comes with it gets the receiving device's default, and it
never replaces a signature there. A signature the owner wrote, an empty one included, comes
along: an account added gets it, and an account here with the default takes it. When both are
the owner's and differ, the owner is asked.

## The subscriptions part

```json
{"calendars": [
  {"key": "6F1D3C0E-8B2A-4D7E-9A51-2C4B7E0F1A33", "name": "Holidays", "color": 3368601,
   "address": "https://example.org/holidays.ics?token=..."}
]}
```

One entry for each subscribed calendar (a published calendar read-only): `key` (a UUID),
`name`, `color` (a number, 0xRRGGBB) and `address`, the URL it is fetched from, which is a
secret. At most 1 024 entries. A calendar with the same `key` is already there: its address
is filled in when the device has none, and its name and colour stay as the device has them.
A calendar with the same address is already there too.

## The openpgp part

This part is what lets the owner take their keys elsewhere. Keys are ordinary OpenPGP
transferable keys (RFC 9580 section 10), ASCII-armored (section 6), so any OpenPGP software
can use them once they are out of the JSON.

```json
{
  "ownKeys": [
    {"address": "sam@example.org", "fingerprint": "<hex>", "standing": "current",
     "published": "<where>", "secretKey": "-----BEGIN PGP PRIVATE KEY BLOCK-----\n..."}
  ],
  "contactKeys": [
    {"address": "kim@example.org", "fingerprint": "<hex>", "key": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...",
     "trust": "verified", "current": true, "rejected": false,
     "source": "wkd", "learnedFrom": "<message-id@example.org>"}
  ],
  "accountSettings": [{"account": "sam@example.org", "enabled": true}],
  "accountDefaults": [{"account": "sam@example.org", "sign": true}]
}
```

- `ownKeys`: the owner's own keys, one entry for each key whose secret is on the device.
  `secretKey` is the armored transferable secret key, exactly as stored, and it is the
  part's one secret. `fingerprint` is 40 hex digits (version 4) or 64 (version 6), in either case.
  `standing` is `current` (the key in use for the address) or `retired`. `published` is an
  optional note of where the public key was published.
- `contactKeys`: other people's keys. `key` is the armored transferable public key and
  `trust` is `unverified` or `verified`; `current` says whether it is the key used for the
  address. `source` is where the key came from (`wkd`, `vks`, `proton`, `autocrypt`,
  `attachment` or `imported`) and `learnedFrom` the Message-ID of the mail it was learned
  from. A key the owner has rejected has `rejected` true and neither `key` nor `trust`.
- `accountSettings`: for each address, whether the owner switched OpenPGP on (`enabled`).
- `accountDefaults`: for each address, what a new message does: `sign` and `encrypt` are
  booleans, and a value that is not there is the default (the app writes no null).

Addresses are lower case. A receiver checks each entry's shape: an address (at most 320
octets, with an `@`, no white space or control characters), a fingerprint as above, a
`standing`, `trust` or armor header this page names, and no field over its limit. It then
checks each key against its bytes: the fingerprint has to match, a secret key has to be a
secret key, and the key needs a user id for the address. An entry that fails either check is
skipped and reported, and the rest of the part is restored. Limits: 1 024 own keys, 8 192
contact keys, 1 024 settings of each kind, 6 MiB for one key; a list over its limit makes the
whole part one that cannot be read. The owner's own keys always come along or the file is
not made; contacts' keys come along while the part stays within 8 MiB.

An own key with the same address and fingerprint as one on the receiving device is already
there: its secret key is filled in when the device has none, and its standing stays as the
device has it. A contact's key the device holds, or has rejected, is already there, and so is
a setting for an address the device has one for. When the file's current key for an address is
another than the device's current one, the owner is asked: the file's key is added either way,
and it becomes the current one (the device's kept, retired) only when the owner chooses so.

To use a key elsewhere, decrypt the file, decode the `openpgp` part's `content` from base64,
and take `secretKey` from an entry of `ownKeys`; it is an armored key as any OpenPGP software
writes it.

## The smime part

The owner's S/MIME setup. Certificates are DER (X.509) and private keys PKCS #8, each in standard
base64, so any S/MIME software can use them once they are out of the JSON.

```json
{
  "own": [{"account": "sam@example.org", "certificate": "<base64 DER>", "key": "<base64 PKCS #8>"}],
  "learned": [{"certificate": "<base64 DER>", "addresses": ["kim@example.org"], "account": "sam@example.org"}],
  "intermediates": ["<base64 DER>"],
  "orgRoots": [{"account": "sam@example.org", "certificate": "<base64 DER>"}],
  "settings": [{"account": "sam@example.org", "isOn": true, "alwaysSign": false,
                "alwaysEncrypt": false, "useForCompose": true}]
}
```

- `own`: the owner's certificates, one entry for each whose private key is on the device, with
  the account's address. `key` is the part's one secret.
- `learned`: other people's certificates, learned from their signed mail. `addresses` are the
  addresses the certificate was learned for, there for the owner's eyes; a reader takes them from
  the certificate itself. `account` is the account it was learned for through that account's
  organisation root; absent, it holds for every account.
- `intermediates`: intermediate certificates kept to build chains.
- `orgRoots`: organisation roots the owner accepted for an account. A reader never trusts one from
  a file: it offers each to the owner for its account, and a learned certificate that chains only
  to an offered root waits for the owner's answer.
- `settings`: for each address, whether S/MIME is on (`isOn`), whether a new message is always
  signed or encrypted, and `useForCompose`, whether writing uses S/MIME when OpenPGP is on too
  (absent: the default, S/MIME on a Microsoft account and OpenPGP on others).

Addresses are lower case. A receiver checks each entry's shape (an address as in the openpgp
part, a certificate or key of at most 512 KiB, at most 16 addresses for a learned certificate),
drops an entry out of shape, and then checks each against its bytes: an own key has to sign as its
certificate's key, and a learned certificate has to chain to a root its account trusts on the
receiving device. An entry that fails is skipped and reported. Limits: 1 024 own certificates,
8 192 learned, 2 048 intermediates, 1 024 organisation roots and 1 024 settings; a list over its
limit makes the whole part one that cannot be read. The owner's own certificates always come
along or the file is not made; learned certificates come along while the part stays within 8 MiB.

An own certificate the receiving account already holds is already there (its key is filled in when
the device has none); one it does not hold is added beside the account's others, so nothing is
asked. A learned certificate the device holds for the address is already there, and so are
settings for an address the device has set. Own certificates are restored whatever the plan, as
the owner had them; the plan decides only what they may be used for.

## Other readers and writers

A reader of the file should treat it as hostile input: check every length against what is
left, cap sizes, and refuse a bundle or a part over the limits above. The bundle's JSON may
come from another program, so a part's `content` is decoded and checked on its own: a part
that does not decode is left out, never the whole file, and in the openpgp part an entry out
of shape is skipped and reported, never the whole part.

## Moving directly

Two devices at hand can move the setup without a file: the one that receives shows a code, the
one that sends scans it, and the setup goes over the local network, encrypted end to end. The
transfer carries the same bundle as the file, in one record. Nothing goes through a server.

Every number below is big-endian unless it says otherwise, and "octet" is a byte.

### The pairing code

The device that shows the code makes it for one transfer. In binary:

| Field | Size | Value |
|---|---|---|
| version | 1 | 1 |
| role | 1 | what the device that shows the code does: 1 receives, 2 sends |
| secret | 32 | random octets, from a secure generator |
| service length | 1 | 12 for a version 1 code |
| service | 12 | the Bonjour instance name, below: 12 characters from `0-9a-f` (6 random octets in hex) |
| device length | 1 | at most 64 |
| device | 0 to 64 | the showing device's name, UTF-8, cut at a character |

The code is at most 112 octets. The text form, which the QR code holds, is `OWSETUP:` followed
by the binary form in base64url (RFC 4648 section 5) without padding. A reader refuses text
over 256 octets, a missing prefix, any character outside `A-Za-z0-9-_`, a length that is 1 more
than a multiple of 4 and a binary form with an octet left over. Version 0, a role other than 1
or 2, a service that is not 12 characters of `0-9a-f`, a length over its cap or text that is not
valid UTF-8 are malformed. A version above 1 is a code from a newer app, and is reported as
that. The device name is hostile: a reader removes control and format characters (Unicode
categories Cc and Cf, bidirectional overrides among them) from it only to show it, and the name
may be empty. The cleaning is for display and nothing else: it never changes the octets the
handshake below uses.

The code lives 5 minutes, or until one device connects: it is for one connection and one
transfer, and a new transfer makes a new code. The secret is only ever in the code, which
travels by the camera.

### Finding the device

The device that shows the code listens on a TCP port of the system's choosing and advertises it
with DNS-SD (RFC 6763), service type `_outwright-setup._tcp`, domain `local`, and the code's
service as the instance name. The device that scans browses for that type and connects to the
instance whose name is the code's service, waiting at most 30 seconds. Both ask for peer-to-peer
links where the system has them. The TCP stream carries no TLS: the Noise session below is what
protects it.

The listener takes the first connection and then stops listening and advertising; a second
connection is dropped. A device that connects and does not prove it holds the code uses the
code up, and the showing device offers a new one. So does a listener the system ends before a
device connected (iOS does when the app is suspended); a showing device that comes back to the
front from the background shows a new code in place of one still shown or one whose listening
ended before any device connected.

### The handshake

The protocol is `Noise_NNpsk0_25519_ChaChaPoly_SHA256` of the Noise Protocol Framework revision 34:
X25519 (RFC 7748), ChaCha20-Poly1305 (RFC 8439), SHA-256, and HMAC-SHA-256 inside HKDF
(RFC 2104, RFC 5869) as that revision defines them.

- The pre-shared key is the code's 32-octet secret.
- The prologue is exactly the octets the code's text form encodes: the decoded base64url body,
  as the showing device made it and as the scanning device read it. A reader never re-encodes the
  code from its fields, cleans the name or cuts it before it uses them as the prologue.
- The device that scanned the code is the initiator and the one that showed it the responder,
  whatever the role in the code.
- The two messages are `psk, e` (initiator) and `e, ee` (responder), both with empty payloads:
  each is 32 octets of ephemeral public key and a 16-octet tag, 48 octets. On the wire each is
  its length as 2 octets and the message, so `00 30` and 48 octets.

Both sides finish the handshake within 30 seconds of starting it. A message that is not 48
octets long, or does not open, fails the handshake. A responder whose first message is not 48
octets long or does not open answers with the empty frame `00 00` before it closes, so that the
scanning device learns the code did not match and does not wait; the initiator takes any other
length than 48 as the same failure. A timeout or a dropped connection gets no such frame: the
side just closes.

### The transport

After the handshake each side seals what it sends with ChaCha20-Poly1305 under its own
transport key, as the revision describes: the initiator sends with the first key `Split()`
returns and receives with the second, the responder the other way round. The nonce is four zero
octets and the message counter as a 64-bit little-endian integer, counting from 0 in each
direction, and there is no associated data. A message that does not open ends the session. On the
wire each sealed message is its length (the ciphertext with its 16-octet tag, at most 65 535) as
2 octets, then the ciphertext, so a message carries at most 65 519 octets of plaintext.

### The records

Everything after the handshake is a record. A record is its header in one message and its
payload in the messages after it:

- The header is exactly 5 octets: the type (1 octet) and the payload's length (4 octets).
- The payload follows in messages of 1 to 65 519 octets that add up to the length exactly;
  a sender fills each message but the last. A zero-length payload has no message of its own.

| Type | Name | Payload | Longest payload |
|---|---|---|---|
| 1 | `hello` | JSON `{"device": "<name>"}` | 4 096 octets |
| 2 | `bundle` | the bundle's JSON, as in the file | 16 MiB (16 777 216 octets) |
| 3 | `done` | JSON `{"restored": true}` | 4 096 octets |
| 4 | `stop` | none | 0 |

A reader checks the header before it reads any payload: an unknown type or a length over its
type's longest is a failure. A `stop` record at any point ends the transfer as one the other
owner cancelled, whatever record was expected; any other type than the expected one is a
failure, and so is a payload message that is empty or longer than what is left of the length. A
payload that is not the JSON above (a field of the wrong type, or missing) is a failure. Other
fields in a record's JSON are ignored. The writer of `hello` cuts the name to 64 octets at a character boundary. The `hello` device name is a name for the owner to see and
is hostile in the way the code's is: a reader removes control and format characters, cuts it to 64 octets,
and it may be empty. The `bundle` payload is the JSON of the bundle exactly as written in the file,
with the same limits, and the receiver treats it as hostile in the same way: a part that cannot
be read is left out and the others are restored, one that does not decode as a bundle is a
failure. A bundle whose `version` is above what the receiver reads comes from a newer app: the
receiver restores nothing, sends `stop` and asks its owner to update.

### The order

The receiving device sends `hello` and the sending device sends `bundle` whichever of them
showed the code.

1. The receiver shows the code, listens and advertises it.
2. The sender scans the code, finds the receiver and connects.
3. They handshake: the scanner initiates and the device showing the code responds.
4. The receiver sends `hello` with its device name.
5. The sender shows the receiver's name and what it would send, and from then on waits for the
   receiver's next record, so a `stop` or a dropped connection ends the transfer while the
   confirmation is up, before anything is unlocked or made. When the owner confirms, and after
   the sender has asked the owner to unlock the device, it sends `bundle`.
6. The receiver restores what it got, as the file's rules say, and sends `done`. When the receiving
   device already has something that differs from the bundle (a password, the current own key),
   it first asks its owner which to keep, as a file's restore does, and restores nothing
   until the owner answers; the sender's wait for `done` (300 seconds, below) is the time the owner
   has. If the sender stops or the connection drops before the answer, the receiver restores
   nothing. Apart from that question, it sends `done` before it does anything that waits for the
   owner, such as asking for access to Contacts or for permission to notify, so the sender is not
   held up. `restored` is true: a receiver that got a bundle always restored what it could, and the
   sender takes no other action on the value.
7. The sender closes the session once it has read `done`; the receiver closes after sending it.

Each wait for a record, and each write, takes at most 300 seconds; the sender's wait for `done`,
which begins at the confirmation, is timed from when `bundle` went. The receiver's wait for its
owner's answer about differences has no time of its own: the sender's wait for `done` bounds it. Before step 4 the receiver
waits at most the code's 5 minutes for a connection (step 2) and 30 seconds for the handshake.

### Failure

There is no resuming. Any failure (a timeout, a record out of order, a message that does not
open, a connection that drops) closes the connection on that side and ends the transfer, and a
new transfer starts from a new code. A side that ends a transfer on purpose, because its owner
cancelled, because the sender cannot make the bundle or because the receiver got a bundle from a
newer app, sends `stop` first, gives it up to 2 seconds to go out, and closes. A sender cancelled
while `bundle` is being written just closes. `stop` exists only once the handshake is done: before that, a side
that ends just closes the connection. A receiver whose owner cancels while asked about differences
restores nothing and sends `stop`. A receiver whose restore is already under way finishes it and tells
the sender with `done`; it does not stop.
