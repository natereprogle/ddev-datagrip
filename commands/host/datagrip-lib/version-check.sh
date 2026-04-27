#!/usr/bin/env bash
# shellcheck shell=bash
#
# datagrip-lib/version-check.sh
# ─────────────────────────────────────────────────────────────────────────────
# Best-effort detection of the installed DataGrip version, with comparison
# against a hardcoded minimum. Sourced by ../datagrip.
#
# This file is meant to be `source`d, not executed. It exposes:
#
#   datagrip_version_check <minimum_version> <ignore_flag>
#     Prints status messages. Returns:
#       0 — version is OK, or could not be determined (best-effort), or the
#           caller passed --ignore-unsupported-versions
#       2 — version was determined and is below minimum
#
# Detection strategy, stopping at the first successful version read:
#   1. JetBrains Toolbox state.json (the structured, authoritative source)
#   2. Toolbox launchCommand → product-info.json next to the binary
#   3. Well-known install paths per platform
#   4. `datagrip` binary on PATH → product-info.json walked up from there
#
# Falls back silently with an informational message if nothing is found.
# ─────────────────────────────────────────────────────────────────────────────

# ─── JSON extraction ────────────────────────────────────────────────────────
#
# We don't require jq. If it's available, great — we use it. If not, we use
# a small awk parser that handles the specific shapes we need (a flat object
# with a "version" key, or an array of objects where one has toolId=datagrip).
#
# These parsers are NOT general-purpose JSON parsers. They assume:
#   - One key/value per line OR pretty-printed JSON (which is what JetBrains
#     and most tools emit)
#   - String values are double-quoted
#   - No deeply nested escaped quotes inside the keys we care about
# Both conditions hold for state.json and product-info.json.

# Extract a top-level "version" field from a product-info.json file.
# Output: the version string on stdout, or empty if not found.
_extract_product_info_version() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.version // empty' "$file" 2>/dev/null
    return 0
  fi

  # Fallback: grep the line, awk out the value between the second pair of quotes.
  awk -F'"' '/"version"[[:space:]]*:/ { print $4; exit }' "$file"
}

# Extract DataGrip's displayVersion from a Toolbox state.json file.
# Output: the version string on stdout, or empty if not found.
_extract_toolbox_version() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.tools[]? | select(.toolId == "datagrip") | .displayVersion // empty' "$file" 2>/dev/null | head -n1
    return 0
  fi

  # Fallback parser: scan the file looking for a tool object whose toolId is
  # "datagrip", then find the displayVersion within that object's bounds.
  # This is brittle if Toolbox ever changes the field order, but state.json
  # has been stable for years.
  awk '
    /"toolId"[[:space:]]*:[[:space:]]*"datagrip"/ { in_dg = 1 }
    in_dg && /"displayVersion"[[:space:]]*:/ {
      # The value is between the third and fourth double quote on this line.
      n = split($0, a, "\"")
      if (n >= 4) {
        print a[4]
        exit
      }
    }
    in_dg && /\}/ { in_dg = 0 }
  ' "$file"
}

# Extract the launchCommand from Toolbox state.json for DataGrip. Used when
# we have state.json but need the binary path to find product-info.json next
# to it.
_extract_toolbox_launch_command() {
  local file="$1"
  [[ -f "$file" ]] || return 1

  if command -v jq >/dev/null 2>&1; then
    jq -r '.tools[]? | select(.toolId == "datagrip") | .launchCommand // empty' "$file" 2>/dev/null | head -n1
    return 0
  fi

  awk '
    /"toolId"[[:space:]]*:[[:space:]]*"datagrip"/ { in_dg = 1 }
    in_dg && /"launchCommand"[[:space:]]*:/ {
      n = split($0, a, "\"")
      if (n >= 4) {
        print a[4]
        exit
      }
    }
    in_dg && /\}/ { in_dg = 0 }
  ' "$file"
}

# ─── Path discovery ─────────────────────────────────────────────────────────

# Echo the path to Toolbox's state.json for the current platform, or empty
# if no candidate exists. $1 is the PLATFORM string from the parent script.
_find_toolbox_state_json() {
  local platform="$1"
  local candidates=()

  case "$platform" in
    macos)
      candidates+=("$HOME/Library/Application Support/JetBrains/Toolbox/state.json")
      ;;
    linux)
      # XDG default, then Toolbox's own override env var if set.
      candidates+=("${XDG_DATA_HOME:-$HOME/.local/share}/JetBrains/Toolbox/state.json")
      [[ -n "${TOOLBOX_DIR:-}" ]] && candidates+=("$TOOLBOX_DIR/state.json")
      ;;
    wsl)
      # We're on WSL but DataGrip lives on the Windows side. Find the
      # Windows username via cmd.exe rather than guessing from $USER.
      local win_user
      win_user="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')"
      if [[ -n "$win_user" ]]; then
        candidates+=("/mnt/c/Users/${win_user}/AppData/Local/JetBrains/Toolbox/state.json")
      fi
      ;;
    windows)
      # Git Bash / MSYS / Cygwin. $LOCALAPPDATA is set on Windows.
      [[ -n "${LOCALAPPDATA:-}" ]] && candidates+=("$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)/JetBrains/Toolbox/state.json")
      [[ -n "${USERPROFILE:-}" ]] && candidates+=("$(cygpath -u "$USERPROFILE" 2>/dev/null)/AppData/Local/JetBrains/Toolbox/state.json")
      ;;
  esac

  for path in "${candidates[@]}"; do
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  done
  return 1
}

# Given a path to a DataGrip launch command (binary, .app, or .sh), return the
# path to the product-info.json that should accompany it. The file lives in
# different places depending on install style:
#
#   macOS .app:    DataGrip.app/Contents/Resources/product-info.json
#   Linux tarball: /opt/datagrip/product-info.json (sibling of bin/)
#   Windows:       C:\Program Files\JetBrains\DataGrip-N\product-info.json
_product_info_for_launch_command() {
  local launch="$1"
  [[ -n "$launch" ]] || return 1

  # macOS .app bundle: walk up to find Contents/Resources/product-info.json
  if [[ "$launch" == *".app/"* || "$launch" == *".app" ]]; then
    local app_root="${launch%.app/*}.app"
    [[ "$launch" == *".app" ]] && app_root="$launch"
    local candidate="${app_root}/Contents/Resources/product-info.json"
    [[ -f "$candidate" ]] && { echo "$candidate"; return 0; }
  fi

  # Linux/Windows: product-info.json sits one level above bin/
  local dir
  dir="$(dirname "$launch")"
  # Walk up at most 3 levels looking for product-info.json
  for _ in 1 2 3; do
    if [[ -f "${dir}/product-info.json" ]]; then
      echo "${dir}/product-info.json"
      return 0
    fi
    dir="$(dirname "$dir")"
    [[ "$dir" == "/" || -z "$dir" ]] && break
  done
  return 1
}

# Return a list of well-known DataGrip install paths to probe for
# product-info.json, one per line. $1 is the PLATFORM string.
_well_known_install_paths() {
  local platform="$1"
  case "$platform" in
    macos)
      cat <<EOF
/Applications/DataGrip.app/Contents/Resources/product-info.json
$HOME/Applications/DataGrip.app/Contents/Resources/product-info.json
/opt/homebrew/Caskroom/datagrip/*/DataGrip.app/Contents/Resources/product-info.json
/usr/local/Caskroom/datagrip/*/DataGrip.app/Contents/Resources/product-info.json
EOF
      ;;
    linux)
      cat <<EOF
/opt/datagrip/product-info.json
/opt/DataGrip/product-info.json
/usr/share/datagrip/product-info.json
$HOME/.local/share/JetBrains/Toolbox/apps/datagrip/*/product-info.json
/snap/datagrip/current/product-info.json
/var/lib/flatpak/app/com.jetbrains.DataGrip/current/active/files/product-info.json
$HOME/.local/share/flatpak/app/com.jetbrains.DataGrip/current/active/files/product-info.json
EOF
      ;;
    wsl)
      local win_user
      win_user="$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')"
      if [[ -n "$win_user" ]]; then
        cat <<EOF
/mnt/c/Program Files/JetBrains/DataGrip*/product-info.json
/mnt/c/Users/${win_user}/AppData/Local/Programs/DataGrip/product-info.json
/mnt/c/Users/${win_user}/AppData/Local/JetBrains/Toolbox/apps/datagrip/*/product-info.json
EOF
      fi
      ;;
    windows)
      [[ -n "${PROGRAMFILES:-}" ]] && echo "$(cygpath -u "$PROGRAMFILES" 2>/dev/null)/JetBrains/DataGrip*/product-info.json"
      [[ -n "${LOCALAPPDATA:-}" ]] && echo "$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)/Programs/DataGrip/product-info.json"
      [[ -n "${LOCALAPPDATA:-}" ]] && echo "$(cygpath -u "$LOCALAPPDATA" 2>/dev/null)/JetBrains/Toolbox/apps/datagrip/*/product-info.json"
      ;;
  esac
}

# ─── Version comparison ─────────────────────────────────────────────────────

# Compare two version strings of the form "YYYY.N[.M]". Returns:
#   0 if $1 >= $2
#   1 if $1 <  $2
#
# Missing trailing segments are treated as 0 (so 2026.1 >= 2026.1.0).
# EAP suffixes ("2026.1 EAP") are stripped — only the leading version token
# is considered. Non-numeric segments after stripping cause a 0 result on
# that segment, which is conservative (treats weird input as "older").
_version_ge() {
  awk -v a="$1" -v b="$2" '
    BEGIN {
      # Strip trailing whitespace / EAP markers.
      sub(/[[:space:]].*$/, "", a)
      sub(/[[:space:]].*$/, "", b)

      na = split(a, A, ".")
      nb = split(b, B, ".")
      max = (na > nb) ? na : nb

      for (i = 1; i <= max; i++) {
        ai = (i <= na) ? A[i] + 0 : 0
        bi = (i <= nb) ? B[i] + 0 : 0
        if (ai > bi) { exit 0 }
        if (ai < bi) { exit 1 }
      }
      exit 0  # equal
    }
  '
}

# ─── Public entry point ─────────────────────────────────────────────────────

# Run the version check.
# Args:
#   $1 — minimum required version (e.g. "2024.1")
#   $2 — "true" if --ignore-unsupported-versions was passed, else "false"
#   $3 — PLATFORM string (macos, linux, wsl, windows, unknown)
#
# Returns:
#   0 — proceed (version OK, undetectable, or ignore flag set)
#   2 — abort (version below minimum)
datagrip_version_check() {
  local min_version="$1"
  local ignore="$2"
  local platform="$3"
  local detected_version=""
  local detection_source=""

  # ─── Step 1: Toolbox state.json ────────────────────────────────────────
  local state_json
  state_json="$(_find_toolbox_state_json "$platform")"
  if [[ -n "$state_json" ]]; then
    detected_version="$(_extract_toolbox_version "$state_json")"
    if [[ -n "$detected_version" ]]; then
      detection_source="JetBrains Toolbox"
    else
      # ─── Step 2: state.json had a launchCommand but no version we could parse ─
      local launch
      launch="$(_extract_toolbox_launch_command "$state_json")"
      if [[ -n "$launch" ]]; then
        local pi
        pi="$(_product_info_for_launch_command "$launch")"
        if [[ -n "$pi" ]]; then
          detected_version="$(_extract_product_info_version "$pi")"
          [[ -n "$detected_version" ]] && detection_source="Toolbox-recorded install ($pi)"
        fi
      fi
    fi
  fi

  # ─── Step 3: Well-known install paths ──────────────────────────────────
  if [[ -z "$detected_version" ]]; then
    while IFS= read -r path_glob; do
      [[ -z "$path_glob" ]] && continue
      # The unquoted expansion below is intentional — these patterns may
      # contain * for version directories. We loop and pick the first match.
      for path in $path_glob; do
        if [[ -f "$path" ]]; then
          detected_version="$(_extract_product_info_version "$path")"
          if [[ -n "$detected_version" ]]; then
            detection_source="$path"
            break 2
          fi
        fi
      done
    done < <(_well_known_install_paths "$platform")
  fi

  # ─── Step 4: datagrip binary on PATH ───────────────────────────────────
  if [[ -z "$detected_version" ]] && command -v datagrip >/dev/null 2>&1; then
    local bin_path
    bin_path="$(command -v datagrip)"
    # Resolve symlinks (Toolbox shims, Homebrew shims) to find the real binary.
    if command -v readlink >/dev/null 2>&1; then
      local resolved
      resolved="$(readlink -f "$bin_path" 2>/dev/null || echo "$bin_path")"
      [[ -n "$resolved" ]] && bin_path="$resolved"
    fi
    local pi
    pi="$(_product_info_for_launch_command "$bin_path")"
    if [[ -n "$pi" ]]; then
      detected_version="$(_extract_product_info_version "$pi")"
      [[ -n "$detected_version" ]] && detection_source="resolved from \`datagrip\` on PATH"
    fi
  fi

  # ─── Decision ──────────────────────────────────────────────────────────
  if [[ -z "$detected_version" ]]; then
    echo "ℹ️  Unable to check installed DataGrip version, continuing..."
    return 0
  fi

  echo "🔎 Detected DataGrip ${detected_version} (via ${detection_source})"

  if _version_ge "$detected_version" "$min_version"; then
    return 0
  fi

  if [[ "$ignore" == "true" ]]; then
    echo "⚠️  DataGrip ${detected_version} is older than the minimum supported version (${min_version}), but --ignore-unsupported-versions was passed. Continuing."
    return 0
  fi

  echo "❌ DataGrip ${detected_version} is older than the minimum supported version (${min_version})."
  echo "   This add-on may work but hasn't been tested below the minimum."
  echo "   To run anyway, rerun the command with --ignore-unsupported-versions"
  return 2
}
