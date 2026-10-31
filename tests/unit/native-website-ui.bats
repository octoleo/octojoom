#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  REAL_DOCKER=''
  export REAL_DOCKER
}

@test "website information always uses the existing whiptail menu" {
  # A real controlling terminal must not select a different renderer.
  joomlaWebsiteMenuCanRender() { return 0; }
  showJoomlaWebsiteTerminal() { printf 'unexpected replacement UI'; return 99; }
  answers back
  run showJoomlaWebsiteMenu first.vdm.dev 'Website information' back Back enable Enable
  assert_success
  assert_equal "$output" back
  assert_answers_used
  assert_file_contains "$STUB_DIR/dialogs.full" 'Website Information | first.vdm.dev'
}

@test "disabled website retains configuration navigation but hides service lifecycle actions" {
  make_joomla_container alpha ALPHA first
  showJoomlaWebsiteMenu() {
    shift 2
    while [ "$#" -gt 0 ]; do printf '%s\n' "$1"; shift 2; done > "$SANDBOX/actions"
    printf 'back\n'
  }
  run showJoomlaWebsiteInformation first.vdm.dev true
  assert_success
  local action
  for action in back enable logs directory permissions php-switch php-settings webserver docroot persistence align database database-change backups ssl clone migrate delete; do
    grep -qxF "$action" "$SANDBOX/actions"
  done
  for action in start stop restart redeploy disable; do
    ! grep -qxF "$action" "$SANDBOX/actions"
  done
}

@test "disabled website settings are not rejected by the menu dispatcher" {
  readJoomlaSiteFacts() { VDM_SITE_ENABLED=disabled; }
  joomla__TRuST__php() { printf 'php %s\n' "$VDM_ACTION"; }
  run runJoomlaSiteAction first.vdm.dev php-settings
  assert_success
  assert_equal "$output" 'php settings'
}

@test "a stale disable action is rejected without calling its handler" {
  readJoomlaSiteFacts() { VDM_SITE_ENABLED=disabled; }
  joomla__TRuST__disable() { touch "$SANDBOX/unexpected-disable"; }
  run runJoomlaSiteAction first.vdm.dev disable
  assert_failure
  [ ! -f "$SANDBOX/unexpected-disable" ]
}

@test "Compose progress uses the existing whiptail gauge rather than an ASCII panel" {
  run declare -f actionProgressDialog
  assert_success
  assert_output_contains 'whiptail'
  refute_output_contains 'actionProgressActivityDialog'
  refute_output_contains 'terminalPanel'
}
