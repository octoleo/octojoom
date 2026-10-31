#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  REAL_DOCKER=''
  export REAL_DOCKER
  VDM_CONTAINER=first.vdm.dev
}

@test "disabled websites reject every service lifecycle command before invoking Compose" {
  resolveJoomlaSite() { return 0; }
  getJoomlaSiteEnabledState() { printf 'disabled\n'; }
  joomlaSiteCompose() { printf '%s\n' "$*" >> "$SANDBOX/unexpected-compose"; }
  local action
  for action in start stop restart redeploy; do
    run joomlaSiteLifecycle "$action"
    assert_failure
    assert_output_contains 'enable it first'
  done
  [ ! -e "$SANDBOX/unexpected-compose" ]
}

@test "enabled websites retain all four service lifecycle commands" {
  resolveJoomlaSite() { return 0; }
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  joomlaSiteCompose() { printf '%s\n' "$*"; }
  run joomlaSiteLifecycle start
  assert_success
  assert_equal "$output" 'first.vdm.dev up -d'
  run joomlaSiteLifecycle stop
  assert_success
  assert_equal "$output" 'first.vdm.dev stop'
  run joomlaSiteLifecycle restart
  assert_success
  assert_equal "$output" 'first.vdm.dev restart'
  run joomlaSiteLifecycle redeploy
  assert_success
  assert_equal "$output" 'first.vdm.dev up -d --force-recreate'
}

@test "disabled website details expose enable and retain maintenance settings" {
  make_joomla_container alpha ALPHA first
  readJoomlaSiteFacts() { VDM_SITE_ENABLED=disabled; }
  showJoomlaSiteFacts() { printf 'Website: first.vdm.dev\nEnabled: disabled\n'; }
  showJoomlaWebsiteMenu() {
    shift 2
    printf '%s\n' "$@" > "$SANDBOX/site-actions"
    printf 'back\n'
  }
  run showJoomlaWebsiteInformation first.vdm.dev true
  assert_success
  grep -qxF php-settings "$SANDBOX/site-actions"
  grep -qxF backups "$SANDBOX/site-actions"
  run ! grep -qxF stop "$SANDBOX/site-actions"
  grep -qxF back "$SANDBOX/site-actions"
  grep -qxF enable "$SANDBOX/site-actions"
}

@test "stale menu selections cannot dispatch actions against a disabled website" {
  readJoomlaSiteFacts() { VDM_SITE_ENABLED=disabled; }
  joomla__TRuST__disable() { touch "$SANDBOX/unexpected-action"; }
  joomla__TRuST__open() { touch "$SANDBOX/unexpected-action"; }
  joomla__TRuST__php() { touch "$SANDBOX/unexpected-action"; }
  joomlaSiteLifecycle() { touch "$SANDBOX/unexpected-action"; }
  local action
  for action in start stop restart redeploy disable; do
    run runJoomlaSiteAction first.vdm.dev "$action"
    assert_failure
    assert_output_contains 'enable it first'
  done
  [ ! -e "$SANDBOX/unexpected-action" ]
}

@test "a disabled website can still be explicitly enabled" {
  readJoomlaSiteFacts() { VDM_SITE_ENABLED=disabled; }
  joomla__TRuST__enable() { printf 'enabled %s\n' "$VDM_CONTAINER"; }
  run runJoomlaSiteAction first.vdm.dev enable
  assert_success
  assert_equal "$output" 'enabled first.vdm.dev'
}
