#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  OCTOJOOM_NON_INTERACTIVE=true
  VDM_TRAEFIK_GATEWAY=proxy_test_gateway
  proxy_dir="$VDM_REPO_PATH/traefik"
  proxy_file="$proxy_dir/docker-compose.yml"
  proxy_env="$proxy_dir/.env"
  mkdir -p "$proxy_dir"
}

legacy_proxy() {
  cat > "$proxy_file" <<'YAML'
# Preserve this local proxy customization.
services:
  traefik:
    image: "traefik:custom"
    container_name: traefik
    command:
      - --entrypoints.web.address=:80
      - --providers.docker=true
      - --certificatesresolvers.vdmresolver.acme.email=${VDM_SECURE_EMAIL:-owner@example.test}
    ports:
      - "8080:80"
      - "8443:443"
    volumes:
      - "${VDM_PROJECT_PATH}/traefik/acme.json:/acme.json"
    environment:
      - CUSTOM_SECRET=${VDM_CUSTOM_SECRET:-unchanged}
    labels:
      - "custom.owner=preserved"
    networks:
      - proxy
networks:
  proxy:
    external: true
    name: proxy_test_gateway
YAML
}

# Daemon operations are simulated; config uses Compose's actual parser when
# installed. The fallback model is restricted to this file's generated fixtures.
proxy_daemon() {
  docker() {
    printf '%s\n' "$*" >> "$SANDBOX/proxy-docker.log"
    case "$1" in
      context) printf 'unix:///var/run/docker.sock\n'; return;;
      info|network) return 0;;
      inspect)
        if [ -f "$SANDBOX/proxy-running" ]; then printf 'true\n'; else printf 'false\n'; fi
        return;;
      ps)
        if [ -f "$SANDBOX/proxy-running" ]; then printf 'traefik\n'; fi
        return;;
      compose) ;;
      *) return 1;;
    esac
    local file='' action='' argument previous=''
    for argument in "${@:2}"; do
      if [ "$previous" = --file ] || [ "$previous" = -f ]; then file="$argument"; fi
      case "$argument" in config|ps|up|stop|down) action="$argument";; esac
      previous="$argument"
    done
    case "$action" in
      config)
        if [ -f "$SANDBOX/proxy-invalid" ] && [ "$file" != "$proxy_file" ] && grep -q -- '--providers.file.directory=/conf' "$file"; then return 17; fi
        if [ -n "${REAL_DOCKER:-}" ]; then "$REAL_DOCKER" "$@"; else proxy_fixture_model "$file"; fi;;
      ps)
        if [ -f "$SANDBOX/proxy-running" ]; then printf 'traefik\n'; fi;;
      up)
        printf '%s\n' "$*" >> "$SANDBOX/proxy-up.log"
        if [ -f "$SANDBOX/proxy-fail-after-start" ]; then
          touch "$SANDBOX/proxy-running"
          rm "$SANDBOX/proxy-fail-after-start"
          return 19
        fi
        if [ -f "$SANDBOX/proxy-fail-start" ]; then rm "$SANDBOX/proxy-fail-start"; return 19; fi
        touch "$SANDBOX/proxy-running";;
      stop|down) rm -f "$SANDBOX/proxy-running";;
      *) return 1;;
    esac
  }
  ensurePortsFree() { return 0; }
}

proxy_fixture_model() {
  local file="$1" commands conf='' port=443 http_port=0 udp_port=0
  commands=$(sed -nE 's/^      - (--[^ ]+)[[:space:]]*$/\1/p' "$file" | joomlaSiteJSON -Rsc 'split("\n") | map(select(length>0))')
  if grep -q ':443' "$file"; then
    if grep -q '8443:443' "$file"; then port=8443; fi
  else port=0; fi
  if grep -q '8080:80' "$file"; then http_port=8080
  elif grep -q '"80:80"' "$file"; then http_port=80; fi
  if grep -q '9443:443/udp' "$file"; then udp_port=9443; fi
  if grep -q ':/conf' "$file"; then conf="$VDM_PROJECT_PATH/traefik/conf"; fi
  joomlaSiteJSON -n --argjson commands "$commands" --arg conf "$conf" --argjson port "$port" --argjson http "$http_port" --argjson udp "$udp_port" '
    {services:{traefik:{image:"traefik:custom",command:$commands,
      ports:((if $http>0 then [{target:80,published:($http|tostring)}] else [] end) +
        (if $port>0 then [{target:443,published:($port|tostring),protocol:"tcp"}] else [] end) +
        (if $udp>0 then [{target:443,published:($udp|tostring),protocol:"udp"}] else [] end)),
      volumes:(if $conf!="" then [{type:"bind",source:$conf,target:"/conf"}] else [] end),
      networks:{proxy:{}}}},networks:{proxy:{external:true,name:"proxy_test_gateway"}}}'
}

@test "Traefik ENV selection uses its own settings then the legacy global file" {
  assert_equal "$(traefikComposeEnvFile)" "$VDM_SRC_PATH/.env"
  printf 'VDM_SECURE_EMAIL="proxy@example.test"\n' > "$proxy_env"
  assert_equal "$(traefikComposeEnvFile)" "$proxy_env"
  rm "$proxy_env" "$VDM_SRC_PATH/.env"
  assert_equal "$(traefikComposeEnvFile)" ''
}

@test "Traefik Compose accepts default expressions and omits an absent ENV argument" {
  legacy_proxy
  rm "$VDM_SRC_PATH/.env"
  docker() { printf '%s\n' "$@" > "$SANDBOX/proxy-arguments"; }
  run traefikRunCompose "$proxy_file" config --format json
  assert_success
  refute_file_contains "$SANDBOX/proxy-arguments" --env-file
  assert_file_contains "$SANDBOX/proxy-arguments" "$proxy_file"
}

@test "Traefik Compose preserves explicit ENV precedence and the original project directory" {
  [ -n "${REAL_DOCKER:-}" ] || skip "Docker Compose is not installed"
  legacy_proxy
  printf 'VDM_PROJECT_PATH="%s"\nVDM_CUSTOM_SECRET="from-file"\n' "$VDM_PROJECT_PATH" > "$proxy_env"
  export VDM_CUSTOM_SECRET=wrong-inherited-value
  # A staged file must still resolve relative mounts against the proxy directory.
  mkdir -p "$SANDBOX/staging"
  sed 's#${VDM_PROJECT_PATH}/traefik/acme.json#./acme.json#' "$proxy_file" > "$SANDBOX/staging/proxy.yml"
  run traefikRunCompose "$SANDBOX/staging/proxy.yml" config --format json
  assert_success
  assert_equal "$(printf '%s' "$output" | joomlaSiteJSON -r '.services.traefik.environment.CUSTOM_SECRET')" from-file
  assert_equal "$(printf '%s' "$output" | joomlaSiteJSON -r '.services.traefik.volumes[] | select(.target=="/acme.json").source')" "$proxy_dir/acme.json"
  assert_equal "$VDM_CUSTOM_SECRET" wrong-inherited-value
}

@test "local HTTPS preparation repairs a stopped legacy proxy and preserves customization" {
  legacy_proxy
  proxy_daemon
  run traefikPrepareLocalHTTPS false
  assert_success
  assert_file_contains "$proxy_file" '--entrypoints.websecure.address=:443'
  assert_file_contains "$proxy_file" '--providers.file.directory=/conf'
  assert_file_contains "$proxy_file" '--providers.file.watch=true'
  assert_file_contains "$proxy_file" '8443:443'
  assert_file_contains "$proxy_file" 'image: "traefik:custom"'
  assert_file_contains "$proxy_file" 'VDM_SECURE_EMAIL:-owner@example.test'
  assert_file_contains "$proxy_file" 'CUSTOM_SECRET=${VDM_CUSTOM_SECRET:-unchanged}'
  assert_file_contains "$proxy_file" 'custom.owner=preserved'
  assert_file_contains "$proxy_file" '# Preserve this local proxy customization.'
  assert_file_contains "$proxy_file" 'name: proxy_test_gateway'
  [ -d "$VDM_PROJECT_PATH/traefik/conf" ]
  refute_file_exists "$SANDBOX/proxy-up.log"
}

@test "local HTTPS preparation is idempotent after repairing a running proxy" {
  legacy_proxy
  proxy_daemon
  touch "$SANDBOX/proxy-running"
  run traefikPrepareLocalHTTPS false
  assert_success
  assert_file_exists "$SANDBOX/proxy-up.log"
  [ "$(wc -l < "$SANDBOX/proxy-up.log" | tr -d ' ')" = 1 ]
  grep -qE ' up .* traefik$' "$SANDBOX/proxy-up.log"
  cp "$proxy_file" "$SANDBOX/prepared.yml"
  run traefikPrepareLocalHTTPS false
  assert_success
  cmp "$proxy_file" "$SANDBOX/prepared.yml"
  [ "$(wc -l < "$SANDBOX/proxy-up.log" | tr -d ' ')" = 1 ]
}

@test "local HTTPS preparation publishes the HTTPS port when a legacy proxy lacks it" {
  legacy_proxy
  sed '/8443:443/d' "$proxy_file" > "$SANDBOX/http-only.yml"
  mv "$SANDBOX/http-only.yml" "$proxy_file"
  proxy_daemon
  run traefikPrepareLocalHTTPS false
  assert_success
  assert_file_contains "$proxy_file" '443:443'
  assert_file_contains "$proxy_file" '8080:80'
  refute_file_exists "$SANDBOX/proxy-up.log"
}

@test "local HTTPS preparation can create and explicitly start a missing proxy" {
  proxy_daemon
  run traefikPrepareLocalHTTPS true
  assert_success
  assert_file_exists "$proxy_file"
  assert_file_contains "$proxy_file" '--providers.file.directory=/conf'
  assert_file_contains "$proxy_file" '--entrypoints.websecure.address=:443'
  assert_file_exists "$SANDBOX/proxy-running"
}

@test "local HTTPS preparation does not implicitly start a newly created proxy" {
  proxy_daemon
  run traefikPrepareLocalHTTPS false
  assert_success
  assert_file_exists "$proxy_file"
  refute_file_exists "$SANDBOX/proxy-up.log"
  refute_file_exists "$SANDBOX/proxy-running"
}

@test "local HTTPS preparation never publishes an invalid candidate" {
  legacy_proxy
  proxy_daemon
  cp "$proxy_file" "$SANDBOX/original.yml"
  touch "$SANDBOX/proxy-invalid"
  run traefikPrepareLocalHTTPS false
  assert_failure
  cmp "$proxy_file" "$SANDBOX/original.yml"
  refute_file_exists "$SANDBOX/proxy-up.log"
}

@test "local HTTPS preparation restores the original after a failed proxy restart" {
  local recovery
  legacy_proxy
  proxy_daemon
  cp "$proxy_file" "$SANDBOX/original.yml"
  touch "$SANDBOX/proxy-running" "$SANDBOX/proxy-fail-start"
  run traefikPrepareLocalHTTPS false
  assert_failure
  cmp "$proxy_file" "$SANDBOX/original.yml"
  [ "$(wc -l < "$SANDBOX/proxy-up.log" | tr -d ' ')" = 2 ]
  [ -f "$SANDBOX/proxy-running" ]
  recovery=$(printf '%s\n' "$output" | sed -n 's/^Traefik preparation failed\. Recovery files: //p')
  [ -n "$recovery" ]
  cmp "$recovery/original.yml" "$SANDBOX/original.yml"
  refute_file_exists "$proxy_dir/.octojoom-change.lock"
}

@test "local HTTPS preparation stops an unchanged proxy after its startup fails" {
  legacy_proxy
  proxy_daemon
  traefikPrepareLocalHTTPS false
  cp "$proxy_file" "$SANDBOX/prepared.yml"
  touch "$SANDBOX/proxy-fail-after-start"
  run traefikPrepareLocalHTTPS true
  assert_failure
  cmp "$proxy_file" "$SANDBOX/prepared.yml"
  refute_file_exists "$SANDBOX/proxy-running"
  grep -qE ' stop traefik$' "$SANDBOX/proxy-docker.log"
}

@test "local HTTPS preparation leaves an HTTPS-only proxy without an HTTP listener" {
  legacy_proxy
  sed -e '/--entrypoints.web.address=:80/d' -e '/8080:80/d' "$proxy_file" > "$SANDBOX/https-only.yml"
  mv "$SANDBOX/https-only.yml" "$proxy_file"
  proxy_daemon
  run traefikPrepareLocalHTTPS false
  assert_success
  refute_file_contains "$proxy_file" '--entrypoints.web.address=:80'
  refute_file_contains "$proxy_file" '80:80'
  assert_file_contains "$proxy_file" '8443:443'
  assert_file_contains "$proxy_file" '--entrypoints.websecure.address=:443'
}

@test "local HTTPS proxy discovery uses the TCP publication when UDP has another port" {
  legacy_proxy
  sed '/"8443:443"/a\
      - "9443:443/udp"' "$proxy_file" > "$SANDBOX/tcp-and-udp.yml"
  mv "$SANDBOX/tcp-and-udp.yml" "$proxy_file"
  proxy_daemon
  traefikPrepareLocalHTTPS false
  joomlaTLSProxy local
  assert_equal "$VDM_TLS_PORT" 8443
  assert_file_contains "$proxy_file" '9443:443/udp'
}
