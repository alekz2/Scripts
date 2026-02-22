#!/usr/bin/env bash

command_not_found_handle() {
    cn "$1"
}

# connects to host using data from ecthosts.json
cn() {
    local input="${1,,}"  # lowercase entire argument

    if [[ ! "$input" =~ ^([a-z]+)([pb])([0-9]+)$ ]]; then
        echo "Usage: cn <APP><p|b><NUM>  (e.g. 'cn abcp1' = ABC prod host1, 'cn abcb2' = ABC bcp host2)"
        return 1
    fi

    local app="${BASH_REMATCH[1]^^}"   # uppercase: abc -> ABC
    local env_char="${BASH_REMATCH[2]}"
    local host_num="${BASH_REMATCH[3]}"

    local env
    case "$env_char" in
        p) env="prod" ;;
        b) env="bcp"  ;;
    esac

    local json_file="${ECT_HOSTS_FILE:-$(dirname "${BASH_SOURCE[0]}")/ecthosts.json}"

    if [[ ! -f "$json_file" ]]; then
        echo "Error: hosts file not found: $json_file" >&2
        return 1
    fi

    # Validate app exists in JSON
    if ! jq -e --arg app "$app" '.[$app]' "$json_file" > /dev/null 2>&1; then
        echo "Error: app '$app' not found. Available: $(jq -r 'keys | join(", ")' "$json_file")" >&2
        return 1
    fi

    # Validate env exists (excluding 'dirs' key)
    if ! jq -e --arg app "$app" --arg env "$env" '.[$app].hosts[$env]' "$json_file" > /dev/null 2>&1; then
        echo "Error: env '$env' not found for '$app'. Available: $(jq -r --arg app "$app" '.[$app].hosts | keys | map(select(. != "dirs")) | join(", ")' "$json_file")" >&2
        return 1
    fi

    # Get host (0-based index = host_num - 1)
    local idx=$(( host_num - 1 ))
    local host
    host=$(jq -r --arg app "$app" --arg env "$env" --argjson idx "$idx" \
        '.[$app].hosts[$env][$idx] // empty' "$json_file")

    if [[ -z "$host" ]]; then
        local max
        max=$(jq -r --arg app "$app" --arg env "$env" '.[$app].hosts[$env] | length' "$json_file")
        echo "Error: host index $host_num out of range (1-$max)" >&2
        return 1
    fi

    echo "Connecting: $app $env host${host_num} -> $host"
    # ssh "$host"
}

main(){
    cn abcb2
}

main
