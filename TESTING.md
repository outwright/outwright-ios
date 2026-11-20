# Testing

## What is here

- **Unit tests** in `Tests/`, one target per module, run with `make test`.
- **Fake servers** in `Sources/OutwrightFakes`: IMAP, SMTP, CalDAV, CardDAV, JMAP and the push
  relay, in process on loopback. The tests talk to them over real connections, with
  synthetic mail on `example.org` addresses. No test ever touches a real mailbox.
- **Property tests:** readers of outside data are fed arbitrary bytes and must never crash.
- **Lint:** SwiftLint, strict, enforces the rules in [AGENTS.md](AGENTS.md),
  including no traps and no web view outside the reading pane.

`make test` builds everything, the iOS app included, and runs all of it; run it before you open
a pull request.

## The engine

The engine in Go (`engine/`: the daemon `outwrightd` and the `outwright` command and MCP server)
has tests of its own, which `make test` runs (`make engine-test`, then `make engine-cross`):

- **Unit tests** beside each package, with `go test`.
- **Fake servers** in `engine/fakes`: IMAP, SMTP, CalDAV and CardDAV, Graph and OAuth, in process
  on loopback, with synthetic mail on `example.org` addresses, as for the app.
- **Fuzz tests:** every reader of outside data is fed arbitrary bytes and must never panic.
- **The layering:** `engine/arch_test.go` fails on a package that imports one it may not.
- **The MCP server:** a golden file over every tool's schema, and the MCP specification's cases.
- **The clients end to end:** the CLI and the MCP server against a daemon run on the fakes.
- **gofmt**, and a vet of every portable package for Linux and Windows.

## What runs on a pull request

Nothing runs on GitHub. When the maintainer brings a pull request home, it runs `make test`
and the integration tests below before it lands.

## What the maintainer runs

Beyond these, the maintainer keeps integration tests that drive the app in the iOS simulator
against real IMAP, SMTP, CalDAV, CardDAV and JMAP servers (Stalwart and Dovecot) in local
containers, and the daemon the same way, through its command and its MCP server. They are not published. Every change, and every pull request before it lands,
passes them. When one fails on your pull request, the maintainer tells you what failed and how
to reproduce it with the fakes, or fixes it on the way in.
