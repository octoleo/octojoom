#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  probe=$(joomlaPlaygroundHttpProbeCode)
  hook_command curl <<'CURL'
cat "$STUB_DIR/http-response"
exit "$(cat "$STUB_DIR/curl-status")"
CURL
  echo 0 > "$STUB_DIR/curl-status"
}

# The final line is curl's --write-out status. Include a real CRLF header block.
http_response() {
  local status="$1"
  shift
  {
    printf 'HTTP/1.1 %s Fixture\r\n' "$status"
    for header in "$@"; do printf '%s\r\n' "$header"; done
    printf '\r\n\n%s' "$status"
  } > "$STUB_DIR/http-response"
}

http_probe() {
  sh -c "$probe" sh "$SANDBOX" shop.example.test nginx
}

@test "Playground HTTP readiness accepts successful transfers and redirects and rejects transport errors" {
  local code
  for code in 200 204 301 302; do
    http_response "$code"
    run http_probe
    assert_success
    [ -z "$output" ]
  done
  for code in 404 500 502; do
    http_response "$code"
    run http_probe
    assert_failure
  done
  http_response 200
  echo 18 > "$STUB_DIR/curl-status"
  run http_probe
  assert_failure
}

@test "a 503 is ready only for the configured offline Joomla site's own session" {
  command -v php >/dev/null || skip 'native PHP is unavailable; the Docker suite checks the offline Joomla site'
  local cookie=06775e9c5bfdceffb83ae07c51980757
  cat > "$SANDBOX/configuration.php" <<'PHP'
<?php
class JConfig {
    public $secret = 'fixture-secret';
    public $offline = 1;
}
PHP
  http_response 503 "sEt-CoOkIe:$cookie=private-fixture-cookie; Path=/; HttpOnly"
  run http_probe
  assert_success
  [ -z "$output" ]

  printf '%s\n' "<?php class JConfig { public \$secret='fixture-secret'; public \$offline=1; public \$session_name=''; }" > "$SANDBOX/configuration.php"
  run http_probe
  assert_success
  for header in 'Server: nginx' 'Set-Cookie: PHPSESSID=private-fixture-cookie' \
    "Set-Cookie: other=$cookie" "Set-Cookie: ${cookie}b=unrelated" "Set-Cookie: $cookie=; Path=/"; do
    http_response 503 "$header"
    run http_probe
    assert_failure
    [ -z "$output" ]
  done
  printf 'HTTP/1.1 103 Early Hints\r\nSet-Cookie: %s=value\r\n\r\nHTTP/1.1 503 Service Unavailable\r\n\r\n\n503' \
    "$cookie" > "$STUB_DIR/http-response"
  run http_probe
  assert_failure

  printf '%s\n' "<?php class JConfig { public \$secret='fixture-secret'; public \$offline=0; }" > "$SANDBOX/configuration.php"
  http_response 503 "Set-Cookie: $cookie=value"
  run http_probe
  assert_failure

  cat > "$SANDBOX/configuration.php" <<'PHP'
<?php
class JConfig {
    public $secret = 'fixture-secret';
    public $offline = '1';
    public $shared_session = 1;
    public $session_name = 'chosen-shared-session';
}
PHP
  run http_probe
  assert_failure
  http_response 503 'Set-Cookie: 083ad7db36feeb02abac12f31a793cf7=value'
  run http_probe
  assert_success
  [ -z "$output" ]
  echo 28 > "$STUB_DIR/curl-status"
  run http_probe
  assert_failure
}

@test "Playground readiness requires the database check before it probes the website" {
  migrationRunCompose() {
    case "$6" in
      php) printf '%s\n' database >> "$SANDBOX/checks"; return "$db_status";;
      sh) printf '%s\n' website >> "$SANDBOX/checks"
        [ "$8" = "$probe" ] && [ "${10}" = /var/www/html/public ] && [ "${11}" = shop.example.test ] && [ "${12}" = nginx ];;
      *) return 1;;
    esac
  }
  # End this isolated attempt on the first retry.
  sleep() { exit 75; }
  local db_status=1
  run joomlaPlaygroundWaitFresh '' "$SANDBOX/compose.yml" app shop.example.test /var/www/html/public nginx
  assert_status 75
  assert_equal "$(cat "$SANDBOX/checks")" database
  : > "$SANDBOX/checks"
  db_status=0
  run joomlaPlaygroundWaitFresh '' "$SANDBOX/compose.yml" app shop.example.test /var/www/html/public nginx
  assert_success
  assert_equal "$(cat "$SANDBOX/checks")" $'database\nwebsite'
}
