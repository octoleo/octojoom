#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  REAL_DOCKER=''
  export REAL_DOCKER
}

@test "full website report preserves every byte and removes its private file for every dialog status" {
  local report=$'Website: first.vdm.dev\nLiteral: $value; $(nothing); `command`; \\n; "quotes"\n'
  report+="Compose: /a path with spaces/$(printf '%0300d' 0)/docker-compose.yml"
  report+=$'\nLast service: healthy\n'
  printf '%s' "$report" > "$SANDBOX/expected-report"
  local TMPDIR="$SANDBOX/temporary files" report_status report_path
  mkdir -p "$TMPDIR"
  whiptail() {
    [ "$1" = --textbox ] || return 97
    printf '%s\n' "$2" > "$SANDBOX/report-path"
    cp "$2" "$SANDBOX/displayed-report"
    file_mode "$2" > "$SANDBOX/report-mode"
    printf '%s\n' "$@" > "$SANDBOX/report.args"
    return "$report_status"
  }
  for report_status in 0 255 1; do
    run showJoomlaWebsiteReport first.vdm.dev "$report"
    assert_status "$report_status"
    assert_equal "$output" ''
    cmp "$SANDBOX/expected-report" "$SANDBOX/displayed-report"
    IFS= read -r report_path < "$SANDBOX/report-path"
    [[ "$report_path" = "$TMPDIR/"* ]]
    [ ! -e "$report_path" ]
    if ! is_windows; then assert_equal "$(cat "$SANDBOX/report-mode")" 600; fi
    assert_file_contains "$SANDBOX/report.args" '--scrolltext'
    assert_file_contains "$SANDBOX/report.args" 'Full Website Information | first.vdm.dev'
  done
}

@test "Back and Escape in full information return to the same website actions without dispatching" {
  make_joomla_container alpha ALPHA first
  local report_status
  whiptail() {
    if [ "$1" = --textbox ]; then
      printf '%s\n' "$2" > "$SANDBOX/report-path"
      cp "$2" "$SANDBOX/displayed-report"
      return "$report_status"
    fi
    command whiptail "$@"
  }
  runJoomlaSiteAction() { printf '%s\n' "$*" >> "$SANDBOX/unexpected-action"; }
  showError() { printf '%s\n' "$*" >> "$SANDBOX/unexpected-error"; }
  for report_status in 0 255; do
    : > "$STUB_DIR/dialogs.full"
    answers information back
    run showJoomlaWebsiteInformation first.vdm.dev true
    assert_success
    assert_answers_used
    [ "$(grep -c 'Website: first.vdm.dev' "$STUB_DIR/dialogs.full")" -eq 2 ]
    refute_file_contains "$STUB_DIR/dialogs.full" 'Select a website'
    assert_file_contains "$SANDBOX/displayed-report" 'Website: first.vdm.dev'
    assert_file_contains "$SANDBOX/displayed-report" 'Compose:'
    [ ! -e "$(cat "$SANDBOX/report-path")" ]
    [ ! -e "$SANDBOX/unexpected-action" ]
    [ ! -e "$SANDBOX/unexpected-error" ]
  done
}

@test "a failed full information viewer reports the failure and returns to website actions" {
  make_joomla_container alpha ALPHA first
  whiptail() {
    if [ "$1" = --textbox ]; then
      printf '%s\n' "$2" > "$SANDBOX/report-path"
      return 1
    fi
    command whiptail "$@"
  }
  runJoomlaSiteAction() { printf '%s\n' "$*" >> "$SANDBOX/unexpected-action"; }
  showError() { printf '%s\n' "$*" >> "$SANDBOX/report-error"; }
  answers information back
  run showJoomlaWebsiteInformation first.vdm.dev true
  assert_success
  assert_answers_used
  assert_file_contains "$SANDBOX/report-error" 'Could not display the full website information (status 1).'
  [ "$(grep -c 'Website: first.vdm.dev' "$STUB_DIR/dialogs.full")" -eq 2 ]
  [ ! -e "$(cat "$SANDBOX/report-path")" ]
  [ ! -e "$SANDBOX/unexpected-action" ]
}

@test "an unavailable temporary directory fails before opening the full information viewer" {
  local TMPDIR="$SANDBOX/missing directory"
  whiptail() { touch "$SANDBOX/unexpected-viewer"; }
  run showJoomlaWebsiteReport first.vdm.dev 'Complete website report'
  assert_status 1
  [ ! -e "$SANDBOX/unexpected-viewer" ]
  [ ! -e "$TMPDIR" ]
}
