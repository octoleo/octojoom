#!/usr/bin/env bats
# shellcheck shell=bash
# Dynamically loaded handlers invoke these test-local function overrides.
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() { octojoom_setup; octojoom_config; }

@test "v4 every advertised operation has a handler and a menu request schema" {
  local group action registry
  registry=$(v4ActionSchemas)
  while IFS=$'\t' read -r group action; do
    case "$group.$action" in site.schema|site.help) continue ;; esac
    run v4Handler "$group" "$action"
    assert_success
    declare -F "$output" >/dev/null
    jq -e --arg action "$group.$action" 'has($action)' <<< "$registry" >/dev/null
  done < <(v4RequestSchema | jq -r '.actions|to_entries[]|.key as $group|.value[]|[$group,.]|@tsv')
}

@test "v4 menu schema never hides an unknown input field" {
  local field schema
  schema=$(v4RequestSchema)
  while IFS= read -r field; do
    jq -e --arg field "$field" '.options|has($field)' <<< "$schema" >/dev/null
  done < <(v4ActionSchemas | jq -r '[.[].fields[]]|unique[]')
}

@test "v4 menu preserves explicit false defaults and secret input markers" {
  run v4ActionSchema site.delete
  assert_success
  [ "$(jq -r '.fields[]|select(.name=="delete_data")|.default' <<< "$output")" = false ]
  run v4ActionSchema site.create
  assert_success
  [ "$(jq -r '.fields[]|select(.name=="admin_password")|.secret' <<< "$output")" = true ]
  [ "$(jq -r '.fields[]|select(.name=="key")|.required' <<< "$output")" = false ]
}

@test "v4 menu required inputs cover import and hook command structures" {
  run v4ActionSchema site.import
  assert_success
  [ "$(jq -r '.fields[]|select(.name=="database_input")|.required' <<< "$output")" = true ]
  run v4ActionSchema hook.configure
  assert_success
  [ "$(jq -r '.fields[]|select(.name=="commands")|.type' <<< "$output")" = array ]
}

@test "v4 SQL menu command captures a structured result instead of opening a terminal" {
  v4Main() {
    printf '%s\n' "$@" > "$SANDBOX/invocation"
    cat > "$SANDBOX/request"
    printf '%s\n' '{"ok":true,"data":{"stdout":"1"},"error":null}'
  }
  whiptail() { [ "$1" = --textbox ]; cat "$2" > "$SANDBOX/display"; }
  run v4TuiRun database.console '{"site":"alpha.test","command":"SELECT 1"}' SQL
  assert_success
  grep -qx -- '--json' "$SANDBOX/invocation"
  [ "$(jq -r .command "$SANDBOX/request")" = 'SELECT 1' ]
  grep -q 'stdout' "$SANDBOX/display"
}

@test "v4 menu forms expose conditional creation inputs and correct path choices" {
  run v4ActionSchema site.create
  assert_success
  [ "$(jq -r '.conditions[]|select(.when.install==true)|.required[0]' <<< "$output")" = admin_email ]
  run v4ActionSchema site.path
  assert_success
  [ "$(jq -c '.fields[]|select(.name=="target")|.enum' <<< "$output")" = '["project","docroot"]' ]
}

@test "v4 menu keeps failed batch details and retained recovery locations visible" {
  v4Main() {
    printf '%s\n' '{"ok":false,"error":{"message":"Inspect per-site results"},"data":{"results":[{"site":"alpha.test","ok":true},{"site":"beta.test","ok":false}],"recovery_archive":"/safe/recovery.tar.gz"}}'
    return 1
  }
  whiptail() { [ "$1" = --textbox ]; cat "$2" > "$SANDBOX/display"; }
  run v4TuiRun backup.create '{"all":true,"yes":true}' Backups
  assert_status 1
  grep -q 'Inspect per-site results' "$SANDBOX/display"
  grep -q 'alpha.test' "$SANDBOX/display"
  grep -q 'beta.test' "$SANDBOX/display"
  grep -q '/safe/recovery.tar.gz' "$SANDBOX/display"
}

@test "v4 empty site inventory exposes host diagnosis and filtered listing" {
  v4Main() { printf '%s\n' '{"ok":true,"data":[]}'; }
  v4TuiAction() { printf '%s\n' "$1" >> "$SANDBOX/actions"; }
  answers diagnose list checkupdate back
  run v4SitesMenu
  assert_success
  assert_answers_used
  [ "$(cat "$SANDBOX/actions")" = $'site.diagnose\nsite.list\nupdate.check' ]
}

@test "v4 menu displays large results from a private file and removes it afterward" {
  local response
  printf -v response '%70000s' ''
  response=${response// /x}
  whiptail() {
    [ "$1" = --textbox ]
    [ -f "$2" ]
    if ! is_windows; then [ "$(file_mode "$2")" = 600 ]; fi
    printf '%s\n' "$2" > "$SANDBOX/result-path"
    cat "$2" > "$SANDBOX/display"
    local argument
    for argument in "$@"; do [ "${#argument}" -lt 1024 ]; done
  }
  run v4TuiDisplay "$response" 'Large result'
  assert_success
  [ "$(cat "$SANDBOX/display")" = "$response" ]
  [ ! -e "$(cat "$SANDBOX/result-path")" ]
}
