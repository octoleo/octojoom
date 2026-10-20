#!/usr/bin/env bats
# shellcheck shell=bash
# Fixture literals and dynamically loaded function overrides are intentional.
# shellcheck disable=SC2317
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

@test "native Docker scalar output removes CRLF without hiding command failure" {
  docker() { printf 'true\r\n'; }
  run v4NetworkDockerScalar inspect --format '{{.State.Running}}' example
  assert_success
  [ "$output" = true ]
  docker() { printf 'failure\r\n'; return 7; }
  run v4NetworkDockerScalar inspect example
  assert_status 7
}

@test "local TLS attaches Nginx rather than PHP FPM to the proxy network" {
  V4_META=$(jq '.webserver="nginx" | .tls.mode="local"' <<<"$V4_META")
  run v4NetworkCompose '{"services":{"joomlademo":{},"nginxdemo":{}},"networks":{}}'
  assert_success
  jq -e '.services.nginxdemo.networks.octojoom_local=={} and (.services.joomlademo|has("networks")|not)' <<<"$output"
}

@test "Node bind sources cross the host path boundary without rewriting container paths" {
  v4DockerHostPath() { printf 'C:/native%s\n' "$1"; }
  V4_META=$(jq '.services.node=true' <<<"$V4_META")
  run v4NetworkCompose '{"services":{"joomlademo":{}},"networks":{}}'
  assert_success
  jq -e --arg root "C:/native$V4_DOCROOT" '.services.nodedemo.volumes[0].source==$root and .services.nodedemo.volumes[0].target=="/var/www/html" and .services.nodedemo.working_dir=="/var/www/html"' <<<"$output"
}

@test "TLS proxy translates host bind and Compose paths but keeps Linux container paths" {
  local root="$SANDBOX/tls"
  v4DockerHostPath() { printf 'C:/native%s\n' "$1"; }
  docker() {
    printf '%s\n' "$*" >>"$SANDBOX/docker-paths.log"
    case "$1 $2" in
      'inspect octojoom-local-proxy'|'network inspect') return 1 ;;
      *) return 0 ;;
    esac
  }
  run v4LocalProxyEnsure "$root" 8080 8443
  assert_success
  jq -e --arg root "C:/native$root" '.services.proxy.volumes[0].source==($root+"/routes") and .services.proxy.volumes[1].source==($root+"/certs") and .services.proxy.volumes[0].target=="/routes" and .services.proxy.volumes[1].target=="/certs" and (.services.proxy.command|index("--providers.file.directory=/routes"))' "$root/proxy.json"
  grep -Fq -- "compose -f C:/native$root/proxy.json config -q" "$SANDBOX/docker-paths.log"
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

@test "an IPv6-only manual host mapping gains the required IPv4 loopback entry" {
  local hosts="$SANDBOX/hosts"
  printf '::1 demo.test # manual IPv6\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  v4HostsEntry add demo.test
  grep -q '^127.0.0.1.*demo.test' "$hosts"
  v4HostsEntry remove demo.test
  [ "$(cat "$hosts")" = '::1 demo.test # manual IPv6' ]
}

@test "Windows CRLF host entries retain conflict protection and exact marker ownership" {
  local hosts="$SANDBOX/hosts"
  printf '192.0.2.8 demo.test\r\n127.0.0.1 other.test # octojoom-v4:other.test\r\n' >"$hosts"
  V4_REQUEST=$(jq --arg path "$hosts" '.hosts_file=$path' <<<"$V4_REQUEST")
  run v4HostsEntry add demo.test
  assert_status 3
  v4HostsEntry remove other.test
  [ "$(wc -l <"$hosts" | tr -d ' ')" -eq 1 ]
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
  # Traefik v3 file-directory discovery accepts YAML/TOML, not .json files.
  [ -f "$root/routes/demo.test.yaml" ]
  [ ! -e "$root/routes/demo.test.json" ]
  jq -e '.http.services["octojoom-demo"].loadBalancer.servers==[{url:"http://nginxdemo:80"}] and .tls.certificates[0].certFile=="/certs/demo.test.pem"' "$root/routes/demo.test.yaml"
  run grep -qE 'docker.sock|phpmyadmin|mailpit|rootCA' "$root/routes/demo.test.yaml"
  assert_failure
}

@test "TLS readiness verifies the site certificate through its dedicated loopback port" {
  curl() { printf '%s\n' "$*" >"$SANDBOX/tls-curl-args"; return 0; }
  run v4LocalTlsVerify demo.test 8443 "$SANDBOX/rootCA.pem"
  assert_success
  grep -Fq -- '--resolve demo.test:8443:127.0.0.1' "$SANDBOX/tls-curl-args"
  grep -Fq -- "--cacert $(v4DockerHostPath "$SANDBOX/rootCA.pem")" "$SANDBOX/tls-curl-args"
  grep -Fq -- '--noproxy *' "$SANDBOX/tls-curl-args"
  run grep -Eq -- '--insecure|(^| )-k( |$)' "$SANDBOX/tls-curl-args"
  assert_failure
}

@test "TLS readiness fails closed when the proxy serves an untrusted certificate" {
  curl() { return 60; }
  run v4LocalTlsVerify demo.test 8443 "$SANDBOX/rootCA.pem" 1
  assert_status 1
  [[ "$output" == *'expected trusted certificate'* ]]
}

@test "local HTTPS redirect retains a custom HTTPS port" {
  local root="$SANDBOX/tls"
  mkdir -p "$root/routes"
  v4LocalRoute "$root" demo demo.test joomlademo 8443
  jq -e '.http.middlewares["octojoom-demo-https"].redirectScheme.port=="8443"' "$root/routes/demo.test.yaml"
}

@test "TLS setup restores old certificates and metadata when hostname conflicts" {
  local root="$VDM_SRC_PATH/local-tls" hosts="$SANDBOX/hosts"
  mkdir -p "$root/certs" "$root/routes" "$SANDBOX/ca"
  printf '%s\n' old-cert >"$root/certs/demo.test.pem"
  printf '%s\n' old-key >"$root/certs/demo.test-key.pem"
  printf '%s\n' old-route >"$root/routes/demo.test.yaml"
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
  v4LocalTlsVerify() { return 0; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  run v4TlsSetup
  assert_failure
  [ "$(cat "$root/certs/demo.test.pem")" = old-cert ]
  [ "$(cat "$root/certs/demo.test-key.pem")" = old-key ]
  [ "$(cat "$root/routes/demo.test.yaml")" = old-route ]
  jq -e '.tls.mode=="none"' "$SANDBOX/last-meta.json"
  [ ! -d "$root/.lock" ]
}

@test "TLS setup can leave hostname resolution unmanaged" {
  local root="$VDM_SRC_PATH/local-tls"
  mkdir -p "$SANDBOX/ca"
  printf '%s\n' ca >"$SANDBOX/ca/rootCA.pem"
  V4_REQUEST='{"site":"demo.test","yes":true,"install_trust":false,"update_hosts":false,"hosts_file":"/missing/unmanaged/hosts"}'
  mkcert() {
    if [ "$1" = -CAROOT ]; then printf '%s\n' "$SANDBOX/ca"; return; fi
    printf '%s\n' cert >"$2"
    printf '%s\n' key >"$4"
  }
  v4Lock() { mkdir "$1"; }
  v4Unlock() { rmdir "$1"; }
  v4LocalProxyEnsure() { return 0; }
  v4LocalTlsVerify() { return 0; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  run v4TlsSetup
  assert_success
  jq -e '.tls.mode=="local" and .tls.update_hosts==false' "$SANDBOX/last-meta.json"
  [ ! -f "$root/hosts/demo.test.json" ]
}

# Exercise the container archive commands against a local fixture: container
# execution is replaced, while tar and atomic-rename recovery run unchanged.
prepare_tls_configuration_rollback() {
  mkdir -p "$SANDBOX/ca"
  printf '%s\n' ca >"$SANDBOX/ca/rootCA.pem"
  # shellcheck disable=SC2016
  printf '%s\n' '<?php' 'class JConfig {' ' public $live_site = "https://original.example";' ' public $cookie_domain = "original.example";' '}' >"$V4_DOCROOT/configuration.php"
  chmod 640 "$V4_DOCROOT/configuration.php"
  cp -p "$V4_DOCROOT/configuration.php" "$SANDBOX/original-configuration.php"
  V4_REQUEST='{"site":"demo.test","yes":true,"install_trust":false,"update_hosts":false}'
  mkcert() {
    if [ "$1" = -CAROOT ]; then printf '%s\n' "$SANDBOX/ca"; return; fi
    printf '%s\n' cert >"$2"
    printf '%s\n' key >"$4"
  }
  v4Lock() { mkdir "$1"; }
  v4Unlock() { rmdir "$1"; }
  v4LocalProxyEnsure() { return 0; }
  v4LocalProxyStopIfIdle() { return 0; }
  v4LocalTlsVerify() { return 1; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  v4Compose() {
    local entrypoint="$8" argument code
    shift 9
    if [ "$entrypoint" = tar ]; then
      local -a arguments=()
      for argument in "$@"; do
        if [ "$argument" = /var/www/html ]; then arguments+=("$V4_DOCROOT"); else arguments+=("$argument"); fi
      done
      tar "${arguments[@]}"
    elif [ "$entrypoint" = sh ]; then
      code="$3"
      code="${code//\/var\/www\/html/$V4_DOCROOT}"
      sh "$1" "$2" "$code"
    else return 2; fi
  }
}

@test "TLS verification failure restores exact Joomla configuration and removes newly saved mail settings" {
  prepare_tls_configuration_rollback
  local mode
  mode=$(file_mode "$V4_DOCROOT/configuration.php")
  v4RealignConfiguration() {
    printf '%s\n' 'changed Joomla URL and proxy configuration' >"$V4_DOCROOT/configuration.php"
    chmod 600 "$V4_DOCROOT/configuration.php"
    printf '%s\n' '{"mailer":"smtp","smtphost":"original"}' >"$V4_DIR/.mail-settings.json"
  }
  run v4TlsSetup
  assert_failure
  cmp -s "$SANDBOX/original-configuration.php" "$V4_DOCROOT/configuration.php"
  [ "$(file_mode "$V4_DOCROOT/configuration.php")" = "$mode" ]
  [ ! -f "$V4_DIR/.mail-settings.json" ]
  jq -e '.tls.mode=="none"' "$SANDBOX/last-meta.json"
  [ ! -d "$VDM_SRC_PATH/local-tls/.lock" ]
}

@test "failed realignment restores existing Joomla configuration and mail sidecar bytes and mode" {
  prepare_tls_configuration_rollback
  printf '%s\n' '{"mailer":"smtp","smtphost":"smtp.original","smtppass":"original secret"}' >"$V4_DIR/.mail-settings.json"
  chmod 600 "$V4_DIR/.mail-settings.json"
  cp -p "$V4_DIR/.mail-settings.json" "$SANDBOX/original-mail-settings.json"
  local mail_mode
  mail_mode=$(file_mode "$V4_DIR/.mail-settings.json")
  v4RealignConfiguration() {
    printf '%s\n' 'partial configuration rewrite' >"$V4_DOCROOT/configuration.php"
    printf '%s\n' '{"mailer":"smtp","smtphost":"changed"}' >"$V4_DIR/.mail-settings.json"
    chmod 644 "$V4_DIR/.mail-settings.json"
    return 1
  }
  run v4TlsSetup
  assert_failure
  cmp -s "$SANDBOX/original-configuration.php" "$V4_DOCROOT/configuration.php"
  cmp -s "$SANDBOX/original-mail-settings.json" "$V4_DIR/.mail-settings.json"
  [ "$(file_mode "$V4_DIR/.mail-settings.json")" = "$mail_mode" ]
  [ ! -d "$VDM_SRC_PATH/local-tls/.lock" ]
}

@test "TLS reconfiguration failure restores the file saved before application restart" {
  prepare_tls_configuration_rollback
  local mode
  mode=$(file_mode "$V4_DOCROOT/configuration.php")
  v4ApplyConfig() {
    printf '%s\n' 'entrypoint changed configuration' >"$V4_DOCROOT/configuration.php"
    chmod 600 "$V4_DOCROOT/configuration.php"
    return 1
  }
  v4RealignConfiguration() { touch "$SANDBOX/should-not-realign"; }
  run v4TlsSetup
  assert_failure
  cmp -s "$SANDBOX/original-configuration.php" "$V4_DOCROOT/configuration.php"
  [ "$(file_mode "$V4_DOCROOT/configuration.php")" = "$mode" ]
  [ ! -e "$SANDBOX/should-not-realign" ]
  [ ! -d "$VDM_SRC_PATH/local-tls/.lock" ]
}

@test "failed TLS configuration restoration retains a private recovery archive" {
  prepare_tls_configuration_rollback
  v4RealignConfiguration() { printf '%s\n' 'changed configuration' >"$V4_DOCROOT/configuration.php"; }
  v4TlsRestoreConfiguration() { return 1; }
  run v4TlsSetup
  assert_failure
  local -a recoveries=("$VDM_SRC_PATH/local-tls/".recovery.*)
  [ "${#recoveries[@]}" -eq 1 ]
  [ -f "${recoveries[0]}/joomla-configuration.tar" ]
  [[ "$output" == *"Exact original files are retained in: ${recoveries[0]}"* ]]
  [[ "$output" != *'original.example'* ]]
  tar -xOf "${recoveries[0]}/joomla-configuration.tar" configuration.php >"$SANDBOX/recovered.php"
  cmp -s "$SANDBOX/original-configuration.php" "$SANDBOX/recovered.php"
  case "${OSTYPE:-}" in msys*|cygwin*) ;; *)
    [ "$(file_mode "${recoveries[0]}")" = 700 ]
    [ "$(file_mode "${recoveries[0]}/joomla-configuration.tar")" = 600 ] ;;
  esac
  [ ! -d "$VDM_SRC_PATH/local-tls/.lock" ]
}

@test "local proxy refuses to join an unrelated same-named network" {
  docker() {
    case "$1 $2" in
      'inspect octojoom-local-proxy') return 1 ;;
      'network inspect') if [ "${3:-}" = --format ]; then printf '%s\n' unrelated; fi ;;
      *) return 1 ;;
    esac
  }
  run v4LocalProxyEnsure "$SANDBOX/tls" 80 443
  assert_status 3
  [[ "$output" == *'unrelated Docker network'* ]]
}

@test "idle proxy cleanup refuses another OctoJoom configuration directory" {
  docker() {
    if [[ "$*" == *'json .Mounts'* ]]; then printf '%s\n' '[{"Destination":"/routes","Source":"/another/installation/routes"}]';
    elif [[ "$*" == *'--format'* ]]; then printf '%s\n' v4;
    elif [ "$1" = stop ]; then touch "$SANDBOX/should-not-stop";
    else return 0; fi
  }
  run v4LocalProxyStopIfIdle "$SANDBOX/tls"
  assert_status 3
  [ ! -f "$SANDBOX/should-not-stop" ]
}

@test "proxy cleanup keeps the proxy running while another route exists" {
  local root="$SANDBOX/tls"
  mkdir -p "$root/routes"
  printf '{}\n' >"$root/routes/other.test.yaml"
  docker() { touch "$SANDBOX/should-not-inspect"; return 1; }
  run v4LocalProxyStopIfIdle "$root"
  assert_success
  [ ! -f "$SANDBOX/should-not-inspect" ]
}

@test "disabling the final TLS site deletes leaf keys and stops only its proxy" {
  local root="$VDM_SRC_PATH/local-tls"
  mkdir -p "$root/routes" "$root/certs" "$root/hosts"
  printf '{}\n' >"$root/routes/demo.test.yaml"
  printf 'certificate\n' >"$root/certs/demo.test.pem"
  printf 'private-key\n' >"$root/certs/demo.test-key.pem"
  printf '{"file":"/etc/hosts"}\n' >"$root/hosts/demo.test.json"
  V4_META=$(jq '.tls.mode="local"' <<<"$V4_META")
  v4Lock() { mkdir "$1"; }
  v4Unlock() { rmdir "$1"; }
  v4ApplyConfig() { printf '%s\n' "$1" >"$SANDBOX/last-meta.json"; }
  docker() {
    if [[ "$*" == *'json .Mounts'* ]]; then jq -n --arg root "$(v4DockerHostPath "$VDM_SRC_PATH/local-tls/routes")" '[{Destination:"/routes",Source:$root}]';
    elif [[ "$*" == *'--format'* ]]; then printf '%s\n' v4;
    elif [ "$1" = stop ]; then printf '%s\n' "$2" >"$SANDBOX/stopped";
    else return 0; fi
  }
  run v4TlsDisable
  assert_success
  jq -e '.local_tls==false and .host_trust_retained==true' <<<"$output"
  [ ! -f "$root/routes/demo.test.yaml" ]
  [ ! -f "$root/certs/demo.test-key.pem" ]
  [ -f "$root/hosts/demo.test.json" ]
  [ "$(cat "$SANDBOX/stopped")" = octojoom-local-proxy ]
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
    local code="${11}" operation="${12}" native_path
    native_path=$(v4DockerHostPath "$SANDBOX/configuration.php")
    code="${code//\/var\/www\/html\/configuration.php/$native_path}"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$V4_TEST_PHP" -r "$code" "$operation"
  }
  local settings
  settings=$(v4MailSettings read)
  jq -e '.smtpport==465 and .smtpauth==true' <<<"$settings"
  settings=$(jq '.smtphost="mailpitdemo" | .smtpport=1025 | .smtppass="quotes: \u0027 \" slash: \\ dollar: $ line:\nnext"' <<<"$settings")
  printf '%s\n' "$settings" | v4MailSettings write
  [ "$(v4MailSettings read | jq -Sc .)" = "$(jq -Sc . <<<"$settings")" ]
  grep -q "Keep this site name" "$SANDBOX/configuration.php"
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$V4_TEST_PHP" -l "$(v4DockerHostPath "$SANDBOX/configuration.php")"
}

@test "mail PHP editor refuses expression properties without modifying the file" {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the embedded configuration editor test'
  export V4_TEST_PHP="$php_binary"
  # shellcheck disable=SC2016
  printf '%s\n' '<?php class JConfig {' ' public $smtppass = CUSTOM_PASSWORD;' '}' >"$SANDBOX/configuration.php"
  cp "$SANDBOX/configuration.php" "$SANDBOX/original.php"
  v4Compose() {
    local code="${11}" operation="${12}" native_path
    native_path=$(v4DockerHostPath "$SANDBOX/configuration.php")
    code="${code//\/var\/www\/html\/configuration.php/$native_path}"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$V4_TEST_PHP" -r "$code" "$operation"
  }
  local status=0
  printf '%s\n' '{"smtppass":"replacement"}' | v4MailSettings write || status=$?
  [ "$status" -eq 2 ]
  cmp -s "$SANDBOX/original.php" "$SANDBOX/configuration.php"
}

# The Joomla mailer needs Factory::getApplication() even when no CLI command is
# dispatched. Exercise that dependency with real PHP and the selected site config.
prepare_joomla_mail_application() {
  local php_binary="${V4_TEST_PHP:-php}"
  command -v "$php_binary" >/dev/null || skip 'PHP CLI is required for the mail application bootstrap test'
  export V4_TEST_PHP="$php_binary"
  V4_META=$(jq '.services.mail=true' <<<"$V4_META")
  mkdir -p "$V4_DOCROOT/includes"
  printf '%s\n' '<?php define("JPATH_CONFIGURATION", JPATH_BASE);' >"$V4_DOCROOT/includes/defines.php"
  cat >"$V4_DOCROOT/configuration.php" <<'PHP'
<?php
class JConfig {
    public $mailer = 'smtp';
    public $smtphost = 'mailpitdemo';
    public $smtpport = 1025;
    public $mailonline = true;
}
PHP
  cat >"$V4_DOCROOT/includes/framework.php" <<'PHP'
<?php
namespace Joomla\Registry {
    class Registry {
        public function __construct(private object $config) {}
        public function get($key, $default = null) { return $this->config->$key ?? $default; }
    }
}
namespace Joomla\CMS {
    class Factory {
        public static $application;
        public static function getContainer() { return new \MailContainer; }
        public static function getApplication() {
            if (!self::$application) { throw new \RuntimeException('Failed to start application'); }
            return self::$application;
        }
    }
}
namespace Joomla\Console {
    class Application {
        public function get($key, $default = null) { return (new \JConfig)->$key ?? $default; }
        public function execute() { throw new \RuntimeException('Must not dispatch a CLI command'); }
    }
}
namespace Joomla\CMS\Mail { interface MailerFactoryInterface {} }
namespace {
    class MailContainer {
        private array $aliases = [];
        public function alias($name, $service) { $this->aliases[$name] = $service; return $this; }
        public function get($name) {
            if ($name === \Joomla\Console\Application::class) {
                if (($this->aliases[\Joomla\Session\SessionInterface::class] ?? null) !== 'session.cli') {
                    throw new \RuntimeException('CLI session service was not configured');
                }
                return new \Joomla\Console\Application;
            }
            if ($name === \Joomla\CMS\Mail\MailerFactoryInterface::class) { return $this; }
            throw new \RuntimeException('Unexpected service');
        }
        public function createMailer($config) { return new TestSiteMailer($config); }
    }
    class TestSiteMailer {
        private string $recipient;
        public function __construct(private object $config) {}
        public function setSender($sender, $name) {}
        public function addRecipient($recipient) { $this->recipient = $recipient; }
        public function setSubject($subject) {}
        public function setBody($body) {}
        public function send() {
            if (!\Joomla\CMS\Factory::getApplication()->get('mailonline', 1)) { throw new \RuntimeException('Mail offline'); }
            file_put_contents(JPATH_BASE.'/sent.json', json_encode(['transport' => $this->config->get('smtphost'), 'recipient' => $this->recipient]));
            return true;
        }
    }
}
PHP
  v4Compose() {
    local code="$6" native_path
    native_path=$(v4DockerHostPath "$V4_DOCROOT")
    code="${code//\/var\/www\/html/$native_path}"
    MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' "$V4_TEST_PHP" -r "$code" "$7"
  }
}

@test "mail test boots Joomla CLI application before using the configured site mailer" {
  prepare_joomla_mail_application
  run v4MailTest
  assert_success
  jq -e '.test_message_sent==true' <<<"$output"
  jq -e '.transport=="mailpitdemo" and .recipient=="capture@example.test"' "$V4_DOCROOT/sent.json"
}

@test "mail test refuses delivery after site SMTP settings point outside capture" {
  prepare_joomla_mail_application
  sed 's/mailpitdemo/smtp.external.example/' "$V4_DOCROOT/configuration.php" >"$SANDBOX/replaced.php"
  mv "$SANDBOX/replaced.php" "$V4_DOCROOT/configuration.php"
  run v4MailTest
  assert_status 3
  [[ "$output" == *'no longer points at this sites capture service'* ]]
  [ ! -f "$V4_DOCROOT/sent.json" ]
}
