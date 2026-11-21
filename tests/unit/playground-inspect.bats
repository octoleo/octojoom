#!/usr/bin/env bats

load ../helpers/common

setup() {
  bats_require_minimum_version 1.5.0
  octojoom_setup
  # Spaces, a single quote and a literal dollar sign must survive CLI parsing.
  package="$SANDBOX/Shop's \$5 export.zip"
}

fixture() {
  python3 "$HELPERS_DIR/playground-fixture.py" "$package" "${1:-valid}"
}

inspect_cli() {
  run --separate-stderr env OCTOJOOM_HOME="$OCTOJOOM_HOME" TERM=dumb bash "$OCTOJOOM_SCRIPT" \
    --type joomla --task playground --action inspect --file "$1" --non-interactive --output json "${@:2}" </dev/null
}

@test "playground inspect reports the verified package through the public CLI on a fresh host" {
  fixture
  local OCTOJOOM_HOME="$SANDBOX/uninitialized"
  inspect_cli "$package"
  assert_success
  jq -e '.success and .task == "playground" and
    (.data | .siteName == "Fixture Shop" and .joomlaVersion == "6.2.0" and
      .phpVersion == "8.4.27" and .preferredPhpVersion == "8.4" and .databasePrefix == "demo_" and
      has("minimumPhpVersion") and .minimumPhpVersion == null and .administratorUsername == "fixture-admin" and
      .fileCount == 7 and .tableCount == 1 and .payloadChecksum == "verified" and
      (.archiveSha256 | test("^[0-9a-f]{64}$")))' <<<"$output"
  refute_output_contains "private-fixture"
  refute_file_exists "$OCTOJOOM_HOME"
  refute_command '^(docker|curl|sudo) '
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "playground inspect supports complete schema-one packages without the optional checksum" {
  fixture legacy
  run joomlaPlaygroundInspectPackage "$package" json
  assert_success
  jq -e '.payloadChecksum == "absent" and .fileCount == 7' <<<"$output"
}

@test "playground inspect reports the installed Joomla manifest PHP minimum when supplied" {
  fixture minimum-php
  run joomlaPlaygroundInspectPackage "$package" json
  assert_success
  jq -e '.minimumPhpVersion == "8.3.0" and .preferredPhpVersion == "8.4"' <<<"$output"
}

@test "playground inspect rejects corruption and inconsistent published checksums" {
  local variant
  for variant in wrong-hash bad-crc truncated; do
    fixture "$variant"
    run joomlaPlaygroundInspectPackage "$package" json
    assert_failure
    [ -n "$output" ]
    refute_output_contains "private-fixture"
    refute_output_contains "Traceback"
  done
}

@test "playground inspect rejects ambiguous entries and unsafe archive paths, types or metadata sizes" {
  local variant
  for variant in duplicate parent-segment symlink large-metadata; do
    fixture "$variant"
    run joomlaPlaygroundInspectPackage "$package" json
    assert_failure
    [ -n "$output" ]
  done
}

@test "playground inspect requires a complete installed site with matching core and metadata" {
  local variant
  for variant in unknown-schema wrong-layout missing-sql empty-sql missing-manifest missing-admin-index missing-autoloader installer version-mismatch; do
    fixture "$variant"
    run joomlaPlaygroundInspectPackage "$package" json
    assert_failure
    [ -n "$output" ]
  done
}

@test "playground CLI rejects incomplete exports and relative paths before first-run setup" {
  local OCTOJOOM_HOME="$SANDBOX/uninitialized"
  fixture missing-autoloader
  inspect_cli "$package"
  assert_failure
  jq -e '.success == false and .task == "playground" and .exit_status != 0' <<<"$output"
  refute_output_contains "private-fixture"
  [[ "${stderr:-}" != *private-fixture* ]]
  fixture
  cd "$SANDBOX" || return 1
  inspect_cli "${package##*/}"
  assert_failure
  jq -e '.success == false' <<<"$output"
  refute_file_exists "$OCTOJOOM_HOME"
  refute_command '^(docker|curl|sudo) '
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "playground CLI refuses multiple container targets before probing either site" {
  fixture
  inspect_cli "$package" --container one.example.test --container two.example.test
  assert_status 17
  [[ "${stderr:-}$output" == *--container* ]]
  refute_command '^(docker|curl|sudo) '
}

@test "playground menu follows Website Information even with no sites and shows package details" {
  octojoom_config
  fixture
  # Capture menu labels, since dialogs.full records the dialog text only.
  # shellcheck disable=SC2317
  whiptail() {
    if [[ " $* " == *" --menu "* ]]; then
      printf '%s\n' "$@" >"$SANDBOX/menu"
    fi
    command whiptail "$@"
  }
  answers playground "$package" back
  run showJoomla
  assert_success
  assert_answers_used
  awk '/^Website Information$/{getline; tag=$0; getline; if (tag=="playground" && $0=="Deploy Joomengine Playground packages") ok=1} END{exit !ok}' "$SANDBOX/menu"
  assert_dialog "Fixture Shop"
  assert_dialog "6.2.0"
  assert_dialog "demo_"
  refute_dialog "private-fixture"
  refute_command 'docker compose .* (up|down|stop|restart)'
}

@test "dismissing the playground path prompt returns to the Joomla menu with no site changes" {
  octojoom_config
  answers playground '<cancel>' back
  run showJoomla
  assert_success
  assert_answers_used
  refute_file_exists "$VDM_REPO_PATH/joomla/available"
  refute_command 'docker compose .* (up|down|stop|restart)'
}
