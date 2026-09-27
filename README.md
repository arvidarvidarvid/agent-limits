# Agent Limits

A macOS menu bar app that shows how much of your AI subscription rate limits you
have left. It reads the usage endpoints that the Claude Code and Codex CLIs use,
reusing the OAuth tokens those tools already store on your machine. No API keys,
no new secrets.

## What it shows

- **Claude**: session and weekly windows, same numbers as `/usage`.
- **Codex** (`codex` CLI, from `~/.codex/auth.json`): the rate-limit windows and
  spend cap, same numbers as `/status`.

## Claude token

The usage endpoint needs a `user:profile`-scoped token. That scope lives only on
the subscription-login OAuth blob, not on a `claude setup-token` token (which is
`user:inference` only and gets rejected), so `setup-token` is not used.

The app finds that blob among the places Claude Code stores it, and there can be
several: keychain service `Claude Code-credentials` keyed by both unix username
and email, plus service `Claude Code` and `~/.claude/.credentials.json`. It reads
all of them and keeps the freshest by `expiresAt`. The access token is renewed
against `https://platform.claude.com/v1/oauth/token` (client id
`9d1c250a-…`), which is Cloudflare-fronted and rejects default HTTP-client and
browser User-Agents, so every request sends `User-Agent: agent-limits/0.1`. The
renewed access and refresh tokens are cached in
`~/.config/agent-limits/config.json` (chmod 600) and rotated as they expire.

Codex needs no config; it reads `~/.codex/auth.json` directly.

### Durability caveat (native Claude Code build)

The native (Mach-O) Claude Code build keeps its *live* token in a store this app
cannot read; the keychain `Claude Code-credentials` entries are older logins left
behind. The app latches onto the freshest of those and keeps its refresh-token
chain alive in the config file. That works as long as the app refreshes before
the chain lapses. If it ever breaks (config deleted, a refresh fails past the
refresh token's own expiry, or a fresh `claude` login rotates things), reseed
with `scripts/claude_refresh.sh`. If even that returns `invalid_grant`, the
orphaned refresh token has died and there is currently no readable live token to
seed from.

The menu bar title stays compact (one peak percentage per provider); the dropdown
shows each window with a bar, a percentage, and when it resets.

## Build and run

```sh
make run        # build the .app and launch it from build/ (quick iteration)
make install    # build, copy to /Applications, re-sign, and relaunch it
make build      # just assemble build/AgentLimits.app
make clean      # remove .build and build
```

`make install` is the one to use after any change once the app lives in
`/Applications`: it rebuilds, replaces the installed copy, re-signs it (ad-hoc),
and relaunches. For a pure code loop you can also `swift run`.

On first launch macOS asks for permission to read the Claude token from your
login keychain. Click **Always Allow**.

## Command line

The `agent-limits` CLI prints the same numbers in the terminal. It shares the
app's credentials and token cache (`~/.config/agent-limits/config.json`), so a
token either one renews is picked up by the other; refreshes are serialized
across processes with a lock file next to the config.

```sh
make install-cli                  # installs to ~/.local/bin (override with BIN_DIR=...)
agent-limits                      # both providers, as a table
agent-limits claude               # just one provider
agent-limits --json               # machine-readable, for scripts and status lines
```

### Caching and rate limits

The usage endpoints rate-limit hard (HTTP 429), and an agent calling the CLI in
a loop hits that quickly. So every fetch goes through a per-provider cache in
`~/Library/Caches/agent-limits/`, shared by the app and all CLI calls:

- A response younger than 60 s is reused without a request (`--fresh` in the
  CLI and **Refresh now** in the app skip this).
- A lock file per provider makes concurrent callers wait for one request and
  reuse its result.
- On a 429, the `Retry-After` delay (or an exponential backoff from 60 s up to
  30 min) is recorded, and until it passes nobody calls the endpoint; callers
  get the last good data with a "Rate limited, retrying in …" note.

It exits with status 1 if any requested provider failed to load. Color is used
only on a terminal and can be turned off with `NO_COLOR=1`. The CLI is a
separate binary, so the first time it needs the keychain macOS asks again.

## Verifying the API shapes

The two providers occasionally change their JSON. If a provider shows "no active
limits" when it shouldn't, dump the live responses and compare field names:

```sh
scripts/probe.sh
```

Then adjust the key names in `Sources/AgentLimitsCore/Decoders.swift` to match. The
decoders walk the JSON loosely, so only the top-level window keys and the
`utilization` / `used_percent` / reset fields need to line up.

## Launch at login

`make install` puts the app in `/Applications`. Tick **Launch at Login** in the
app's menu once so it starts automatically (it registers itself as a login item
via `SMAppService`, and shows up under `System Settings → General → Login
Items`, where it can also be switched off). After that, `make install` keeps the
installed copy up to date on each change.

## Layout

`AgentLimitsCore` is a library shared by the app and the CLI:

- `Sources/AgentLimitsCore/Credentials.swift` reads the keychain and `auth.json`.
- `Sources/AgentLimitsCore/ClaudeAuth.swift` refreshes the Claude token when stale.
- `Sources/AgentLimitsCore/Usage.swift` fetches both endpoints and normalizes results.
- `Sources/AgentLimitsCore/Decoders.swift` maps each provider's JSON to windows.
- `Sources/AgentLimitsCore/Config.swift` reads and writes `~/.config/agent-limits/config.json`.
- `Sources/AgentLimitsCore/Format.swift` has the text bar and reset-time helpers.

Front ends:

- `Sources/AgentLimits/AppDelegate.swift` builds the `NSStatusItem` menu.
- `Sources/AgentLimits/Logos.swift` draws the provider marks as vectors.
- `Sources/AgentLimitsCLI/main.swift` is the `agent-limits` command.
- `Makefile` has the `build` / `run` / `install` / `install-cli` / `clean` targets.
- `scripts/build_app.sh` wraps the binary into a menu-bar-only `.app`.
- `scripts/probe.sh` dumps the raw usage JSON for verifying field names.
- `scripts/claude_refresh.sh` seeds the Claude token chain from the keychain.

## Adding another provider

Add a fetcher in `Usage.swift` and a decoder in `Decoders.swift` that returns a
`ProviderUsage`, then include it in `Usage.fetchAll()`. The menu renders whatever
providers that returns; to expose it in the CLI, add its name to the argument
parsing in `Sources/AgentLimitsCLI/main.swift`.
