#!/usr/bin/env bash

## #ddev-generated: If you want to edit and own this file, remove this line.

# shellcheck shell=bash
#
# datagrip-lib/version-check.sh

datagrip_autorefresh() {
    set -euo pipefail

    COLUMNS=$(tput cols)
    echo ""
    title="Configure AutoRefresh with LivePlugin?"
    printf "%*s\n" $(((${#title}+$COLUMNS)/2)) "$title"
    printf "%*s" "$COLUMNS" | tr ' ' '-'
    echo "LivePlugin allows for creating lightweight plugins in JetBrains IDEs without requiring a full Plugin SDK setup."
    echo "This Add-On ships with a LivePlugin plugin that can immediately auto-refresh a data source when DataGrip is opened."
    echo "For more info, check out https://github.com/natereprogle/ddev-datagrip/#initial-data-refresh"
    echo ""
    prompt="Would you like to install the LivePlugin plugin? (y/N) "
    echo -n "$prompt"

    read -r -t 30 -n 1 reply || reply="n"
    echo

    reply="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"

    if [[ "$reply" != "y" ]]; then
        echo "Skipping LivePlugin installation."
        exit 0
    fi

    if ! command -v datagrip >/dev/null 2>&1; then
        echo "Warning: 'datagrip' command not found. Is the launcher script in your PATH?"
        echo "You can install the LivePlugin plugin manually from the Plugins menu or by running 'ddev datagrip autorefresh'."
        exit 2
    fi

    pattern='DataGrip|datagrip'

    snapshot_pids() {
        pgrep -f "$pattern" 2>/dev/null \
        | grep -v "^$$$" \
        | sort -u \
        || true
    }

    before="$(snapshot_pids)"

    datagrip installPlugins LivePlugin >/dev/null 2>&1 &
    launcher_pid=$!

    spinner=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )
    i=0

    spin_for_seconds() {
        local duration="$1"
        local start="$SECONDS"

        while (( SECONDS - start < duration )); do
        printf "\rInstalling LivePlugin... %s" "${spinner[i++ % ${#spinner[@]}]}"
        sleep 0.1
        done
    }

    # Give the launcher time to spawn detached DataGrip processes.
    spin_for_seconds 1

    after="$(snapshot_pids)"

    new_pids="$(
        comm -13 \
        <(printf '%s\n' "$before" | sed '/^$/d' | sort -u) \
        <(printf '%s\n' "$after"  | sed '/^$/d' | sort -u) \
        || true
    )"

    tracked_pids="$(printf '%s\n%s\n' "$launcher_pid" "$new_pids" | sed '/^$/d' | sort -u)"

    launcher_exit_status=""
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
        if wait "$launcher_pid" 2>/dev/null; then
        launcher_exit_status=0
        else
        launcher_exit_status=$?
        fi
    fi

    if [[ -z "$new_pids" && "${launcher_exit_status:-0}" != "0" ]]; then
        printf "\rInstalling LivePlugin... failed.   \n"
        echo "Could not launch DataGrip to install the LivePlugin plugin."
        echo "Please install the LivePlugin plugin manually from the Plugins menu."
        exit 2
    fi

    # If DataGrip detached too quickly for us to reliably track it,
    # keep the spinner up briefly as a fallback.
    if [[ -z "$new_pids" ]]; then
        fallback_until=$((SECONDS + 10))
    else
        fallback_until=0
    fi

    any_alive() {
        local pid

        while read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -0 "$pid" 2>/dev/null && return 0
        done <<< "$tracked_pids"

        return 1
    }

    while any_alive || (( SECONDS < fallback_until )); do
        printf "\rInstalling LivePlugin... %s" "${spinner[i++ % ${#spinner[@]}]}"
        sleep 0.1
    done

    wait "$launcher_pid" 2>/dev/null || true

    printf "\rInstalling LivePlugin... done.   \n"
}