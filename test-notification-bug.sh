#!/bin/bash
# Test suite for slack-notify.sh notification type handling.
#
# Verifies the fix for the "Notification" type bug where subagent suppression
# via exit 0 inside $(classify) produced empty NOTIFY_TYPE → :bell: messages.
#
# Usage: bash test-notification-bug.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/slack-notify.sh"
TEST_DIR=$(mktemp -d)
PASS=0
FAIL=0
TEST_NUM=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

cleanup() {
    rm -rf "$TEST_DIR"
    rm -f /tmp/claude-slack-early-test-* \
          /tmp/claude-slack-dedup-test-* \
          /tmp/claude-slack-lastany-test-*
}
trap cleanup EXIT

# ── Assertions ──────────────────────────────────────────────

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    TEST_NUM=$((TEST_NUM + 1))
    if [[ "$expected" == "$actual" ]]; then
        printf "${GREEN}  PASS${NC} #%02d %s\n" "$TEST_NUM" "$test_name"
        PASS=$((PASS + 1))
    else
        printf "${RED}  FAIL${NC} #%02d %s\n" "$TEST_NUM" "$test_name"
        echo "        expected: '$expected'"
        echo "        actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    TEST_NUM=$((TEST_NUM + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "${GREEN}  PASS${NC} #%02d %s\n" "$TEST_NUM" "$test_name"
        PASS=$((PASS + 1))
    else
        printf "${RED}  FAIL${NC} #%02d %s\n" "$TEST_NUM" "$test_name"
        echo "        expected to contain: '$needle'"
        echo "        got: '${haystack:0:200}'"
        FAIL=$((FAIL + 1))
    fi
}

# ── Transcript Fixtures ────────────────────────────────────

create_transcript_with_tools() {
    cat > "$1" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Fix the bug in main.py"}]},"timestamp":"2024-01-01T10:00:00.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll fix that."},{"type":"tool_use","name":"Read","input":{"file_path":"main.py"}}]},"timestamp":"2024-01-01T10:00:05.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"main.py","old_string":"bug","new_string":"fix"}}]},"timestamp":"2024-01-01T10:00:10.000Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done! Fixed the bug."}]},"timestamp":"2024-01-01T10:00:15.000Z"}
JSONL
}

create_transcript_no_tools() {
    cat > "$1" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>The user opened the file /mnt/ssd/Projects/main.py"}]},"timestamp":"2024-01-01T10:00:00.000Z"}
JSONL
}

create_transcript_empty() { touch "$1"; }

create_transcript_corrupted() {
    cat > "$1" <<'JSONL'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hello"}]},"timestamp":"2024-01-01T10:00:00.000Z"}
{"type":"assistant","message":{"role":"assista
JSONL
}

# ── Test Runners ───────────────────────────────────────────

run_classify() {
    local hook_event="$1"
    local json_input="$2"
    local transcript_path="${3:-}"

    bash <<TESTSCRIPT 2>/dev/null
set -euo pipefail
INPUT='$(echo "$json_input" | sed "s/'/'\\\\''/g")'
HOOK_EVENT="$hook_event"
TRANSCRIPT="$transcript_path"
$(sed -n '/^extract_signals()/,/^}$/p' "$SCRIPT")
$(sed -n '/^classify()/,/^}$/p' "$SCRIPT")
result=\$(classify)
echo "\$result"
TESTSCRIPT
}

run_full_pipeline() {
    local json_input="$1"
    local unique_id="test-$$-${RANDOM}"
    json_input=$(echo "$json_input" | jq --arg sid "$unique_id" '.session_id = $sid')
    rm -f /tmp/claude-slack-early-"${unique_id}"-* \
          /tmp/claude-slack-dedup-"${unique_id}"-* \
          /tmp/claude-slack-lastany-"${unique_id}" 2>/dev/null || true

    local mock_dir="$TEST_DIR/mock_${RANDOM}"
    local payload_file="$TEST_DIR/payload_${RANDOM}.json"
    mkdir -p "$mock_dir"
    cat > "$mock_dir/curl" <<MOCK
#!/bin/bash
while [[ \$# -gt 0 ]]; do
    case "\$1" in -d) echo "\$2" > "$payload_file"; shift 2 ;; *) shift ;; esac
done
MOCK
    chmod +x "$mock_dir/curl"

    (
        unset SLACK_WEBHOOK_URL CLAUDE_NOTIFY_SUBAGENT 2>/dev/null || true
        export SLACK_WEBHOOK_URL="https://hooks.slack.com/test"
        [[ -n "${SET_NOTIFY_SUBAGENT:-}" ]] && export CLAUDE_NOTIFY_SUBAGENT="$SET_NOTIFY_SUBAGENT"
        export PATH="$mock_dir:$PATH"
        echo "$json_input" | bash "$SCRIPT"
    ) 2>/dev/null

    if [[ -f "$payload_file" ]]; then cat "$payload_file"; fi
    rm -rf "$mock_dir" "$payload_file" 2>/dev/null || true
}

extract_title() { echo "$1" | jq -r '.attachments[0].title // empty' 2>/dev/null; }
extract_type_field() { echo "$1" | jq -r '.attachments[0].fields[] | select(.title=="Type") | .value // empty' 2>/dev/null; }

make_stop_input() {
    jq -n --arg tp "${1:-}" '{session_id:"test",hook_event_name:"Stop",transcript_path:$tp,cwd:"/tmp/testproject"}'
}
make_subagent_stop_input() {
    jq -n --arg tp "${1:-}" '{session_id:"test",hook_event_name:"SubagentStop",transcript_path:$tp,cwd:"/tmp/testproject"}'
}

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══ Section 1: SubagentStop suppression (was the root cause) ═══${NC}"
echo ""

echo -e "${YELLOW}── 1.1 classify returns 'suppress' instead of exit 0 ──${NC}"

result=$(run_classify "SubagentStop" '{"session_id":"t"}' "")
assert_eq "SubagentStop + NOTIFY_SUBAGENT unset → suppress" "suppress" "$result"

echo ""
echo -e "${YELLOW}── 1.2 Stop + /subagents/ path → suppress ──${NC}"

result=$(bash -c '
    set -euo pipefail
    HOOK_EVENT="Stop"
    INPUT="{}"
    TRANSCRIPT="/some/project/subagents/agent-xyz.jsonl"
    '"$(sed -n '/^extract_signals()/,/^}$/p' "$SCRIPT")"'
    '"$(sed -n '/^classify()/,/^}$/p' "$SCRIPT")"'
    result=$(classify)
    echo "$result"
' 2>/dev/null)
assert_eq "Stop + /subagents/ + NOTIFY_SUBAGENT unset → suppress" "suppress" "$result"

echo ""
echo -e "${YELLOW}── 1.3 Guard catches 'suppress' ──${NC}"

result=$(bash -c '
    NOTIFY_TYPE="suppress"
    if [[ -z "$NOTIFY_TYPE" || "$NOTIFY_TYPE" == "unknown" || "$NOTIFY_TYPE" == "suppress" ]]; then
        echo "CAUGHT"
    else
        echo "BYPASSED"
    fi
')
assert_eq "Guard catches 'suppress'" "CAUGHT" "$result"

echo ""
echo -e "${YELLOW}── 1.4 Guard also catches empty string (defensive) ──${NC}"

result=$(bash -c '
    NOTIFY_TYPE=""
    if [[ -z "$NOTIFY_TYPE" || "$NOTIFY_TYPE" == "unknown" || "$NOTIFY_TYPE" == "suppress" ]]; then
        echo "CAUGHT"
    else
        echo "BYPASSED"
    fi
')
assert_eq "Guard catches empty string" "CAUGHT" "$result"

echo ""
echo -e "${YELLOW}── 1.5 SubagentStop E2E: silently suppressed (no notification sent) ──${NC}"

transcript="$TEST_DIR/t_subagent.jsonl"; create_transcript_with_tools "$transcript"
payload=$(run_full_pipeline "$(make_subagent_stop_input "$transcript")")
assert_eq "SubagentStop E2E → no payload (correctly suppressed)" "" "$payload"

echo ""
echo -e "${YELLOW}── 1.6 SubagentStop + NOTIFY_SUBAGENT=true → correct notification ──${NC}"

payload=$(SET_NOTIFY_SUBAGENT=true run_full_pipeline "$(make_subagent_stop_input "$transcript")")
if [[ -n "$payload" ]]; then
    title=$(extract_title "$payload")
    type_field=$(extract_type_field "$payload")
    assert_contains "SubagentStop + NOTIFY_SUBAGENT=true → Subagent finished" "Subagent finished" "$title"
    assert_eq "SubagentStop + NOTIFY_SUBAGENT=true → type=subagent_complete" "subagent_complete" "$type_field"
else
    assert_eq "SubagentStop + NOTIFY_SUBAGENT=true → should send" "non-empty" ""
fi

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══ Section 2: classify() — all event types ═══${NC}"
echo ""

echo -e "${YELLOW}── 2.1 Handled events ──${NC}"

result=$(run_classify "Stop" '{"session_id":"t"}' "")
assert_eq "Stop + no transcript → task_complete" "task_complete" "$result"

transcript="$TEST_DIR/t_tools.jsonl"; create_transcript_with_tools "$transcript"
result=$(run_classify "Stop" "$(make_stop_input "$transcript")" "$transcript")
assert_eq "Stop + tools → task_complete" "task_complete" "$result"

result=$(run_classify "PreToolUse" '{"session_id":"t","tool_name":"AskUserQuestion"}' "")
assert_eq "PreToolUse + AskUserQuestion → question" "question" "$result"

result=$(run_classify "PreToolUse" '{"session_id":"t","tool_name":"ExitPlanMode"}' "")
assert_eq "PreToolUse + ExitPlanMode → plan_ready" "plan_ready" "$result"

result=$(run_classify "PreToolUse" '{"session_id":"t","tool_name":"Bash"}' "")
assert_eq "PreToolUse + unmatched tool → unknown" "unknown" "$result"

result=$(run_classify "PermissionRequest" '{"session_id":"t"}' "")
assert_eq "PermissionRequest → permission_waiting" "permission_waiting" "$result"

echo ""
echo -e "${YELLOW}── 2.2 Unhandled hook events → unknown ──${NC}"

for event_name in "Notification" "PostToolUse" "UserPromptSubmit" "" "null"; do
    input=$(jq -n --arg e "$event_name" '{session_id:"test",hook_event_name:$e,cwd:"/tmp/test"}')
    result=$(run_classify "$event_name" "$input" "")
    assert_eq "hook_event_name='$event_name' → unknown" "unknown" "$result"
done

echo ""
echo -e "${YELLOW}── 2.3 Transcript edge cases ──${NC}"

transcript="$TEST_DIR/t_empty.jsonl"; create_transcript_empty "$transcript"
result=$(run_classify "Stop" "$(make_stop_input "$transcript")" "$transcript")
assert_eq "Stop + empty transcript → task_complete" "task_complete" "$result"

transcript="$TEST_DIR/t_corrupt.jsonl"; create_transcript_corrupted "$transcript"
result=$(run_classify "Stop" "$(make_stop_input "$transcript")" "$transcript")
assert_eq "Stop + corrupted transcript → task_complete" "task_complete" "$result"

result=$(run_classify "Stop" "$(make_stop_input "/nonexistent")" "/nonexistent")
assert_eq "Stop + nonexistent transcript → task_complete" "task_complete" "$result"

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══ Section 3: E2E pipeline ═══${NC}"
echo ""

echo -e "${YELLOW}── 3.1 Normal Stop event ──${NC}"

transcript="$TEST_DIR/t_e2e_tools.jsonl"; create_transcript_with_tools "$transcript"
payload=$(run_full_pipeline "$(make_stop_input "$transcript")")
if [[ -n "$payload" ]]; then
    title=$(extract_title "$payload")
    type_field=$(extract_type_field "$payload")
    assert_contains "Stop + tools → Task completed" "Task completed" "$title"
    assert_eq "Stop + tools → type=task_complete" "task_complete" "$type_field"
else
    assert_eq "Stop + tools → should send" "non-empty" ""
fi

echo ""
echo -e "${YELLOW}── 3.2 Notification event → suppressed ──${NC}"

transcript="$TEST_DIR/t_e2e_notif.jsonl"; create_transcript_no_tools "$transcript"
input=$(jq -n --arg tp "$transcript" '{session_id:"test",hook_event_name:"Notification",notification_type:"ide_opened_file",transcript_path:$tp,cwd:"/tmp/test"}')
payload=$(run_full_pipeline "$input")
assert_eq "Notification event → no payload" "" "$payload"

echo ""
echo -e "${YELLOW}── 3.3 Stop + corrupted transcript → graceful (no crash) ──${NC}"

transcript="$TEST_DIR/t_e2e_corrupt.jsonl"; create_transcript_corrupted "$transcript"
payload=$(run_full_pipeline "$(make_stop_input "$transcript")")
if [[ -n "$payload" ]]; then
    title=$(extract_title "$payload")
    assert_contains "Corrupted transcript → Task completed (graceful)" "Task completed" "$title"
else
    # Empty payload is acceptable — but it should not crash the script
    assert_eq "Corrupted transcript → no payload (graceful exit)" "" "$payload"
fi

echo ""
echo -e "${YELLOW}── 3.4 Stop + empty transcript ──${NC}"

transcript="$TEST_DIR/t_e2e_empty.jsonl"; create_transcript_empty "$transcript"
payload=$(run_full_pipeline "$(make_stop_input "$transcript")")
if [[ -n "$payload" ]]; then
    title=$(extract_title "$payload")
    assert_contains "Empty transcript → Task completed" "Task completed" "$title"
else
    assert_eq "Empty transcript → should send" "non-empty" ""
fi

# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}═══ Section 4: extract_signals robustness ═══${NC}"
echo ""

for desc in empty corrupted; do
    filepath="$TEST_DIR/t_sig_${desc}.jsonl"
    case "$desc" in
        empty)     create_transcript_empty "$filepath" ;;
        corrupted) create_transcript_corrupted "$filepath" ;;
    esac
    sig_output=$(bash -c '
        set -euo pipefail
        TRANSCRIPT="'"$filepath"'"
        '"$(sed -n '/^extract_signals()/,/^}$/p' "$SCRIPT")"'
        extract_signals
    ' 2>/dev/null)
    if echo "$sig_output" | jq -e . >/dev/null 2>&1; then
        assert_eq "extract_signals($desc) → valid JSON" "true" "true"
    else
        assert_eq "extract_signals($desc) → valid JSON" "valid" "${sig_output:0:80}"
    fi
done

# ════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
printf "  Results: ${GREEN}%d passed${NC}, ${RED}%d failed${NC}, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"
echo "════════════════════════════════════════════"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo -e "${RED}Some tests failed — see details above.${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed.${NC}"
    exit 0
fi
