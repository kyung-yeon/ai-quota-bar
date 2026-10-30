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
- Persistent floating completion cards for multiple Codex / Claude Code sessions, with animation, session navigation, and individual dismissal.
- Session checklist progress such as **Design review · Step 5/7**, with a compact strip and full checklist on hover when the provider supplies it. [Progress setup and limitations](Docs/Notifications.md#session-progress).
- Korean when your Mac's primary preferred language is Korean; English otherwise. Dates follow the selected language and your local time zone. Restart the app after changing the system language.

## Requirements

- macOS 13 or later, on Apple Silicon or Intel.
- Xcode Command Line Tools, including Swift, Python 3, Git, and `make`.
- A separately installed and signed-in [Codex CLI](https://developers.openai.com/codex/cli/) and/or [Claude Code](https://code.claude.com/docs/en/quickstart) to display that provider's quota. The app also runs when neither is installed.

## Install from the command line

1. Install Apple's command line tools if needed, and wait for installation to finish:

   ```sh
   xcode-select --install
   ```

2. Download the source and install:

   ```sh
   git clone https://github.com/kyung-yeon/ai-quota-bar.git
   cd ai-quota-bar
   make install
   ```

   This builds for your Mac's architecture, runs the tests, signs the local app, installs it, and starts it. A new installation uses `~/Applications/AiQuotaBar.app` without `sudo`. An existing copy in `~/Applications` or `/Applications` is updated in place; you need write access to that folder. If both exist, the current login item determines which copy to keep, with the user folder preferred otherwise.

3. Click the Codex and Claude icons in the menu bar to see usage. AiQuotaBar does not appear in the Dock.

The installer registers `~/Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist` to start the app at login. It replaces legacy **Codex Weekly** installations and removes duplicate copies in the two Applications folders. It also removes the temporary `dist/AiQuotaBar.app` after installation, keeping one installed app. No persistent app backups are created; a failed replacement attempts to restore the previous app and login item.

### Update

From your existing source folder:

```sh
git pull --ff-only
make install
```

Your account settings and notification data are preserved.

To build an app bundle for development without installing, run `make package`. Local builds use an ad-hoc signature. The bundle includes editable source under `Contents/Resources/source/`.

## Connect your accounts

Install either CLI using its official guide above, complete its login flow, then choose **Refresh now** in AiQuotaBar. The app uses the existing CLI account; quota checks do not require a separate login form or model request.

| Display | Meaning / next step |
| --- | --- |
| Install required | The provider's CLI was not found. Install it, then refresh. |
| Sign in required | Sign in to that CLI, or sign in again if the session expired. |
| Keychain access required | Choose **Allow Claude Code Keychain access…** and respond to the macOS permission prompt. |
| Limits unavailable | The account does not expose a supported subscription quota, for example an API-key-only account. |
| Refresh required | The last result is older than 15 minutes, or its reset time has passed. |
| Connection error / Request timed out | Check connectivity, then refresh. Other providers continue to work independently. |

The app searches standard Homebrew paths, `~/.local/bin`, the launch environment's `PATH`, nvm Node installations, and `~/.claude/local/claude`. Local packaging also records CLI paths found during the build. For a custom installation, build from a terminal whose `PATH` contains the CLI. Environment variables used by a custom account setup must also be supplied to the app's launch environment; Finder does not inherit your shell configuration.

## Completion notifications

Launch AiQuotaBar to automatically connect installed Codex and Claude Code CLIs; no connection menu or setup dialog is required. Start a new agent session afterward. Codex still requires reviewing and trusting new hooks in `/hooks`. The floating list shows open sessions: idle rows are gray, working rows have an animated indicator, and unread completions move to the top with animation. Each provider/session keeps one row, updated by its newest completion. Dismissing an open session returns it to the idle list. Subagents appear as compact indented rows beneath their parent, with model metadata when available. Cards remain until dismissed, survive app restarts, and include project, session, and completion time. Opening a card keeps it unread until you explicitly dismiss it.

Each card can show the last five visible lines of its latest reported response or request beneath the session header and progress. Short messages use less space; longer cards reduce the number of rows on a page to fit the display without scrolling. Local Orca supplies available messages from existing tabs; other environments use connected lifecycle hooks. Missing message data leaves the compact row unchanged. Only a bounded preview is retained locally, not a conversation archive.

Unread subagents keep their parent tree even after the session exits or the app restarts. Verified one-off `codex exec --ephemeral` automation is excluded from new alerts unless it has explicit native child ownership; existing alerts with unknown provenance are preserved.

Use **Open floating panel / Close floating panel** in the menu bar, or the **×** button in the upper-right corner. **Settings → Floating panel settings → Rows per page** lets you choose 5, 10 (default), 15, or 20 rows per page; the choice is saved. Closing keeps monitoring and unread data intact; the panel stays closed across new completions and restarts until you reopen it.

Enable **Settings → Transparency → Enable transparency** for a translucent background while keeping text and controls opaque. The choice is saved; macOS **Reduce Transparency** takes precedence.

Each session has a follow-up input. For an idle local Orca agent, click **↑** or press **⌘ Enter** to send; **Enter** adds a line. You can draft while it is working. Drafts survive refreshes and page changes in memory, and sending is disabled for closed or unsupported sessions and subagents that share their parent’s terminal. See [direct input](Docs/Notifications.md#direct-input) for delivery behavior and compatibility.

Notifications initially appear on the macOS primary display. Drag the header or background to any connected monitor; new alerts and app restarts preserve your chosen position. Disconnecting that monitor returns the panel to the primary display.

Double-click the **AI sessions** header to collapse the panel to its title, count, and close button. Double-click again to expand it. Monitoring continues while collapsed, and the collapsed state is remembered across new completions and app restarts.

This is a custom floating window, independent of macOS notification banners. Each card keeps a compact 48-point header, with its message preview and input below. Each card keeps the provider icon, project, session, completion time, and small action buttons. Completed rows slide upward smoothly over 0.6 seconds. The panel gives a periodic reminder only while completed responses remain unacknowledged; idle and working rows alone never trigger it. Motion respects Reduce Motion.

Direct navigation is implemented for Terminal, iTerm2, Warp, cmux, Orca, WezTerm, and configured kitty sessions. Herdr needs an attachment wrapper so the correct outer terminal is selected. Unsupported or closed targets display an explanation; open or resume those sessions in their original terminal. Automatic setup preserves existing hooks and backs up changed configuration files. Missing tools are skipped and detected after installation; invalid or disabled hook settings are left intact and shown as a connection issue.

See the [completion notification guide](Docs/Notifications.md) for supported versions and environments, Herdr setup, custom profiles, completion semantics, and local data retention.

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

## Stop automatic launch or uninstall

Before deleting the app, run its executable with `--remove-completion-hooks codex` and `--remove-completion-hooks claude` for each provider and custom profile ([CLI instructions](Docs/Notifications.md#custom-profiles-and-agent-managers)). Unread completion metadata is stored separately in `~/Library/Application Support/AiQuotaBar/Notifications/`.

Choose **Quit AiQuotaBar** to end the current session. It will run again at the next login unless you disable the login item:

```sh
launchctl bootout "gui/$(id -u)/local.kyungyeon.ai-quota-bar"
rm "$HOME/Library/LaunchAgents/local.kyungyeon.ai-quota-bar.plist"
```

If `bootout` says the service was not found, it is already stopped. To uninstall, move the installed `AiQuotaBar.app` to the Trash from `~/Applications` or `/Applications`, whichever the installer reported. Your Codex and Claude installations and accounts are unaffected.

## License

AiQuotaBar's original code and documentation are licensed under the [MIT License](LICENSE). Anyone may use, modify, and redistribute them, including for commercial purposes, provided the copyright and license notices are preserved. The software is provided without warranty.

Third-party provider icons and trademarks belong to their respective owners and are not covered by this MIT license. See [provider icon attribution](Assets/README.md).
