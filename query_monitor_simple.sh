#!/bin/env bash
#
# Simplified version of query_monitor.sh — uses bash while loop + sed
# instead of awk for log analysis.
#
# Monitors are configured via two maps keyed by label:
#   MONITORS_FILE     label → logfile path
#   MONITORS_TRIGGER  label → comma-separated trigger patterns
#
# Usage: query_monitor_simple.sh [-h] [-l label ...]
#   -l label   Monitor label to check (repeatable; default: all)
#
# Exit codes:
#   0 — alert sent (at least one query is hung)
#   1 — error (missing config, unknown label)
#   2 — no alert needed (all queries completed or logs are empty)
#
# Bash 4.2 / RHEL7 compatible.

set -euo pipefail

# --- constants ---
ALERT_THRESHOLD=900   # 15 minutes in seconds — suppress alerts for younger queries
ALERT_MAILTO=alexrivera2001@hotmail.com

# --- monitor config maps (keyed by label) ---
# MONITORS_FILE:    logfile path (relative paths resolve from script dir)
# MONITORS_TRIGGER: comma-separated trigger patterns matched in the log
declare -A MONITORS_FILE=(
    ["g1"]="./data/query.log"
    ["g2"]="./data/query.log"
)
declare -A MONITORS_TRIGGER=(
    ["g1"]="do_g1_query,do_g2_query"
    ["g2"]="do_g2_query"
)

# --- globals set by check_log(), consumed by send_alert() ---
QUERY_PID=""
QUERY_TIME=""
QUERY_SQL=""
QUERY_TRIGGER=""
WAIT_COUNT=0
ELAPSED_SECS=0
# ============================================================
# Log analysis
# ============================================================

check_log() {
    # Reads the log in reverse (tac) and processes line by line in bash.
    # Uses sed to extract PID, timestamp, and SQL from the trigger line.
    # Exits early once the trigger is found.
    local logfile=$1
    local triggers=$2       # comma-separated trigger patterns (ours)
    local all_triggers=$3   # comma-separated trigger patterns (all labels)

    # Split triggers into arrays
    local IFS=','
    local -a our_trigs=($triggers)
    local -a all_trigs=($all_triggers)
    unset IFS

    local decided=0 last_is_wait=0 waits=0 found=0
    local pid="" qtime="" sql="" matched_trig=""

    while read -r line; do
        # Skip blank lines
        [[ -z "${line// /}" ]] && continue

        # Check if line matches one of our triggers
        local trig
        for trig in "${our_trigs[@]}"; do
            if [[ "$line" == *"$trig"* ]]; then
                # Extract PID and timestamp via bash regex
                [[ "$line" =~ ^([0-9]+):\ \[([0-9:]+)\] ]] \
                    && { pid="${BASH_REMATCH[1]}"; qtime="${BASH_REMATCH[2]}"; }
                # Extract SQL — everything after the trigger pattern
                sql="${line#*"$trig"}"
                matched_trig="$trig"
                found=1
                break 2  # break out of both for and while
            fi
        done

        # Check if line matches a different trigger — end our section
        for trig in "${all_trigs[@]}"; do
            if [[ "$line" == *"$trig"* ]]; then
                break 2  # not our trigger, stop scanning
            fi
        done

        # First non-blank content decides hung status
        if [[ "$line" == *">>> Waiting on results"* ]]; then
            (( waits++ ))
            if (( !decided )); then
                last_is_wait=1
                decided=1
            fi
        elif (( !decided )); then
            last_is_wait=0
            decided=1
        fi
    done < <(tac "$logfile")

    # Set globals
    QUERY_PID="$pid"
    QUERY_TIME="$qtime"
    QUERY_TRIGGER="$matched_trig"
    QUERY_SQL="$sql"
    WAIT_COUNT="$waits"

    local is_hung=0
    if (( found )); then
        is_hung=$last_is_wait
    fi

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
  Trigger:      %s
  Query start:  %s
  Waiting for:  %d minutes
  Wait count:   %d (and still waiting)
  SQL:          %s
  Log file:     %s
  Checked at:   %s" \
        "$current_host" \
        "$QUERY_PID" \
        "$QUERY_TRIGGER" \
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
