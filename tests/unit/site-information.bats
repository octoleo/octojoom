#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  VDM_CONTAINER_TYPE=joomla
  OCTOJOOM_OUTPUT=text
  REAL_DOCKER=''
  export REAL_DOCKER
}

site_proxy() {
  mkdir -p "${VDM_REPO_PATH}/traefik"
  cat >"${VDM_REPO_PATH}/traefik/docker-compose.yml" <<'YAML'
services:
  traefik:
    image: traefik
    ports:
      - "8088:80"
      - "8448:443"
YAML
}

@test "site inventory includes unchanged original sites and custom YAML without metadata" {
  make_joomla_container alpha ALPHA first
  mkdir -p "${VDM_REPO_PATH}/joomla/available/custom.example.test"
  printf 'services: {app: {image: custom/runtime:latest}}\n' >"${VDM_REPO_PATH}/joomla/available/custom.example.test/docker-compose.yml"
  run listJoomlaSites
  assert_success
  assert_output_contains first.vdm.dev
  assert_output_contains custom.example.test
  VDM_CONTAINER=custom.example.test
  run joomla__TRuST__info
  assert_success
  assert_output_contains 'Image configured: unknown'
}

@test "site facts resolve original shared ENV, a distinct project key and actual proxy ports" {
  make_joomla_container alpha ALPHA first
  site_proxy
  VDM_CONTAINER=first.vdm.dev
  run joomla__TRuST__info
  assert_success
  assert_output_contains 'Website URL: http://first.vdm.dev:8088'
  assert_output_contains "Host directory: ${VDM_PROJECT_PATH}/alpha/joomla"
  assert_output_contains "Environment: ${VDM_REPO_PATH}/joomla/.env"
  refute_output_contains rootsecret
  refute_output_contains 'secret'
}

@test "site reads use their own effective ENV and never assign credential globals" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  cp "${VDM_REPO_PATH}/joomla/.env" "${VDM_REPO_PATH}/joomla/available/second.vdm.dev/.env"
  writeEnvVariable "${VDM_REPO_PATH}/joomla/available/second.vdm.dev/.env" "VDM_PROJECT_PATH=${SANDBOX}/different projects" true
  VDM_ALPHA_DB_PASS=unchanged
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_HOST_PATH" "${VDM_PROJECT_PATH}/alpha/joomla"
  readJoomlaSiteFacts second.vdm.dev
  assert_equal "$VDM_SITE_HOST_PATH" "${SANDBOX}/different projects/beta/joomla"
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_HOST_PATH" "${VDM_PROJECT_PATH}/alpha/joomla"
  assert_equal "$VDM_ALPHA_DB_PASS" unchanged
}

@test "site facts distinguish enabled stopped and unavailable Docker" {
  make_joomla_container alpha ALPHA first
  link_enabled joomla first.vdm.dev
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_ENABLED" enabled
  assert_equal "$VDM_SITE_RUNNING" stopped
  fail_command docker-compose-ps 23
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_ENABLED" enabled
  assert_equal "$VDM_SITE_RUNNING" unavailable
}

@test "site runtime facts distinguish partial service state and unhealthy containers" {
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *' ps --all --quiet') printf 'webid\ndbid\n'; exit 0 ;;
  'inspect '*webid) printf 'running|unhealthy|joomla:latest|sha256:abc|joomlaalpha\n'; exit 0 ;;
  'inspect '*dbid) printf 'exited|not-defined|mariadb:latest|sha256:def|mariadbalpha\n'; exit 0 ;;
  *' exec -T joomlaalpha php -r echo PHP_VERSION;') printf '8.4.1'; exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_RUNNING" partial
  assert_equal "$VDM_SITE_HEALTH" unhealthy
  assert_equal "$VDM_SITE_RUNTIME_IMAGE" joomla:latest
  assert_equal "$VDM_SITE_PHP_VERSION" 8.4.1
}

@test "site path reports a named volume without fabricating a host path" {
  make_joomla_container alpha ALPHA first
  local compose="${VDM_REPO_PATH}/joomla/available/first.vdm.dev/docker-compose.yml"
  sed 's#${VDM_PROJECT_PATH}/alpha/joomla:#alpha_web:#' "$compose" >"$compose.next"
  mv "$compose.next" "$compose"
  VDM_CONTAINER=first.vdm.dev
  readJoomlaSiteFacts "$VDM_CONTAINER"
  assert_equal "$VDM_SITE_MOUNT_TYPE" volume
  assert_equal "$VDM_SITE_MOUNT_SOURCE" alpha_web
  run joomla__TRuST__path
  assert_failure
  assert_output_contains 'no resolved bind-mounted host directory'
}

@test "site installed release filter reads manifest and preserves unknown in unfiltered list" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  mkdir -p "${VDM_PROJECT_PATH}/alpha/joomla/administrator/manifests/files"
  printf '<extension><version>6.2.3</version></extension>\n' >"${VDM_PROJECT_PATH}/alpha/joomla/administrator/manifests/files/joomla.xml"
  VDM_SHORT=true
  run joomla__TRuST__list
  assert_success
  assert_output_contains first.vdm.dev
  assert_output_contains second.vdm.dev
  VDM_VERSION_PREFIX=6.2
  run joomla__TRuST__list
  assert_success
  assert_equal "$output" first.vdm.dev
}

@test "site nested document root reads scoped data without changing future defaults" {
  make_joomla_container alpha ALPHA first
  printf "VDM_ALPHA_DOCROOT='site'\nVDM_ALPHA_WEBSERVER='nginx'\n" >>"${VDM_REPO_PATH}/joomla/.env"
  VDM_CONTAINER=first.vdm.dev
  run joomla__TRuST__path
  assert_success
  assert_equal "$output" "${VDM_PROJECT_PATH}/alpha/joomla/site"
}

@test "site lifecycle stops only the selected site and preserves enabled state" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  link_enabled joomla first.vdm.dev
  link_enabled joomla second.vdm.dev
  running_containers joomlaalpha mariadbalpha phpmyadminalpha joomlabeta mariadbbeta phpmyadminbeta
  VDM_CONTAINER=first.vdm.dev
  run joomla__TRuST__stop
  assert_success
  assert_command '^docker compose .*available/first\.vdm\.dev/docker-compose\.yml stop$'
  refute_command '^docker compose .*second\.vdm\.dev'
  [ -L "${VDM_REPO_PATH}/joomla/enabled/first.vdm.dev" ]
  grep -qx joomlabeta "${STUB_DIR}/docker/running"
  run grep -qx joomlaalpha "${STUB_DIR}/docker/running"
  assert_failure
}

@test "site lifecycle preserves Compose failure status and disabled state" {
  make_joomla_container alpha ALPHA first
  VDM_CONTAINER=first.vdm.dev
  fail_command docker-compose-up 27
  run joomla__TRuST__redeploy
  assert_status 27
  [ ! -e "${VDM_REPO_PATH}/joomla/enabled/first.vdm.dev" ]
}

@test "site Compose isolates interpolated exported values including custom default expressions" {
  make_joomla_container alpha ALPHA first
  printf '\n# ${OTHER_SECRET:-default}\n' >>"${VDM_REPO_PATH}/joomla/available/first.vdm.dev/docker-compose.yml"
  export VDM_ALPHA_DB_PASS=wrong OTHER_SECRET=wrong
  hook_command docker <<'HOOK'
[ -z "${VDM_ALPHA_DB_PASS+x}" ] && [ -z "${OTHER_SECRET+x}" ] || exit 44
exit 0
HOOK
  run joomlaSiteCompose first.vdm.dev config --quiet
  assert_success
  assert_equal "$VDM_ALPHA_DB_PASS" wrong
  assert_equal "$OTHER_SECRET" wrong
}

@test "site navigation returns from an action to same details then back to list" {
  make_joomla_container alpha ALPHA first
  answers first.vdm.dev stop back back
  run showJoomlaWebsiteInformation
  assert_success
  assert_answers_used
  assert_command '^docker compose .*first\.vdm\.dev/docker-compose\.yml stop$'
  [ "$(grep -c 'Website: first.vdm.dev' "${STUB_DIR}/dialogs.full")" -eq 2 ]
}

@test "site JSON exposes facts but never environment credentials" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  VDM_CONTAINER=first.vdm.dev OCTOJOOM_OUTPUT=json
  run joomla__TRuST__info
  assert_success
  printf '%s' "$output" | jq -e '.site=="first.vdm.dev" and .running=="stopped"' >/dev/null
  refute_output_contains rootsecret
  refute_output_contains 'secret'
}

@test "site structured inspection supports custom service names and long bind mounts" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *'config --format json')
    printf '{"services":{"customweb":{"image":"registry.example/custom:latest","environment":{"JOOMLA_DB_HOST":"database"},"volumes":[{"type":"bind","source":"/custom path/site","target":"/var/www/html"}],"labels":{}},"database":{"image":"mariadb:latest"}}}'
    exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_SERVICE" customweb
  assert_equal "$VDM_SITE_IMAGE" registry.example/custom:latest
  assert_equal "$VDM_SITE_HOST_PATH" '/custom path/site'
}

@test "site URLs use actual direct published ports when no proxy is configured" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *'config --format json')
    printf '{"services":{"web":{"image":"joomla:latest","environment":{"JOOMLA_DB_HOST":"database"},"ports":[{"host_ip":"127.0.0.1","published":"8099","target":80}]}}}'
    exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_URL" 'http://127.0.0.1:8099'
  assert_equal "$VDM_SITE_ADMIN_URL" 'http://127.0.0.1:8099/administrator/'
}

@test "site permission repair targets the selected nested root and uses noninteractive sudo" {
  make_joomla_container alpha ALPHA first
  mkdir -p "${VDM_PROJECT_PATH}/alpha/joomla/site"
  printf 'private' >"${VDM_PROJECT_PATH}/alpha/joomla/site/configuration.php"
  printf "VDM_ALPHA_DOCROOT='site'\n" >>"${VDM_REPO_PATH}/joomla/.env"
  VDM_CONTAINER=first.vdm.dev OCTOJOOM_NON_INTERACTIVE=true
  run joomla__TRuST__permissions
  assert_success
  assert_command '^sudo -n find .*/alpha/joomla/site -type f'
  assert_command '^sudo -n find .*/alpha/joomla/site -type d'
  refute_command '^sudo.*chown'
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "site exec passes native arguments literally at the selected root" {
  make_joomla_container alpha ALPHA first
  VDM_CONTAINER=first.vdm.dev
  OCTOJOOM_ARGS=(php -r 'echo "literal $value; $(touch unsafe)";')
  hook_command docker <<'HOOK'
case "$*" in
  *' exec -T --workdir '*)
    [ "${*: -1}" = 'echo "literal $value; $(touch unsafe)";' ] || exit 29
    exit 28 ;;
esac
HOOK
  run joomla__TRuST__exec
  assert_status 28
  assert_command '^docker compose .*first.* exec -T --workdir /var/www/html joomlaalpha php -r'
  [ ! -e unsafe ]
}
