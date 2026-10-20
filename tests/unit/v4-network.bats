#!/usr/bin/env bats
# shellcheck shell=bash
# shellcheck disable=SC2030,SC2031,SC2034,SC2154,SC2329
load ../helpers/common

setup() {
  if [ -n "${OCTOJOOM_TEST_SCRIPT:-}" ]; then OCTOJOOM_SCRIPT="$OCTOJOOM_TEST_SCRIPT"; fi
  octojoom_setup
  V4_HOST=demo.test
  V4_KEY=demo
  V4_ENV_KEY=DEMO
  V4_DIR="$VDM_REPO_PATH/joomla/available/demo.test"
  V4_PROJECT="$VDM_PROJECT_PATH/demo"
  V4_DOCROOT="$V4_PROJECT/joomla"
  V4_WEB_SERVICE=joomlademo
  mkdir -p "$V4_DIR" "$V4_DOCROOT"
  V4_META=$(jq -n --arg project "$V4_PROJECT" '{schema_version:1,host:"demo.test",key:"demo",env_key:"DEMO",project_dir:$project,docroot:"joomla",webserver:"apache",profile:"local",database:{engine:"mariadb",version:"11.4",name:"joomla",user:"joomla"},tls:{mode:"none"},services:{mail:false,redis:false,node:false}}')
  V4_REQUEST='{"site":"demo.test","yes":true}'
  v4LoadSite() { [ "$1" = "$V4_HOST" ]; }
  v4Confirm() { [ "$(v4Get yes false)" = true ]; }
  v4Require() { local key; for key in "$@"; do [ -n "$(v4Get "$key" '')" ] || return 2; done; }
  v4Get() { jq -r --arg key "$1" --arg default "${2:-}" 'if has($key) then .[$key]|tostring else $default end' <<<"$V4_REQUEST"; }
  v4Error() { printf '%s\n' "$1" >&2; return "${2:-1}"; }
  v4Result() { printf '%s\n' "$1"; }
}

@test "optional developer services do not expose SMTP Redis or Node publicly" {
  V4_META=$(jq '.services={mail:true,mail_port:0,redis:true,node:true} | .tls.mode="local"' <<<"$V4_META")
  run v4NetworkCompose '{"services":{"joomlademo":{"networks":["default"]},"mariadbdemo":{}},"networks":{"default":{}}}'
  assert_success
  jq -e '.services.mailpitdemo.ports==["127.0.0.1:0:8025"] and (.services.redisdemo|has("ports")|not) and (.services.nodedemo|has("ports")|not) and (.services.joomlademo.networks|has("octojoom_local")) and (.services.mariadbdemo|has("networks")|not) and .services.nodedemo.profiles==["tools"]' <<<"$output"
}

@test "local TLS attaches Nginx rather than PHP FPM to the proxy network" {
  V4_META=$(jq '.webserver="nginx" | .tls.mode="local"' <<<"$V4_META")
  run v4NetworkCompose '{"services":{"joomlademo":{},"nginxdemo":{}},"networks":{}}'
  assert_success
  jq -e '.services.nginxdemo.networks.octojoom_local=={} and (.services.joomlademo|has("networks")|not)' <<<"$output"
}

@test "invalid service port fails before returning Compose" {
  V4_META=$(jq '.services.mail=true | .services.mail_port=65536' <<<"$V4_META")
  run v4NetworkCompose '{"services":{}}'
  assert_failure
  [[ "$output" == *'Invalid mail UI port'* ]]
}

@test "hosts entry addition is idempotent and removal preserves user entries" {
  local hosts="$SANDBOX/hosts"
  printf '127.0.0.1 localhost\n192.0.2.8 customer.example # retained\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  v4HostsEntry add demo.test
  v4HostsEntry add demo.test
  [ "$(grep -c 'octojoom-v4:demo.test' "$hosts")" -eq 1 ]
  v4HostsEntry remove demo.test
  [ "$(wc -l <"$hosts" | tr -d ' ')" -eq 2 ]
  grep -q '192.0.2.8 customer.example # retained' "$hosts"
}

@test "hosts entry refuses to shadow an existing remote hostname" {
  local hosts="$SANDBOX/hosts"
  printf '192.0.2.8 demo.test\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  run v4HostsEntry add demo.test
  assert_status 3
  [ "$(cat "$hosts")" = '192.0.2.8 demo.test' ]
}

@test "hosts entry leaves a manually supplied loopback mapping intact" {
  local hosts="$SANDBOX/hosts"
  printf '127.0.0.1 demo.test # manually configured\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  v4HostsEntry add demo.test
  v4HostsEntry remove demo.test
  grep -qx '127.0.0.1 demo.test # manually configured' "$hosts"
}

@test "hosts removal does not match another hostname with the same prefix" {
  local hosts="$SANDBOX/hosts"
  printf '127.0.0.1 demo.test # octojoom-v4:demo.test\n127.0.0.1 demo.test.other # octojoom-v4:demo.test.other\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  v4HostsEntry remove demo.test
  [ "$(cat "$hosts")" = '127.0.0.1 demo.test.other # octojoom-v4:demo.test.other' ]
}

@test "TLS requires explicit confirmation before touching trust or Docker" {
  V4_REQUEST='{"site":"demo.test","yes":false}'
  run v4TlsSetup
  assert_failure
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "local route targets only selected HTTP service without Docker socket" {
  local root="$SANDBOX/tls"
  mkdir -p "$root/routes"
  v4LocalRoute "$root" demo demo.test nginxdemo
  jq -e '.http.services["octojoom-demo"].loadBalancer.servers==[{url:"http://nginxdemo:80"}] and .tls.certificates[0].certFile=="/certs/demo.test.pem"' "$root/routes/demo.test.json"
  run grep -qE 'docker.sock|phpmyadmin|mailpit|rootCA' "$root/routes/demo.test.json"
  assert_failure
}

@test "local HTTPS redirect retains a custom HTTPS port" {
  local root="$SANDBOX/tls"
  mkdir -p "$root/routes"
  v4LocalRoute "$root" demo demo.test joomlademo 8443
  jq -e '.http.middlewares["octojoom-demo-https"].redirectScheme.port=="8443"' "$root/routes/demo.test.json"
}

@test "TLS setup restores old certificates and metadata when hostname conflicts" {
  local root="$VDM_SRC_PATH/local-tls" hosts="$SANDBOX/hosts"
  mkdir -p "$root/certs" "$root/routes" "$SANDBOX/ca"
  printf '%s\n' old-cert >"$root/certs/demo.test.pem"
  printf '%s\n' old-key >"$root/certs/demo.test-key.pem"
  printf '%s\n' old-route >"$root/routes/demo.test.json"
  printf '%s\n' ca >"$SANDBOX/ca/rootCA.pem"
  printf '192.0.2.1 demo.test\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path | .install_trust=false' <<<"$V4_REQUEST")
  mkcert() {
    if [ "$1" = -CAROOT ]; then printf '%s\n' "$SANDBOX/ca"; return; fi
    printf '%s\n' new-cert >"$2"
    printf '%s\n' new-key >"$4"
  }
  v4Lock() { mkdir "$1"; }
  v4Unlock() { rmdir "$1"; }
  v4LocalProxyEnsure() { return 0; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  run v4TlsSetup
  assert_failure
  [ "$(cat "$root/certs/demo.test.pem")" = old-cert ]
  [ "$(cat "$root/certs/demo.test-key.pem")" = old-key ]
  [ "$(cat "$root/routes/demo.test.json")" = old-route ]
  jq -e '.tls.mode=="none"' "$SANDBOX/last-meta.json"
  [ ! -d "$root/.lock" ]
}

@test "sharing is refused for server profiles before opening a tunnel" {
  V4_META=$(jq '.profile="server"' <<<"$V4_META")
  run v4ShareStart
  assert_status 2
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "share cleanup refuses containers owned by another site" {
  docker() { if [[ "$*" == *'--format'* ]]; then printf '%s\n' other.test; else return 0; fi; }
  run v4ShareRemove
  assert_status 3
  [[ "$output" == *'owned by another site'* ]]
}

@test "share start points a tunnel at the selected web service and stores its URL" {
  v4Compose() { printf '%s\n' container-id; }
  docker() {
    printf '%s\n' "$*" >>"$SANDBOX/docker-network.log"
    case "$1 $2" in
      'inspect octojoom-share-demo') return 1 ;;
      'inspect --format')
        if [[ "$3" == *NetworkSettings* ]]; then printf '%s\n' '{"demo_default":{}}'; else printf '%s\n' true; fi ;;
      'run -d') printf '%s\n' tunnel-id ;;
      'logs octojoom-share-demo') printf '%s\n' 'https://example-test.trycloudflare.com' ;;
      *) return 1 ;;
    esac
  }
  run v4ShareStart
  assert_success
  jq -e '.url=="https://example-test.trycloudflare.com" and .running==true' <<<"$output"
  grep -q -- '--url http://joomlademo:80' "$SANDBOX/docker-network.log"
  run grep -q -- '--http-host-header' "$SANDBOX/docker-network.log"
  assert_failure
  run grep -qE 'phpmyadmin|mailpit' "$SANDBOX/docker-network.log"
  assert_failure
  [ -f "$V4_DIR/.share.json" ]
}

@test "mail enable preserves original settings and disable restores them" {
  local settings="$SANDBOX/mail.json"
  printf '%s\n' '{"mailer":"smtp","smtphost":"smtp.example.test","smtpport":465,"smtpauth":true,"smtpsecure":"ssl","smtpuser":"alice","smtppass":"secret"}' >"$settings"
  cp "$settings" "$settings.original"
  v4MailSettings() { if [ "$1" = read ]; then cat "$SANDBOX/mail.json"; else cat >"$SANDBOX/mail.json"; fi; }
  v4ApplyConfig() { V4_META="$1"; }
  v4MailConfigure >"$SANDBOX/result"
  jq -e '.smtphost=="mailpitdemo" and .smtppass==""' "$settings"
  cmp -s "$settings.original" "$V4_DIR/.mail-settings.json"
  V4_REQUEST='{"site":"demo.test","yes":true,"enabled":false}'
  v4MailConfigure >"$SANDBOX/result"
  cmp -s "$settings.original" "$settings"
  [ ! -e "$V4_DIR/.mail-settings.json" ]
}

@test "failed mail configuration reverts service metadata" {
  v4MailSettings() { if [ "$1" = read ]; then printf '%s\n' '{"mailer":"mail","smtphost":"localhost"}'; else cat >/dev/null; return 1; fi; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  run v4MailConfigure
  assert_failure
  jq -e '.services.mail==false' "$SANDBOX/last-meta.json"
}

@test "disabling mail without preserved settings refuses to remove capture" {
  V4_REQUEST='{"site":"demo.test","yes":true,"enabled":false}'
  v4MailSettings() { printf '%s\n' '{"mailer":"smtp","smtphost":"mailpitdemo"}'; }
  v4ApplyConfig() { touch "$SANDBOX/should-not-apply"; }
  run v4MailConfigure
  assert_status 3
  [ ! -e "$SANDBOX/should-not-apply" ]
}

@test "mail PHP editor preserves configuration and round trips escaped credentials" {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the embedded configuration editor test'
  export V4_TEST_PHP="$php_binary"
  cat >"$SANDBOX/configuration.php" <<'PHP'
<?php
class JConfig {
    public $sitename = 'Keep this site name';
    public $mailer = 'smtp';
    public $smtphost = 'smtp.example.test';
    public $smtpport = 465;
    public $smtpauth = true;
    public $smtpsecure = 'ssl';
    public $smtpuser = 'user';
    public $smtppass = 'original';
    public $mailonline = true;
}
PHP
  v4Compose() {
    local code="${11}" operation="${12}"
    code="${code//\/var\/www\/html\/configuration.php/$SANDBOX\/configuration.php}"
    "$V4_TEST_PHP" -r "$code" "$operation"
  }
  local settings
  settings=$(v4MailSettings read)
  jq -e '.smtpport==465 and .smtpauth==true' <<<"$settings"
  settings=$(jq '.smtphost="mailpitdemo" | .smtpport=1025 | .smtppass="quotes: \u0027 \" slash: \\ dollar: $ line:\nnext"' <<<"$settings")
  printf '%s\n' "$settings" | v4MailSettings write
  [ "$(v4MailSettings read | jq -Sc .)" = "$(jq -Sc . <<<"$settings")" ]
  grep -q "Keep this site name" "$SANDBOX/configuration.php"
  "$V4_TEST_PHP" -l "$SANDBOX/configuration.php"
}

@test "mail PHP editor refuses expression properties without modifying the file" {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the embedded configuration editor test'
  export V4_TEST_PHP="$php_binary"
  # shellcheck disable=SC2016
  printf '%s\n' '<?php class JConfig {' ' public $smtppass = CUSTOM_PASSWORD;' '}' >"$SANDBOX/configuration.php"
  cp "$SANDBOX/configuration.php" "$SANDBOX/original.php"
  v4Compose() {
    local code="${11}" operation="${12}"
    code="${code//\/var\/www\/html\/configuration.php/$SANDBOX\/configuration.php}"
    "$V4_TEST_PHP" -r "$code" "$operation"
  }
  local status=0
  printf '%s\n' '{"smtppass":"replacement"}' | v4MailSettings write || status=$?
  [ "$status" -eq 2 ]
  cmp -s "$SANDBOX/original.php" "$SANDBOX/configuration.php"
}
