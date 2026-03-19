#!/bin/bash
# Enhanced Slack webhook notification for Claude Code hook events.
# Classifies notifications into 8 distinct types with smart deduplication.
# Requires: jq, curl
#
# Environment Variables:
#   SLACK_WEBHOOK_URL          - (required) Slack webhook URL
#   CLAUDE_NOTIFY_SUBAGENT     - (optional) Send subagent notifications: "true"|"false" (default: false)
#   CLAUDE_QUESTION_COOLDOWN   - (optional) Seconds to suppress question after any notification (default: 10)
#   CLAUDE_VSCODE_SCHEME       - URI scheme: "vscode"|"cursor"|"vscodium" (default: vscode)
#   CLAUDE_VSCODE_REMOTE_HOST  - SSH host alias (required for SSH remote sessions)
#   CLAUDE_VSCODE_REMOTE_TYPE  - Force type: "local"|"ssh"|"wsl"|"container"

set -euo pipefail

# ===== UTILITIES =====

build_vscode_link() {
    local path="$1"
    local scheme="${CLAUDE_VSCODE_SCHEME:-vscode}"
    local remote_type="${CLAUDE_VSCODE_REMOTE_TYPE:-}"
    local remote_host="${CLAUDE_VSCODE_REMOTE_HOST:-}"

    if [[ -z "$remote_type" ]]; then
        if [[ -f /proc/version ]] && grep -qi microsoft /proc/version 2>/dev/null; then
            remote_type="wsl"
        elif [[ -f /.dockerenv ]] || [[ -n "${REMOTE_CONTAINERS:-}" ]]; then
            remote_type="container"
        elif [[ -n "${SSH_CONNECTION:-}" ]] || [[ -n "${SSH_CLIENT:-}" ]]; then
            remote_type="ssh"
        else
            remote_type="local"
        fi
    fi

    case "$remote_type" in
        local)     echo "${scheme}://file${path}" ;;
        ssh)       [[ -n "$remote_host" ]] && echo "${scheme}://vscode-remote/ssh-remote+${remote_host}${path}" ;;
        wsl)       echo "${scheme}://vscode-remote/wsl+${WSL_DISTRO_NAME:-Ubuntu}${path}" ;;
        container) : ;;
    esac
}

escape_mrkdwn() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    echo "$text"
}

truncate_sentence() {
    local text="$1"
    local max="${2:-150}"
    if [[ ${#text} -le $max ]]; then
        echo "$text"
        return
    fi
    # Try to cut at first sentence boundary within limit
    local cut="${text:0:$max}"
    if [[ "$cut" =~ ^(.+\.)\ .* ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "${cut}..."
    fi
}

clean_text() {
    # Strip markdown, collapse whitespace, trim
    tr '\n' ' ' | sed 's/```[^`]*```//g; s/`[^`]*`//g; s/\*\*//g; s/\*//g; s/^[[:space:]]*//; s/[[:space:]]*$//; s/  */ /g'
}

# ===== DEDUPLICATION =====

check_early_dedup() {
    local lock_file="/tmp/claude-slack-early-${SESSION_ID}-${HOOK_EVENT}"
    local now="$NOW"
    local last
    last=$(cat "$lock_file" 2>/dev/null || echo 0)
    if (( now - last < 2 )); then
        return 1  # duplicate
    fi
    echo "$now" > "$lock_file"
    return 0
}

check_content_dedup() {
    local content="$1"
    local hash
    hash=$(echo -n "$content" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | md5 -q 2>/dev/null || echo -n "$content" | tr '[:upper:]' '[:lower:]' | tr -s ' ' | md5sum 2>/dev/null | cut -d' ' -f1)
    local dedup_file="/tmp/claude-slack-dedup-${SESSION_ID}-${hash}"
    local now="$NOW"
    local last
    last=$(cat "$dedup_file" 2>/dev/null || echo 0)
    if (( now - last < 180 )); then
        return 1  # duplicate
    fi
    echo "$now" > "$dedup_file"
    return 0
}

check_question_cooldown() {
    local cooldown="${CLAUDE_QUESTION_COOLDOWN:-10}"
    local last_any_file="/tmp/claude-slack-lastany-${SESSION_ID}"
    local last_any
    last_any=$(cat "$last_any_file" 2>/dev/null || echo 0)
    if (( NOW - last_any < cooldown )); then
        return 1  # suppress
    fi
    return 0
}

update_last_notification() {
    echo "$NOW" > "/tmp/claude-slack-lastany-${SESSION_ID}"
}

# ===== CLASSIFICATION =====

extract_signals() {
    # Single jq call to extract all classification signals from transcript tail
    tail -60 "$TRANSCRIPT" 2>/dev/null | jq -rs '
      def is_active: . as $t | ["Write","Edit","Bash","NotebookEdit","SlashCommand","KillShell"] | any(. == $t);

      # Session limit: last 3 assistant text messages
      ([.[] | select(.type=="assistant" or .message.role=="assistant")
        | .message.content[]? | select(.type=="text") | .text] | .[-3:]
        | any(test("session.*limit.*reached|session cost limit"; "i"))) as $session_limit |

      # API error
      (any(.[]; .isApiErrorMessage == true)) as $api_error |

      # Tools after last user text message
      (
        ([to_entries[] | select(
          (.value.type=="user" or .value.message.role=="user") and
          ((.value.message.content | type) == "string" or (.value.message.content[]? | .type == "text"))
        ) | .key] | last // -1) as $last_user_idx |
        [.[$last_user_idx + 1:][]
          | select(.type=="assistant" or .message.role=="assistant")
          | .message.content[]? | select(.type=="tool_use") | .name] | .[-15:]
      ) as $recent_tools |

      {
        session_limit: $session_limit,
        api_error: $api_error,
        recent_tools: $recent_tools,
        last_tool: ($recent_tools | last // null),
        has_active: ($recent_tools | any(is_active)),
        has_plan: ($recent_tools | any(. == "ExitPlanMode")),
        tool_count: ($recent_tools | length)
      }
    ' 2>/dev/null || echo '{"session_limit":false,"api_error":false,"recent_tools":[],"last_tool":null,"has_active":false,"has_plan":false,"tool_count":0}'
}

classify() {
    case "$HOOK_EVENT" in
        PreToolUse)
            local tool_name
            tool_name=$(echo "$INPUT" | jq -r '.tool_name // ""')
            case "$tool_name" in
                ExitPlanMode)      echo "plan_ready" ;;
                AskUserQuestion)   echo "question" ;;
                *)                 echo "unknown" ;;
            esac
            ;;
        PermissionRequest)
            echo "permission_waiting"
            ;;
        SubagentStop)
            if [[ "${CLAUDE_NOTIFY_SUBAGENT:-false}" != "true" ]]; then echo "suppress"; return; fi
            echo "subagent_complete"
            ;;
        Stop)
            # Detect subagent via transcript path
            if [[ "$TRANSCRIPT" == */subagents/* ]]; then
                if [[ "${CLAUDE_NOTIFY_SUBAGENT:-false}" != "true" ]]; then echo "suppress"; return; fi
                echo "subagent_complete"
                return
            fi

            # No transcript or file missing → can't analyze, default to task_complete
            if [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]]; then
                echo "task_complete"
                return
            fi

            local signals
            signals=$(extract_signals)

            local session_limit api_error last_tool has_active has_plan tool_count
            session_limit=$(echo "$signals" | jq -r '.session_limit // false')
            api_error=$(echo "$signals" | jq -r '.api_error // false')
            last_tool=$(echo "$signals" | jq -r '.last_tool // ""')
            has_active=$(echo "$signals" | jq -r '.has_active // false')
            has_plan=$(echo "$signals" | jq -r '.has_plan // false')
            tool_count=$(echo "$signals" | jq -r '.tool_count // 0')

            if [[ "$session_limit" == "true" ]]; then echo "session_limit"; return; fi
            if [[ "$api_error" == "true" ]]; then echo "api_error"; return; fi
            if [[ "$last_tool" == "ExitPlanMode" ]]; then echo "plan_ready"; return; fi
            if [[ "$last_tool" == "AskUserQuestion" ]]; then echo "question"; return; fi
            if [[ "$has_plan" == "true" && "$has_active" == "true" ]]; then echo "task_complete"; return; fi
            if [[ "$has_active" == "true" ]]; then echo "task_complete"; return; fi
            if (( ${tool_count%%[^0-9]*} > 0 )); then echo "task_complete"; return; fi
            echo "task_complete"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# ===== SUMMARY EXTRACTION =====

extract_summary() {
    local notify_type="$1"

    case "$notify_type" in
        question)
            # PreToolUse: extract from tool_input directly
            local q
            q=$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // empty' 2>/dev/null)
            if [[ -z "$q" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                # Stop fallback: find AskUserQuestion in transcript
                q=$(tail -30 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="tool_use" and .name=="AskUserQuestion")
                    | .input.questions[0].question] | last // empty
                ' 2>/dev/null)
            fi
            if [[ -z "$q" ]]; then
                # Try last_assistant_message from hook input
                q=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
            fi
            if [[ -z "$q" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                # Further fallback: shortest text with "?"
                q=$(tail -30 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="text") | .text
                    | select(contains("?"))]
                  | sort_by(length) | first // empty
                ' 2>/dev/null)
            fi
            echo "${q:-Claude needs your input to continue.}" | clean_text | cut -c1-200
            ;;

        permission_waiting)
            # Extract what tool needs permission from transcript
            local pending_info
            if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                pending_info=$(tail -30 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="tool_use")
                    | {name, detail: (
                        if .name == "Bash" then (.input.command // "" | .[0:100])
                        elif .name == "Write" then (.input.file_path // "")
                        elif .name == "Edit" then (.input.file_path // "")
                        elif .name == "Read" then (.input.file_path // "")
                        else ""
                        end
                      )}
                  ] | last // {name: "a tool", detail: ""}
                ' 2>/dev/null)
                local tool_name tool_detail
                tool_name=$(echo "$pending_info" | jq -r '.name // "a tool"')
                tool_detail=$(echo "$pending_info" | jq -r '.detail // ""')
                if [[ -n "$tool_detail" ]]; then
                    echo "Needs permission to run: ${tool_name}(${tool_detail})"
                else
                    echo "Needs permission to run: ${tool_name}"
                fi
            else
                echo "Waiting for permission approval."
            fi
            ;;

        plan_ready)
            # PreToolUse: extract from tool_input directly
            local plan
            plan=$(echo "$INPUT" | jq -r '.tool_input.plan // empty' 2>/dev/null)
            if [[ -z "$plan" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                plan=$(tail -30 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="tool_use" and .name=="ExitPlanMode")
                    | .input.plan] | last // empty
                ' 2>/dev/null)
            fi
            if [[ -n "$plan" ]]; then
                # Take first non-empty line
                echo "$plan" | grep -m1 '.' | clean_text | cut -c1-200
            else
                echo "Plan is ready for review."
            fi
            ;;

        task_complete)
            # Primary: use last_assistant_message from hook input (always available on Stop)
            local msg
            msg=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
            # Fallback: parse transcript (use tail -30 to skip progress/system entries)
            if [[ -z "$msg" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                msg=$(tail -30 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="text") | .text] | last // empty
                ' 2>/dev/null)
            fi
            msg="${msg:-Task completed.}"
            echo "$msg" | clean_text | { read -r line; truncate_sentence "$line" 150; }
            ;;

        subagent_complete)
            # SubagentStop provides last_assistant_message directly
            local msg
            msg=$(echo "$INPUT" | jq -r '.last_assistant_message // empty' 2>/dev/null)
            if [[ -z "$msg" && -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
                msg=$(tail -10 "$TRANSCRIPT" | jq -rs '
                  [.[] | select(.type=="assistant" or .message.role=="assistant")
                    | .message.content[]? | select(.type=="text") | .text] | last // ""
                ' 2>/dev/null)
            fi
            echo "${msg:-Subagent task finished.}" | clean_text | cut -c1-150
            ;;

        session_limit)
            echo "Session limit reached. Start a new session to continue."
            ;;

        api_error)
            echo "API error occurred. Check authentication or rate limits."
            ;;

        *)
            echo "Notification from Claude Code."
            ;;
    esac
}

# ===== ACTIONS SUMMARY =====

generate_actions() {
    [[ -z "$TRANSCRIPT" || ! -f "$TRANSCRIPT" ]] && return

    local counts
    counts=$(tail -60 "$TRANSCRIPT" 2>/dev/null | jq -rs '
      ([to_entries[] | select(
        (.value.type=="user" or .value.message.role=="user") and
        ((.value.message.content | type) == "array") and
        (.value.message.content[]? | .type == "text")
      ) | .key] | last // -1) as $idx |
      [.[$idx + 1:][] | select(.type=="assistant" or .message.role=="assistant")
        | .message.content[]? | select(.type=="tool_use") | .name] |
      {
        writes: [.[] | select(. == "Write")] | length,
        edits: [.[] | select(. == "Edit")] | length,
        bash: [.[] | select(. == "Bash")] | length,
        reads: [.[] | select(. == "Read" or . == "Grep" or . == "Glob")] | length
      }
    ' 2>/dev/null) || return

    local writes edits bash_count reads parts=()
    writes=$(echo "$counts" | jq -r '.writes')
    edits=$(echo "$counts" | jq -r '.edits')
    bash_count=$(echo "$counts" | jq -r '.bash')
    reads=$(echo "$counts" | jq -r '.reads')

    [[ "${writes:-0}" -gt 0 ]] && parts+=("${writes} new")
    [[ "${edits:-0}" -gt 0 ]] && parts+=("${edits} edits")
    [[ "${bash_count:-0}" -gt 0 ]] && parts+=("${bash_count} cmds")
    [[ "${reads:-0}" -gt 0 ]] && parts+=("${reads} reads")

    # Duration from last user message to last assistant message
    local duration
    duration=$(tail -60 "$TRANSCRIPT" 2>/dev/null | jq -rs '
      def parse_ts: if . then (split(".")[0] + "Z" | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) else 0 end;
      ([.[] | select((.type=="user" or .message.role=="user") and
        ((.message.content | type) == "array") and
        (.message.content[]? | .type == "text"))
        | .timestamp] | last // null) as $start |
      ([.[] | select(.type=="assistant" or .message.role=="assistant") | .timestamp] | last // null) as $end |
      if $start and $end then (($end | parse_ts) - ($start | parse_ts)) else null end
    ' 2>/dev/null) || true

    if [[ -n "$duration" && "$duration" != "null" && "${duration:-0}" -gt 0 ]]; then
        if [[ "$duration" -lt 60 ]]; then
            parts+=("${duration}s")
        else
            local mins=$((duration / 60))
            local secs=$((duration % 60))
            parts+=("${mins}m ${secs}s")
        fi
    fi

    if [[ ${#parts[@]} -gt 0 ]]; then
        local IFS=", "
        echo "${parts[*]}"
    fi
}

# ===== NOTIFICATION FORMAT =====

format_notification() {
    local notify_type="$1"
    case "$notify_type" in
        task_complete)
            EMOJI=":white_check_mark:"
            COLOR="#36a64f"
            TYPE_TITLE="Task completed"
            ;;
        question)
            EMOJI=":question:"
            COLOR="#ff9500"
            TYPE_TITLE="Waiting for answer"
            ;;
        permission_waiting)
            EMOJI=":raised_hand:"
            COLOR="#e67e22"
            TYPE_TITLE="Waiting for permission"
            ;;
        plan_ready)
            EMOJI=":clipboard:"
            COLOR="#9b59b6"
            TYPE_TITLE="Plan ready for review"
            ;;
        session_limit)
            EMOJI=":warning:"
            COLOR="#e74c3c"
            TYPE_TITLE="Session limit reached"
            ;;
        api_error)
            EMOJI=":x:"
            COLOR="#e74c3c"
            TYPE_TITLE="API error"
            ;;
        subagent_complete)
            EMOJI=":robot_face:"
            COLOR="#95a5a6"
            TYPE_TITLE="Subagent finished"
            ;;
        *)
            EMOJI=":bell:"
            COLOR="#808080"
            TYPE_TITLE="Notification"
            ;;
    esac
}

# ===== MAIN =====

INPUT=$(cat)

[[ -z "${SLACK_WEBHOOK_URL:-}" ]] && exit 0
echo "$INPUT" | jq -e . >/dev/null 2>&1 || exit 0

# Parse common fields
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "global"')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "Stop"')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
NOW=$(date +%s)

# Layer 1: Early dedup (2s lockout per session+event)
check_early_dedup || exit 0

# Classification
NOTIFY_TYPE=$(classify)
[[ -z "$NOTIFY_TYPE" || "$NOTIFY_TYPE" == "unknown" || "$NOTIFY_TYPE" == "suppress" ]] && exit 0

# Question/permission cooldown (suppress if any notification was sent recently)
if [[ "$NOTIFY_TYPE" == "question" || "$NOTIFY_TYPE" == "permission_waiting" ]]; then
    check_question_cooldown || exit 0
fi

# Extract summary
SUMMARY=$(extract_summary "$NOTIFY_TYPE")

# Layer 2: Content-based dedup (180s window)
check_content_dedup "${NOTIFY_TYPE}:${SUMMARY}" || exit 0

# Extract task context (first user message)
TASK=""
if [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]]; then
    TASK=$(jq -rs '[.[] | select(.type=="user" or .message.role=="user") | .message.content | if type == "string" then . elif type == "array" then ([.[]? | select(.type=="text") | .text] | first) else null end] | map(select(. != null)) | first // empty' "$TRANSCRIPT" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-150 || true)
fi

# Actions summary
ACTIONS=$(generate_actions)

# Build message body
PROJECT_DIR=$(echo "$INPUT" | jq -r '.cwd // empty')
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_NAME=$(basename "$PROJECT_DIR")

# Format notification
format_notification "$NOTIFY_TYPE"
TITLE="${EMOJI} ${PROJECT_NAME} — ${TYPE_TITLE}"
VSCODE_LINK=$(build_vscode_link "$PROJECT_DIR")
SCHEME="${CLAUDE_VSCODE_SCHEME:-vscode}"

TASK_SAFE=$(escape_mrkdwn "$TASK")
SUMMARY_SAFE=$(escape_mrkdwn "$SUMMARY")

DESC=""
[[ -n "$TASK_SAFE" ]] && DESC="*Task:* ${TASK_SAFE}"$'\n\n'
DESC+="*Response:* ${SUMMARY_SAFE}"
[[ -n "$VSCODE_LINK" ]] && DESC+=$'\n\n'"<${VSCODE_LINK}|:computer: Open in ${SCHEME}>"

# Build fields array
FIELDS="["
FIELDS+="{\"title\":\"Project\",\"value\":$(echo "$PROJECT_NAME" | jq -Rs .),\"short\":true},"
FIELDS+="{\"title\":\"Type\",\"value\":$(echo "$NOTIFY_TYPE" | jq -Rs .),\"short\":true}"
if [[ -n "$ACTIONS" ]]; then
    FIELDS+=",{\"title\":\"Actions\",\"value\":$(echo "$ACTIONS" | jq -Rs .),\"short\":false}"
fi
FIELDS+="]"

PAYLOAD=$(jq -n \
    --arg title "$TITLE" \
    --arg desc "$DESC" \
    --arg color "$COLOR" \
    --argjson ts "$NOW" \
    --argjson fields "$FIELDS" \
    '{attachments: [{
        color: $color,
        title: $title,
        text: $desc,
        fields: $fields,
        ts: $ts,
        mrkdwn_in: ["text", "fields"]
    }]}')

curl -sS -X POST -H "Content-Type: application/json" -d "$PAYLOAD" --max-time 10 "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true

# Update dedup state
update_last_notification
