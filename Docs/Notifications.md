# Completion notifications

AiQuotaBar can show persistent completion cards for multiple Codex and Claude Code sessions. Cards initially appear on the macOS primary display, float above other apps across Spaces (including full-screen spaces), and remain until you choose **Dismiss**. Drag the panel's header or background to any connected display. Its position is remembered, including when new cards arrive or the app restarts. If that display is disconnected, the panel returns to the primary display.

Double-click the header to collapse the list to its title, count, and close button; double-click again to expand. The top edge stays fixed, monitoring continues, and new completions do not expand it. The collapsed preference survives app restarts. Unread reminders still apply to the compact header.

Only the latest completion for each provider/session appears. A new completion updates that card and its time; previous event IDs remain stored for replay protection. Existing duplicate cards are collapsed when the app loads them. Dismissing the newest card does not reveal older completions.

The inbox is an independent, borderless floating window; it does not send macOS Notification Center banners. Each compact 48-point card shows a provider icon, project, session label, and relative completion time. Hover over the icon for the provider and terminal, or the time for the exact date and time. Clicking the project or **↗ Open session** targets the original session without dismissing its card. **✓ Dismiss** acknowledges the card. The title uses the available row width, and action buttons are square. All icon buttons have tooltips and accessibility labels. The window stays above other app windows and fits its cards without an internal scrollbar. The default is 10 rows per page. Choose 5, 10, 15, or 20 in the menu bar’s **Floating panel settings**; the value persists across relaunches. Fewer rows may fit on a small display, and previous/next buttons expose the rest. Native subagent rows are 36 points tall, indented with connector lines. A continuation page repeats its parent context.

A new completion slides upward with a 0.6-second ease-in/ease-out animation. While completed responses remain unacknowledged, the panel gives a three-swing reminder every 12 seconds, avoiding overlap with the slide. Rotation is reduced for tall pages so corners remain inside the window. Working and idle sessions alone never trigger a reminder; confirming the last completion or closing the panel stops it immediately. macOS **Reduce motion** disables movement, including animations already running.


<img src="../Assets/screenshots/completions-en.png" alt="Attention, working and idle rows for fictional AI sessions" width="390">

*Rendered from the app using fictional sessions, with no account or conversation data.*

## Open sessions and visibility

The list orders **needs attention → working → idle/open**. Idle rows are gray but remain clickable. Working rows have a rotating indicator. A newly completed session moves to the first page and animates upward; Reduce Motion disables movement and spinning. Dismissing a completion leaves its session in the list while it is open. A closed session is removed unless it has an unread completion. Pagination keeps every row accessible without a scrollbar.

**Open floating panel / Close floating panel** in the menu bar and the **×** button in the upper-right corner control visibility. Closing does not acknowledge anything or stop collection. This choice survives new completions and relaunches; reopen the panel from the menu.

Lifecycle hooks track sessions after they start or submit a prompt. The owning CLI process and its start time, when available, remove sessions that exit without a final hook. Other terminals' already-running sessions need a new session with hooks enabled; stored conversation history is not treated as an open session. Claude interruption without a hook can leave the last reported state until its next lifecycle event.

For an already-running local **Orca** runtime, AiQuotaBar also reads `terminal list` and `worktree ps`. Connected agent terminals appear immediately, including those started before AiQuotaBar. The runtime's working-to-done transition can supply a completion when hooks are missing; discovering an already-idle tab never creates an alert. Polling can miss a whole turn between samples, so hooks remain the preferred completion signal. Runtime-only identity is scoped to the terminal handle until a hook provides the provider session ID. Failed or incomplete runtime reads retain rows with unknown activity and an explanation. This covers the current Orca profile and sessions its CLI exposes, not every native chat, remote runtime, or custom profile. No prompts, terminal previews, or conversation history are stored.

If a hook lacks terminal metadata, AiQuotaBar can recover its local Orca destination from the owning process's routing variables. It verifies the PID/start time, local Orca ancestry, and current provider/profile/terminal handle before unifying runtime and native identities. Ambiguous owners and intervening SSH or multiplexers remain separate. Arguments and unrelated environment variables are not retained.

### Subagent trees

Native Codex / Claude Code subagents appear beneath their owning session; nested relationships are retained when the provider exposes them. The whole family moves together when attention is prioritized. Child rows show a name or role (otherwise a short identifier), model when supplied, and activity. An in-process child's arrow is labeled **Open parent session**, since it shares the parent's terminal; a child with its own Orca pane keeps its own navigation target.

Orca's canonical `children` list takes precedence over its legacy `subagents` roster, even when empty. Settled children are hidden unless they own a live descendant or have an unread completion. Unverifiable runtime child state does not show a running indicator. Hooks also collect `SubagentStart` / `SubagentStop`; child completion updates that row without falsely announcing that the parent's response has finished. Hook-only children remain idle until the parent ends because those hooks do not reliably report separate child closure. Unread children retain their tree after child/parent exit and app relaunch, with closed ancestors shown only as context. Confirming the last unread descendant removes that retained context. Names and model labels survive lifecycle events that omit them. A child sharing its parent's terminal cannot claim, replace, or suppress the parent's completion. Task descriptions and child messages are never saved.

Verified `codex exec --ephemeral` (or `codex e --ephemeral`) invocations are excluded from new session/alert collection unless explicit native child ownership is known. This prevents one-off automation from filling the interactive list. Detection reads only the invocation mode of the current owning process; it never stores arguments. Same-project IDs alone do not establish a parent relationship. Older alerts with unknown provenance remain untouched.

## Automatic connection

1. Install this build of AiQuotaBar in its permanent location and keep it running.
2. Installed Codex and Claude Code CLIs are connected automatically, without a menu action or setup dialog.
3. Start a new agent session. In Codex, open `/hooks` and review and trust the new AiQuotaBar hooks. Automatic registration does not grant Codex's separate hook trust.
4. Complete a response. The floating card normally appears within about two seconds.

The app adds `SessionStart`, `UserPromptSubmit`, `Stop`, `SessionEnd`, `SubagentStart`, and `SubagentStop` command hooks, plus Codex `Interrupt` or Claude `StopFailure`, to `~/.codex/hooks.json` or `~/.claude/settings.json`. Existing settings and other tools' hooks are preserved. Changed files receive a sibling `*.aiquotabar-backup-<id>` backup. Checks run at launch, once a minute, and on **Refresh now**. Unchanged settings are not rewritten or backed up again. Missing CLIs are skipped, including configuration creation; installing them later is detected on the next check.

Invalid JSON, symbolic-link configuration files, and globally disabled hooks are left intact. **Check notification connection…** appears in the menu when a connection fails. Automatic connection does not install a CLI or sign into an account.

The hook executable is the installed app itself; no Python, Node, or extra daemon is required. Hooks save events even while AiQuotaBar is closed. The next launch restores the unread list. After moving the app, launch it from the new location to update hook paths automatically; Codex may require trust review again. Disconnect before deleting the app.

### Custom profiles and agent managers

Automatic setup uses `CODEX_HOME` / `CLAUDE_CONFIG_DIR` from **AiQuotaBar's launch environment**. Finder does not inherit shell exports. In a custom profile, run the following **from the terminal that launches the agent**, using your installed app path:

```sh
AQB="/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar"
"$AQB" --install-completion-hooks codex
"$AQB" --install-completion-hooks claude
```

For a source installation, use `$HOME/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar`. To disconnect a profile, use `--remove-completion-hooks codex` or `--remove-completion-hooks claude` in the same environment. This removes only AiQuotaBar hooks and writes a sibling `*.aiquotabar-disabled` marker so automatic checks do not reconnect that profile. An explicit install command re-enables it. Start a new agent session after either change. The command prints the configuration path. Do not run it against a manager's generated configuration if that manager recreates the file; use that manager's persistent hook settings instead, with the command `'<absolute app executable>' --completion-hook codex` (or `claude`) for the applicable lifecycle events above.

Session names use `AIQUOTABAR_SESSION_NAME` when set before starting the agent, then an event-supplied session name, then a short session identifier. Example:

```sh
AIQUOTABAR_SESSION_NAME="Account settings" codex
```

## Terminal navigation

| Environment | Navigation in this build | Conditions |
| --- | --- | --- |
| macOS Terminal | Existing tab by TTY | Captures the owning process lifetime to reject reused TTYs; macOS Automation permission may be requested. |
| iTerm2 | Existing session via `iterm2:reveal` | Requires `ITERM_SESSION_ID` in the agent's environment and iTerm2 still running. |
| Warp | Existing session via `WARP_FOCUS_URL` | Requires a version supplying the focus URL; stable macOS Warp must be running. |
| cmux | Exact surface via its AppleScript `focus` command | Requires `CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID`, and a cmux version exposing AppleScript. Does not enable unrestricted socket access. |
| Orca | Runtime-issued terminal handle via `orca terminal switch` | Uses `ORCA_TERMINAL_HANDLE` and the originating profile. A stale handle produces an error; it is not guessed from the current project. Native chat support is limited to sessions the installed Orca exposes through this API. |
| WezTerm | Existing pane via `wezterm cli activate-pane` | Requires `WEZTERM_PANE`; preserves `WEZTERM_UNIX_SOCKET` when supplied. |
| kitty | Existing pane via `kitten @ focus-window` | Requires `KITTY_WINDOW_ID`, a local `unix:` `KITTY_LISTEN_ON`, and already-configured remote-control permission. AiQuotaBar does not change kitty settings. |
| Herdr | Current attached terminal plus the Herdr agent pane | Start Herdr using the wrapper below. The most recently registered live attachment is used. |
| Ghostty, VS Code / Cursor integrated terminal, tmux, screen, SSH | Completion cards only | Exact-tab navigation is not implemented. These environments need additional session mapping or an extension/remote bridge. |

Navigation uses captured identifiers, never the frontmost tab, project name, or screen coordinates. A closed tab, unavailable CLI, denied Automation permission, unsupported environment, or expired handle leaves the card unread with an explanation. If navigation is unavailable, open or resume the session in its original terminal. URL-based integrations can acknowledge only that macOS accepted the URL, not that the pane became visible, so opening a card never counts as dismissal.

### Herdr

Herdr's server can outlive the terminal that first started it. To avoid following stale inherited terminal IDs, attach through AiQuotaBar:

```sh
AQB="/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar"
"$AQB" --run-herdr
# Or a named local session:
"$AQB" --run-herdr --session work
```

Run this in a supported outer terminal, then launch Codex / Claude with the hooks connected. The wrapper records the outer terminal and replaces itself with `herdr`; it does not create an additional agent or intercept terminal input. On click, AiQuotaBar checks that attachment's process lifetime and the Herdr socket identity, selects the Herdr pane, and reveals the outer tab. Reattach with the wrapper after changing terminals. If several clients attach, the last registered live client is the destination. A server restart invalidates old pane destinations; reopen the session manually instead of following a potentially reused pane ID. SSH and nested tmux/Herdr attachments are not supported by this wrapper.

## What “finished” means

The default integration observes the main agent's `Stop` hook: the agent has reached the end of a response. This is **not a verification that the requested task succeeded**, all background jobs ended, or all other hooks permitted the agent to stop. A different Stop hook can continue work after AiQuotaBar is notified. Session exit, interruption, failure, and child-agent Stop events do not generate completion cards.

For Codex workflows with continuation hooks, prefer the finalized [`agent-turn-complete` notify event](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications). Add this at the root of your Codex config **only if you do not already have a `notify` command**:

```toml
notify = ["/Applications/AiQuotaBar.app/Contents/MacOS/AiQuotaBar", "--notify-codex"]
```

Before switching to this advanced integration, run `--remove-completion-hooks codex` so automatic checks do not restore the `Stop` hook. The notify payload itself supplies Codex session and turn identity, and its process environment supplies the terminal destination. If another tool owns `notify`, chain the commands in your own notifier rather than replacing it. AiQuotaBar never rewrites `config.toml`. Hook and notify deliveries with the same provider/session/turn ID are deduplicated. Older Claude releases without a prompt ID use the token recorded at `UserPromptSubmit`; connecting mid-session without that hook falls back to a response hash and can collapse identical responses.

## Local data and troubleshooting

`~/Library/Application Support/AiQuotaBar/Notifications/` holds completion metadata, destination IDs, and local Herdr bindings. Files are user-only; writes are atomic and protected by a process lock. Prompt and assistant text, credentials, and terminal output are not saved. There is no analytics or network collector. The latest unread card per provider/session never expires; acknowledged and replaced event IDs are kept for 90 days to prevent replay after restart. All unread cards remain available through page controls; the panel fits its current page without scrolling.

- **Only some sessions notify:** sessions already running when hooks were installed or trusted may still use their previous hook configuration. After their current work finishes, restart Codex and resume the same conversation with `codex resume`, then review AiQuotaBar in `/hooks`. Installing or restarting AiQuotaBar alone does not refresh those running Codex sessions.
- **No cards:** check the configuration path, start a new session, review Codex `/hooks`, and ensure hooks are not globally disabled. Test from the same profile used by the agent manager.
- **No direct navigation:** check the table above, Automation permissions, and whether the original tab still exists; open the session manually when the destination is unavailable. For Herdr, attach through `--run-herdr`.
- **Store error:** AiQuotaBar preserves an unreadable file rather than silently resetting it. Quit the app and back up the Notifications folder before repairing it.
- **Moving:** launch from the new location to update the automatic profile; reconnect custom profiles with the CLI. **Uninstalling:** disconnect hooks in every profile first. Unread metadata remains until you separately remove the Notifications folder.

Official contracts: [Codex hooks](https://learn.chatgpt.com/docs/hooks), [Claude Code hooks](https://code.claude.com/docs/en/hooks), [cmux CLI](https://cmux.com/docs/api), [Orca CLI](https://www.onorca.dev/docs/cli/reference), [Herdr CLI](https://herdr.dev/docs/cli-reference/), [Herdr socket API](https://herdr.dev/docs/socket-api/).
