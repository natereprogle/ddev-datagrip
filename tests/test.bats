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
#
# ─── Performance design ──────────────────────────────────────────────────────
# Heavy operations (ddev config, ddev start, add-on install) happen ONCE in
# setup_file rather than per-test. Per-test setup() does only fast cleanup
# (rm of a few files) so each test starts from a known clean state.
#
# This reduces total test time from ~27 minutes (60s × 27 tests) to under 3
# minutes for the non-release suite. The cost is weaker isolation: a test
# that mutates shared state in ways the cleanup doesn't anticipate could
# cascade. Cleanup wipes everything we know any test touches.
# ─────────────────────────────────────────────────────────────────────────────

# ═══════════════════════════════════════════════════════════════════════════
#  setup_file / teardown_file — runs ONCE per file
# ═══════════════════════════════════════════════════════════════════════════

setup_file() {
  set -eu -o pipefail

  export GITHUB_REPO=natereprogle/ddev-datagrip

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH:-}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"

  # The path to the add-on repo root (where install.yaml lives).
  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p ~/tmp

  # Allocate two SIBLING tempdirs (not parent/child — ddev rejects that):
  #   TESTDIR — the ddev project root
  #   FAKEHOME — overridden $HOME for the test
  export TESTDIR=$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)
  export FAKEHOME=$(mktemp -d ~/tmp/${PROJNAME}-home.XXXXXX)
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true

  # Override HOME so writes (~/.pgpass, fake state.json) land in the sandbox.
  export REAL_HOME="$HOME"
  export HOME="$FAKEHOME"

  # Clean up any leftover project from a prior run, then create + start ours.
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  ddev config --project-name="${PROJNAME}" --project-tld=ddev.site >/dev/null
  ddev start -y >/dev/null

  # Fake `datagrip` binary on PATH. Tab-stripping heredoc keeps shebang on
  # column 1. The stub captures invocation args to TESTDIR/datagrip-launch.log.
  cat > "${TESTDIR}/datagrip" <<-'EOF'
	#!/bin/bash
	echo "datagrip stub called with: $*" > "${TESTDIR}/datagrip-launch.log"
	echo "datagrip"
EOF
  chmod +x "${TESTDIR}/datagrip"
  export PATH="${TESTDIR}:${PATH}"

  # Install the add-on once. This writes commands/host/datagrip and
  # commands/host/datagrip-lib/* into the project's .ddev/ directory.
  # We use `ddev utility refresh-custom-commands` instead of `ddev restart`
  # to register the new commands without paying the ~30s restart cost.
  ddev add-on get "${DIR}" >/dev/null
  ddev utility refresh-custom-commands >/dev/null
}

teardown_file() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  if [[ -n "${REAL_HOME:-}" ]]; then
    export HOME="$REAL_HOME"
  fi
  [ "${TESTDIR:-}" != "" ] && rm -rf "${TESTDIR}"
  [ "${FAKEHOME:-}" != "" ] && rm -rf "${FAKEHOME}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  setup / teardown — runs PER TEST, fast cleanup only
# ═══════════════════════════════════════════════════════════════════════════

setup() {
  set -eu -o pipefail
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  # Reset all per-test mutable state so each test starts clean. Tests have
  # a small, well-defined set of side effects:
  #   - $HOME/.pgpass and $HOME/.pgpass.bak (pgpass tests)
  #   - $HOME/.local/share/JetBrains/Toolbox/state.json (version-check tests)
  #   - .ddev/datagrip/.user-config.yaml (config tests)
  #   - .ddev/datagrip/.gitignore (config tests)
  #   - .ddev/datagrip/config.yaml — DELIBERATELY preserved across tests so
  #     the project UUID stays stable; tests that need a fresh UUID call
  #     `ddev datagrip --reset` explicitly.
  #   - .ddev/datagrip/.idea/ — preserved unless --reset is invoked.
  #
  # The user-config wipe is critical: tests that rely on default behavior
  # would otherwise see leftover settings from a previous test.
  rm -f "${HOME}/.pgpass" "${HOME}/.pgpass.bak"
  rm -rf "${HOME}/.local/share/JetBrains"
  rm -f "${TESTDIR}/.ddev/datagrip/.user-config.yaml"
  rm -f "${TESTDIR}/.ddev/datagrip/.gitignore"
}

# No teardown() needed — setup() of the next test handles cleanup, and
# teardown_file() handles final cleanup.

# ─── Helpers ────────────────────────────────────────────────────────────────

# Reconfigure the project to use Postgres and restart. This is expensive
# (~30-60s) so it's used by exactly one test that needs the postgres path.
# After the test, it switches the project back to mysql so subsequent tests
# (and teardown_file) operate on the original config.
switch_to_postgres() {
  ddev config --database=postgres:16 >/dev/null
  ddev restart -y >/dev/null
}

switch_to_mysql() {
  ddev config --database=mysql:8.0 >/dev/null
  ddev restart -y >/dev/null
}

# The original health check — runs the command and asserts it exits cleanly.
health_checks() {
  run ddev datagrip
  assert_success
}

# Path helpers
datasources_xml_path() { echo "${TESTDIR}/.ddev/datagrip/.idea/dataSources.xml"; }
datasources_local_xml_path() { echo "${TESTDIR}/.ddev/datagrip/.idea/dataSources.local.xml"; }
project_config_path() { echo "${TESTDIR}/.ddev/datagrip/config.yaml"; }
user_config_path() { echo "${TESTDIR}/.ddev/datagrip/.user-config.yaml"; }

# ═══════════════════════════════════════════════════════════════════════════
#  Smoke test — verifies setup_file did its job
# ═══════════════════════════════════════════════════════════════════════════

@test "smoke: add-on installed and datagrip command available" {
  # If setup_file failed silently the add-on wouldn't be installed.
  assert_file_exists "${TESTDIR}/.ddev/commands/host/datagrip"
  assert_file_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"
  assert_file_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib/config.sh"
  health_checks
}

# bats test_tags=release
@test "install from release" {
  # This test installs from the GitHub release, not the local directory.
  # It necessarily does its own ddev work and pays the full setup cost.
  # The test_tags=release decorator means CI can skip it via --filter-tags '!release'.
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev utility refresh-custom-commands
  assert_success
  health_checks
  # Re-install the local version so the rest of the suite uses the code we're
  # testing, not whatever's on the GitHub release.
  run ddev add-on get "${DIR}"
  assert_success
  run ddev utility refresh-custom-commands
  assert_success
}

# ═══════════════════════════════════════════════════════════════════════════
#  XML output tests
# ═══════════════════════════════════════════════════════════════════════════

@test "datasources.xml is written with the project UUID" {
  run ddev datagrip
  assert_success
  assert_file_exists "$(datasources_xml_path)"
  assert_file_exists "$(datasources_local_xml_path)"
  assert_file_exists "$(project_config_path)"
  run grep -E '^uuid:' "$(project_config_path)"
  assert_success

  # UUID in config.yaml must appear in both XML files.
  uuid_in_config="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  [[ -n "$uuid_in_config" ]]
  run grep -F "$uuid_in_config" "$(datasources_xml_path)"
  assert_success
  run grep -F "$uuid_in_config" "$(datasources_local_xml_path)"
  assert_success
}

@test "uuid is RFC 4122 v4 format" {
  run ddev datagrip
  assert_success
  uuid="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  [[ "$uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]
}

@test "uuid persists across runs" {
  run ddev datagrip
  assert_success
  uuid_first="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  run ddev datagrip
  assert_success
  uuid_second="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  [[ "$uuid_first" == "$uuid_second" ]]
}

@test "--reset regenerates the uuid" {
  run ddev datagrip
  assert_success
  uuid_before="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  run ddev datagrip --reset
  assert_success
  uuid_after="$(awk -F: '/^uuid:/ {gsub(/[ "]/, "", $2); print $2}' "$(project_config_path)")"
  [[ "$uuid_before" != "$uuid_after" ]]
  run grep -F "$uuid_after" "$(datasources_xml_path)"
  assert_success
}

# ═══════════════════════════════════════════════════════════════════════════
#  Config subcommand tests
# ═══════════════════════════════════════════════════════════════════════════

@test "config list shows '(no user config set)' when nothing is set" {
  run ddev datagrip config list
  assert_success
  assert_output --partial "(no user config set)"
}

@test "config set writes a value and config get reads it back" {
  run ddev datagrip config set pg-pass true
  assert_success
  assert_output --partial "Set pg-pass = true"

  run ddev datagrip config get pg-pass
  assert_success
  assert_output --partial "true"

  assert_file_exists "$(user_config_path)"
}

@test "config set creates a .gitignore excluding the user config" {
  run ddev datagrip config set pg-pass true
  assert_success
  gitignore="${TESTDIR}/.ddev/datagrip/.gitignore"
  assert_file_exists "$gitignore"
  run grep -F ".user-config.yaml" "$gitignore"
  assert_success
}

@test "config set rejects unknown keys" {
  run ddev datagrip config set nope-key foo
  assert_failure
  assert_output --partial "Unknown config key"
}

@test "config set rejects invalid bool values" {
  run ddev datagrip config set pg-pass yes
  assert_failure
  assert_output --partial "expects 'true' or 'false'"
}

@test "config set rejects invalid number values" {
  run ddev datagrip config set auto-refresh fast
  assert_failure
  assert_output --partial "expects a number"
}

@test "config unset removes a key" {
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
  run ddev datagrip config path
  assert_success
  assert_output --partial ".user-config.yaml"
}

@test "config with no subcommand prints help" {
  run ddev datagrip config
  assert_success
  assert_output --partial "Usage: ddev datagrip config"
  assert_output --partial "Valid keys:"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Defaults flow / --no-defaults
# ═══════════════════════════════════════════════════════════════════════════

@test "default-database from config affects the JDBC URL" {
  run ddev datagrip config set default-database custom_db
  assert_success
  run ddev datagrip
  assert_success
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_success
}

@test "--no-defaults bypasses user config" {
  run ddev datagrip config set default-database custom_db
  assert_success

  # Without --no-defaults: custom_db
  run ddev datagrip
  assert_success
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_success

  # With --no-defaults: hardcoded fallback "db"
  run ddev datagrip --no-defaults
  assert_success
  run grep -F "/db?" "$(datasources_xml_path)"
  assert_success
  run grep -F "/custom_db" "$(datasources_xml_path)"
  assert_failure
}

@test "explicit --database flag wins over config default" {
  run ddev datagrip config set default-database custom_db
  assert_success
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
#  Switching to postgres requires a real ddev restart (~30-60s). To minimize
#  that cost we have ONE postgres test that exercises three assertion groups
#  with explicit cleanup between them.
#
#  The test switches back to mysql at the end so subsequent tests (and
#  teardown_file) operate on the standard mysql config.
# ═══════════════════════════════════════════════════════════════════════════

@test "pg-pass: postgres project — flag, config-driven, and --no-defaults bypass" {
  switch_to_postgres

  # Group 1: --pg-pass flag writes to $HOME/.pgpass
  run ddev datagrip --pg-pass
  assert_success
  assert_file_exists "$HOME/.pgpass"
  run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
  assert_success

  rm -f "$HOME/.pgpass" "$HOME/.pgpass.bak"
  rm -f "$(user_config_path)"

  # Group 2: config-set pg-pass=true triggers pgpass without flag
  run ddev datagrip config set pg-pass true
  assert_success
  run ddev datagrip
  assert_success
  assert_file_exists "$HOME/.pgpass"
  run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
  assert_success

  rm -f "$HOME/.pgpass" "$HOME/.pgpass.bak"

  # Group 3: --no-defaults bypasses config-driven pgpass
  run ddev datagrip --no-defaults
  assert_success
  if [[ -f "$HOME/.pgpass" ]]; then
    run grep -F "${PROJNAME}.ddev.site" "$HOME/.pgpass"
    assert_failure
  fi

  # Switch back to mysql for subsequent tests + teardown_file.
  switch_to_mysql
}

@test "pg-pass on non-postgres project warns and is a no-op" {
  # Default project is mysql (or restored to mysql by the previous test).
  run ddev datagrip --pg-pass
  assert_success
  assert_output --partial "--pg-pass cannot be used without a Postgres DB"
  assert_file_not_exists "$HOME/.pgpass"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Version check
# ═══════════════════════════════════════════════════════════════════════════

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
  write_fake_toolbox_state_json "2099.1.2"
  run ddev datagrip
  assert_success
  assert_output --partial "Detected DataGrip 2099.1.2"
  assert_output --partial "JetBrains Toolbox"
}

@test "version check falls back gracefully when no state.json exists" {
  # setup() wipes state.json each test; no need to do it again here.
  run ddev datagrip
  assert_success
  assert_output --partial "Unable to check installed DataGrip version"
}

@test "version check unit: comparison handles 2024.10 vs 2024.2 correctly" {
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"
  _version_ge "2024.10" "2024.2"
  assert_equal "$?" "0"
  run _version_ge "2024.2" "2024.10"
  assert_failure
}

@test "version check unit: EAP suffix is stripped before comparing" {
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"
  _version_ge "2026.1 EAP" "2026.1"
  assert_equal "$?" "0"
  _version_ge "2026.1" "2026.1 EAP"
  assert_equal "$?" "0"
}

@test "version check unit: detects too-old version with controlled minimum" {
  write_fake_toolbox_state_json "2020.1"
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"
  run datagrip_version_check "2024.1" "false" "linux"
  assert_failure
  [[ "$status" == "2" ]]
  assert_output --partial "older than the minimum"
}

@test "version check unit: --ignore-unsupported-versions bypasses block" {
  write_fake_toolbox_state_json "2020.1"
  source "${TESTDIR}/.ddev/commands/host/datagrip-lib/version-check.sh"
  run datagrip_version_check "2024.1" "true" "linux"
  assert_success
  assert_output --partial "but --ignore-unsupported-versions was passed"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Removal — runs LAST because it uninstalls the add-on
#
#  Bats runs tests in file order, so as long as this stays at the bottom of
#  the file, no subsequent test depends on the add-on being installed.
# ═══════════════════════════════════════════════════════════════════════════

@test "removal cleans up datagrip-lib directory" {
  assert_dir_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib"
  run ddev add-on remove datagrip
  assert_success
  assert_file_not_exists "${TESTDIR}/.ddev/commands/host/datagrip"
  assert_dir_not_exists "${TESTDIR}/.ddev/commands/host/datagrip-lib"
  assert_dir_not_exists "${TESTDIR}/.ddev/datagrip"
}
