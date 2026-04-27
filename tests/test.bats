#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs
#
# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure
#
# CI target: ubuntu-latest. Tests assume Linux paths and tools (uuidgen, awk,
# mktemp, /proc/sys/kernel/random/uuid). They are NOT expected to pass on macOS
# without adjustments to the Toolbox state.json path.

# ═══════════════════════════════════════════════════════════════════════════
#  Setup / teardown
# ═══════════════════════════════════════════════════════════════════════════

setup() {
  set -eu -o pipefail

  export GITHUB_REPO=natereprogle/ddev-datagrip

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p ~/tmp
  export TESTDIR=$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true

  # Override HOME so anything the script writes there (~/.pgpass, fake Toolbox
  # state.json, etc.) lands in the test sandbox instead of the runner's home.
  # ddev itself reads $HOME/.ddev/, but we don't depend on any pre-existing
  # global ddev config.
  export REAL_HOME="$HOME"
  export HOME="$TESTDIR/home"
  mkdir -p "$HOME"

  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site
  assert_success
  run ddev start -y
  assert_success

  # Fake `datagrip` binary on PATH. Captures the args it was called with so
  # tests can verify launch-time behavior. Uses a tab-stripping heredoc so the
  # shebang lands on the first column.
  cat > "${TESTDIR}/datagrip" <<-'EOF'
	#!/bin/bash
	echo "datagrip stub called with: $*" > "${TESTDIR}/datagrip-launch.log"
	echo "datagrip"
EOF
  chmod +x "${TESTDIR}/datagrip"
  export PATH="${TESTDIR}:${PATH}"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy ${PROJNAME} >/dev/null 2>&1 || true
  # Restore real HOME so any post-teardown bats internals don't get confused.
  if [[ -n "${REAL_HOME:-}" ]]; then
    export HOME="$REAL_HOME"
  fi
  [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
}

# ─── Helpers ────────────────────────────────────────────────────────────────

# Install the add-on from the local repo into the current ddev project.
install_addon() {
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
}

# Reconfigure the project to use Postgres instead of the default MySQL.
# Used by tests that exercise the pg-pass codepath. Adds noticeable runtime
# (a full restart), so only call when needed.
switch_to_postgres() {
  run ddev config --database=postgres:16
  assert_success
  run ddev restart -y
  assert_success
}

# The original health check — runs the command and asserts it exits cleanly.
health_checks() {
  run ddev datagrip
  assert_success
}

# Path to the project's idea/datasources XML.
datasources_xml_path() {
  echo "${TESTDIR}/.ddev/datagrip/.idea/dataSources.xml"
}

datasources_local_xml_path() {
  echo "${TESTDIR}/.ddev/datagrip/.idea/dataSources.local.xml"
}

# Path to the project-shared config (UUID lives here).
project_config_path() {
  echo "${TESTDIR}/.ddev/datagrip/config.yaml"
}

# Path to the per-user config.
user_config_path() {
  echo "${TESTDIR}/.ddev/datagrip/.user-config.yaml"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Install / smoke tests (preserved from original)
# ═══════════════════════════════════════════════════════════════════════════

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  install_addon
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  health_checks
}

# ═══════════════════════════════════════════════════════════════════════════
#  XML output tests
# ═══════════════════════════════════════════════════════════════════════════

@test "datasources.xml is written with the project UUID" {
  install_addon
  run ddev datagrip
  assert_success

  # Both XML files should exist
  assert_file_exists "$(datasources_xml_path)"
  assert_file_exists "$(datasources_local_xml_path)"

  # Project config should exist with a UUID line
  assert_file_exists "$(project_config_path)"
  run grep -E '^uuid:' "$(project_config_path)"
  assert_success

  # Extract the UUID from config.yaml and assert it appears in dataSources.xml.
  # The yaml stores the value quoted, so strip surrounding quotes.
  uuid_in_config="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  [[ -n "$uuid_in_config" ]]
  run grep -F "$uuid_in_config" "$(datasources_xml_path)"
  assert_success
  run grep -F "$uuid_in_config" "$(datasources_local_xml_path)"
  assert_success
}

@test "uuid is RFC 4122 v4 format" {
  install_addon
  run ddev datagrip
  assert_success

  uuid="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  # 8-4-4-4-12 hex, version nibble 4, variant nibble 8/9/a/b
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

@test "uuid persists across runs" {
  install_addon

  run ddev datagrip
  assert_success
  uuid_first="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"

  run ddev datagrip
  assert_success
  uuid_second="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"

  [[ "$uuid_first" == "$uuid_second" ]]
}

@test "--reset regenerates the uuid" {
  install_addon

  run ddev datagrip
  assert_success
  uuid_before="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"

  run ddev datagrip --reset
  assert_success
  uuid_after="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"

  [[ "$uuid_before" != "$uuid_after" ]]
  # New UUID should be in the (rewritten) XML files
  run grep -F "$uuid_after" "$(datasources_xml_path)"
  assert_success
}

# ═══════════════════════════════════════════════════════════════════════════
#  Config subcommand tests
# ═══════════════════════════════════════════════════════════════════════════

@test "config list shows '(no user config set)' when nothing is set" {
  install_addon
  run ddev datagrip config list
  assert_success
  assert_output --partial "(no user config set)"
}

@test "config set writes a value and config get reads it back" {
  install_addon

  run ddev datagrip config set pg-pass true
  assert_success
  assert_output --partial "Set pg-pass = true"

  run ddev datagrip config get pg-pass
  assert_success
  assert_output --partial "true"

  # The user-config file should exist
  assert_file_exists "$(user_config_path)"
}

@test "config set creates a .gitignore excluding the user config" {
  install_addon

  run ddev datagrip config set pg-pass true
  assert_success

  gitignore="${TESTDIR}/.ddev/datagrip/.gitignore"
  assert_file_exists "$gitignore"
  run grep -F ".user-config.yaml" "$gitignore"
  assert_success
}

@test "config set rejects unknown keys" {
  install_addon

  run ddev datagrip config set nope-key foo
  assert_failure
  assert_output --partial "Unknown config key"
}

@test "config set rejects invalid bool values" {
  install_addon

  run ddev datagrip config set pg-pass yes
  assert_failure
  assert_output --partial "expects 'true' or 'false'"
}

@test "config set rejects invalid number values" {
  install_addon

  run ddev datagrip config set auto-refresh fast
  assert_failure
  assert_output --partial "expects a number"
}

@test "config unset removes a key" {
  install_addon

  run ddev datagrip config set default-database mydb
  assert_success

  run ddev datagrip config get default-database
  assert_success
  assert_output --partial "mydb"

  run ddev datagrip config unset default-database
  assert_success

  run ddev datagrip config get default-database
  assert_success
  assert_output --partial "(unset)"
}

@test "config list shows multiple set values" {
  install_addon

  run ddev datagrip config set pg-pass true
  assert_success
  run ddev datagrip config set default-database mydb
  assert_success
  run ddev datagrip config set auto-refresh 2
  assert_success

  run ddev datagrip config list
  assert_success
  assert_output --partial "pg-pass=true"
  assert_output --partial "default-database=mydb"
  assert_output --partial "auto-refresh=2"
}

@test "config path prints the per-user config file path" {
  install_addon

  run ddev datagrip config path
  assert_success
  assert_output --partial ".user-config.yaml"
}

@test "config with no subcommand prints help" {
  install_addon

  run ddev datagrip config
  assert_success
  assert_output --partial "Usage: ddev datagrip config"
  assert_output --partial "Valid keys:"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Defaults flow / --no-defaults
# ═══════════════════════════════════════════════════════════════════════════

@test "default-database from config affects the JDBC URL" {
  install_addon

  run ddev datagrip config set default-database custom_db
  assert_success

  run ddev datagrip
  assert_success

  # The JDBC URL in dataSources.xml should reference custom_db
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_success
}

@test "--no-defaults bypasses user config" {
  install_addon

  run ddev datagrip config set default-database custom_db
  assert_success

  # Without --no-defaults, custom_db should be used
  run ddev datagrip
  assert_success
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_success

  # With --no-defaults, the hardcoded fallback "db" should be used
  run ddev datagrip --no-defaults
  assert_success
  run grep -F "/db?" "$(datasources_xml_path)"
  assert_success
  # And the custom value should NOT appear
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_failure
}

@test "explicit --database flag wins over config default" {
  install_addon

  run ddev datagrip config set default-database custom_db
  assert_success

  # --database should override the config
  run ddev datagrip --database flag_db
  assert_success
  run grep -F "/flag_db" "$(datasources_xml_path)"
  assert_success
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_failure
}

# ═══════════════════════════════════════════════════════════════════════════
#  Postgres + pg-pass
#
#  The three postgres assertion groups are merged into one test to amortize
#  the project-restart cost (~30-60s per restart on free-tier CI). Cleanup
#  between groups is explicit: each group resets ~/.pgpass and the user
#  config so the next group's assertions are meaningful.
#
#  The non-postgres test (which doesn't trigger a restart) stays separate
#  because merging it in wouldn't save runtime and would muddy the failure
#  diagnostics.
# ═══════════════════════════════════════════════════════════════════════════

@test "pg-pass: postgres project — flag, config-driven, and --no-defaults bypass" {
  install_addon
  switch_to_postgres

  # ─── Group 1: --pg-pass flag writes to $HOME/.pgpass ──────────────────
  # The script writes to $HOME/.pgpass; setup() overrode HOME so this is
  # the sandbox HOME, not the runner's real home.
  run ddev datagrip --pg-pass
  assert_success
  assert_file_exists "$HOME/.pgpass"
  run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
  assert_success

  # Cleanup before next group: reset pgpass and config to a clean slate.
  # Note: this means each group is treated as "first use" by the script,
  # so the .pgpass.bak creation message will fire each time. We don't
  # assert on that message, only on the contents of .pgpass, so it's fine.
  rm -f "$HOME/.pgpass" "$HOME/.pgpass.bak"
  rm -f "$(user_config_path)"

  # ─── Group 2: config-set pg-pass=true triggers pgpass without flag ────
  run ddev datagrip config set pg-pass true
  assert_success

  run ddev datagrip
  assert_success
  assert_file_exists "$HOME/.pgpass"
  run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
  assert_success

  # Cleanup: keep the config (we want pg-pass=true for the next group)
  # but clear the pgpass file so we can verify it does NOT get rewritten.
  rm -f "$HOME/.pgpass" "$HOME/.pgpass.bak"

  # ─── Group 3: --no-defaults bypasses config-driven pgpass ─────────────
  # pg-pass=true is still in the user config from group 2. With
  # --no-defaults, the config should be ignored and pgpass not written.
  run ddev datagrip --no-defaults
  assert_success

  # File either doesn't exist or doesn't contain our project. Either is OK.
  if [[ -f "$HOME/.pgpass" ]]; then
    run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
    assert_failure
  fi
}

@test "pg-pass on non-postgres project warns and is a no-op" {
  install_addon
  # Default project is mysql — don't switch

  run ddev datagrip --pg-pass
  assert_success
  assert_output --partial "--pg-pass cannot be used without a Postgres DB"

  # No pgpass file should have been written
  assert_file_not_exists "$HOME/.pgpass"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Version check
#
#  The host command runs on the host machine, NOT inside a container. ddev
#  spawns it with the host's environment, but we still need to be careful
#  about where it looks for state.json. Our setup() overrides HOME, so a
#  fake state.json placed under $HOME/.local/share/JetBrains/Toolbox/ will
#  be picked up by the version-check helper's Linux path lookup.
# ═══════════════════════════════════════════════════════════════════════════

# Helper: write a fake Toolbox state.json with the given DataGrip version.
write_fake_toolbox_state_json() {
  local version="$1"
  local toolbox_dir="$HOME/.local/share/JetBrains/Toolbox"
  mkdir -p "$toolbox_dir"
  cat > "$toolbox_dir/state.json" <<EOF
{
  "tools": [
    {
      "channelId": "datagrip-test",
      "toolId": "datagrip",
      "productCode": "DB",
      "displayName": "DataGrip",
      "displayVersion": "${version}",
      "buildNumber": "999.999.999",
      "installLocation": "/fake/path/DataGrip",
      "launchCommand": "/fake/path/DataGrip/bin/datagrip"
    }
  ]
}
EOF
}

@test "version check detects DataGrip from fake Toolbox state.json" {
  install_addon
  write_fake_toolbox_state_json "2099.1.2"

  run ddev datagrip
  assert_success
  assert_output --partial "Detected DataGrip 2099.1.2"
  assert_output --partial "JetBrains Toolbox"
}

@test "version check falls back gracefully when no state.json exists" {
  install_addon
  # No fake state.json, no product-info.json on disk, no real DataGrip.
  # The check should print "Unable to check" and continue.
  run ddev datagrip
  assert_success
  assert_output --partial "Unable to check installed DataGrip version"
}

# Source the version-check library directly and run unit-style tests against
# the comparison logic. Avoids the cost of a full ddev round-trip.
@test "version check unit: comparison handles 2024.10 vs 2024.2 correctly" {
  install_addon

  # Source the helper directly. SCRIPT_DIR is the helper dir; we need to
  # source from the installed location inside .ddev/.
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"

  # 2024.10 should be greater than 2024.2 (the lexicographic trap)
  _version_ge "2024.10" "2024.2"
  assert_equal "$?" "0"

  # Reverse: 2024.2 should NOT be greater than or equal to 2024.10
  run _version_ge "2024.2" "2024.10"
  assert_failure
}

@test "version check unit: EAP suffix is stripped before comparing" {
  install_addon
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"

  # "2026.1 EAP" should compare equal to "2026.1"
  _version_ge "2026.1 EAP" "2026.1"
  assert_equal "$?" "0"
  _version_ge "2026.1" "2026.1 EAP"
  assert_equal "$?" "0"
}

@test "version check unit: detects too-old version with controlled minimum" {
  install_addon
  write_fake_toolbox_state_json "2020.1"

  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"

  # Run the public entry point directly with a minimum the fake version
  # doesn't satisfy. Should return 2.
  run datagrip_version_check "2024.1" "false" "linux"
  assert_failure
  [[ "$status" == "2" ]]
  assert_output --partial "older than the minimum"
}

@test "version check unit: --ignore-unsupported-versions bypasses block" {
  install_addon
  write_fake_toolbox_state_json "2020.1"

  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"

  # With ignore=true, even a too-old version should pass through
  run datagrip_version_check "2024.1" "true" "linux"
  assert_success
  assert_output --partial "but --ignore-unsupported-versions was passed"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Removal
# ═══════════════════════════════════════════════════════════════════════════

@test "removal cleans up datagrip-lib directory" {
  install_addon

  # Directory exists after install
  assert_dir_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib"

  run ddev add-on remove datagrip
  assert_success

  # Both the main script and the lib directory should be gone
  assert_file_not_exists "${TESTDIR}/.ddev/commands/host/datagrip"
  assert_dir_not_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib"
  # Runtime data should also be gone
  assert_dir_not_exists "${TESTDIR}/.ddev/datagrip"
}
