#!/usr/bin/env bash
## #ddev-generated
# shellcheck shell=bash
#
# datagrip-lib/version-check.sh
# ─────────────────────────────────────────────────────────────────────────────
# Detection of the installed DataGrip version and version-to-script manifest
# lookup. Sourced by ../datagrip.
#
# Public interface:
#
#   datagrip_detect_version <platform>
#     Detects the installed DataGrip version. Sets globals:
#       _DG_DETECTED_VERSION — version string, or empty if undetectable
#       _DG_VERSION_SOURCE   — human-readable description of where it was found
#     Prints a status line when detection succeeds. Returns 0 if detected, 1
#     if not.
#
#   datagrip_find_version_script <version> <manifest_path>
#     Finds the script filename for the given version from the JSON manifest.
#     Sets global:
#       _DG_VERSION_SCRIPT — basename of the matching script (e.g. "2025.2.5.sh")
#     Returns 0 if found, 1 on error or no match.
#
# Detection strategy, stopping at the first successful version read:
#   1. JetBrains Toolbox state.json (the structured, authoritative source)
#   2. Toolbox launchCommand → product-info.json next to the binary
#   3. Well-known install paths per platform
#   4. `datagrip` binary on PATH → product-info.json walked up from there
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

# ─── Manifest parsing ────────────────────────────────────────────────────────

# Parse a flat JSON manifest {"key": "value", ...} and print "key=value" lines.
_parse_versions_manifest() {
  local manifest="$1"

  if command -v jq >/dev/null 2>&1; then
    jq -r 'to_entries[] | "\(.key)=\(.value)"' "$manifest" 2>/dev/null
    return 0
  fi

  # Fallback: match lines of the form:   "key": "value"[,]
  # Split on " gives: $1=leading ws, $2=key, $3=": ", $4=value, rest=trailing
  awk -F'"' '
    /^[[:space:]]*"[^"]*"[[:space:]]*:[[:space:]]*"[^"]*"/ {
      print $2 "=" $4
    }
  ' "$manifest"
}

# ─── Public entry points ─────────────────────────────────────────────────────

# Detect the installed DataGrip version.
# Args:
#   $1 — PLATFORM string (macos, linux, wsl, windows, unknown)
#
# Sets globals (no stdout for version — avoids subshell issues):
#   _DG_DETECTED_VERSION — detected version string, or empty
#   _DG_VERSION_SOURCE   — human-readable detection source, or empty
#
# Prints a status line when detection succeeds.
# Returns 0 if detected, 1 if not.
datagrip_detect_version() {
  local platform="$1"
  _DG_DETECTED_VERSION=""
  _DG_VERSION_SOURCE=""

  # ─── Step 1: Toolbox state.json ──────────────────────────────────────────
  local state_json
  state_json="$(_find_toolbox_state_json "$platform")"
  if [[ -n "$state_json" ]]; then
    _DG_DETECTED_VERSION="$(_extract_toolbox_version "$state_json")"
    if [[ -n "$_DG_DETECTED_VERSION" ]]; then
      _DG_VERSION_SOURCE="JetBrains Toolbox"
    else
      # ─── Step 2: state.json had a launchCommand but no parseable version ───
      local launch
      launch="$(_extract_toolbox_launch_command "$state_json")"
      if [[ -n "$launch" ]]; then
        local pi
        pi="$(_product_info_for_launch_command "$launch")"
        if [[ -n "$pi" ]]; then
          _DG_DETECTED_VERSION="$(_extract_product_info_version "$pi")"
          [[ -n "$_DG_DETECTED_VERSION" ]] && _DG_VERSION_SOURCE="Toolbox-recorded install ($pi)"
        fi
      fi
    fi
  fi

  # ─── Step 3: Well-known install paths ────────────────────────────────────
  if [[ -z "$_DG_DETECTED_VERSION" ]]; then
    while IFS= read -r path_glob; do
      [[ -z "$path_glob" ]] && continue
      # The unquoted expansion below is intentional — these patterns may
      # contain * for version directories. We loop and pick the first match.
      for path in $path_glob; do
        if [[ -f "$path" ]]; then
          _DG_DETECTED_VERSION="$(_extract_product_info_version "$path")"
          if [[ -n "$_DG_DETECTED_VERSION" ]]; then
            _DG_VERSION_SOURCE="$path"
            break 2
          fi
        fi
      done
    done < <(_well_known_install_paths "$platform")
  fi

  # ─── Step 4: datagrip binary on PATH ─────────────────────────────────────
  if [[ -z "$_DG_DETECTED_VERSION" ]] && command -v datagrip >/dev/null 2>&1; then
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
      _DG_DETECTED_VERSION="$(_extract_product_info_version "$pi")"
      [[ -n "$_DG_DETECTED_VERSION" ]] && _DG_VERSION_SOURCE="resolved from \`datagrip\` on PATH"
    fi
  fi

  if [[ -n "$_DG_DETECTED_VERSION" ]]; then
    echo "🔎 Detected DataGrip ${_DG_DETECTED_VERSION} (via ${_DG_VERSION_SOURCE})"
    return 0
  fi

  return 1
}

# Find the version-specific script filename for the given DataGrip version.
# Args:
#   $1 — DataGrip version string (e.g. "2025.2.5")
#   $2 — path to versions.json manifest
#
# Sets global:
#   _DG_VERSION_SCRIPT — script basename (e.g. "2025.2.5.sh"), or empty
#
# Matching rules:
#   - Bare version keys (e.g. "2025.2.5") act as minimum-version thresholds.
#     Among all matching bare keys (where detected >= key), the highest key wins.
#   - Keys prefixed with "<" (e.g. "<2025.2.5") match when detected < key_version.
#     These are checked only if no bare key matched.
#
# Returns 0 if a script was found, 1 on error or no match.
datagrip_find_version_script() {
  local version="$1"
  local manifest="$2"
  _DG_VERSION_SCRIPT=""

  if [[ ! -f "$manifest" ]]; then
    echo "❌ Version manifest not found: $manifest" >&2
    return 1
  fi

  local best_key=""
  local best_script=""
  local range_script=""

  while IFS='=' read -r key script; do
    [[ -z "$key" || -z "$script" ]] && continue

    if [[ "$key" == "<"* ]]; then
      # Range key: matches when detected < stripped version
      local range_ver="${key#<}"
      if ! _version_ge "$version" "$range_ver"; then
        range_script="$script"
      fi
    else
      # Bare key: matches when detected >= key; prefer the highest matching key
      if _version_ge "$version" "$key"; then
        if [[ -z "$best_key" ]] || _version_ge "$key" "$best_key"; then
          best_key="$key"
          best_script="$script"
        fi
      fi
    fi
  done < <(_parse_versions_manifest "$manifest")

  if [[ -n "$best_script" ]]; then
    _DG_VERSION_SCRIPT="$best_script"
    return 0
  fi

  if [[ -n "$range_script" ]]; then
    _DG_VERSION_SCRIPT="$range_script"
    return 0
  fi

  echo "❌ No matching entry in version manifest for DataGrip ${version}." >&2
  echo "   Check $(dirname "$manifest")/versions.json to add support for this version." >&2
  return 1
}
