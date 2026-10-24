#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  OCTOJOOM_NON_INTERACTIVE=false
  site=alpha.example.test
  showInfo() { :; }
}

@test "local HTTPS menu proceeds when status and the proxy are not ready" {
  joomlaTLSStatus() { printf 'Traefik is missing its HTTPS entrypoint.\n' >&2; return 1; }
  joomlaTLSProxy() { touch "$SANDBOX/premature-proxy-check"; return 1; }
  showJoomlaTLSChange() { printf '%s %s %s\n' "$1" "$2" "$3" > "$SANDBOX/connection-choice"; }
  answers local
  run showJoomlaTLS "$site"
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/connection-choice")" "$site local false"
  refute_file_exists "$SANDBOX/premature-proxy-check"
  assert_file_contains "$STUB_DIR/dialogs.full" 'prepare the website and Traefik automatically'
}

@test "local HTTPS change shows the actual diagnostic and returns its failure status" {
  joomlaTLSSet() { printf 'Cannot bind published port 8443: address already in use.\n' >&2; return 21; }
  run showJoomlaTLSChange "$site" local
  assert_status 21
  assert_file_contains "$STUB_DIR/dialogs.full" "Could not configure $site."
  assert_file_contains "$STUB_DIR/dialogs.full" 'Cannot bind published port 8443: address already in use.'
  refute_dialog 'Connection configured'
}

@test "local HTTPS selection uses the change helper for each checked site" {
  listJoomlaSites() { printf '%s\n' alpha.example.test beta.example.test gamma.example.test; }
  joomlaTLSDiscover() { VDM_TLS_MODE=http; [ "$1" != beta.example.test ] || VDM_TLS_MODE=local; }
  whiptail() { printf '%s\n' "$*" > "$SANDBOX/selection-menu"; printf 'alpha.example.test\ngamma.example.test\n' >&2; }
  showJoomlaTLSChange() {
    printf '%s %s\n' "$1" "$2" >> "$SANDBOX/connection-choices"
    [ "$1" != alpha.example.test ]
  }
  run showJoomlaTLSSelection
  assert_success
  assert_equal "$(cat "$SANDBOX/connection-choices")" $'alpha.example.test local\ngamma.example.test local'
  refute_file_contains "$SANDBOX/selection-menu" beta.example.test
  assert_file_contains "$SANDBOX/selection-menu" '0 112 0'
}

@test "Traefik preparation is discoverable and the menu calls its update action" {
  run cliTaskNames traefik
  assert_success
  [[ "$output" == *update* ]]
  traefikPrepareLocalHTTPS() { printf '%s\n' "$1" >> "$SANDBOX/proxy-preparation"; }
  whiptail() { printf '%s\n' "$*" >> "$SANDBOX/traefik-menu"; command whiptail "$@"; }
  answers update back
  run showTraefik
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/proxy-preparation")" false
  assert_file_contains "$SANDBOX/traefik-menu" 'Prepare local HTTPS (preserve existing settings)'
  assert_file_contains "$STUB_DIR/dialogs.full" 'Traefik is ready for local HTTPS.'
}

@test "Traefik preparation displays its actionable failure in the menu" {
  traefikPrepareLocalHTTPS() { printf 'Cannot create /local/projects/traefik/conf: permission denied.\n' >&2; return 1; }
  run traefik__TRuST__update
  assert_failure
  assert_file_contains "$STUB_DIR/dialogs.full" 'Cannot create /local/projects/traefik/conf: permission denied.'
  refute_dialog 'Traefik is ready'
}
