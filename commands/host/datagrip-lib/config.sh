#!/usr/bin/env bash
## #ddev-generated
# shellcheck shell=bash
#
# datagrip-lib/config.sh
# ─────────────────────────────────────────────────────────────────────────────
# Configuration management for ddev-datagrip. Sourced by ../datagrip.
#
# Two-file design:
#   - .ddev/datagrip/config.yaml       — project-shared, holds the UUID. Meant
#                                        to be committed so teammates share
#                                        the same DataGrip data source identity.
#   - .ddev/datagrip/.user-config.yaml — per-user preferences. Auto-gitignored.
#                                        Stores defaults like pg-pass and
#                                        default-database.
#
# Public functions:
#   datagrip_config_get_uuid                     — prints the project UUID,
#                                                  generating + persisting one
#                                                  on first call
#   datagrip_config_load_user_defaults <vars...> — populates DEFAULT_* shell
#                                                  vars from user config
#   datagrip_config_subcommand <args...>         — handles `ddev datagrip config`
#
# YAML scope: flat `key: value`. No nesting, no anchors, no multiline. The
# parser is intentionally minimal so the script doesn't depend on yq/python.
# ─────────────────────────────────────────────────────────────────────────────

# Resolved at source-time. Caller (main script) sets DDEV_APPROOT in env.
_DG_CONFIG_DIR="${DDEV_APPROOT:-.}/.ddev/datagrip"
_DG_PROJECT_CONFIG="${_DG_CONFIG_DIR}/config.yaml"
_DG_USER_CONFIG="${_DG_CONFIG_DIR}/.user-config.yaml"
_DG_GITIGNORE="${_DG_CONFIG_DIR}/.gitignore"

# Valid config keys. Keep in sync with the keys honored in the main script.
# Format: "key:type" where type is one of bool, number, string.
_DG_VALID_KEYS=(
  "pg-pass:bool"
  "default-database:string"
  "auto-refresh:number"
  "datagrip-version:string"
)

# ─── UUID generation ────────────────────────────────────────────────────────

# Generate a random UUID v4. Tries uuidgen, then /proc/sys/kernel/random/uuid,
# then a /dev/urandom + awk fallback. Outputs to stdout.
_dg_generate_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi

  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  # Portable fallback: read 16 bytes from /dev/urandom and format as UUID v4.
  # Sets the version nibble (13th hex char) to 4 and the variant nibble
  # (17th hex char) to one of 8/9/a/b per RFC 4122.
  if [[ -r /dev/urandom ]]; then
    od -An -N16 -tx1 /dev/urandom | awk '
      {
        gsub(/ /, "")
        # Version: force the 13th nibble (1-indexed) to 4
        h = substr($0, 1, 12) "4" substr($0, 14, 3)
        # Variant: force the 17th nibble to 8/9/a/b
        v_chars = "89ab"
        v_pick = substr(v_chars, (int(rand() * 4) + 1), 1)
        h = h v_pick substr($0, 18, 15)
        # Format as 8-4-4-4-12
        printf("%s-%s-%s-%s-%s\n",
          substr(h, 1, 8),
          substr(h, 9, 4),
          substr(h, 13, 4),
          substr(h, 17, 4),
          substr(h, 21, 12))
      }
    '
    return 0
  fi

  echo "❌ Could not generate a UUID: no uuidgen, no /proc/sys/kernel/random/uuid, no /dev/urandom" >&2
  return 1
}

# ─── YAML I/O ───────────────────────────────────────────────────────────────

# Read a flat key from a YAML file. Prints the value (without quotes) on
# stdout, or nothing if the key isn't present. Handles comments, blank lines,
# and optionally-quoted values. Returns 0 always — callers check empty output.
_dg_yaml_get() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0

  awk -v key="$key" '
    # Strip trailing comments (but only outside quoted values — naive
    # detection: if line starts with key, no quotes ahead, treat # as comment)
    {
      # Match: ^<spaces>key<spaces>:<spaces>value<spaces>(#comment)?$
      pattern = "^[[:space:]]*" key "[[:space:]]*:[[:space:]]*"
      if ($0 ~ pattern) {
        # Strip the key portion
        sub(pattern, "", $0)
        # Strip a trailing comment if not inside quotes
        if ($0 !~ /^["'\'']/) {
          sub(/[[:space:]]*#.*$/, "", $0)
        }
        # Trim trailing whitespace
        sub(/[[:space:]]+$/, "", $0)
        # Strip surrounding quotes if present
        if ($0 ~ /^".*"$/) {
          $0 = substr($0, 2, length($0) - 2)
        } else if ($0 ~ /^'\''.*'\''$/) {
          $0 = substr($0, 2, length($0) - 2)
        }
        print $0
        exit
      }
    }
  ' "$file"
}

# Set a key in a YAML file (creating the file if needed). If the key exists,
# its line is rewritten; otherwise it's appended. Values are quoted if they
# contain whitespace or special chars; otherwise written bare.
#
# Args: file, key, value
_dg_yaml_set() {
  local file="$1"
  local key="$2"
  local value="$3"

  # Decide whether to quote. Bools and numbers go bare; strings with anything
  # remotely special get double-quoted.
  local formatted_value
  if [[ "$value" == "true" || "$value" == "false" ]]; then
    formatted_value="$value"
  elif [[ "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    formatted_value="$value"
  else
    # Escape any embedded double quotes
    local escaped="${value//\"/\\\"}"
    formatted_value="\"${escaped}\""
  fi

  mkdir -p "$(dirname "$file")"

  if [[ ! -f "$file" ]]; then
    # New file — write a header and the single entry
    cat > "$file" <<EOF
# ddev-datagrip configuration
# Edit via 'ddev datagrip config set <key> <value>' or by hand.
${key}: ${formatted_value}
EOF
    return 0
  fi

  # Existing file — rewrite, replacing the line if found, appending if not
  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v key="$key" -v val="$formatted_value" '
    BEGIN { found = 0 }
    {
      pattern = "^[[:space:]]*" key "[[:space:]]*:"
      if ($0 ~ pattern) {
        print key ": " val
        found = 1
      } else {
        print
      }
    }
    END {
      if (!found) {
        print key ": " val
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# Remove a key from a YAML file. No-op if the key or file doesnt exist.
_dg_yaml_unset() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0

  local tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  awk -v key="$key" '
    {
      pattern = "^[[:space:]]*" key "[[:space:]]*:"
      if ($0 !~ pattern) print
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# List all key:value pairs in a YAML file (skipping comments and blanks).
# Output format: one "key=value" line per setting.
_dg_yaml_list() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*[A-Za-z][A-Za-z0-9_-]*[[:space:]]*:/ {
      # Split on first colon
      idx = index($0, ":")
      key = substr($0, 1, idx - 1)
      val = substr($0, idx + 1)
      # Trim whitespace from key and value
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      # Strip a trailing comment (naive — only outside quotes)
      if (val !~ /^["'\'']/) {
        sub(/[[:space:]]*#.*$/, "", val)
      }
      # Strip surrounding quotes
      if (val ~ /^".*"$/) {
        val = substr(val, 2, length(val) - 2)
      } else if (val ~ /^'\''.*'\''$/) {
        val = substr(val, 2, length(val) - 2)
      }
      print key "=" val
    }
  ' "$file"
}

# ─── Validation ─────────────────────────────────────────────────────────────

# Look up a key's expected type. Prints "bool", "number", "string", or empty
# if the key is unknown.
_dg_key_type() {
  local key="$1"
  for entry in "${_DG_VALID_KEYS[@]}"; do
    local k="${entry%%:*}"
    local t="${entry#*:}"
    if [[ "$k" == "$key" ]]; then
      echo "$t"
      return 0
    fi
  done
  return 1
}

# Validate a value against an expected type. Returns 0 on success; on failure
# prints an error to stderr and returns 1.
_dg_validate_value() {
  local key="$1"
  local value="$2"
  local type
  type="$(_dg_key_type "$key")" || {
    echo "❌ Unknown config key: '$key'" >&2
    echo "   Valid keys:" >&2
    for entry in "${_DG_VALID_KEYS[@]}"; do
      echo "     - ${entry%%:*}" >&2
    done
    return 1
  }

  case "$type" in
    bool)
      if [[ "$value" != "true" && "$value" != "false" ]]; then
        echo "❌ Key '$key' expects 'true' or 'false', got: '$value'" >&2
        return 1
      fi
      ;;
    number)
      if [[ ! "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        echo "❌ Key '$key' expects a number, got: '$value'" >&2
        return 1
      fi
      ;;
    string)
      # Anything is a valid string
      ;;
  esac
  return 0
}

# ─── Project config (UUID) ──────────────────────────────────────────────────

# Get the project UUID. Generates and persists one on first call. If the
# config file exists but has no UUID (manual deletion?), generates a new one
# and writes it. Output: the UUID on stdout.
datagrip_config_get_uuid() {
  local uuid
  uuid="$(_dg_yaml_get "$_DG_PROJECT_CONFIG" "uuid")"
  if [[ -n "$uuid" ]]; then
    echo "$uuid"
    return 0
  fi

  uuid="$(_dg_generate_uuid)" || return 1
  _dg_yaml_set "$_DG_PROJECT_CONFIG" "uuid" "$uuid"
  echo "$uuid"
}

# Force-regenerate the project UUID. Called on --reset. Returns the new UUID.
datagrip_config_regenerate_uuid() {
  local uuid
  uuid="$(_dg_generate_uuid)" || return 1
  _dg_yaml_set "$_DG_PROJECT_CONFIG" "uuid" "$uuid"
  echo "$uuid"
}

# ─── User config (preferences) ──────────────────────────────────────────────

# Ensure .gitignore exists in the config dir. The canonical .gitignore is
# shipped by install.yaml as a project_file (with a #ddev-generated marker),
# so in normal use this function is a no-op: the file is already there.
#
# This function only creates a fallback if the file is missing — which can
# happen if the user deleted it, or if they removed the #ddev-generated
# marker AND then deleted the file later. The fallback intentionally does
# NOT include the #ddev-generated marker, because that marker is a contract
# between DDEV and the install.yaml-shipped file. A runtime-created fallback
# isn't part of that contract and shouldn't claim to be.
_dg_ensure_gitignore() {
  mkdir -p "$_DG_CONFIG_DIR"
  if [[ -f "$_DG_GITIGNORE" ]]; then
    return 0
  fi
  cat > "$_DG_GITIGNORE" <<EOF
# Per-user preferences (set via 'ddev datagrip config set ...')
.user-config.yaml
# DataGrip schema cache and IDE state — regenerated on connect
.idea/
EOF
}

# Load user-config defaults into shell variables. The caller passes a list of
# keys to load; for each key 'foo-bar' the variable DEFAULT_FOO_BAR is set
# (if a value exists in the user config). Caller is responsible for
# initializing DEFAULT_* with hardcoded fallback values before calling this.
#
# Example:
#   DEFAULT_PG_PASS=false
#   datagrip_config_load_user_defaults pg-pass default-database auto-refresh
#   # DEFAULT_PG_PASS, DEFAULT_DEFAULT_DATABASE, DEFAULT_AUTO_REFRESH now reflect user config
datagrip_config_load_user_defaults() {
  [[ -f "$_DG_USER_CONFIG" ]] || return 0
  local key value var
  for key in "$@"; do
    value="$(_dg_yaml_get "$_DG_USER_CONFIG" "$key")"
    if [[ -n "$value" ]]; then
      # Convert hyphens to underscores, uppercase
      var="DEFAULT_$(echo "$key" | tr 'a-z-' 'A-Z_')"
      printf -v "$var" '%s' "$value"
    fi
  done
}

# ─── Subcommand handler ─────────────────────────────────────────────────────

_dg_config_help() {
  cat <<EOF
Usage: ddev datagrip config <subcommand> [args]

Subcommands:
  get <key>          Print the current value of <key>
  set <key> <value>  Set <key> to <value> in the per-user config
  unset <key>        Remove <key> from the per-user config
  list               List all configured key/value pairs
  path               Print the path to the per-user config file

Valid keys:
EOF
  for entry in "${_DG_VALID_KEYS[@]}"; do
    local k="${entry%%:*}"
    local t="${entry#*:}"
    printf "  %-32s (%s)\n" "$k" "$t"
  done
  cat <<EOF

Per-user config file:
  $_DG_USER_CONFIG

The per-user config file is automatically gitignored. Project-level
identity (the DataGrip data source UUID) lives in:
  $_DG_PROJECT_CONFIG
which IS meant to be committed so teammates share the same DataGrip identity.
EOF
}

# Main entry point for `ddev datagrip config ...`. Returns the exit code that
# the caller should propagate.
datagrip_config_subcommand() {
  local sub="${1:-}"
  shift || true

  case "$sub" in
    ""|"help"|"-h"|"--help")
      _dg_config_help
      return 0
      ;;
    get)
      local key="${1:-}"
      if [[ -z "$key" ]]; then
        echo "❌ 'config get' requires a key argument" >&2
        echo "   Usage: ddev datagrip config get <key>" >&2
        return 1
      fi
      _dg_key_type "$key" >/dev/null || {
        echo "❌ Unknown config key: '$key'" >&2
        return 1
      }
      local value
      value="$(_dg_yaml_get "$_DG_USER_CONFIG" "$key")"
      if [[ -z "$value" ]]; then
        echo "(unset)"
      else
        echo "$value"
      fi
      return 0
      ;;
    set)
      local key="${1:-}"
      local value="${2:-}"
      if [[ -z "$key" || $# -lt 2 ]]; then
        echo "❌ 'config set' requires a key and value" >&2
        echo "   Usage: ddev datagrip config set <key> <value>" >&2
        return 1
      fi
      _dg_validate_value "$key" "$value" || return 1
      _dg_yaml_set "$_DG_USER_CONFIG" "$key" "$value"
      _dg_ensure_gitignore
      echo "✓ Set $key = $value"
      return 0
      ;;
    unset)
      local key="${1:-}"
      if [[ -z "$key" ]]; then
        echo "❌ 'config unset' requires a key argument" >&2
        return 1
      fi
      _dg_key_type "$key" >/dev/null || {
        echo "❌ Unknown config key: '$key'" >&2
        return 1
      }
      _dg_yaml_unset "$_DG_USER_CONFIG" "$key"
      echo "✓ Unset $key"
      return 0
      ;;
    list)
      if [[ ! -f "$_DG_USER_CONFIG" ]]; then
        echo "(no user config set)"
        return 0
      fi
      local pairs
      pairs="$(_dg_yaml_list "$_DG_USER_CONFIG")"
      if [[ -z "$pairs" ]]; then
        echo "(no user config set)"
      else
        echo "$pairs"
      fi
      return 0
      ;;
    path)
      echo "$_DG_USER_CONFIG"
      return 0
      ;;
    *)
      echo "❌ Unknown config subcommand: '$sub'" >&2
      echo "" >&2
      _dg_config_help >&2
      return 1
      ;;
  esac
}
