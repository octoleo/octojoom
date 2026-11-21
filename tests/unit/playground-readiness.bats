#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  db_status=0
  migrationRunCompose() {
    case "$6" in
      php) printf '%s\n' database >> "$SANDBOX/checks"; return "$db_status";;
      curl) printf '%s\n' website >> "$SANDBOX/checks"
        shift 5
        command "$@";;
      *) return 1;;
    esac
  }
}

@test "Playground readiness requires the database check before it probes the website" {
  # End this isolated attempt on the first retry.
  sleep() { exit 75; }
  db_status=1
  run joomlaPlaygroundWaitFresh '' "$SANDBOX/compose.yml" app shop.example.test /var/www/html/public nginx
  assert_status 75
  assert_equal "$(cat "$SANDBOX/checks")" database
  refute_command '^curl '
  : > "$SANDBOX/checks"
  db_status=0
  run joomlaPlaygroundWaitFresh '' "$SANDBOX/compose.yml" app shop.example.test /var/www/html/public nginx
  assert_success
  assert_equal "$(cat "$SANDBOX/checks")" $'database\nwebsite'
  assert_command '^curl --fail --silent --connect-timeout 3 --max-time 8 --header Host: shop[.]example[.]test http://nginx/$'
}

@test "Playground readiness rejects HTTP 503 and failed transfers" {
  # curl --fail returns 22 for HTTP 503, including an offline Joomla response.
  printf 'HTTP/1.1 503 Service Unavailable\r\nSet-Cookie: joomla-session=value\r\n\r\n' > "$STUB_DIR/curl-body"
  sleep() { :; }
  local code
  for code in 22 18 28; do
    fail_command curl "$code"
    run joomlaPlaygroundWaitFresh '' "$SANDBOX/compose.yml" app shop.example.test /var/www/html/public nginx
    assert_failure
    assert_output_contains 'Joomla did not establish its database connection and serve the website after startup.'
  done
}
