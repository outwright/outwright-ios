# Release notes

## 0.2.1 (2026-11-19)

- Bringing your setup to another device brings your accounts, keys and signatures but not the app's settings, asks about each difference on its own, and remembers your answers for the next time.
- Search on the server also looks in folders you haven't opened yet, such as Sent right after adding an account.

## 0.2.0 (2026-11-18)

Across the app:
- Add Microsoft 365 and Outlook.com accounts, with mail, calendar and contacts.
- Send and read OpenPGP-encrypted and signed mail, with Proton Mail users and anyone else with a key.
- Outwright runs on iPad, with folders, the message list and the message side by side.
- Every tab has the account avatar, and the drawer follows the tab: folders on Mail, calendars on Calendar, address books on Contacts.
- A problem with an account shows on its avatar, in the drawer, in Settings and on every tab.
- A new account's notifications are on, and the Do Not Disturb bell silences them.
- The app icon shows how many unread messages are in your Inboxes (Focused only while Focused Inbox is on).
- Send diagnostics now says what went wrong for each account (sync, sending and push), and the mail says plainly that it holds no private information, no mail and no details of any account.
- One look for titles, section headers, sheet buttons and colours, and more of the app follows the text size.
- First run, adding an account and Settings work as in Outlook.
- Back up your accounts and OpenPGP keys, or move them to another device, as an encrypted file.
- Move your setup to another device by scanning a code, no file or passphrase needed.
- In dark mode, a message that sets its own colours is shown in dark colours too, and the sun button shows it as written.
- Restoring a setup, from a file or from another device, asks before it replaces a password, your OpenPGP key or settings that differ on this device.
- Push through your own program is "Push for a server without push", under an account's Notifications switch while push from the server is not on.

Mail:
- A new-mail notification now shows the right message, and tapping it opens that message.
- Undo after moving or deleting, multi-select with bulk actions, and clearer unread rows.
- The reading view hides the tab bar, wraps the subject and shows the message at once.
- Search groups its results and shows messages as the inbox does.
- A reply or new message starts writing at the top, above the signature.
- Compose asks before discarding, warns before Send stops, wraps recipients, keeps the original when forwarding, and attaches photos and camera shots.

Calendar:
- Jump to any date, scroll the agenda both ways, and create an event by tapping a time.
- Event details join online meetings and open people; the editor has show as, private and custom repeat.

Contacts:
- A contact whose phone number has no label can be saved again; the Microsoft limits warning no longer shows for your own server's address books.
- A contact opens as a page, its buttons work in two panes, and its card lists events.
- Job title and photo for Microsoft contacts, and a read-only address book says why.

## 0.1.5 (2026-11-16)

Features:
- Push for any IMAP server through your own push worker: "Use your own push worker" on every IMAP account.

- Bug fixes and improvements

## 0.1.4 (2026-11-16)

- Bug fixes and improvements

## 0.1.3 (2026-11-16)

Features:
- New-mail notifications for every account, when iOS lets the app check (may be late or missed).
- Background refresh switch in Settings.
- Bug fixes and improvements

## 0.1.1 (2026-11-13)

- Landscape view.
- Bug fixes and improvements

## 0.1.0 (2026-11-12)

Features:
- Dovecot support.
- General IMAP support.
- Basic Microsoft support.
- Subscribed calendars from a published ICS link.
- Send diagnostics.

Improvements:
- Addresses with non-ASCII characters are sent with SMTPUTF8.
- An organiser's update or cancellation by mail reaches the calendar on the server at once.
- Invitation answers reach the organiser as RFC 6638 says.
- A folder learns of mail moved away elsewhere on servers that answer QRESYNC before [CLOSED].
- Various bug fixes and improvements

