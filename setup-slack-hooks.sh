#!/bin/bash
# Setup script for Claude Code Slack notification hooks.
# Safely injects hook configuration into ~/.claude/settings.json
# and copies slack-notify.sh into ~/.claude/scripts/.
#
# Usage:
#   bash setup-slack-hooks.sh                      # Interactive setup
#   bash setup-slack-hooks.sh --webhook-url=URL     # Non-interactive with URL
#   bash setup-slack-hooks.sh --dry-run             # Show changes without writing
#   bash setup-slack-hooks.sh --uninstall           # Remove hooks
#   bash setup-slack-hooks.sh --force               # Overwrite slack-notify.sh without prompt
#
# Requires: jq

set -euo pipefail

# ===== CONFIG =====
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SCRIPTS_DIR="$CLAUDE_DIR/scripts"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="bash ~/.claude/scripts/slack-notify.sh"
NOTIFY_SCRIPT="slack-notify.sh"

# ===== PARSE ARGS =====
DRY_RUN=false
UNINSTALL=false
FORCE=false
WEBHOOK_URL=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)        DRY_RUN=true ;;
        --uninstall)      UNINSTALL=true ;;
        --force)          FORCE=true ;;
        --webhook-url=*)  WEBHOOK_URL="${arg#*=}" ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown option: $arg (use --help for usage)"
            exit 1
            ;;
    esac
done

# ===== HELPERS =====

log()  { echo "[setup] $*"; }
warn() { echo "[setup] WARNING: $*" >&2; }
die()  { echo "[setup] ERROR: $*" >&2; exit 1; }

check_deps() {
    command -v jq >/dev/null 2>&1 || die "jq is required but not installed. Install it first."
    command -v curl >/dev/null 2>&1 || die "curl is required but not installed. Install it first."
}

backup_settings() {
    if [[ -f "$SETTINGS" ]]; then
        local backup="${SETTINGS}.bak.$(date +%s)"
        cp "$SETTINGS" "$backup"
        log "Backed up settings.json to $(basename "$backup")"
        echo "$backup"
    fi
}

validate_json() {
    local file="$1"
    local backup="${2:-}"
    if ! jq -e . "$file" >/dev/null 2>&1; then
        if [[ -n "$backup" && -f "$backup" ]]; then
            cp "$backup" "$file"
            die "JSON validation failed after modification. Restored backup."
        else
            die "Invalid JSON in $file"
        fi
    fi
}

has_hook() {
    local event="$1"
    jq -e ".hooks.${event}[]?.hooks[]? | select(.command == \"$HOOK_CMD\")" "$SETTINGS" >/dev/null 2>&1
}

has_env() {
    local key="$1"
    jq -e ".env.${key} // empty" "$SETTINGS" >/dev/null 2>&1
}

# Add a hook entry to a given event type.
# $1 = event name (e.g., "Stop")
# $2 = matcher (e.g., "" or "AskUserQuestion|ExitPlanMode")
add_hook() {
    local event="$1"
    local matcher="$2"
    local hook_entry
    hook_entry=$(jq -n \
        --arg matcher "$matcher" \
        --arg cmd "$HOOK_CMD" \
        '{matcher: $matcher, hooks: [{type: "command", command: $cmd}]}')

    local tmp
    tmp=$(mktemp)
    jq --argjson entry "$hook_entry" \
        ".hooks //= {} | .hooks.${event} //= [] | .hooks.${event} += [\$entry]" \
        "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

remove_hooks() {
    local tmp
    tmp=$(mktemp)
    # Remove any hook entry whose command matches HOOK_CMD from all event types
    jq --arg cmd "$HOOK_CMD" '
      if .hooks then
        .hooks |= with_entries(
          .value |= map(
            .hooks |= map(select(.command != $cmd))
          )
          | .value |= map(select((.hooks | length) > 0))
        )
        | if .hooks | to_entries | all(.value | length == 0) then del(.hooks) else . end
      else .
      end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

remove_env() {
    local tmp
    tmp=$(mktemp)
    jq 'if .env.SLACK_WEBHOOK_URL then del(.env.SLACK_WEBHOOK_URL) else . end
        | if .env and (.env | length == 0) then del(.env) else . end' \
        "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
}

# ===== UNINSTALL =====

do_uninstall() {
    if [[ ! -f "$SETTINGS" ]]; then
        log "No settings.json found. Nothing to uninstall."
        exit 0
    fi

    validate_json "$SETTINGS"

    if ! has_hook "Stop" && ! has_hook "PermissionRequest" && ! has_hook "PreToolUse" && ! has_hook "SubagentStop"; then
        log "No slack-notify hooks found. Nothing to uninstall."
        exit 0
    fi

    if $DRY_RUN; then
        log "[dry-run] Would remove all slack-notify.sh hooks from settings.json"
        log "[dry-run] Would remove SLACK_WEBHOOK_URL from env (if present)"
        log "[dry-run] Would NOT delete ~/.claude/scripts/slack-notify.sh (manual cleanup)"
        exit 0
    fi

    local backup
    backup=$(backup_settings)

    remove_hooks
    remove_env
    validate_json "$SETTINGS" "$backup"

    log "Removed all slack-notify hooks from settings.json"
    log "Backup available at: $(basename "$backup")"
    log "Note: ~/.claude/scripts/slack-notify.sh was NOT deleted. Remove manually if desired."
}

# ===== MAIN =====

check_deps

if $UNINSTALL; then
    do_uninstall
    exit 0
fi

# --- 1. Ensure directories ---
if $DRY_RUN; then
    [[ ! -d "$CLAUDE_DIR" ]] && log "[dry-run] Would create $CLAUDE_DIR"
    [[ ! -d "$SCRIPTS_DIR" ]] && log "[dry-run] Would create $SCRIPTS_DIR"
else
    mkdir -p "$SCRIPTS_DIR"
fi

# --- 2. Copy slack-notify.sh ---
SOURCE_SCRIPT="$SCRIPT_DIR/$NOTIFY_SCRIPT"
DEST_SCRIPT="$SCRIPTS_DIR/$NOTIFY_SCRIPT"

if [[ ! -f "$SOURCE_SCRIPT" ]]; then
    die "$NOTIFY_SCRIPT not found in $SCRIPT_DIR. Place it next to this setup script."
fi

if [[ -f "$DEST_SCRIPT" ]] && ! $FORCE; then
    if $DRY_RUN; then
        log "[dry-run] $NOTIFY_SCRIPT already exists at $DEST_SCRIPT (use --force to overwrite)"
    elif ! cmp -s "$SOURCE_SCRIPT" "$DEST_SCRIPT"; then
        echo ""
        echo "  $DEST_SCRIPT already exists and differs from source."
        read -rp "  Overwrite? [y/N] " answer
        if [[ "$answer" =~ ^[Yy] ]]; then
            cp "$SOURCE_SCRIPT" "$DEST_SCRIPT"
            chmod +x "$DEST_SCRIPT"
            log "Overwritten $NOTIFY_SCRIPT"
        else
            log "Kept existing $NOTIFY_SCRIPT"
        fi
    else
        log "$NOTIFY_SCRIPT already up to date"
    fi
elif $DRY_RUN; then
    log "[dry-run] Would copy $NOTIFY_SCRIPT to $SCRIPTS_DIR/"
else
    cp "$SOURCE_SCRIPT" "$DEST_SCRIPT"
    chmod +x "$DEST_SCRIPT"
    log "Copied $NOTIFY_SCRIPT to $SCRIPTS_DIR/"
fi

# --- 3. Create or validate settings.json ---
if [[ ! -f "$SETTINGS" ]]; then
    if $DRY_RUN; then
        log "[dry-run] Would create $SETTINGS with empty structure"
    else
        echo '{}' > "$SETTINGS"
        log "Created $SETTINGS"
    fi
fi

if ! $DRY_RUN; then
    validate_json "$SETTINGS"
fi

# --- 4. Backup settings.json ---
BACKUP=""
if [[ -f "$SETTINGS" ]] && ! $DRY_RUN; then
    BACKUP=$(backup_settings)
fi

# --- 5. Inject hooks ---
get_matcher() {
    case "$1" in
        PreToolUse) echo "AskUserQuestion|ExitPlanMode" ;;
        *)          echo "" ;;
    esac
}

HOOKS_ADDED=0
HOOKS_SKIPPED=0

for event in Stop PermissionRequest PreToolUse SubagentStop; do
    matcher=$(get_matcher "$event")

    if $DRY_RUN; then
        if [[ -f "$SETTINGS" ]] && has_hook "$event"; then
            log "[dry-run] $event: already configured (skip)"
            HOOKS_SKIPPED=$((HOOKS_SKIPPED + 1))
        else
            log "[dry-run] $event: would add hook (matcher: '${matcher:-<none>}')"
            HOOKS_ADDED=$((HOOKS_ADDED + 1))
        fi
        continue
    fi

    if has_hook "$event"; then
        log "$event: already configured (skip)"
        HOOKS_SKIPPED=$((HOOKS_SKIPPED + 1))
    else
        add_hook "$event" "$matcher"
        log "$event: added hook"
        HOOKS_ADDED=$((HOOKS_ADDED + 1))
    fi
done

# --- 6. Ensure SLACK_WEBHOOK_URL in env ---
WEBHOOK_ADDED=false

if $DRY_RUN; then
    if [[ -f "$SETTINGS" ]] && has_env "SLACK_WEBHOOK_URL"; then
        log "[dry-run] SLACK_WEBHOOK_URL: already set (skip)"
    elif [[ -n "$WEBHOOK_URL" ]]; then
        log "[dry-run] SLACK_WEBHOOK_URL: would set to ${WEBHOOK_URL:0:30}..."
    else
        log "[dry-run] SLACK_WEBHOOK_URL: would prompt for URL"
    fi
else
    if has_env "SLACK_WEBHOOK_URL"; then
        log "SLACK_WEBHOOK_URL: already set (skip)"
    else
        # Prompt if not provided via flag
        if [[ -z "$WEBHOOK_URL" ]]; then
            echo ""
            read -rp "  Enter your Slack webhook URL: " WEBHOOK_URL
            echo ""
        fi

        if [[ -z "$WEBHOOK_URL" ]]; then
            warn "No webhook URL provided. You can set it later in settings.json under env.SLACK_WEBHOOK_URL"
        else
            local_tmp=$(mktemp)
            jq --arg url "$WEBHOOK_URL" '.env //= {} | .env.SLACK_WEBHOOK_URL = $url' \
                "$SETTINGS" > "$local_tmp" && mv "$local_tmp" "$SETTINGS"
            log "SLACK_WEBHOOK_URL: configured"
            WEBHOOK_ADDED=true
        fi
    fi
fi

# --- 7. Final validation ---
if ! $DRY_RUN && [[ -f "$SETTINGS" ]]; then
    validate_json "$SETTINGS" "$BACKUP"
fi

# --- 8. Summary ---
echo ""
echo "==============================="
if $DRY_RUN; then
    echo "  Dry run complete"
else
    echo "  Setup complete"
fi
echo "==============================="
echo "  Hooks added:   $HOOKS_ADDED"
echo "  Hooks skipped: $HOOKS_SKIPPED (already configured)"
if [[ -n "$BACKUP" ]]; then
    echo "  Backup:        $(basename "$BACKUP")"
fi
echo ""

if ! $DRY_RUN && [[ $HOOKS_ADDED -gt 0 || "$WEBHOOK_ADDED" == "true" ]]; then
    echo "  Restart Claude Code for changes to take effect."
    echo ""
fi
