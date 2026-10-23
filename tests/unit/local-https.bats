#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container alpha ALPHA alpha example.test
  site=alpha.example.test
  directory="$VDM_REPO_PATH/joomla/available/$site"
  compose="$directory/docker-compose.yml"
  work="$SANDBOX/tls"
  mkdir -p "$work" "$VDM_PROJECT_PATH/traefik/conf"
  routes=$'joomlaalpha\tjoomlaalpha\talpha.example.test\nphpmyadminalpha\tphpmyadminalpha\talphadb.example.test\n'
}

@test "TLS rewrites only owned routers and retains application data and custom labels" {
  joomlaServiceProperty "$compose" joomlaalpha labels > "$work/labels"
  printf '%s\n' '      - "backup.owner=alpha"' '      - "traefik.http.routers.joomlaalpha.middlewares=auth,joomla-security,custom"' >> "$work/labels"
  joomlaSetServiceProperty "$compose" "$work/original.yml" joomlaalpha labels "$work/labels"
  joomlaTLSRewrite "$work/original.yml" "$work/result.yml" "$routes" local "$work"
  assert_file_contains "$work/result.yml" 'traefik.http.routers.joomlaalpha.tls=true'
  assert_file_contains "$work/result.yml" 'traefik.http.routers.phpmyadminalpha.tls=true'
  assert_file_contains "$work/result.yml" 'traefik.http.routers.joomlaalpha.middlewares=auth,custom'
  assert_file_contains "$work/result.yml" 'backup.owner=alpha'
  refute_file_contains "$work/result.yml" '.tls.certresolver='
  assert_equal "$(joomlaServiceProperty "$compose" joomlaalpha environment)" "$(joomlaServiceProperty "$work/result.yml" joomlaalpha environment)"
  assert_equal "$(joomlaServiceProperty "$compose" joomlaalpha volumes)" "$(joomlaServiceProperty "$work/result.yml" joomlaalpha volumes)"
  assert_equal "$(joomlaServiceBlock "$compose" mariadbalpha)" "$(joomlaServiceBlock "$work/result.yml" mariadbalpha)"
}

@test "TLS local public Cloudflare and HTTP round trip retains custom middleware" {
  joomlaTLSRewrite "$compose" "$work/local.yml" "$routes" local "$work"
  joomlaTLSRewrite "$work/local.yml" "$work/acme.yml" "$routes" acme "$work"
  assert_file_contains "$work/acme.yml" '.tls.certresolver=vdmresolver'
  joomlaTLSRewrite "$work/acme.yml" "$work/cloud.yml" "$routes" cloudflare "$work"
  assert_file_contains "$work/cloud.yml" '.tls.certresolver=cfresolver'
  joomlaTLSRewrite "$work/cloud.yml" "$work/http.yml" "$routes" http "$work"
  refute_file_contains "$work/http.yml" '.tls='
  refute_file_contains "$work/http.yml" '.tls.certresolver='
  refute_file_contains "$work/http.yml" 'joomla-security'
  assert_file_contains "$work/http.yml" '.entrypoints=web'
  assert_file_contains "$work/http.yml" '.priority=10000'
  joomlaTLSRewrite "$work/http.yml" "$work/repeated.yml" "$routes" http "$work"
  cmp "$work/http.yml" "$work/repeated.yml"
}

@test "TLS repeated local mode is byte stable" {
  joomlaTLSRewrite "$compose" "$work/first.yml" "$routes" local "$work"
  joomlaTLSRewrite "$work/first.yml" "$work/second.yml" "$routes" local "$work"
  cmp "$work/first.yml" "$work/second.yml"
}

@test "TLS rejects unfamiliar label syntax without modifying original" {
  printf '    labels:\n      traefik.enable: "true"\n' > "$work/map"
  joomlaSetServiceProperty "$compose" "$work/custom.yml" joomlaalpha labels "$work/map"
  cp "$work/custom.yml" "$work/before.yml"
  run joomlaTLSRewrite "$work/custom.yml" "$work/result.yml" "$routes" local "$work"
  assert_failure
  assert_output_contains 'list-style labels'
  cmp "$work/before.yml" "$work/custom.yml"
}

@test "TLS HTTP refuses custom TLS policy rather than accidentally retaining encryption" {
  joomlaServiceProperty "$compose" joomlaalpha labels > "$work/labels"
  printf '%s\n' '      - "traefik.http.routers.joomlaalpha.tls.options=custom@file"' >> "$work/labels"
  joomlaSetServiceProperty "$compose" "$work/custom.yml" joomlaalpha labels "$work/labels"
  run joomlaTLSRewrite "$work/custom.yml" "$work/result.yml" "$routes" http "$work"
  assert_failure
  assert_output_contains 'custom TLS settings'
}

@test "TLS discovery follows actual resolved labels not stale saved mode" {
  joomlaSiteCompose() {
    cat <<'JSON'
{"services":{"nginxalpha":{"labels":{"traefik.http.routers.joomlaalpha.rule":"Host(`alpha.example.test`)","traefik.http.routers.joomlaalpha.tls":"true"}},"phpmyadminalpha":{"labels":{"traefik.http.routers.phpmyadminalpha.rule":"Host(`alphadb.example.test`)"}},"unrelated":{"labels":{"traefik.http.routers.custom.rule":"Host(`elsewhere.example.test`)"}}}}
JSON
  }
  joomlaTLSDiscover "$site"
  assert_equal "$VDM_TLS_MODE" local
  [[ "$VDM_TLS_ROUTES" == *$'nginxalpha\tjoomlaalpha\talpha.example.test'* ]]
  [[ "$VDM_TLS_ROUTES" == *alphadb.example.test* && "$VDM_TLS_ROUTES" != *elsewhere* ]]
}

@test "TLS discovery refuses duplicate website routers" {
  joomlaSiteCompose() {
    printf '%s' '{"services":{"a":{"labels":{"traefik.http.routers.joomlaalpha.rule":"Host(`alpha.example.test`)"}},"b":{"labels":{"traefik.http.routers.joomlabeta.rule":"Host(`alpha.example.test`)"}}}}'
  }
  run joomlaTLSDiscover "$site"
  assert_failure
}

@test "TLS scoped environment retains credentials and saved settings but not other sites" {
  printf '%s\n' 'VDM_ALPHA_TLS_MODE="local"' 'VDM_ALPHA_SMTP_PASSWORD="literal$pass"' 'VDM_OTHER_DB_PASS="private-other"' >> "$VDM_REPO_PATH/joomla/.env"
  siteWriteScopedEnv "$compose" "$VDM_REPO_PATH/joomla/.env" ALPHA "$work/.env"
  assert_file_contains "$work/.env" 'VDM_ALPHA_TLS_MODE='
  assert_file_contains "$work/.env" 'VDM_ALPHA_DB_PASS='
  assert_file_contains "$work/.env" 'VDM_ALPHA_SMTP_PASSWORD='
  refute_file_contains "$work/.env" VDM_OTHER
}

@test "TLS Joomla URL patch preserves subdirectories cookie domain and force_ssl on HTTPS" {
  cat > "$work/config.php" <<'PHP'
<?php
class JConfig {
 public $live_site = 'http://alpha.example.test:8080/subdir';
 public $cookie_domain = '.example.test';
 public $force_ssl = 2;
 public $password = 'untouched';
}
PHP
  joomlaTLSPatchConfiguration "$work/config.php" "$work/https.php" "$site" https://alpha.example.test:8443 local
  assert_file_contains "$work/https.php" "https://alpha.example.test:8443/subdir"
  assert_file_contains "$work/https.php" "public \$cookie_domain = '.example.test';"
  assert_file_contains "$work/https.php" 'public $force_ssl = 2;'
  joomlaTLSPatchConfiguration "$work/https.php" "$work/http.php" "$site" http://alpha.example.test:8080 http
  assert_file_contains "$work/http.php" 'public $force_ssl = 0;'
}

@test "TLS empty live_site stays empty and custom expressions are refused" {
  printf '%s\n' '<?php' 'class JConfig {' " public \$live_site = '';" '}' > "$work/config.php"
  joomlaTLSPatchConfiguration "$work/config.php" "$work/result.php" "$site" https://alpha.example.test local
  assert_file_contains "$work/result.php" "public \$live_site = '';"
  printf '%s\n' '<?php' 'class JConfig {' ' public $live_site = getenv("URL");' '}' > "$work/config.php"
  run joomlaTLSPatchConfiguration "$work/config.php" "$work/result.php" "$site" https://alpha.example.test local
  assert_failure
}

@test "TLS URL preserves nondefault proxy ports" {
  assert_equal "$(joomlaTLSURL local "$site" 8443)" "https://$site:8443"
  assert_equal "$(joomlaTLSURL local "$site" 443)" "https://$site"
  assert_equal "$(joomlaTLSURL http "$site" 8080)" "http://$site:8080"
}

@test "TLS task actions modes and setup option are discoverable" {
  run cliTaskNames joomla
  assert_output_contains ssl
  assert_equal "$(cliComplete --mode '' joomla ssl)" $'http\nlocal\nacme\ncloudflare'
  assert_equal "$(cliComplete --action '' joomla ssl)" $'status\nset\nrenew'
  assert_equal "$(cliOptionVariable --tls-mode)" VDM_TLS_CHOICE
}

@test "TLS headless prerequisite refuses interactive trust installation" {
  OCTOJOOM_NON_INTERACTIVE=true
  mkcert() { if [ "$1" = -CAROOT ]; then printf '%s\n' "$work/ca"; else touch "$work/install-called"; fi; }
  joomlaTLSTrusted() { return 1; }
  run joomlaTLSPrerequisites
  assert_failure
  assert_output_contains 'mkcert -install interactively'
  refute_file_exists "$work/install-called"
}

@test "TLS proxy rejects remote Docker before changing files" {
  mkdir -p "$VDM_REPO_PATH/traefik"
  touch "$VDM_REPO_PATH/traefik/docker-compose.yml"
  DOCKER_HOST=ssh://remote
  run joomlaTLSProxy local
  assert_failure
  assert_output_contains 'local Docker context'
}

# Exercise the real transaction and ENV/label transformations; only external
# certificate/container IO is replaced here. Real IO has its own acceptance job.
tls_transaction_fixture() {
  joomlaTLSDiscover() { resolveJoomlaSite "$1"; VDM_TLS_ROUTES=$'joomlaalpha\tjoomlaalpha\talpha.example.test\nphpmyadminalpha\tphpmyadminalpha\talphadb.example.test\n'; VDM_TLS_MODE=http; }
  joomlaTLSProxy() { VDM_TLS_CONF="$VDM_PROJECT_PATH/traefik/conf"; VDM_TLS_PORT=8443; }
  joomlaTLSPrerequisites() { VDM_TLS_CAROOT="$work/ca"; }
  joomlaTLSCertificateValid() { [ -f "$1" ]; }
  mkcert() { printf 'certificate\n' > "$2"; printf 'leaf-key\n' > "$4"; }
  updateHostFile() { :; }
  joomlaDatabaseConfigurationFile() { : > "$3"; }
}

@test "TLS transaction isolates shared ENV and removes local certificate from public mode" {
  tls_transaction_fixture
  cp "$VDM_REPO_PATH/joomla/.env" "$work/shared-before"
  run joomlaTLSSet "$site" local
  assert_success
  assert_output_contains "https://$site:8443"
  cmp "$VDM_REPO_PATH/joomla/.env" "$work/shared-before"
  assert_file_contains "$directory/.env" 'VDM_ALPHA_TLS_MODE="local"'
  [ -f "$VDM_PROJECT_PATH/traefik/conf/octojoom-$site.yaml" ]
  run joomlaTLSSet "$site" acme
  assert_success
  refute_file_exists "$VDM_PROJECT_PATH/traefik/conf/octojoom-$site.yaml"
  assert_file_contains "$compose" '.tls.certresolver=vdmresolver'
  refute_file_exists "$directory/.octojoom-change.lock"
}

@test "TLS failed publication restores dynamic certificate and original Compose" {
  tls_transaction_fixture
  cp "$compose" "$work/before.yml"
  sitePublishConfiguration() { return 1; }
  run joomlaTLSSet "$site" local
  assert_failure
  cmp "$compose" "$work/before.yml"
  refute_file_exists "$directory/.env"
  refute_file_exists "$VDM_PROJECT_PATH/traefik/conf/octojoom-$site.yaml"
  refute_file_exists "$directory/.octojoom-change.lock"
}

@test "TLS invalid Compose never creates certificates or changes settings" {
  tls_transaction_fixture
  siteValidateCompose() { return 1; }
  run joomlaTLSSet "$site" local
  assert_failure
  refute_file_exists "$directory/.env"
  [ -z "$(ls -A "$VDM_PROJECT_PATH/traefik/conf")" ]
}

@test "TLS rejects concurrent site changes and retains their lock" {
  tls_transaction_fixture
  mkdir "$directory/.octojoom-change.lock"
  run joomlaTLSSet "$site" local
  assert_failure
  assert_output_contains 'Another configuration change'
  [ -d "$directory/.octojoom-change.lock" ]
}

@test "TLS selector excludes local sites and changes only checked websites" {
  make_joomla_container beta BETA beta example.test
  joomlaTLSDiscover() { VDM_TLS_MODE=http; [ "$1" != beta.example.test ] || VDM_TLS_MODE=local; }
  joomlaTLSSet() { printf '%s\n' "$1" >> "$SANDBOX/selected-sites"; }
  whiptail() { printf '%s\n' "$*" >> "$SANDBOX/menu-arguments"; command whiptail "$@"; }
  answers alpha.example.test
  showJoomlaTLSSelection
  assert_equal "$(cat "$SANDBOX/selected-sites")" alpha.example.test
  assert_file_contains "$SANDBOX/menu-arguments" '0 112 0'
  refute_file_contains "$SANDBOX/menu-arguments" beta.example.test
}

@test "TLS JSON input uses the same action and mode as direct flags" {
  printf '%s' '{"type":"joomla","task":"ssl","container":"alpha.example.test","action":"set","options":{"mode":"local","update-hosts":true}}' > "$work/request.json"
  parseCLI --input-json "$work/request.json"
  cliApplyValues
  assert_equal "$VDM_MODE" local
  assert_equal "$VDM_ACTION" set
  assert_equal "$VDM_CONTAINER" alpha.example.test
  assert_equal "$VDM_UPDATE_HOST" true
  cliPreflightOtherTask
}
