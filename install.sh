#!/bin/bash
# One-line installer for Claude Code Slack webhook notifications.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/ohjoonhee/claude-webhook-notification/main/install.sh | bash
#   curl -sSL ... | bash -s -- --webhook-url="https://hooks.slack.com/services/..."
#   curl -sSL ... | bash -s -- --uninstall
#   curl -sSL ... | bash -s -- --dry-run

set -euo pipefail

REPO="ohjoonhee/claude-webhook-notification"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/$REPO/$BRANCH"

# ===== Dependency check =====
for cmd in jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[install] ERROR: '$cmd' is required but not installed."
        echo ""
        case "$cmd" in
            jq)
                echo "  Install jq:"
                echo "    macOS:  brew install jq"
                echo "    Ubuntu: sudo apt install jq"
                echo "    Arch:   sudo pacman -S jq"
                ;;
            curl)
                echo "  Install curl:"
                echo "    Ubuntu: sudo apt install curl"
                ;;
        esac
        exit 1
    }
done

# ===== Pipe detection =====
# When piped (curl | bash), stdin is not a terminal — interactive prompts won't work.
# Check if --webhook-url is provided when running non-interactively.
HAS_WEBHOOK=false
IS_UNINSTALL=false
IS_DRYRUN=false
for arg in "$@"; do
    case "$arg" in
        --webhook-url=*) HAS_WEBHOOK=true ;;
        --uninstall)     IS_UNINSTALL=true ;;
        --dry-run)       IS_DRYRUN=true ;;
    esac
done

if [[ ! -t 0 ]] && ! $HAS_WEBHOOK && ! $IS_UNINSTALL && ! $IS_DRYRUN; then
    # Check if SLACK_WEBHOOK_URL is already configured
    if [[ -f "$HOME/.claude/settings.json" ]] && jq -e '.env.SLACK_WEBHOOK_URL // empty' "$HOME/.claude/settings.json" >/dev/null 2>&1; then
        : # Already configured, no need for --webhook-url
    else
        echo "[install] ERROR: Running in pipe mode without --webhook-url."
        echo ""
        echo "  Usage:"
        echo "    curl -sSL $BASE_URL/install.sh | bash -s -- --webhook-url=\"https://hooks.slack.com/services/...\""
        echo ""
        echo "  Or run interactively:"
        echo "    bash <(curl -sSL $BASE_URL/install.sh)"
        exit 1
    fi
fi

# ===== Download to temp dir =====
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[install] Downloading from $REPO..."

curl -sSfL "$BASE_URL/slack-notify.sh" -o "$TMPDIR/slack-notify.sh" || {
    echo "[install] ERROR: Failed to download slack-notify.sh"
    exit 1
}

curl -sSfL "$BASE_URL/setup-slack-hooks.sh" -o "$TMPDIR/setup-slack-hooks.sh" || {
    echo "[install] ERROR: Failed to download setup-slack-hooks.sh"
    exit 1
}

chmod +x "$TMPDIR/setup-slack-hooks.sh"

echo "[install] Running setup..."
echo ""

# ===== Run setup with forwarded args =====
bash "$TMPDIR/setup-slack-hooks.sh" "$@"
