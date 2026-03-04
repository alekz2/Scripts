#!/bin/env bash
#
# Monitors query log files for hung queries (stuck in "Waiting on results").
# Sends an email alert via mailx when a hung query is detected.
# Intended to run every 15 minutes via cron.
#
# Monitors are configured via two maps keyed by label:
#   MONITORS_FILE     label → logfile path
#   MONITORS_TRIGGER  label → comma-separated trigger patterns
#
# Usage: query_monitor.sh [-h] [-l label ...]
#   -l label   Monitor label to check (repeatable; default: all)
#
# Exit codes:
#   0 — alert sent (at least one query is hung)
#   1 — error (missing config, unknown label)
#   2 — no alert needed (all queries completed or logs are empty)
#
# Cron example:
#   */15 * * * * /path/to/query_monitor.sh -l g1
#
# Bash 4.4.2 / RHEL8 compatible.

set -euo pipefail

# --- constants ---
ALERT_THRESHOLD=900   # 15 minutes in seconds — suppress alerts for younger queries
ALERT_MAILTO=alexrivera2001@hotmail.com

# --- monitor config maps (keyed by label) ---
# MONITORS_FILE:    logfile path (relative paths resolve from script dir)
# MONITORS_TRIGGER: comma-separated trigger patterns matched in the log
declare -A MONITORS_FILE=(
    ["g1"]="./data/query.log"
    ["g2"]="./data/query_large.log"
)
declare -A MONITORS_TRIGGER=(
    ["g1"]="do_g1_query"
    ["g2"]="do_g3_query"
)

# --- globals set by check_log(), consumed by send_alert() ---
QUERY_PID=""
QUERY_TIME=""
QUERY_SQL=""
WAIT_COUNT=0
ELAPSED_SECS=0
# ============================================================
# Log analysis
# ============================================================

check_log() {
    # Reads the log in reverse (tac) so we find the LAST occurrence of our
    # trigger quickly and exit early — O(lines-from-end) instead of O(file).
    #
    # Reverse reading order: blank lines → waits → (maybe non-wait lines) → trigger.
    # Once we hit the trigger line we have everything and can exit immediately.
    local logfile=$1
    local triggers=$2       # comma-separated trigger patterns (ours)
    local all_triggers=$3   # comma-separated trigger patterns (all labels)
    local awk_result
    awk_result=$(tac "$logfile" | awk -v triggers="$triggers" -v all_triggers="$all_triggers" '
        BEGIN {
            n = split(triggers, trig, ",")
            na = split(all_triggers, all_trig, ",")
        }

        # Skip leading blank lines (trailing in original file)
        /^[[:space:]]*$/ { next }

        # Our trigger — capture details and exit immediately
        {
            for (i = 1; i <= n; i++) {
                if ($0 ~ trig[i]) {
                    match($0, /^([0-9]+): \[([0-9:]+)\]/, m)
                    pid = m[1]
                    qtime = m[2]
                    sub(".*" trig[i], "")
                    sql = $0
                    found = 1
                    exit
                }
            }
        }

        # A different trigger means our trigger is not the most recent — stop
        {
            for (i = 1; i <= na; i++) {
                if ($0 ~ all_trig[i]) { exit }
            }
        }

        # In reverse, the first non-blank content decides hung status.
        # If it is a wait line → hung.  If not → query completed.
        # Once decided, only count additional waits without changing status.
        />>> Waiting on results/ {
            waits++
            if (!decided) { last_is_wait = 1; decided = 1 }
            next
        }

        # First non-wait, non-blank line means query produced output → not hung
        !decided {
            last_is_wait = 0
            decided = 1
        }

        END {
            printf "%s\x1e%s\x1e%s\x1e%d\x1e%d", pid, qtime, sql, waits+0, (found ? last_is_wait+0 : 0)
        }
    ')

    # Parse awk output
    local IFS=$'\x1e'
    local fields
    read -ra fields <<< "$awk_result"

    QUERY_PID="${fields[0]:-}"
    QUERY_TIME="${fields[1]:-}"
    QUERY_SQL="${fields[2]:-}"
    WAIT_COUNT="${fields[3]:-0}"
    local is_hung="${fields[4]:-0}"

    # Return 0 if hung (alert needed), 1 if not
    [[ "$is_hung" -eq 1 && "$WAIT_COUNT" -gt 0 ]]
}

# ============================================================
# Elapsed time check
# ============================================================

elapsed_exceeded() {
    # Compare QUERY_TIME (HH:MM:SS) to current time.
    # Returns 0 if elapsed >= ALERT_THRESHOLD, 1 otherwise.
    # Sets ELAPSED_SECS for use in alert messages.
    [[ -z "$QUERY_TIME" ]] && return 1

    local now_epoch query_epoch
    now_epoch=$(date '+%s')
    query_epoch=$(date -d "today $QUERY_TIME" '+%s' 2>/dev/null) || return 1

    # If query_time appears in the future (edge case: log from yesterday near midnight)
    if (( query_epoch > now_epoch )); then
        query_epoch=$(( query_epoch - 86400 ))
    fi

    ELAPSED_SECS=$(( now_epoch - query_epoch ))
    (( ELAPSED_SECS >= ALERT_THRESHOLD ))
}

# ============================================================
# Email alert
# ============================================================

send_alert() {
    local recipient=$1
    local logfile=$2
    local current_host
    current_host=$(hostname)

    local elapsed_min=$(( ELAPSED_SECS / 60 ))
    local subject="ALERT: Query hung - PID ${QUERY_PID} (${elapsed_min} mins)"
    local body
    printf -v body \
"Query appears hung and has not returned results.

  Host:         %s
  PID:          %s
  Query start:  %s
  Waiting for:  %d minutes
  Wait count:   %d (and still waiting)
  SQL:          %s
  Log file:     %s
  Checked at:   %s" \
        "$current_host" \
        "$QUERY_PID" \
        "$QUERY_TIME" \
        "$elapsed_min" \
        "$WAIT_COUNT" \
        "$QUERY_SQL" \
        "$logfile" \
        "$(date '+%Y-%m-%d %H:%M:%S')"

    # echo "$body" | mailx -s "$subject" "$recipient"
    echo "$body"
    echo "Alert sent to ${recipient} — PID ${QUERY_PID} hung (${WAIT_COUNT} waits)"
}

# ============================================================
# Main
# ============================================================

main() {
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # --- argument parsing ---
    local labels=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help) usage ;;
            -l) if [[ -z "${2:-}" ]]; then
                    echo "Error: -l requires a label argument" >&2; exit 1
                fi
                labels+=("$2"); shift 2 ;;
            -*)  echo "Unknown option: $1" >&2; usage ;;
            *)   echo "Unexpected argument: $1 (use -l to specify labels)" >&2; usage ;;
        esac
    done

    # Default to all labels when none specified
    if [[ ${#labels[@]} -eq 0 ]]; then
        labels=("${!MONITORS_FILE[@]}")
    fi

    # --- validation ---
    if [[ -z "${ALERT_MAILTO:-}" ]]; then
        echo "Error: ALERT_MAILTO environment variable is required" >&2
        exit 1
    fi

    if [[ ${#MONITORS_FILE[@]} -eq 0 ]]; then
        echo "Error: MONITORS_FILE map is empty — nothing to monitor" >&2
        exit 1
    fi

    # Verify all requested labels exist in both maps before doing any work
    local label
    for label in "${labels[@]}"; do
        if [[ -z "${MONITORS_FILE[$label]+set}" ]]; then
            echo "Error: unknown label '$label'" >&2
            echo "Available labels: ${!MONITORS_FILE[*]}" >&2
            exit 1
        fi
        if [[ -z "${MONITORS_TRIGGER[$label]+set}" ]]; then
            echo "Error: label '$label' has no entry in MONITORS_TRIGGER" >&2
            exit 1
        fi
    done

    # --- collect all triggers for section boundary detection ---
    local all_triggers=""
    for label in "${!MONITORS_TRIGGER[@]}"; do
        if [[ -n "$all_triggers" ]]; then
            all_triggers+=","
        fi
        all_triggers+="${MONITORS_TRIGGER[$label]}"
    done

    # --- check each requested monitor ---
    local alerted=0
    for label in "${labels[@]}"; do
        local logfile="${MONITORS_FILE[$label]}"
        local triggers="${MONITORS_TRIGGER[$label]}"

        # Resolve relative paths against script directory
        if [[ "$logfile" != /* ]]; then
            logfile="${script_dir}/${logfile}"
        fi

        if [[ ! -f "$logfile" ]]; then
            echo "Warning: [$label] log file not found: $logfile" >&2
            continue
        fi

        if check_log "$logfile" "$triggers" "$all_triggers"; then
            if elapsed_exceeded; then
                send_alert "$ALERT_MAILTO" "$logfile"
                alerted=1
            else
                echo "OK — [$label] query waiting but under threshold ($(( ELAPSED_SECS / 60 ))m < $(( ALERT_THRESHOLD / 60 ))m)"
            fi
        else
            echo "OK — [$label] no hung query detected in ${logfile}"
        fi
    done

    if (( alerted )); then
        exit 0
    else
        exit 2
    fi
}

usage() {
    echo "Usage: $(basename "$0") [-h] [-l label ...]" >&2
    echo "  -l label   Monitor label to check (repeatable; default: all)" >&2
    if [[ ${#MONITORS_FILE[@]} -gt 0 ]]; then
        echo "" >&2
        echo "Available labels:" >&2
        local label
        for label in "${!MONITORS_FILE[@]}"; do
            echo "  $label  — triggers: ${MONITORS_TRIGGER[$label]}, logfile: ${MONITORS_FILE[$label]}" >&2
        done
    fi
    exit 1
}

main "$@"
