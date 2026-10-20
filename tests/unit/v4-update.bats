#!/usr/bin/env bats
# shellcheck shell=bash
# Fixture literals and dynamically loaded function overrides are intentional.
# shellcheck disable=SC2317
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2329
load ../helpers/common

setup() {
  if [ -n "${OCTOJOOM_TEST_SCRIPT:-}" ]; then OCTOJOOM_SCRIPT="$OCTOJOOM_TEST_SCRIPT"; fi
  octojoom_setup
  mkdir -p "$SANDBOX/bin"
  UPDATE_TARGET="$SANDBOX/bin/octojoom"
  UPDATE_DOWNLOAD="$SANDBOX/download"
  printf '%s\n' '#!/usr/bin/env bash' '_VERSION="4.0.0"' 'PROGRAM_NAME="Octojoom"' 'echo old' >"$UPDATE_TARGET"
  chmod 755 "$UPDATE_TARGET"
  cp "$UPDATE_TARGET" "$SANDBOX/original"
  printf '%s\n' '#!/usr/bin/env bash' '_VERSION="4.1.0"' 'PROGRAM_NAME="Octojoom"' 'echo new' >"$UPDATE_DOWNLOAD"
  V4_REQUEST=$(jq -n --arg path "$UPDATE_TARGET" '{yes:true,channel:"master",install_path:$path}')
  v4Confirm() { [ "$(v4Get yes false)" = true ]; }
  v4Get() { jq -r --arg key "$1" --arg default "${2:-}" 'if has($key) then .[$key]|tostring else $default end' <<<"$V4_REQUEST"; }
  v4Error() { printf '%s\n' "$1" >&2; return "${2:-1}"; }
  v4Result() { printf '%s\n' "$1"; }
  curl() {
    local destination=''
    printf '%s\n' "$*" >"$SANDBOX/curl-args"
    while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then destination="$2"; shift; fi; shift; done
    cp "$UPDATE_DOWNLOAD" "$destination"
  }
}

@test "update requires explicit confirmation before download or replacement" {
  V4_REQUEST=$(jq '.yes=false' <<<"$V4_REQUEST")
  run v4UpdateApply
  assert_failure
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -e "$SANDBOX/curl-args" ]
}

@test "failed update download preserves the installed executable and releases lock" {
  curl() { return 22; }
  run v4UpdateApply
  assert_failure
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
}

@test "invalid downloaded Bash never replaces the installation" {
  printf 'if broken\n' >>"$UPDATE_DOWNLOAD"
  run v4UpdateApply
  assert_failure
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
}

@test "successful update is atomic keeps recovery and never executes downloaded code" {
  printf 'touch %q\n' "$SANDBOX/should-not-execute" >>"$UPDATE_DOWNLOAD"
  run v4UpdateApply
  assert_success
  local recovery
  recovery=$(jq -r '.recovery_path' <<<"$output")
  jq -e '.previous=="4.0.0" and .version=="4.1.0" and .updated==true and .restart_required==true' <<<"$output"
  cmp -s "$UPDATE_DOWNLOAD" "$UPDATE_TARGET"
  cmp -s "$SANDBOX/original" "$recovery"
  [ -x "$UPDATE_TARGET" ]
  [ ! -e "$SANDBOX/should-not-execute" ]
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
  grep -q -- '--proto =https --proto-redir =https' "$SANDBOX/curl-args"
}

@test "update verification failure atomically restores the previous executable" {
  cmp() { return 1; }
  run v4UpdateApply
  assert_failure
  command cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
}

@test "update refuses symlink targets without changing their referent" {
  mv "$UPDATE_TARGET" "$SANDBOX/real-program"
  ln -s "$SANDBOX/real-program" "$UPDATE_TARGET"
  run v4UpdateApply
  assert_status 3
  cmp -s "$SANDBOX/original" "$SANDBOX/real-program"
  [ ! -e "$SANDBOX/curl-args" ]
}

@test "update does not silently downgrade an installed version" {
  sed 's/4.1.0/3.9.0/' "$UPDATE_DOWNLOAD" >"$SANDBOX/older"
  mv "$SANDBOX/older" "$UPDATE_DOWNLOAD"
  run v4UpdateApply
  assert_status 2
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
}

@test "update leaves another updater lock intact" {
  mkdir "${UPDATE_TARGET}.update.lock"
  printf 'another owner\n' >"${UPDATE_TARGET}.update.lock/owner"
  run v4UpdateApply
  assert_status 4
  [ "$(cat "${UPDATE_TARGET}.update.lock/owner")" = 'another owner' ]
  [ ! -e "$SANDBOX/curl-args" ]
}

@test "interrupted download preserves installation and removes its own lock" {
  curl() { kill -TERM "${BASHPID}"; }
  run v4UpdateApply
  assert_status 143
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
}

@test "interruption after publishing the update restores the previous executable" {
  mv() {
    local source="${3:-}" destination="${4:-}"
    command mv "$@" || return $?
    if [[ "$source" == */.octojoom-update.* ]] && [ "$destination" = "$UPDATE_TARGET" ]; then kill -TERM "${BASHPID}"; fi
  }
  run v4UpdateApply
  assert_status 143
  cmp -s "$SANDBOX/original" "$UPDATE_TARGET"
  [ ! -d "${UPDATE_TARGET}.update.lock" ]
}
