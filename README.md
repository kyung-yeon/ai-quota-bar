# AiQuotaBar

[한국어 가이드](README.ko.md)

A native macOS menu bar app for checking Codex and Claude Code usage in one place.

- Provider icons and remaining weekly quota in the menu bar; session and weekly limits in the menu when available.
- Reset times displayed in your Mac's time zone.
- Available Codex reset passes with individual expiration dates, when the service supplies them.
- Independent **Install required** and **Sign in required** states for each provider.
- Refresh every five minutes, on wake, or manually with **⌘R**.
- Korean when your Mac's primary preferred language is Korean; English otherwise. Dates follow the selected language and your local time zone. Restart the app after changing the system language.

## Requirements

- macOS 13 or later.
- Xcode Command Line Tools, including Swift, Python 3, and `make`.
- A separately installed and signed-in [Codex CLI](https://developers.openai.com/codex/cli/) and/or [Claude Code](https://code.claude.com/docs/en/quickstart) to display that provider's quota. The app also runs when neither is installed.

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

The app is signed locally for personal use. It is not notarized for public distribution. The bundle also includes editable source under `Contents/Resources/source/`.

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

The app searches standard Homebrew paths, `~/.local/bin`, the launch environment's `PATH`, nvm Node installations, and `~/.claude/local/claude`. Packaging also records CLI paths found during the build. For a custom installation, build from a terminal whose `PATH` contains the CLI. Environment variables used by a custom account setup must also be supplied to the app's launch environment; Finder does not inherit your shell configuration.

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
```

Render sample UI for visual checks; these values are fixtures, not live usage:

```sh
./build/AiQuotaBar --preview-demo --language en --preview /tmp/aiquota-en.png
./build/AiQuotaBar --preview-demo --language ko --dark --preview /tmp/aiquota-ko.png
```

Implementation: `Sources/` · tests: `Tests/` · entry point: `main.swift` · packaging: `package.py` · installation: `install.py`.

## Stop automatic launch or uninstall

Choose **Quit AiQuotaBar** to end the current session. It will run again at the next login unless you disable the login item:

```sh
launchctl bootout "gui/$(id -u)/local.kyungyeon.ai-quota-bar"
rm "$HOME/Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist"
```

If `bootout` says the service was not found, it is already stopped. To uninstall, also move `~/Applications/AiQuotaBar.app` to the Trash. Backups under `~/Library/Application Support/AiQuotaBar/Backups/` may be kept for rollback or removed separately. Your Codex and Claude installations and accounts are unaffected.

## License

AiQuotaBar's original code and documentation are licensed under the [MIT License](LICENSE). Anyone may use, modify, and redistribute them, including for commercial purposes, provided the copyright and license notices are preserved. The software is provided without warranty.

Third-party provider icons and trademarks belong to their respective owners and are not covered by this MIT license. See [provider icon attribution](Assets/README.md).
