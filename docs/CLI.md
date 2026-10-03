# The `keel` command line

`keel` talks to Keel's agent server: the MCP endpoint the browser runs on
`http://127.0.0.1:9333/mcp` when **Settings → Agents & permissions → Allow
agent connections** is on. It pairs with the browser, bridges stdio MCP
clients (Claude Code, Cursor, Codex) to it, and replays recorded agent
sessions.

It is Foundation-only and lives in `Sources/KeelCLI`; the protocol logic it
relies on (line framing, session handling, replay plans) is in
`Sources/AgentKit/MCPClientCore.swift` and is checked by
`swift run AgentKitChecks`.

## Installing

The release DMG ships the tool inside the app at
`Keel.app/Contents/Helpers/keel`. Put it on your PATH with:

```sh
scripts/install-cli.sh              # links the installed app's keel, else builds this checkout's
scripts/install-cli.sh --dev        # always this checkout's debug build
scripts/install-cli.sh --app /path/to/Keel.app
scripts/install-cli.sh --uninstall
```

The link goes to `/usr/local/bin/keel` when that directory is writable,
otherwise `~/.local/bin/keel` (set `KEEL_BIN_DIR` to choose). Without
installing, run it from a checkout with `swift run keel-cli <command>`.

> The SwiftPM product is called `keel-cli`, not `keel`: on a
> case-insensitive disk (the macOS default) `keel` and the app's `Keel`
> would be the same file, both in `.build/` and in `Contents/MacOS/`. That is
> also why the bundled copy lives in `Contents/Helpers/`.

## Pairing

Every client gets a token of its own, approved by you in Keel.

```sh
keel pair [--name <name>] [--port <port>]
```

1. `keel` sends `POST /pair` with its name, version and process id.
2. Keel shows a pairing request naming the client and its process id, with a
   six-digit code. `keel` prints the same name and pid:

   ```
   Waiting for you to approve “keel” in Keel… (pid 41230)
   ```

   Check they match, then approve. The request waits up to five minutes.
3. The token is stored in the login Keychain as a generic password (service
   **Keel CLI token**, account **127.0.0.1:<port>**). If the Keychain cannot
   be used, it goes to `~/Library/Application Support/Keel/cli-token`
   (mode 0600) instead.

`keel unpair` deletes the stored token. The client stays listed in Keel until
you revoke it there (Settings → Agents & permissions).

If Keel is not running, `keel` starts it (`open -b
dev.simplebrowser.SimpleBrowser`, then `open -a Keel`) and waits up to 15
seconds for the server. If the app runs but nothing answers, it tells you to
turn on agent connections.

## Commands

### `keel mcp [--port <port>]`

The stdio launcher. It reads newline-delimited JSON-RPC messages from stdin,
forwards each to `POST /mcp` with the stored token and the session id, and
writes each reply as one line to stdout, flushed per line. Notifications the
server accepts (HTTP 202) produce no output. Batches go through as batches.

- **No token, or a refused token (401):** runs the pairing flow first. All
  messages go to stderr; stdout carries only JSON-RPC. The request is named
  after the MCP client, for example “keel mcp · claude-code”.
- **Session lost (404, error -32001)**, for example after Keel restarted:
  `keel mcp` initializes a new session with the client's original
  `initialize` params, then resends the message. The client does not notice.
- **Keel not running:** starts it and retries for about 15 seconds.
- **Server off:** each request gets a JSON-RPC error (code -32002) saying
  “Turn on Keel → Settings → Agents & permissions → Allow agent
  connections”. A later request tries again.
- **stdin closes:** waits for requests still in flight, sends
  `DELETE /mcp` for the session, and exits.

Pairing can take longer than a client's start-up timeout, so run `keel pair`
once before you add Keel to a client.

### `keel status [--port <port>]`

Whether the server answers, its tool schema version (and a warning when its
major version differs from this `keel`'s), whether a token is stored and
where, and whether the server accepts it: it initializes a session, calls
`tools/list` and prints the tool count. Exit code 0 when everything works, 69
when the server is unreachable, 77 when the token is refused.

### `keel schema [--out <file>] [--port <port>]`

Prints the published tool schema (`GET /schema`) as pretty JSON: every tool,
its input schema, the error codes and the stability promise under one
`toolSchemaVersion`. When Keel is not reachable it prints the schema built
into this `keel` and says so on stderr. `--out` writes it to a file.

### `keel replay <file.json> [--dry-run] [--keep-going] [--port <port>]`

Runs a session exported from Keel's Agent panel again. The file is a replay
export:

```json
{"keelReplay": 1, "client": "Claude Code", "steps": [
  {"tool": "click", "arguments": {"ref": "e14"}, "summary": "Clicked Save", "url": "https://example.com/form"}
]}
```

Only calls that acted and succeeded are in it; reads, refusals and tab ids are
left out. `keel replay` opens its own MCP session, then opens a tab with
`new_tab` at the first step's URL unless the first step is `navigate` or
`new_tab`, and calls each step's tool in order:

```
Replay of 3 steps by Claude Code
✔ 1. new_tab: Opened tab 21dc5dfa. Later tools act on it.
✔ 2. click: Clicked Save.
✘ 3. fill: No element e15 on the page
Stopped at step 3. Pass --keep-going to run the rest anyway.
```

It stops at the first failure unless you pass `--keep-going`, and exits 1 if
any step failed. `--dry-run` lists the calls without connecting. Element refs
(`e14`) come from the recorded page; if the page has changed, the steps that
use them fail.

### `keel events [--after <id>] [--follow] [--port <port>]`

Prints your client's session events through the `session_events` tool: tool
calls, approvals, denials, blocked navigations, the person taking over. Keel
keeps one session per paired client, so this shows what `keel mcp` (and the
agent behind it) did with the same token. `--after <id>` starts after an event
id; `--follow` keeps polling every second.

### `keel unpair`, `keel --version`, `keel help`

`unpair` deletes the stored token for the port. `--version` prints the
version and the tool schema version it was built with.

## Environment

| Variable | Effect |
| --- | --- |
| `KEEL_PORT` | Port of the agent server. Default: the port set in Keel's settings, else 9333. `--port` overrides it. |
| `KEEL_TOKEN` | Use this token instead of the stored one. For scripts, CI, or an app started with `--mcp-token`. |

For a scripted run against a throwaway app instance:

```sh
.build/debug/Keel --quiet --mcp-port 9411 --mcp-token test123 about:blank &
KEEL_TOKEN=test123 KEEL_PORT=9411 keel status
```

## Setting up clients

Pair once, then add Keel as a stdio server.

**Claude Code**

```sh
keel pair
claude mcp add keel -- keel mcp
```

With a non-default port: `claude mcp add keel -- keel mcp --port 9444`.

**Cursor** (`~/.cursor/mcp.json`) and other clients that take `mcpServers`:

```json
{
  "mcpServers": {
    "keel": { "command": "keel", "args": ["mcp"] }
  }
}
```

If the client does not inherit your shell's PATH, use the full path, for
example `/usr/local/bin/keel` or
`/Applications/Keel.app/Contents/Helpers/keel`.

**Codex** (`~/.codex/config.toml`):

```toml
[mcp_servers.keel]
command = "keel"
args = ["mcp"]
```

Clients that speak Streamable HTTP can also connect directly to
`http://127.0.0.1:9333/mcp` with an `Authorization: Bearer <token>` header;
the stdio launcher saves you from putting the token in a config file.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | A replay step or request failed |
| 64 | Usage error |
| 69 | Keel or its agent server is not reachable |
| 77 | Not paired, or the token was refused |
