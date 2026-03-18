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

| Slack Message | When | Color |
|---|---|---|
| **Task completed** | Claude finished writing/editing/running commands | Green |
| **Waiting for answer** | Claude is asking you a question | Orange |
| **Waiting for permission** | Claude needs tool approval (shows which tool) | Amber |
| **Plan ready for review** | Claude finished a plan and wants approval | Purple |
| **Session limit reached** | Session cost limit hit | Red |
| **API error** | Authentication or rate limit error | Red |
| **Subagent finished** | A spawned agent completed (disabled by default) | Gray |

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
