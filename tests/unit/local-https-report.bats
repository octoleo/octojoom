#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  OCTOJOOM_NON_INTERACTIVE=false
  OCTOJOOM_NO_PROGRESS=true
  site=alpha.example.test
  directory="$VDM_REPO_PATH/joomla/available/$site"
  mkdir -p "$directory"
  receipt="$directory/.octojoom-last-connection.txt"
}

@test "HTTPS completion persists a private curated receipt and displays its location" {
  joomlaTLSSet() {
    joomlaTLSReport 'Reused the existing local certificate.'
    printf 'raw-tool-output-secret\n' >&2
    printf 'https://%s\n' "$1"
  }
  run showJoomlaTLSChange "$site" local
  assert_success
  assert_file_contains "$receipt" 'Reused the existing local certificate.'
  assert_file_contains "$STUB_DIR/dialogs.full" "Summary saved to: $receipt"
  assert_file_contains "$STUB_DIR/dialogs.full" "https://$site"
  refute_file_contains "$receipt" raw-tool-output-secret
  refute_file_contains "$STUB_DIR/dialogs.full" raw-tool-output-secret
  if ! is_windows; then assert_equal "$(file_mode "$receipt")" 600; fi
}

@test "failed HTTPS setup preserves the previous successful receipt and shows current activity" {
  printf 'Previous successful connection\n' > "$receipt"
  joomlaTLSSet() {
    joomlaTLSReport 'Traefik was prepared before the site change failed.'
    printf 'The previous site configuration was restored.\n' >&2
    return 23
  }
  run showJoomlaTLSChange "$site" local
  assert_status 23
  assert_equal "$(cat "$receipt")" 'Previous successful connection'
  assert_file_contains "$STUB_DIR/dialogs.full" 'The previous site configuration was restored.'
  assert_file_contains "$STUB_DIR/dialogs.full" 'Traefik was prepared before the site change failed.'
  refute_file_contains "$STUB_DIR/dialogs.full" 'Connection configured for'
}

@test "a summary path occupied by a directory does not turn a successful connection into a failure" {
  mkdir "$receipt"
  joomlaTLSSet() { joomlaTLSReport 'Connection configured.'; printf 'https://%s\n' "$1"; }
  run showJoomlaTLSChange "$site" local
  assert_success
  assert_file_contains "$STUB_DIR/dialogs.full" 'saving this summary failed'
  [ -z "$(ls -A "$receipt")" ]
}

@test "summary storage refuses symlinks without changing their targets" {
  skip_on_windows 'Symbolic link policy is covered on Unix runners'
  printf 'private existing file\n' > "$SANDBOX/original"
  printf 'new report\n' > "$SANDBOX/report"
  ln -s "$SANDBOX/original" "$receipt"
  run joomlaTLSSaveReport "$SANDBOX/report" "$receipt"
  assert_failure
  assert_equal "$(cat "$SANDBOX/original")" 'private existing file'
}

@test "optional reporting never changes action status when its destination is unavailable" {
  OCTOJOOM_TLS_REPORT="$SANDBOX/missing/report"
  run joomlaTLSReport 'Completed successfully.'
  assert_success
  assert_equal "$output" ''
  refute_file_exists "$SANDBOX/missing/report"
}

@test "authorization pauses and resumes progress while preserving command failure" {
  actionProgressPause() { printf 'pause\n' >> "$SANDBOX/prompt-order"; }
  actionProgressResume() { printf 'resume\n' >> "$SANDBOX/prompt-order"; }
  authorize() { printf 'authorize\n' >> "$SANDBOX/prompt-order"; return 19; }
  run joomlaTLSPrompt authorize
  assert_status 19
  assert_equal "$(cat "$SANDBOX/prompt-order")" $'pause\nauthorize\nresume'
}

# Keep the real site publication, environment scoping and certificate metadata
# path. Only host trust, certificate generation and container IO are stand-ins.
report_transaction_fixture() {
  make_joomla_container alpha ALPHA alpha example.test
  compose="$directory/docker-compose.yml"
  work="$SANDBOX/tls"
  mkdir -p "$work" "$VDM_PROJECT_PATH/traefik/conf/octojoom"
  OCTOJOOM_TLS_REPORT="$SANDBOX/action-report"
  : > "$OCTOJOOM_TLS_REPORT"
  traefikPrepareLocalHTTPS() { :; }
  joomlaTLSDiscover() {
    resolveJoomlaSite "$1"
    VDM_TLS_ROUTES=$'joomlaalpha\tjoomlaalpha\talpha.example.test\nphpmyadminalpha\tphpmyadminalpha\talphadb.example.test'
    VDM_TLS_MODE=http
  }
  joomlaTLSProxy() { VDM_TLS_CONF="$VDM_PROJECT_PATH/traefik/conf/octojoom"; VDM_TLS_PORT=8443; }
  joomlaTLSPrerequisites() { VDM_TLS_CAROOT="$work/ca"; }
  joomlaTLSCertificateValid() { [ -f "$1" ]; }
  mkcert() { printf 'test-certificate\n' > "$2"; printf 'PRIVATE-LEAF-SECRET\n' > "$4"; }
  updateHostFile() { :; }
  hostFileHasHost() { return 1; }
  joomlaDatabaseConfigurationFile() { : > "$3"; }
  joomlaTLSVerify() { joomlaTLSReport 'Verified HTTPS: https://alpha.example.test:8443 (HTTP 200).'; }
}

@test "TLS action keeps stdout as its URL and reports generated certificate and configuration paths without secrets" {
  report_transaction_fixture
  local result certificate
  result=$(joomlaTLSSet "$site" local 2> "$SANDBOX/diagnostic")
  assert_equal "$result" "https://$site:8443"
  certificate=$(jq -r '.tls.certificates[0].certFile' "$VDM_PROJECT_PATH/traefik/conf/octojoom-$site.yaml")
  assert_file_contains "$OCTOJOOM_TLS_REPORT" "Issued local certificate: $VDM_PROJECT_PATH/traefik/conf/${certificate#/conf/}"
  assert_file_contains "$OCTOJOOM_TLS_REPORT" "Published Traefik certificate configuration: $VDM_PROJECT_PATH/traefik/conf/octojoom-$site.yaml"
  assert_file_contains "$OCTOJOOM_TLS_REPORT" "Saved website Compose: $compose"
  assert_file_contains "$OCTOJOOM_TLS_REPORT" "Saved scoped website environment: $directory/.env"
  refute_file_contains "$OCTOJOOM_TLS_REPORT" PRIVATE-LEAF-SECRET
  refute_file_contains "$OCTOJOOM_TLS_REPORT" 'VDM_ALPHA_DB_PASS='
}

@test "repeating local HTTPS reports the reused certificate and aligned files" {
  report_transaction_fixture
  joomlaTLSSet "$site" local > "$SANDBOX/url" 2> "$SANDBOX/diagnostic"
  : > "$OCTOJOOM_TLS_REPORT"
  run joomlaTLSSet "$site" local
  assert_success
  assert_file_contains "$OCTOJOOM_TLS_REPORT" 'Reused valid local certificate:'
  assert_file_contains "$OCTOJOOM_TLS_REPORT" 'Website Compose and environment were already aligned:'
  refute_file_contains "$OCTOJOOM_TLS_REPORT" 'Issued local certificate:'
}

@test "public HTTPS receipt distinguishes routing changes from certificate issuance" {
  report_transaction_fixture
  run joomlaTLSSet "$site" acme
  assert_success
  assert_file_contains "$OCTOJOOM_TLS_REPORT" 'Public HTTPS routing is configured.'
  assert_file_contains "$OCTOJOOM_TLS_REPORT" 'has not verified public DNS or certificate issuance'
  refute_file_contains "$OCTOJOOM_TLS_REPORT" 'Verified HTTPS:'
}
