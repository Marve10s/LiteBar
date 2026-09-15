# LiteBar

A native macOS menu bar app for Codex, Claude Code, Antigravity, and OpenCode usage. Built with SwiftUI and AppKit, with no third-party runtime dependencies, embedded browser, or telemetry.

LiteBar shows quota windows, reset times, and a menu bar gauge. Provider details and local token totals load on demand. The countdown updates only while the popover is open. One network notice covers all providers, and usage refreshes when macOS reports that connectivity has returned.

## Build and install

Requires macOS 14 or later and Swift 6 or later. Check the installed toolchain with `swift --version`. Build on the Mac where you will use the app; the package script targets its native architecture.

Fork this repository and clone your fork, or clone this repository directly:

```sh
git clone https://github.com/Marve10s/LiteBar.git
cd LiteBar
./scripts/package.sh
mkdir -p ~/Applications
cp -R dist/LiteBar.app ~/Applications/
open ~/Applications/LiteBar.app
```

The script builds an optimized release and signs it ad hoc. No Apple Developer membership, Developer ID certificate, or notarization is required for this source-build workflow. Prebuilt downloads are not provided.

Quit an existing LiteBar instance before replacing the installed app. Install it in its final location before enabling Claude capture. macOS may request Keychain access again after rebuilding an ad-hoc-signed app. If you already have a stable local signing identity, you can select it with `CODESIGN_IDENTITY` when packaging.

For development:

```sh
swift build --jobs 1
.build/debug/LiteBar
```

Use the packaged app for the bundled Claude capture helper and launch-at-login support.

## Provider setup

Disable providers you do not use in Settings. Automatic refresh defaults to five minutes; manual refresh is also available. On a CLI page, the filter button picks which limits are listed and which one the overview shows.

| Provider | Setup and credential source |
| --- | --- |
| Codex | Sign in through the Codex CLI. LiteBar reads `~/.codex/auth.json` and saves refreshed tokens there. |
| Claude live | Connect separately in LiteBar Settings. The renewable profile-access grant lives in Keychain under `dev.ibrahime.LiteBar.claude`. LiteBar does not read or rotate Claude Code credentials. |
| Claude local | Enable the capture helper in Settings and complete a response in Claude Code. |
| Antigravity | Sign in through the `agy` CLI. LiteBar reads the saved token under `~/.gemini/antigravity-cli` and discovers the OAuth client from the installed CLI or Antigravity app. |
| OpenCode | Sign in to OpenCode Go. LiteBar reads `~/.local/share/opencode/auth.json` and the cached model catalog. |

Provider usage endpoints and credential formats are unofficial integrations and can change. LiteBar contacts provider services directly. It has no application server and sends no telemetry. Local token totals come from CLI logs or OpenCode's SQLite database when you expand that section.

## Claude modes

Choose **Settings → Claude Code → Source**.

For **Live limits**, click **Connect Claude**, approve profile access in the browser, then paste the complete authorization code into LiteBar. The authorization client may be labeled Claude Code. LiteBar creates its own grant and renews it when needed during a refresh. No browser or Claude process stays open. Revoked access requires a new sign-in.

For **Local capture**, click **Enable in Claude Code**. LiteBar backs up `~/.claude/settings.json` and installs its native helper as the status-line command. An existing status-line command keeps its input, output, and exit status through forwarding. Claude Code must publish `rate_limits` in its status-line JSON; the integration was verified with Claude Code 2.1.268.

The helper saves only quota windows and the time they changed, then exits. It has no network code. Unchanged figures cause no capture write or LiteBar wakeup. Local figures can become stale while Claude Code is closed, when switching accounts, or when using Claude elsewhere. Captures live in `~/Library/Caches/dev.ibrahime.LiteBar/claude-usage.json` and contain no credentials or conversation text.

Capture remains active in Claude Code after switching LiteBar to live mode. Its installed command contains the app's absolute location. If you move the app, remove the old capture command before enabling capture at the new location.

## Remove LiteBar

If capture is installed, edit only the `statusLine` entry in `~/.claude/settings.json`: restore its value from the `settings.json.litebar-backup-*` file created during setup, or remove the entry if there was no previous status line. Keep other settings and later edits intact.

Disable launch at login in LiteBar Settings, quit the app, and delete it. You can delete the Claude capture directory above and the Keychain item with service `dev.ibrahime.LiteBar.claude` and account `usage` to remove LiteBar's saved Claude data. Leave the CLIs' own credentials intact.

## License and credits

LiteBar code is available under the [MIT license](LICENSE).

The Claude and OpenAI icons come from [Simple Icons](https://github.com/simple-icons/simple-icons), with OpenAI matching version 15.0.0. Its [CC0 dedication](https://github.com/simple-icons/simple-icons/blob/develop/LICENSE.md) and [brand disclaimer](https://github.com/simple-icons/simple-icons/blob/develop/DISCLAIMER.md) apply.

The Antigravity and OpenCode icons come from [CodexBar](https://github.com/steipete/CodexBar). Copyright (c) 2026 Peter Steinberger, distributed under the [MIT license](https://github.com/steipete/CodexBar/blob/main/LICENSE).

Provider names and marks belong to their respective owners. LiteBar is an independent project; these licenses do not grant trademark rights or imply endorsement.
