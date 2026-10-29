# AiQuotaBar

[한국어 가이드](README.ko.md)

A native macOS menu bar app for checking Codex and Claude Code usage in one place.

<p align="center">
  <img src="Assets/screenshots/aiquotabar-preview.png" alt="Illustrative AiQuotaBar preview with Codex and Claude Code signed in, showing remaining quotas and reset times using sample data" width="560">
</p>

<p align="center"><em>Illustrative preview with both providers signed in. All usage values, dates, and reset passes are fictional examples.</em></p>

- Provider icons and remaining weekly quota in the menu bar; session and weekly limits in the menu when available.
- Reset times displayed in your Mac's time zone.
- Available Codex reset passes with individual expiration dates, when the service supplies them.
- Independent **Install required** and **Sign in required** states for each provider.
- Refresh every five minutes, on wake, or manually with **⌘R**.
- Persistent floating completion cards for multiple Codex / Claude Code sessions, with animation, session navigation, and individual or bulk dismissal (source builds; not included in the v0.1.0 DMG).
- Korean when your Mac's primary preferred language is Korean; English otherwise. Dates follow the selected language and your local time zone. Restart the app after changing the system language.

## Requirements

- macOS 13 or later, on Apple Silicon or Intel.
- Xcode Command Line Tools, including Swift, Python 3, and `make`, only if building from source. The DMG does not require them.
- A separately installed and signed-in [Codex CLI](https://developers.openai.com/codex/cli/) and/or [Claude Code](https://code.claude.com/docs/en/quickstart) to display that provider's quota. The app also runs when neither is installed.

## Install from DMG

**[Download AiQuotaBar for macOS](https://github.com/kyung-yeon/ai-quota-bar/releases/download/v0.1.0/AiQuotaBar-0.1.0-universal.dmg)** · [All releases and checksums](https://github.com/kyung-yeon/ai-quota-bar/releases)

1. Open the DMG and drag **AiQuotaBar.app** onto **Applications**.
2. Eject the DMG, then open AiQuotaBar from Applications.
3. Click its menu bar icons to see your usage. It does not appear in the Dock.

The DMG opens a compact installation window with AiQuotaBar on the left and Applications on the right. Follow the arrow to copy the app. The same app supports Apple Silicon and Intel; English and Korean installation guides are included inside its bundle. To start it at login, add the installed app under **System Settings → General → Login Items → Open at Login**. Drag-and-drop installation does not register a login item automatically.

**Updating an existing installation:** quit AiQuotaBar and replace the app in its existing folder. If you previously used `make install`, replace `~/Applications/AiQuotaBar.app` there to preserve its login item. Avoid keeping another copy in `/Applications`.

**First launch:** this release is ad-hoc signed and **not notarized by Apple**. If macOS blocks it, confirm the file came from this project's Releases page. If you trust the build, use **System Settings → Privacy & Security → Open Anyway** after trying to open it, following [Apple's instructions](https://support.apple.com/en-us/102445).

## Install from source

1. Install Apple's command line tools if needed:

   ```sh
   xcode-select --install
   ```

2. Open Terminal in this source folder and run:

   ```sh
   make install
   ```

   This builds the app for your Mac's architecture, runs the tests, signs the local bundle, installs it at `~/Applications/AiQuotaBar.app`, and starts it. No `sudo` is required.

3. Look for the Codex and Claude icons in the menu bar. AiQuotaBar does not appear in the Dock. Click the menu bar item to see detailed usage.

The installer adds `~/Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist` to start the app at login. If **Codex Weekly** is already installed at `~/Applications/Codex Weekly.app`, the installer stops and replaces it, including its old login item. Previous app bundles and login items are preserved under `~/Library/Application Support/AiQuotaBar/Backups/`. A failed installation attempts to restore the previous installation.

To build without installing:

```sh
make package
open dist/AiQuotaBar.app
```

Local builds use an ad-hoc signature. The bundle also includes editable source under `Contents/Resources/source/`.

## Connect your accounts

Install either CLI using its official guide above, complete its login flow, then choose **Refresh now** in AiQuotaBar. The app uses the existing CLI account; it does not provide a separate login form or run a model request.

| Display | Meaning / next step |
| --- | --- |
| Install required | The provider's CLI was not found. Install it, then refresh. |
| Sign in required | Sign in to that CLI, or sign in again if the session expired. |
| Keychain access required | Choose **Allow Claude Code Keychain access…** and respond to the macOS permission prompt. |
| Limits unavailable | The account does not expose a supported subscription quota, for example an API-key-only account. |
| Refresh required | The last result is older than 15 minutes, or its reset time has passed. |
| Connection error / Request timed out | Check connectivity, then refresh. Other providers continue to work independently. |

The app searches standard Homebrew paths, `~/.local/bin`, the launch environment's `PATH`, nvm Node installations, and `~/.claude/local/claude`. Local packaging also records CLI paths found during the build; the portable DMG omits build-machine paths. For a custom installation, build from a terminal whose `PATH` contains the CLI. Environment variables used by a custom account setup must also be supplied to the app's launch environment; Finder does not inherit your shell configuration.

## Completion notifications

Launch AiQuotaBar to automatically connect installed Codex and Claude Code CLIs; no connection menu or setup dialog is required. Start a new agent session afterward. Codex still requires reviewing and trusting new hooks in `/hooks`. Cards remain until dismissed, survive app restarts, and include project, session, and completion time. Opening a card keeps it unread until you explicitly dismiss it.

Notifications appear on the macOS primary display, regardless of which monitor has the active app. Changing the primary display repositions the panel automatically.

Direct navigation is implemented for Terminal, iTerm2, Warp, cmux, Orca, WezTerm, and configured kitty sessions. Herdr needs an attachment wrapper so the correct outer terminal is selected. Unsupported or closed targets offer a copyable resume command. Automatic setup preserves existing hooks and backs up changed configuration files. Missing tools are skipped and detected after installation; invalid or disabled hook settings are left intact and shown as a connection issue.

See the [completion notification guide](Docs/Notifications.md) for supported versions and environments, Herdr setup, custom profiles, completion semantics, and local data retention. This feature is available in source builds and is not yet in the published v0.1.0 DMG.

## Reset passes and data sources

**Codex:** Uses `codex app-server --stdio`, `account/read`, and `account/rateLimits/read`. The server's available pass count is authoritative; detailed rows can be incomplete. Expired and redeemed passes are excluded from the expiration list. Missing dates are shown explicitly, and a pass with a null expiration is displayed as having no expiration. The app displays passes only; it never redeems them. See the [official app-server protocol](https://learn.chatgpt.com/docs/app-server#6-rate-limits-chatgpt).

**Claude Code:** Reads its existing OAuth credential from the macOS Keychain, with Claude Code's `.credentials.json` fallback. It supports the `CLAUDE_CONFIG_DIR`-specific Keychain name and `CLAUDE_CODE_OAUTH_TOKEN` when supplied in the app's launch environment. It requests the same `https://api.anthropic.com/api/oauth/usage` endpoint used by the official CLI and reads `five_hour` and `seven_day` utilization. This is an internal endpoint, not a stable public API; changes may require an update. Credential storage is described in [Claude Code authentication](https://code.claude.com/docs/en/authentication).

Claude's usage response does not have a verified reset-pass schema in this implementation, so its pass section displays **unavailable**, rather than assuming zero passes. Paid extra usage is not treated as a reset pass. Claude quota retrieval needs a signed-in subscription account; it has not been verified against a live Claude account on the development Mac because no Claude CLI is installed there.

Credentials and usage responses are not written to logs or bundled with the app. Claude credentials are read in memory and sent only to Anthropic's usage endpoint; redirects are rejected. Codex handles its own authentication. Network failures are shown separately from sign-in requirements.

## Development and verification

```sh
make test                         # Offline parsing and state tests
make check                        # Live, read-only quota checks
./build/AiQuotaBar --smoke-test     # Create a real menu bar item, fetch, print status, exit
./build/AiQuotaBar --self-test --language en
./build/AiQuotaBar --self-test --language ko
./build/AiQuotaBar --completion-ui-test --language en  # Sample UI + persistence; no live agent calls
```

Render sample UI for visual checks; these values are fixtures, not live usage:

```sh
./build/AiQuotaBar --preview-demo --language en --preview /tmp/aiquota-en.png
./build/AiQuotaBar --preview-demo --language ko --dark --preview /tmp/aiquota-ko.png
./build/AiQuotaBar --preview-completions /tmp/completions-en.png --language en
./build/AiQuotaBar --preview-completions /tmp/completions-ko.png --language ko --dark
```

Implementation: `Sources/` · tests: `Tests/` · entry point: `main.swift` · packaging: `package.py` · installation: `install.py`. Completion lifetime tests use a temporary local Unix socket; UI tests need a logged-in macOS desktop session.

Build a distributable DMG:

```sh
make dmg
```

This compiles both architectures, creates a portable bundle, and produces `dist/AiQuotaBar-0.1.0-universal.dmg` with its `.dmg.sha256` checksum. The build uses Finder to save the window size, background, and icon positions before compressing the image, so run it in a logged-in macOS desktop session. Allow your terminal to control Finder if macOS asks. The build verifies the disk image, mounts it read-only, checks both executable architectures, the app signature, and the saved layout, runs offline tests from the mounted app, and ejects it. It does not install or launch the menu bar app. Release packaging lives in `dmg.py`, layout tools in `Tools/`, and installation guides in `Docs/`.

## Stop automatic launch or uninstall

Before deleting the app, run its executable with `--remove-completion-hooks codex` and `--remove-completion-hooks claude` for each provider and custom profile ([CLI instructions](Docs/Notifications.md#custom-profiles-and-agent-managers)). Unread completion metadata is stored separately in `~/Library/Application Support/AiQuotaBar/Notifications/`.

Choose **Quit AiQuotaBar** to end the current session. It will run again at the next login unless you disable the login item:

```sh
launchctl bootout "gui/$(id -u)/local.kyungyeon.ai-quota-bar"
rm "$HOME/Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist"
```

If `bootout` says the service was not found, it is already stopped. To uninstall, also move `~/Applications/AiQuotaBar.app` to the Trash. Backups under `~/Library/Application Support/AiQuotaBar/Backups/` may be kept for rollback or removed separately. Your Codex and Claude installations and accounts are unaffected.

## License

AiQuotaBar's original code and documentation are licensed under the [MIT License](LICENSE). Anyone may use, modify, and redistribute them, including for commercial purposes, provided the copyright and license notices are preserved. The software is provided without warranty.

Third-party provider icons and trademarks belong to their respective owners and are not covered by this MIT license. See [provider icon attribution](Assets/README.md).
