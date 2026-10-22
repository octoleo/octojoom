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
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" enabled
  if ! is_windows; then [ -L "${VDM_REPO_PATH}/joomla/enabled/first.vdm.dev" ]; fi
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

@test "database and backup menus keep the selected website and return to its details" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  showJoomlaDatabaseTools() { printf 'tools %s\n' "$1" >> "$SANDBOX/site-actions"; }
  showJoomlaDatabaseChange() { printf 'change %s\n' "$1" >> "$SANDBOX/site-actions"; }
  showJoomlaBackups() { printf 'backups %s\n' "$1" >> "$SANDBOX/site-actions"; }
  answers first.vdm.dev database database-change backups back back
  run showJoomlaWebsiteInformation
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/site-actions")" $'tools first.vdm.dev\nchange first.vdm.dev\nbackups first.vdm.dev'
  [ "$(grep -c 'Website: first.vdm.dev' "$STUB_DIR/dialogs.full")" -eq 4 ]
  refute_command '^docker compose .*second\.vdm\.dev'
}

@test "Joomla batch backup action returns to the existing Joomla menu" {
  make_joomla_container alpha ALPHA first
  showJoomlaBackupSelection() { printf 'selected\n' >> "$SANDBOX/backup-selection"; }
  answers backup back
  run showJoomla
  assert_success
  assert_answers_used
  assert_equal "$(cat "$SANDBOX/backup-selection")" selected
  [ "$(grep -c 'Make your selection' "$STUB_DIR/dialogs.full")" -eq 2 ]
}

@test "restoration can open destination details directly and Back returns to its caller" {
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA restored
  answers back
  run showJoomlaWebsiteInformation restored.vdm.dev true
  assert_success
  assert_answers_used
  assert_file_contains "$STUB_DIR/dialogs.full" 'Website: restored.vdm.dev'
  refute_file_contains "$STUB_DIR/dialogs.full" 'Select a website'
  refute_command '^docker compose .*first\.vdm\.dev'
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
  # Exercise Unix privilege delegation with the sandboxed sudo stand-in.
  OS_NUMBER=1
  make_joomla_container alpha ALPHA first
  mkdir -p "${VDM_PROJECT_PATH}/alpha/joomla/site"
  printf 'private' >"${VDM_PROJECT_PATH}/alpha/joomla/site/configuration.php"
  printf "VDM_ALPHA_DOCROOT='site'\n" >>"${VDM_REPO_PATH}/joomla/.env"
  VDM_CONTAINER=first.vdm.dev OCTOJOOM_NON_INTERACTIVE=true
  run joomla__TRuST__permissions
  assert_success
  assert_command '^sudo( -n)? find .*/alpha/joomla/site -type f'
  assert_command '^sudo( -n)? find .*/alpha/joomla/site -type d'
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

@test "site facts distinguish logical named volume source from actual daemon volume name" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *'config --format json')
    printf '{"services":{"web":{"image":"joomla:latest","volumes":[{"type":"volume","source":"siteweb","target":"/var/www/html"}]}},"volumes":{"siteweb":{"name":"project_siteweb"}}}'
    exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_MOUNT_SOURCE" siteweb
  assert_equal "$VDM_SITE_VOLUME_NAME" project_siteweb
}

@test "original project permission repair has headless parity including database storage" {
  # Exercise Unix privilege delegation with the sandboxed sudo stand-in.
  OS_NUMBER=1
  make_joomla_container alpha ALPHA first
  make_joomla_container beta BETA second
  VDM_PROJECT=alpha VDM_PUID=1000 VDM_PGID=1000 OCTOJOOM_NON_INTERACTIVE=true
  run joomla__TRuST__fix
  assert_success
  assert_command '^sudo( -n)? chown -R 1000:1000 .*/alpha/joomla$'
  assert_command '^sudo( -n)? chown -R 999:999 .*/alpha/db$'
  refute_command '^sudo.*beta'
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "headless project permission repair rejects missing identity before changes" {
  make_joomla_container alpha ALPHA first
  VDM_PROJECT=alpha VDM_PUID=1000 OCTOJOOM_NON_INTERACTIVE=true
  unset VDM_PGID
  run joomla__TRuST__fix
  assert_status 17
  refute_command '^sudo'
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "unrelated Nginx service does not replace the Joomla website URL or server" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *'config --format json')
    printf '{"services":{"app":{"image":"joomla:php8.4-apache","volumes":[{"type":"volume","source":"siteweb","target":"/var/www/html"}],"ports":[{"host_ip":"127.0.0.1","published":"8081","target":80}]},"zdocs":{"image":"nginx:stable-alpine","volumes":[{"type":"volume","source":"docs","target":"/var/www/html"}],"ports":[{"host_ip":"127.0.0.1","published":"8082","target":80}]}}}'
    exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_URL" http://127.0.0.1:8081
  assert_equal "$VDM_SITE_WEBSERVER" apache
}

@test "Nginx companion serving the Joomla mount supplies its HTTP URL" {
  command -v jq >/dev/null 2>&1 || skip 'optional jq is unavailable'
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *'config --format json')
    printf '{"services":{"app":{"image":"joomla:php8.4-fpm","volumes":[{"type":"volume","source":"siteweb","target":"/var/www/html"}]},"http":{"image":"nginx:stable-alpine","depends_on":{"app":{"condition":"service_healthy"}},"volumes":[{"type":"volume","source":"siteweb","target":"/var/www/html","read_only":true}],"ports":[{"host_ip":"127.0.0.1","published":"8091","target":80}]}}}'
    exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_URL" http://127.0.0.1:8091
  assert_equal "$VDM_SITE_WEBSERVER" nginx
}

@test "configured but absent services are partial and do not produce healthy website status" {
  make_joomla_container alpha ALPHA first
  hook_command docker <<'HOOK'
case "$*" in
  *' ps --all --quiet') printf 'dbid\n'; exit 0 ;;
  'inspect '*dbid) printf 'running|healthy|mariadb:latest|sha256:def|mariadbalpha\n'; exit 0 ;;
esac
HOOK
  readJoomlaSiteFacts first.vdm.dev
  assert_equal "$VDM_SITE_RUNNING" partial
  assert_equal "$VDM_SITE_HEALTH" partially-checked
}

@test "native exec keeps a non-web service's own working directory" {
  make_joomla_container alpha ALPHA first
  VDM_CONTAINER=first.vdm.dev VDM_SERVICE=mariadbalpha
  OCTOJOOM_ARGS=(mariadb --version)
  run joomla__TRuST__exec
  assert_success
  assert_command '^docker compose .* exec -T mariadbalpha mariadb --version$'
  refute_command '^docker compose .*exec -T --workdir .*mariadbalpha'
}

@test "information retains configured database and viewer images when Docker is unavailable" {
  make_joomla_container alpha ALPHA first
  VDM_CONTAINER=first.vdm.dev
  fail_command docker-compose-ps 23
  run joomla__TRuST__info
  assert_success
  assert_output_contains 'Services: unavailable'
  assert_output_contains 'mariadbalpha: mariadb:latest'
  assert_output_contains 'phpmyadminalpha: phpmyadmin/phpmyadmin'
}

@test "Windows copied enable entries require current Compose and private environment contents" {
  make_joomla_container alpha ALPHA first
  local available="${VDM_REPO_PATH}/joomla/available/first.vdm.dev" enabled="${VDM_REPO_PATH}/joomla/enabled/first.vdm.dev"
  cp "${VDM_REPO_PATH}/joomla/.env" "$available/.env"
  mkdir -p "${VDM_REPO_PATH}/joomla/enabled"
  cp -R "$available" "$enabled"
  OS_NUMBER=3
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" enabled
  printf '\n# changed\n' >>"$enabled/docker-compose.yml"
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" invalid-link
  cp "$available/docker-compose.yml" "$enabled/docker-compose.yml"
  printf '\nVDM_ALPHA_DOCROOT=other\n' >>"$enabled/.env"
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" invalid-link
  rm "$enabled/.env"
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" invalid-link
  cp "$available/.env" "$enabled/.env"
  OS_NUMBER=1
  assert_equal "$(getJoomlaSiteEnabledState first.vdm.dev)" invalid-link
}

@test "site JSON reader preserves native arguments and normalizes CRLF without hiding failure" {
  jq() {
    [ "${MSYS_NO_PATHCONV:-}" = 1 ] && [ "${MSYS2_ARG_CONV_EXCL:-}" = '*' ] || return 42
    [ "$1" = --arg ] && [ "$2" = root ] && [ "$3" = /var/www/html ] || return 43
    printf 'app\r\n/var/www/html\r\n'
    return 7
  }
  run joomlaSiteJSON --arg root /var/www/html '$root'
  assert_status 7
  assert_equal "$output" $'app\n/var/www/html'
}
