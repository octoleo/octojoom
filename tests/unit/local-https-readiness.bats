#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  site=alpha.example.test
  VDM_TLS_PORT=8443 VDM_TLS_ADDRESS=127.0.0.1 VDM_TLS_CAROOT="$SANDBOX/ca"
  VDM_TLS_VERIFY_ROUTES=$'joomlaalpha\tjoomlaalpha\talpha.example.test\nphpmyadminalpha\tphpmyadminalpha\talphadb.example.test'
  printf 'joomlaalpha\n' > "$SANDBOX/running"
  : > "$SANDBOX/curl-calls"
  : > "$SANDBOX/sleeps"
  : > "$SANDBOX/report"
  printf '200\n' > "$SANDBOX/responses"
  traefikRunCompose() { printf 'traefik\n'; }
  joomlaSiteCompose() { cat "$SANDBOX/running"; }
  actionProgressStep() { printf '%s %s\n' "$1" "$2" >> "$SANDBOX/progress"; }
  joomlaTLSReport() { printf '%s\n' "$1" >> "$SANDBOX/report"; }
  sleep() { printf '%s\n' "$1" >> "$SANDBOX/sleeps"; }
  curl() {
    local number response
    printf '%s\n' "$*" >> "$SANDBOX/curl-calls"
    number=$(wc -l < "$SANDBOX/curl-calls")
    response=$(sed -n "${number}p" "$SANDBOX/responses")
    [ -n "$response" ] || response=$(tail -n 1 "$SANDBOX/responses")
    case "$response" in
      error:*) printf 000; return "${response#error:}";;
      *) printf '%s' "$response";;
    esac
  }
}

@test "HTTPS readiness waits for proxy and application responses after certificate trust succeeds" {
  printf '%s\n' 404 502 503 504 302 > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 5
  assert_equal "$(wc -l < "$SANDBOX/sleeps" | tr -d ' ')" 4
  assert_file_contains "$SANDBOX/progress" 'check 5 of 15'
  assert_file_contains "$SANDBOX/report" 'Verified HTTPS: https://alpha.example.test:8443 (HTTP 302).'
  assert_file_contains "$SANDBOX/curl-calls" '--cacert'
  assert_file_contains "$SANDBOX/curl-calls" '--resolve alpha.example.test:8443:127.0.0.1'
  refute_file_contains "$SANDBOX/curl-calls" '--insecure'
}

@test "persistent HTTP 404 ends the bounded wait with an honest warning without undoing valid TLS" {
  printf '404\n' > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 15
  assert_equal "$(wc -l < "$SANDBOX/sleeps" | tr -d ' ')" 14
  assert_output_contains 'returned HTTP 404'
  assert_file_contains "$SANDBOX/report" 'website is not confirmed ready'
  assert_file_contains "$SANDBOX/report" 'Connection settings were saved.'
  refute_file_contains "$SANDBOX/report" 'Verified HTTPS:'
}

@test "a bad certificate remains a transaction failure even when HTTP later would be available" {
  printf 'error:60\n' > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_failure
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 15
  assert_output_contains 'Certificate verification failed'
  refute_file_contains "$SANDBOX/report" 'Verified HTTPS:'
}

@test "HTTPS readiness recovers from a connection delay and reports stopped companion explicitly" {
  printf '%s\n' error:7 200 > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 2
  assert_file_contains "$SANDBOX/report" 'Verified HTTPS: https://alpha.example.test:8443 (HTTP 200).'
  assert_file_contains "$SANDBOX/report" 'phpmyadminalpha is stopped, so its endpoint was not checked.'
  refute_file_contains "$SANDBOX/curl-calls" alphadb.example.test
}

@test "a stopped proxy is reported without claiming its endpoints were verified" {
  traefikRunCompose() { :; }
  run joomlaTLSVerify "$site"
  assert_success
  assert_file_contains "$SANDBOX/report" 'Traefik is stopped'
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 0
  refute_file_contains "$SANDBOX/report" 'Verified HTTPS:'
}

@test "an authenticated HTTPS endpoint does not consume the routing retry budget" {
  printf '401\n' > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 1
  assert_file_contains "$SANDBOX/report" 'HTTP 401; the website requires authorization'
}

@test "a permanent application error is shown separately from certificate trust" {
  printf '500\n' > "$SANDBOX/responses"
  run joomlaTLSVerify "$site"
  assert_success
  assert_equal "$(wc -l < "$SANDBOX/curl-calls" | tr -d ' ')" 1
  assert_output_contains 'returned HTTP 500'
  assert_file_contains "$SANDBOX/report" 'check its application and Traefik logs'
}

status_fixture() {
  OCTOJOOM_OUTPUT=json
  joomlaTLSDiscover() { VDM_TLS_MODE=acme; }
  joomlaTLSProxy() { VDM_TLS_PORT=443; }
}

@test "SSL status exposes HTTP errors instead of calling a 404 endpoint verified" {
  status_fixture
  printf '404\n' > "$SANDBOX/responses"
  run joomlaTLSStatus "$site"
  assert_success
  assert_equal "$(printf '%s' "$output" | jq -r '.endpoint')" http-404
  assert_equal "$(printf '%s' "$output" | jq -r '.http_status')" 404
}

@test "SSL status retains verified for successful responses and unreachable for transport failures" {
  status_fixture
  printf '%s\n' 200 error:60 > "$SANDBOX/responses"
  run joomlaTLSStatus "$site"
  assert_success
  assert_equal "$(printf '%s' "$output" | jq -r '.endpoint')" verified
  assert_equal "$(printf '%s' "$output" | jq -r '.http_status')" 200
  run joomlaTLSStatus "$site"
  assert_success
  assert_equal "$(printf '%s' "$output" | jq -r '.endpoint')" unreachable
  assert_equal "$(printf '%s' "$output" | jq -r '.http_status')" unavailable
}
