# Claude Code Slack Notifications

Get Slack notifications when Claude Code finishes a task, asks a question, needs permission, or hits an error — so you don't have to keep checking your terminal.

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/ohjoonhee/claude-webhook-notification/main/install.sh | bash -s -- --webhook-url="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

Or interactively (prompts for webhook URL):

```bash
bash <(curl -sSL https://raw.githubusercontent.com/ohjoonhee/claude-webhook-notification/main/install.sh)
```

## What It Does

The installer:
1. Copies `slack-notify.sh` to `~/.claude/scripts/`
2. Adds hooks to `~/.claude/settings.json` (Stop, PermissionRequest, PreToolUse, SubagentStop)
3. Sets your `SLACK_WEBHOOK_URL` in the Claude Code environment
4. Creates a timestamped backup of your existing `settings.json`

## Notification Types

Each notification has a distinct emoji, color, and message so you can tell at a glance what Claude needs.

| Type | Emoji | Color | Example Message |
|---|---|---|---|
| **Task completed** | :white_check_mark: | Green | *Created the login page and updated the router. All tests pass.* |
| **Waiting for answer** | :question: | Orange | *Which database engine should I use: PostgreSQL or MySQL?* |
| **Waiting for permission** | :raised_hand: | Amber | *Needs permission to run: Bash(npm run deploy --production)* |
| **Plan ready for review** | :clipboard: | Purple | *Refactoring Plan: 1. Extract routes 2. Add middleware...* |
| **Session limit reached** | :warning: | Red | *Session limit reached. Start a new session to continue.* |
| **API error** | :x: | Red | *API error occurred. Check authentication or rate limits.* |
| **Subagent finished** | :robot_face: | Gray | *Found 15 API endpoints in the codebase.* |

Each notification also includes:
- **Task** — your original prompt (truncated to 150 chars)
- **Project** — the project directory name
- **Actions** — tool usage summary (e.g., `2 new, 3 edits, 5 cmds — 1m 24s`)
- **VSCode link** — click to open the project (supports local, SSH, WSL, and container remotes)

### Smart Deduplication

Notifications are deduplicated across three layers to avoid spam:
- **2s lockout** — same hook firing multiple times rapidly
- **180s content dedup** — identical messages from different code paths
- **10s question cooldown** — suppresses question/permission notifications immediately after a task completion

## Configuration

Set these in `~/.claude/settings.json` under `"env"`:

| Variable | Default | Description |
|---|---|---|
| `SLACK_WEBHOOK_URL` | (required) | Your Slack incoming webhook URL |
| `CLAUDE_NOTIFY_SUBAGENT` | `false` | Send notifications for subagent completions |
| `CLAUDE_QUESTION_COOLDOWN` | `10` | Seconds to suppress question notifications after any notification |
| `CLAUDE_VSCODE_SCHEME` | `vscode` | URI scheme for deep links (`vscode`, `cursor`, `vscodium`) |
| `CLAUDE_VSCODE_REMOTE_HOST` | — | SSH host alias for remote VSCode links |

## Uninstall

```bash
curl -sSL https://raw.githubusercontent.com/ohjoonhee/claude-webhook-notification/main/install.sh | bash -s -- --uninstall
```

Or manually: remove the `slack-notify.sh` hook entries from `~/.claude/settings.json` and delete `~/.claude/scripts/slack-notify.sh`.

## Manual Install

```bash
git clone https://github.com/ohjoonhee/claude-webhook-notification.git
cd claude-webhook-notification
bash setup-slack-hooks.sh --webhook-url="https://hooks.slack.com/services/..."
```

## Options

| Flag | Description |
|---|---|
| `--webhook-url=URL` | Set Slack webhook URL (skips interactive prompt) |
| `--dry-run` | Show what would change without writing anything |
| `--force` | Overwrite existing `slack-notify.sh` without prompting |
| `--uninstall` | Remove all hooks and webhook URL from settings |

## Prerequisites

- [jq](https://jqlang.github.io/jq/download/) — JSON processor
- [curl](https://curl.se/) — HTTP client
- A [Slack incoming webhook URL](https://api.slack.com/messaging/webhooks)
