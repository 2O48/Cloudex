<div align="center">

<img src="resources/icons/cloudex.png" alt="Cloudex logo" width="120" />

# Cloudex

English | [中文](README-CN.md)

</div>

A local console for controlling Codex from your phone: a lightweight HTTP/SSE service running on your computer, a native iOS client, and an `npx`-distributable CLI. From your phone you can view Codex sessions on your computer, create and resume tasks, watch streaming output in real time, approve command executions, and even browse and review code.

## What it is

Cloudex has two parts:

- **Local control server** (`apps/server`): wraps the Codex CLI and exposes task control, session history, file browsing, and approvals as an HTTP/SSE API consumable from a phone. It relies entirely on the standalone Codex CLI and does not depend on Codex Desktop; on Windows it automatically falls back to driving Codex CLI subprocesses when the app-server control channel is unavailable.
- **Native iOS client** (`apps/ios-native`): a pure SwiftUI implementation with no Expo, React Native, or third-party Swift packages. It connects to the server over LAN or Tailscale and pairs by scanning a QR code.

The access path is `Codex CLI ⇄ local server ⇄ iOS app`. The server runs only on your computer; the phone reaches it over LAN or Tailscale, and all conversation history stays in `~/.codex/sessions` on the computer.

## Key features

**Task control**

- Create, resume (steer), stop, and archive Codex tasks
- Model and reasoning effort selection, with task forking
- SSE live streaming of replies, task status, and errors
- Command execution approvals: allow, deny, or "allow for this session" from the app or a lock-screen notification

**Phone-side development helpers**

- Browse the computer's file tree and attach images/files to a conversation
- Code file preview (common languages and config files)
- Git project review: changed files from a diff, added/deleted line counts, untracked files
- Full conversation message search to quickly find past conclusions

**Pairing & security**

- Prints a QR code on startup (`cloudex://connect`, containing the address and token) that the app scans to connect
- Non-loopback access requires `AUTH_TOKEN`; `FILE_ROOTS` limits the paths browsable from the phone
- Connection history is stored locally in the app, with automatic / LAN / Tailscale modes

## Repository layout

```text
apps/
  server/           Local control server + cloudex CLI (distributable via npm pack)
    src/            HTTP server, Codex client, CLI session parsing, Windows CLI fallback
    bin/cloudex.js  CLI entry (serve / pair / about / version / help)
  ios-native/       Native SwiftUI iOS client (Xcode project)
packages/
  shared/           Shared API endpoint helpers (ENDPOINTS / URL builders)
resources/
  config/           Environment variable templates (server.env.example)
  icons/            Icon source files
  screenshots/      Screenshots and product references
  docs/             Protocol, deployment, and product docs (planned)
```

## Quick start

Requirements: Node.js ≥ 22 and the standalone Codex CLI.

### 1. Start the server

```bash
# macOS / Linux
./start-cloudex.sh

# Windows PowerShell
.\start-cloudex.ps1
```

Or directly with npm / the CLI:

```bash
npm run server          # or npm start
npx cloudex serve       # using the packaged cloudex command
```

The server listens on `0.0.0.0:8890` by default. On startup it prints the phone pairing QR code and the server address.

### 2. Use the CLI

```bash
cloudex pair                # print the pairing QR code and server address
cloudex about               # inspect local environment, Codex CLI, and server status
cloudex serve --port 8890   # start the server on an explicit port
cloudex --help
```

When `AUTH_TOKEN` is not set, `pair` / `serve` reuse or generate `.cloudex-state/auth-token`, matching the startup scripts. See `apps/server/README.md` for packaging and publishing.

### 3. Connect the iOS app

1. Open `apps/ios-native/CloudexNative.xcodeproj` in Xcode and build to a simulator or a signed device
2. Scan the QR code printed by the startup script, or manually enter the server address and token
3. Real devices cannot use `127.0.0.1`; use `http://<computer-LAN-IP>:8890` on LAN or `http://<computer-Tailscale-IP>:8890` over Tailscale

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8890` | Listening port |
| `HOST` | `0.0.0.0` | Listening address |
| `AUTH_TOKEN` | auto-generated | Bearer token for the API; required for non-loopback access |
| `CODEX_BIN` | auto-detected | Path to the Codex CLI executable |
| `FILE_ROOTS` | current directory | Root paths browsable from the phone (path-delimiter separated, `;` on Windows) |
| `CLOUDEX_PUBLIC_URL` | auto-inferred | Fixed server URL shown in the QR code |
| `CLOUDEX_STATE_DIR` | `.cloudex-state` | State directory for the token, approval history, etc. |

## API overview

```text
GET  /api/health                     Health check
GET  /api/models                     Available models
GET  /api/projects                   Projects aggregated from sessions
GET  /api/threads?archived=false     List sessions
POST /api/threads                    Create a session and send the first message
GET  /api/threads/:id/stream         Per-session SSE live stream
POST /api/threads/:id/message        Send a message
POST /api/threads/:id/steer          Resume/steer the current task
POST /api/threads/:id/stop           Stop the current task
POST /api/threads/:id/fork           Fork a new task from a conversation turn
POST /api/threads/:id/archive        Archive a session
GET  /api/files?path=...             List files
GET  /api/file?path=...              File contents (preview)
GET  /api/review?path=...            Git change review
GET  /api/search/messages?q=...      Search conversation messages
GET  /api/events                     SSE global events
GET  /api/approvals                  Pending approvals
POST /api/approvals/:id/respond      Respond to an approval (allow / deny / allow for session)
```

When `AUTH_TOKEN` is enabled, every `/api` request (including `/api/health`) requires `Authorization: Bearer <token>` (or a `?token=` query parameter); without a token only loopback addresses can connect, and the server refuses to start with the default `HOST=0.0.0.0`.

## Security model

- The server refuses to start on a non-loopback address without `AUTH_TOKEN`
- The pairing QR embeds the token; do not share it
- `FILE_ROOTS` limits the local paths browsable and selectable from the phone
- Tailscale is the recommended way to reach the server from a phone, avoiding public exposure
- Local notifications (approvals, task results) are generated on the device by the iOS app, with no third-party push channel

## Development

```bash
npm install
npm test                # run server unit tests (node --test)
npm run server:dev      # hot-reload the server with --watch
npm run cli -- --help   # run the CLI directly
npm run pack:server     # produce cloudex-<version>.tgz for npx distribution
```

Command-line build check for iOS (macOS):

```bash
xcodebuild -project apps/ios-native/CloudexNative.xcodeproj \
  -scheme CloudexNative -sdk iphonesimulator -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## Notes

- Session history is read from `~/.codex/sessions` by default (`cli-local` mode), so historical data is available even when the server is offline
- ChatGPT account `remote-control` cloud pairing is an optional Codex feature, **not** a Cloudex prerequisite; phone access to Cloudex is secured by LAN / Tailscale plus `AUTH_TOKEN`
