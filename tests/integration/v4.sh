#!/usr/bin/env bash
# End-to-end v4 CLI acceptance against real Joomla/PHP and database containers.
# Run separately in CI: V4_SCENARIO=lifecycle|mysql|postgres|migration bash tests/integration/v4.sh
# This is intentionally an actual Joomla installation, not a mock JConfig fixture.
# TLS uses a disposable CA and hosts file, without installing host trust.
# Lifecycle sharing exposes only this generated fixture for the test duration.
# Every resource is scoped to a random test identity; cleanup never prunes Docker.

set -e -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../../src/octojoom"
SCENARIO="${V4_SCENARIO:-lifecycle}"
if [ "${SCENARIO}" = migration ]; then exec bash "${TEST_DIR}/v4-migration.sh"; fi
JOOMLA_VERSION='5.4.9'
PHP_VERSION='8.2'
PHP_TARGET_VERSION='8.3'
MARIADB_VERSION='11.4.12'
MYSQL_VERSION='8.4'
POSTGRES_VERSION='16'

fail() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   - %s\n' "$*"; }

[[ "${OSTYPE}" == linux* ]] || fail 'This test requires a Linux Docker host.'
(( BASH_VERSINFO[0] >= 4 )) || fail 'This test requires Bash 4 or newer.'
case "${SCENARIO}" in lifecycle | mysql | postgres) ;; *) fail "Unknown V4_SCENARIO: ${SCENARIO}" ;; esac
for command in docker jq curl timeout awk sed sha256sum tar gzip zip unzip; do
  command -v "${command}" >/dev/null || fail "Missing prerequisite: ${command}"
done
DOCKER_BIN="$(type -P docker)"
timeout 15s "${DOCKER_BIN}" info >/dev/null || fail 'Docker daemon is unavailable.'
timeout 15s "${DOCKER_BIN}" compose version >/dev/null || fail 'Docker Compose v2 is required.'
if [ "${SCENARIO}" = lifecycle ]; then
  command -v mkcert >/dev/null || fail 'The lifecycle scenario requires mkcert.'
  command -v python3 >/dev/null || fail 'The lifecycle scenario requires Python 3 to allocate test ports.'
  if "${DOCKER_BIN}" inspect octojoom-local-proxy >/dev/null 2>&1 || "${DOCKER_BIN}" network inspect octojoom_local >/dev/null 2>&1; then
    fail 'Run lifecycle acceptance on an isolated Docker host without an existing OctoJoom local TLS proxy.'
  fi
fi
if (( EUID != 0 )); then
  if ! command -v sudo >/dev/null || ! sudo -n true; then
    fail 'Root or passwordless sudo is required for container-owned files.'
  fi
fi
privileged() { if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/octojoom-v4.XXXXXXXX")"
RUN_ID="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')"
OCTOJOOM_HOME="${WORK}/home"
export OCTOJOOM_HOME
REPO_PATH="${OCTOJOOM_HOME}/Docker"
PROJECT_PATH="${OCTOJOOM_HOME}/Projects"
BACKUP_PATH="${OCTOJOOM_HOME}/Backups"
NETWORK="octojoom-v4-${RUN_ID}"
SOURCE_KEY="source${RUN_ID}"
TARGET_KEY="target${RUN_ID}"
BLOCKED_KEY="blocked${RUN_ID}"
SOURCE_SITE="source.${RUN_ID}.invalid"
TARGET_SITE="target.${RUN_ID}.invalid"
BLOCKED_SITE="blocked.${RUN_ID}.invalid"
ADMIN_PASSWORD="Integration-Admin-${RUN_ID}"
DB_PASSWORD="Integration-Db-${RUN_ID}"
ROOT_PASSWORD="Integration-Root-${RUN_ID}"
RESULT="${WORK}/result.json"
ERROR_OUTPUT="${WORK}/errors.log"
RESOURCE_KEYS=("${SOURCE_KEY}" "${TARGET_KEY}" "${BLOCKED_KEY}")
RESOURCE_SITES=("${SOURCE_SITE}" "${TARGET_SITE}" "${BLOCKED_SITE}")
TLS_RESOURCES_OWNED=false
mkdir -p "${WORK}/bin" "${OCTOJOOM_HOME}/.config/octojoom" "${REPO_PATH}" "${PROJECT_PATH}" "${BACKUP_PATH}"
printf '127.0.0.1 localhost\n' >"${WORK}/hosts"

# A noninteractive invocation must never fall back into a dialog or auto-install.
cat >"${WORK}/bin/whiptail" <<'SH'
#!/usr/bin/env bash
printf 'Unexpected interactive prompt: %s\n' "$*" >&2
exit 97
SH
chmod 700 "${WORK}/bin/whiptail"
PATH="${WORK}/bin:${PATH}"
export PATH

cleanup() {
  local status=$? key service site compose network
  trap - EXIT INT TERM HUP
  set +e
  if (( status != 0 )); then
    printf '\nV4 integration diagnostics (%s):\n' "${SCENARIO}" >&2
    [ ! -s "${RESULT}" ] || cat "${RESULT}" >&2
    [ ! -s "${ERROR_OUTPUT}" ] || tail -80 "${ERROR_OUTPUT}" >&2
    for key in "${RESOURCE_KEYS[@]}"; do
      for service in joomla nginx mariadb mysql postgres phpmyadmin adminer mailpit redis; do
        if timeout 10s "${DOCKER_BIN}" inspect --format '{{.Name}} {{json .State}}' "${service}${key}" >&2 2>/dev/null; then
          timeout 10s "${DOCKER_BIN}" logs --tail 40 "${service}${key}" >&2 2>&1
        fi
      done
      if timeout 10s "${DOCKER_BIN}" inspect "octojoom-share-${key}" >/dev/null 2>&1; then
        timeout 10s "${DOCKER_BIN}" logs --tail 40 "octojoom-share-${key}" >&2 2>&1
      fi
    done
    if [ "${TLS_RESOURCES_OWNED}" = true ]; then
      timeout 10s "${DOCKER_BIN}" logs --tail 40 octojoom-local-proxy >&2 2>&1
    fi
  fi
  for site in "${RESOURCE_SITES[@]}"; do
    compose="${REPO_PATH}/joomla/available/${site}/docker-compose.yml"
    if [ -f "${compose}" ] && [ -f "${compose%/*}/.env" ]; then
      timeout 60s "${DOCKER_BIN}" compose --env-file "${compose%/*}/.env" -f "${compose}" down --volumes --remove-orphans >/dev/null 2>&1
    fi
  done
  if [ "${TLS_RESOURCES_OWNED}" = true ]; then
    timeout 15s "${DOCKER_BIN}" rm -fv octojoom-local-proxy >/dev/null 2>&1
    timeout 15s "${DOCKER_BIN}" network rm octojoom_local >/dev/null 2>&1
  fi
  # Exact names cover an interrupted create that has not published its files yet.
  for key in "${RESOURCE_KEYS[@]}"; do
    timeout 15s "${DOCKER_BIN}" rm -fv "octojoom-share-${key}" >/dev/null 2>&1
    for service in joomla nginx mariadb mysql postgres phpmyadmin adminer mailcatcher mailpit redis node; do
      timeout 15s "${DOCKER_BIN}" rm -fv "${service}${key}" >/dev/null 2>&1
    done
    while IFS= read -r network; do
      [ -z "${network}" ] || timeout 15s "${DOCKER_BIN}" network rm "${network}" >/dev/null 2>&1
    done < <("${DOCKER_BIN}" network ls --filter "label=com.docker.compose.project=octojoom${key}" --format '{{.ID}}')
  done
  timeout 15s "${DOCKER_BIN}" network rm "${NETWORK}" >/dev/null 2>&1
  privileged rm -rf -- "${WORK}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

"${DOCKER_BIN}" network create --label "io.octojoom.integration=${RUN_ID}" "${NETWORK}" >/dev/null
cat >"${OCTOJOOM_HOME}/.config/octojoom/.env" <<ENV
VDM_REPO_PATH="${REPO_PATH}"
VDM_PROJECT_PATH="${PROJECT_PATH}"
VDM_TRAEFIK_GATEWAY="${NETWORK}"
VDM_UPDATE_HOST=false
VDM_MULTI_DOMAIN=false
VDM_SECURE=false
VDM_EXPERT_MODE=false
ENV
chmod 600 "${OCTOJOOM_HOME}/.config/octojoom/.env"

# Only JSON files hold credentials. They never occur in process arguments.
api() {
  local group="$1" action="$2" request="$3" status=0 secret
  shift 3
  jq --arg repo "${REPO_PATH}" --arg projects "${PROJECT_PATH}" --arg backups "${BACKUP_PATH}" \
    '. + {schema_version:1,repo_path:$repo,project_path:$projects,backup_path:$backups}' \
    <<<"${request}" >"${WORK}/request.json" || fail 'Could not build an integration request.'
  chmod 600 "${WORK}/request.json"
  : >"${ERROR_OUTPUT}"
  timeout --signal=TERM --kill-after=20s 600s bash "${SCRIPT}" "${group}" "${action}" \
    --config "${WORK}/request.json" --json --no-interaction "$@" >"${RESULT}" 2>"${ERROR_OUTPUT}" || status=$?
  for secret in "${ADMIN_PASSWORD}" "${DB_PASSWORD}" "${ROOT_PASSWORD}"; do
    if grep -Fq -- "${secret}" "${RESULT}"; then fail 'A command exposed a credential in its JSON result.'; fi
  done
  if (( status != 0 )); then
    printf 'Command failed: %s %s (exit %s)\n' "${group}" "${action}" "${status}" >&2
    return "${status}"
  fi
  jq -e -s 'length == 1 and .[0].schema_version == 1 and .[0].ok == true' "${RESULT}" >/dev/null || fail 'Successful command did not produce one valid JSON result.'
}

request_for_site() { jq -cn --arg site "$1" '{site:$site}'; }

expect_failure() {
  local expected_status="$1" status=0
  shift
  api "$@" || status=$?
  [ "${status}" -eq "${expected_status}" ] || fail "Expected exit ${expected_status}, received ${status}."
  jq -e -s 'length == 1 and .[0].schema_version == 1 and .[0].ok == false and .[0].error != null' "${RESULT}" >/dev/null || fail 'Failure did not produce a structured JSON error.'
}

# Use the actual installed Joomla configuration to connect, so restoration tests
# verify application credentials/host realignment rather than root DB access.
sql() {
  local key="$1" statement="$2"
  # PHP receives these variables literally; the host shell must not expand them.
  # shellcheck disable=SC2016
  printf '%s' "${statement}" | timeout 30s "${DOCKER_BIN}" exec -i "joomla${key}" php -r '
    require "/var/www/html/configuration.php";
    $config = new JConfig;
    $pg = $config->dbtype === "pgsql" || $config->dbtype === "postgresql";
    $host = $config->host;
    $port = $pg ? "5432" : "3306";
    if (preg_match("/^(.+):([0-9]+)$/", $host, $parts)) { $host = $parts[1]; $port = $parts[2]; }
    $dsn = ($pg ? "pgsql" : "mysql") . ":host=" . $host . ";port=" . $port . ";dbname=" . $config->db;
    $pdo = new PDO($dsn, $config->user, $config->password, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $query = $pdo->query(stream_get_contents(STDIN));
    if ($query->columnCount()) {
        foreach ($query->fetchAll(PDO::FETCH_NUM) as $row) { echo implode("\t", $row), "\n"; }
    }
  '
}

php_version() { timeout 15s "${DOCKER_BIN}" exec "joomla$1" php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;'; }
joomla_version() {
  timeout 15s "${DOCKER_BIN}" exec "joomla$1" php -r '
    echo simplexml_load_file("/var/www/html/administrator/manifests/files/joomla.xml")->version;
  '
}

http() {
  local key="$1" service="$2" path="$3" binding port host="${SOURCE_SITE}"
  [ "${key}" != "${TARGET_KEY}" ] || host="${TARGET_SITE}"
  binding=$(timeout 15s "${DOCKER_BIN}" inspect --format '{{json .NetworkSettings.Ports}}' "${service}${key}")
  jq -e '.["80/tcp"] | length == 1 and .[0].HostIp == "127.0.0.1"' <<<"${binding}" >/dev/null || fail 'Local HTTP must publish only on IPv4 loopback.'
  port=$(jq -r '.["80/tcp"][0].HostPort' <<<"${binding}")
  curl -sS --retry 15 --retry-connrefused --retry-delay 1 --retry-max-time 45 --max-time 10 \
    -H "Host: ${host}" -o "${WORK}/http-body" -w '%{http_code}' "http://127.0.0.1:${port}${path}" >"${WORK}/http-status"
  cat "${WORK}/http-body"
}

# Resolve only this fixture's companion domain, with the private CA explicitly
# trusted. Both the reported URL and the served application must match the site.
companion_get() {
  local host="$1" path="$2" output="$3" started=$SECONDS
  while (( SECONDS - started < 30 )); do
    if curl -fsS --noproxy '*' --connect-timeout 3 --max-time 5 --cacert "${CAROOT}/rootCA.pem" \
      --resolve "${host}:${TLS_HTTPS_PORT}:127.0.0.1" "https://${host}:${TLS_HTTPS_PORT}${path}" \
      >"${output}" 2>"${WORK}/companion-errors"; then return 0; fi
    sleep 1
  done
  cat "${WORK}/companion-errors" >&2
  fail "The selected companion endpoint did not become ready: ${host}"
}

assert_companion_disabled() {
  local host="$1" status started=$SECONDS
  while (( SECONDS - started < 30 )); do
    if status=$(curl -sS --noproxy '*' --connect-timeout 3 --max-time 5 --cacert "${CAROOT}/rootCA.pem" \
      --resolve "${host}:${TLS_HTTPS_PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${host}:${TLS_HTTPS_PORT}/" \
      2>"${WORK}/companion-errors") && [ "${status}" = 404 ]; then return 0; fi
    sleep 1
  done
  cat "${WORK}/companion-errors" >&2
  fail "Disabled companion retained a local HTTPS route: ${host}"
}

assert_viewer_isolated() {
  companion_get "${TARGET_SITE}" / "${WORK}/viewer-site-homepage.html"
  grep -qi '<html' "${WORK}/viewer-site-homepage.html" || fail 'Changing the database viewer stopped the Joomla HTTPS frontend.'
  [ "$(sql "${TARGET_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = target-only ] || fail 'Changing a database viewer changed its Joomla data.'
  [ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = source-changed ] || fail 'Changing a database viewer affected another site database.'
  [ "$("${DOCKER_BIN}" inspect --format '{{.Id}}' "phpmyadmin${SOURCE_KEY}")" = "${SOURCE_VIEWER_ID}" ] || fail 'Changing a database viewer recreated another site viewer.'
  api site info "$(request_for_site "${SOURCE_SITE}")"
  jq -e --arg url "${SOURCE_VIEWER_URL}" '.data.urls.database == $url and .data.database_ui.enabled == true and .data.database_ui.provider == "phpmyadmin"' "${RESULT}" >/dev/null || fail 'Changing a database viewer altered another site settings or URL.'
}

assert_database_viewer() {
  local provider="$1" url="https://${DATABASE_HOST}:${TLS_HTTPS_PORT}"
  api site info "$(request_for_site "${TARGET_SITE}")"
  jq -e --arg provider "${provider}" --arg service "${provider}${TARGET_KEY}" --arg host "${DATABASE_HOST}" --arg url "${url}" \
    '.data.database_ui.enabled == true and .data.database_ui.provider == $provider and .data.database_ui.service == $service and
     .data.database_ui.host == $host and .data.database_ui.state.running == true and .data.database_ui.url == $url and .data.urls.database == $url' \
    "${RESULT}" >/dev/null || fail 'Database viewer facts do not match the selected provider and site domain.'
  companion_get "${DATABASE_HOST}" / "${WORK}/database-viewer.html"
  grep -qi "${provider}" "${WORK}/database-viewer.html" || fail 'The database domain did not serve the selected viewer login page.'
  assert_viewer_isolated
}

assert_installed() {
  local key="$1" service="${2:-joomla}" engine="$3" expected_version="${4:-${PHP_VERSION}}" database_version
  timeout 15s "${DOCKER_BIN}" exec "joomla${key}" test -f /var/www/html/configuration.php || fail 'Joomla configuration was not installed.'
  timeout 15s "${DOCKER_BIN}" exec "joomla${key}" test ! -d /var/www/html/installation || fail 'Joomla installer directory remains after creation.'
  [ "$(php_version "${key}")" = "${expected_version}" ] || fail 'Wrong PHP runtime is running.'
  [ "$(joomla_version "${key}")" = "${JOOMLA_VERSION}" ] || fail 'Wrong installed Joomla version.'
  [ "$(sql "${key}" 'SELECT 1')" = 1 ] || fail 'Joomla credentials cannot reach their database.'
  database_version=$(sql "${key}" 'SELECT VERSION()')
  case "${engine}" in
    mariadb) [[ "${database_version}" == *MariaDB* ]] || fail 'Joomla is not connected to MariaDB.' ;;
    mysql) [[ "${database_version}" != *MariaDB* && "${database_version}" == 8.4.* ]] || fail 'Joomla is not connected to MySQL 8.4.' ;;
    postgres) [[ "${database_version}" == PostgreSQL\ 16.* ]] || fail 'Joomla is not connected to PostgreSQL 16.' ;;
  esac
  # Restored ownership must allow Joomla's actual web worker to write; checking
  # only HTTP rendering would miss broken uploads, caches and extension installs.
  # shellcheck disable=SC2016
  timeout 15s "${DOCKER_BIN}" exec --user www-data "joomla${key}" php -r '
    foreach (["tmp", "cache", "images"] as $directory) {
        $path = "/var/www/html/$directory/octojoom-write-test";
        if (file_put_contents($path, "writable") === false || !unlink($path)) exit(1);
    }
  ' || fail 'Joomla web worker cannot write its runtime directories.'
  http "${key}" "${service}" / >"${WORK}/homepage.html"
  [ "$(cat "${WORK}/http-status")" = 200 ] || fail 'Joomla frontend did not return HTTP 200.'
  grep -qi '<html' "${WORK}/homepage.html" || fail 'Joomla did not render its frontend.'
  timeout 15s "${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "joomla${key}" | grep -Fxq "octojoom${key}" || fail 'Container does not have its disposable Compose project label.'
  if [ "${engine}" = postgres ]; then
    timeout 15s "${DOCKER_BIN}" exec "joomla${key}" php -r 'require "/var/www/html/configuration.php"; exit((new JConfig)->dbtype === "pgsql" ? 0 : 1);' || fail 'PostgreSQL driver was not selected.'
  fi
  pass "Real Joomla ${JOOMLA_VERSION}, PHP ${expected_version}, ${service} and ${engine} work together"
}

create_site() {
  local engine="$1" version="$2" request
  request=$(jq -cn \
    --arg site "${SOURCE_SITE}" --arg key "${SOURCE_KEY}" --arg joomla "${JOOMLA_VERSION}" --arg php "${PHP_VERSION}" \
    --arg engine "${engine}" --arg version "${version}" --arg admin "${ADMIN_PASSWORD}" --arg db "${DB_PASSWORD}" --arg root "${ROOT_PASSWORD}" \
    '{site:$site,key:$key,joomla_version:$joomla,php_version:$php,webserver:"apache",profile:"local",tls_mode:"none",
      database_engine:$engine,database_version:$version,database_name:"octojoom_test",database_user:"octojoom_test",database_password:$db,database_root_password:$root,
      site_name:"OctoJoom Integration",admin_name:"Integration Administrator",admin_username:"integration",admin_email:"integration@example.invalid",admin_password:$admin,
      activate:true,install:true,yes:true}')
  api site create "${request}" || fail 'Fresh Joomla creation failed.'
  assert_installed "${SOURCE_KEY}" joomla "${engine}"
}

# Scenario implementation follows the same public request schema as the desktop API.
case "${SCENARIO}" in
  lifecycle) ENGINE=mariadb; create_site "${ENGINE}" "${MARIADB_VERSION}" ;;
  mysql) ENGINE=mysql; create_site "${ENGINE}" "${MYSQL_VERSION}" ;;
  postgres) ENGINE=postgres; create_site "${ENGINE}" "${POSTGRES_VERSION}" ;;
esac

sql "${SOURCE_KEY}" 'CREATE TABLE octojoom_integration_marker (id INTEGER PRIMARY KEY, value VARCHAR(100) NOT NULL)'
sql "${SOURCE_KEY}" "INSERT INTO octojoom_integration_marker (id, value) VALUES (1, 'before-backup')"
printf '%s\n' 'before-backup' | timeout 15s "${DOCKER_BIN}" exec -i "joomla${SOURCE_KEY}" sh -c 'cat > /var/www/html/octojoom-integration.txt'
pass 'Created file and database fixtures through the actual Joomla runtime'

api site info "$(request_for_site "${SOURCE_SITE}")"
jq -e --arg engine "${ENGINE}" --arg joomla "${JOOMLA_VERSION}" \
  '.data.web.running and .data.database.engine == $engine and .data.joomla_version == $joomla and (.data.urls.site | length > 0)' "${RESULT}" >/dev/null || fail 'Site facts do not describe the running installation.'
# This assertion deliberately contains shell syntax that must remain literal.
# shellcheck disable=SC2016
api site exec "$(request_for_site "${SOURCE_SITE}")" -- php -r 'echo $argv[1];' 'literal ; $(touch /tmp/octojoom-must-not-exist)'
jq -e '.data.stdout == "literal ; $(touch /tmp/octojoom-must-not-exist)" and .data.exit_code == 0' "${RESULT}" >/dev/null || fail 'Command arguments were not passed literally.'
timeout 15s "${DOCKER_BIN}" exec "joomla${SOURCE_KEY}" test ! -e /tmp/octojoom-must-not-exist || fail 'Literal arguments were executed as shell code.'
pass 'Machine-readable facts and literal command execution work without dialogs'

TABLE_EXPORT="${BACKUP_PATH}/${SOURCE_SITE}-table.sql.gz"
api database export "$(jq -cn --arg site "${SOURCE_SITE}" --arg output "${TABLE_EXPORT}" \
  '{site:$site,output:$output,tables:["octojoom_integration_marker"]}')"
gzip -t "${TABLE_EXPORT}"
gzip -dc "${TABLE_EXPORT}" >"${WORK}/selected.sql"
grep -q 'before-backup' "${WORK}/selected.sql" || fail 'Selected-table export omitted the actual row.'
if grep -qE 'CREATE TABLE.*(extensions|users)' "${WORK}/selected.sql"; then fail 'Selected-table export included unrelated Joomla tables.'; fi
[ "$(jq -r '.data.sha256' "${RESULT}")" = "$(sha256sum "${TABLE_EXPORT}" | awk '{print $1}')" ] || fail 'Export checksum is incorrect.'
pass 'A selected-table export contains real SQL and reports its checksum'

SNAPSHOT="${BACKUP_PATH}/${SOURCE_SITE}-snapshot.tar.gz"
api snapshot create "$(jq -cn --arg site "${SOURCE_SITE}" --arg output "${SNAPSHOT}" '{site:$site,output:$output,label:"Before edits"}')"
sql "${SOURCE_KEY}" "UPDATE octojoom_integration_marker SET value='after-snapshot' WHERE id=1"
printf '%s\n' 'after-snapshot' | timeout 15s "${DOCKER_BIN}" exec -i "joomla${SOURCE_KEY}" sh -c 'cat > /var/www/html/octojoom-integration.txt'
api snapshot restore "$(jq -cn --arg site "${SOURCE_SITE}" --arg input "${SNAPSHOT}" '{site:$site,input:$input,yes:true}')"
[ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = before-backup ] || fail 'Snapshot did not restore the original data.'
[ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${SOURCE_KEY}" cat /var/www/html/octojoom-integration.txt)" = after-snapshot ] || fail 'Database snapshot overwrote Joomla files.'
api snapshot list "$(request_for_site "${SOURCE_SITE}")"
jq -e --arg file "${SNAPSHOT}" '.data.snapshots | any(.file == $file and .label == "Before edits")' "${RESULT}" >/dev/null || fail 'Named snapshot is not discoverable.'
pass 'Named snapshot restores SQL while preserving later file changes'

# Fail after a schema change, not just during request validation. The importer
# must roll back its partial database and restart the original application.
printf '%s\n' 'CREATE TABLE octojoom_failed_import (id INTEGER);' 'THIS IS INTENTIONALLY INVALID SQL;' >"${WORK}/invalid.sql"
expect_failure 1 database import "$(jq -cn --arg site "${SOURCE_SITE}" --arg input "${WORK}/invalid.sql" '{site:$site,input:$input,replace:true,yes:true}')"
[ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = before-backup ] || fail 'Failed SQL import did not restore original data.'
if [ "${ENGINE}" = postgres ]; then
  [ "$(sql "${SOURCE_KEY}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='octojoom_failed_import'")" = 0 ] || fail 'Partial PostgreSQL import survived recovery.'
else
  [ "$(sql "${SOURCE_KEY}" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='octojoom_failed_import'")" = 0 ] || fail 'Partial MySQL-family import survived recovery.'
fi
assert_installed "${SOURCE_KEY}" joomla "${ENGINE}"
pass 'Invalid SQL import rolls back actual partial changes and resumes Joomla'

ARCHIVE="${BACKUP_PATH}/${SOURCE_SITE}-full.tar.gz"
api backup create "$(jq -cn --arg site "${SOURCE_SITE}" --arg output "${ARCHIVE}" '{site:$site,output:$output,scope:"full",format:"tar.gz",label:"Portable integration backup"}')"
[ "$(jq -r '.data.sha256' "${RESULT}")" = "$(sha256sum "${ARCHIVE}" | awk '{print $1}')" ] || fail 'Archive checksum is incorrect.'
tar -tzf "${ARCHIVE}" >"${WORK}/archive-members"
if grep -qE '^\.?/?project/db(/|$)' "${WORK}/archive-members"; then fail 'Portable archive included raw database storage.'; fi
sql "${SOURCE_KEY}" "UPDATE octojoom_integration_marker SET value='source-changed' WHERE id=1"
printf '%s\n' 'source-changed' | timeout 15s "${DOCKER_BIN}" exec -i "joomla${SOURCE_KEY}" sh -c 'cat > /var/www/html/octojoom-integration.txt'

restore_request=$(jq -cn --arg input "${ARCHIVE}" --arg site "${TARGET_SITE}" --arg key "${TARGET_KEY}" \
  '{input:$input,target_site:$site,target_key:$key,activate:true,yes:true}')
if [ "${SCENARIO}" = lifecycle ]; then
  restore_request=$(jq -c '.docroot="public/joomla"' <<<"${restore_request}")
fi
api backup restore "${restore_request}"
assert_installed "${TARGET_KEY}" joomla "${ENGINE}"
[ "$(sql "${TARGET_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = before-backup ] || fail 'Restored site does not contain archived data.'
[ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" cat /var/www/html/octojoom-integration.txt)" = after-snapshot ] || fail 'Restored site does not contain archived files.'

# A clone must work with the entire source stack stopped. Independent writes
# must still be isolated after the source starts again.
api site stop "$(request_for_site "${SOURCE_SITE}")"
[ "$("${DOCKER_BIN}" inspect --format '{{.State.Running}}' "${ENGINE}${SOURCE_KEY}")" = false ] || fail 'Source database did not stop.'
assert_installed "${TARGET_KEY}" joomla "${ENGINE}"
sql "${TARGET_KEY}" "UPDATE octojoom_integration_marker SET value='target-only' WHERE id=1"
api site start "$(request_for_site "${SOURCE_SITE}")"
[ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = source-changed ] || fail 'The restored site wrote into the source database.'
[ "$(sql "${TARGET_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = target-only ] || fail 'The restored site lost its independent data.'
pass 'Portable restore has independent files, configuration, database and network'

api database export '{"all":true}'
jq -e '.data.results | length == 2 and all(.[]; .ok == true and (.file | length > 0))' "${RESULT}" >/dev/null || fail 'Batch export did not return both completed site exports.'
pass 'Batch database export returns an explicit result for each site'

if [ "${SCENARIO}" = lifecycle ]; then
  original_index=$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" sha256sum /var/www/html/index.php | awk '{print $1}')
  api site php "$(jq -cn --arg site "${TARGET_SITE}" --arg php "${PHP_TARGET_VERSION}" '{site:$site,php_version:$php,yes:true}')"
  assert_installed "${TARGET_KEY}" joomla "${ENGINE}" "${PHP_TARGET_VERSION}"
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" sha256sum /var/www/html/index.php | awk '{print $1}')" = "${original_index}" ] || fail 'PHP runtime swap changed Joomla core files.'
  [ "$(sql "${TARGET_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = target-only ] || fail 'PHP runtime swap changed site data.'
  pass 'PHP container swap preserves installed Joomla release, files and data'

  api site webserver "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,webserver:"nginx",yes:true}')"
  assert_installed "${TARGET_KEY}" nginx "${ENGINE}" "${PHP_TARGET_VERSION}"
  for api_path in /api/v1/content/articles /api/index.php/v1/content/articles; do
    http "${TARGET_KEY}" nginx "${api_path}" >"${WORK}/api-response.json"
    case "$(cat "${WORK}/http-status")" in 401|403) ;; *) fail "Joomla API routing did not reach authentication: ${api_path}" ;; esac
    jq -e '.errors | type == "array" and length > 0' "${WORK}/api-response.json" >/dev/null || fail "Nginx did not route ${api_path} to Joomla's JSON API."
  done
  http "${TARGET_KEY}" nginx /configuration.php >"${WORK}/configuration-response"
  if grep -qE '<\?php|class JConfig|Integration-Db-' "${WORK}/configuration-response"; then fail 'Nginx exposed PHP source or database credentials.'; fi
  pass 'Nginx/FPM serves Joomla and both API route forms without exposing PHP source'

  # mkcert creates an isolated CA while issuing the bootstrap leaf. Never call
  # -install here: curl trusts this CA explicitly, leaving the runner unchanged.
  export CAROOT="${WORK}/certificate-authority"
  mkdir -m 700 "${CAROOT}"
  mkcert -cert-file "${WORK}/bootstrap.pem" -key-file "${WORK}/bootstrap-key.pem" bootstrap.invalid >/dev/null 2>"${ERROR_OUTPUT}"
  read -r TLS_HTTP_PORT TLS_HTTPS_PORT < <(python3 - <<'PY'
import socket
with socket.socket() as http, socket.socket() as https:
    http.bind(("127.0.0.1", 0))
    https.bind(("127.0.0.1", 0))
    print(http.getsockname()[1], https.getsockname()[1])
PY
  )
  TLS_RESOURCES_OWNED=true
  api tls setup "$(jq -cn --arg site "${TARGET_SITE}" --arg hosts "${WORK}/hosts" --argjson http "${TLS_HTTP_PORT}" --argjson https "${TLS_HTTPS_PORT}" \
    '{site:$site,hosts_file:$hosts,http_port:$http,https_port:$https,trust:false,yes:true}')"
  jq -e '.data.trust_installed == false' "${RESULT}" >/dev/null || fail 'TLS test unexpectedly installed system certificate trust.'
  tls_ready=false
  for ((attempt=0; attempt<30; attempt++)); do
    if curl -fsS --noproxy '*' --max-time 5 --cacert "${CAROOT}/rootCA.pem" \
      --resolve "${TARGET_SITE}:${TLS_HTTPS_PORT}:127.0.0.1" "https://${TARGET_SITE}:${TLS_HTTPS_PORT}/" \
      >"${WORK}/https-body" 2>"${WORK}/tls-errors"; then tls_ready=true; break; fi
    sleep 1
  done
  [ "${tls_ready}" = true ] || { cat "${WORK}/tls-errors" >&2; fail 'The local CA did not authenticate a working Joomla HTTPS endpoint.'; }
  grep -qi '<html' "${WORK}/https-body" || fail 'HTTPS did not serve Joomla.'
  curl -sS --noproxy '*' --max-time 10 --resolve "${TARGET_SITE}:${TLS_HTTP_PORT}:127.0.0.1" \
    -D "${WORK}/redirect-headers" -o /dev/null "http://${TARGET_SITE}:${TLS_HTTP_PORT}/"
  grep -Fqi "location: https://${TARGET_SITE}:${TLS_HTTPS_PORT}/" "${WORK}/redirect-headers" || fail 'Local HTTP did not redirect to the configured HTTPS port.'
  grep -Fq "# octojoom-v4:${TARGET_SITE}" "${WORK}/hosts" || fail 'TLS setup did not register the selected hostname in its supplied hosts file.'
  pass 'Local TLS uses a valid workstation certificate, preserves Host routing and redirects to its selected HTTPS port'

  DATABASE_HOST="${TARGET_SITE%%.*}db.${TARGET_SITE#*.}"
  MAIL_HOST="${TARGET_SITE%%.*}mail.${TARGET_SITE#*.}"
  SOURCE_VIEWER_ID=$("${DOCKER_BIN}" inspect --format '{{.Id}}' "phpmyadmin${SOURCE_KEY}")
  api site info "$(request_for_site "${SOURCE_SITE}")"
  SOURCE_VIEWER_URL=$(jq -er '.data.urls.database | select(length > 0)' "${RESULT}")
  assert_database_viewer phpmyadmin
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"database-ui",enabled:true,provider:"adminer",yes:true}')"
  if "${DOCKER_BIN}" inspect "phpmyadmin${TARGET_KEY}" >/dev/null 2>&1; then fail 'Switching to Adminer left the previous phpMyAdmin container behind.'; fi
  assert_database_viewer adminer
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"database-ui",enabled:false,yes:true}')"
  api site info "$(request_for_site "${TARGET_SITE}")"
  jq -e '.data.database_ui.enabled == false and .data.database_ui.state.running == false and .data.database_ui.state.status == "disabled" and (.data.urls.database // "") == ""' \
    "${RESULT}" >/dev/null || fail 'Disabled database viewer still reports an active service or URL.'
  for provider in phpmyadmin adminer; do
    if "${DOCKER_BIN}" inspect "${provider}${TARGET_KEY}" >/dev/null 2>&1; then fail 'Disabling the database viewer left its container behind.'; fi
  done
  assert_companion_disabled "${DATABASE_HOST}"
  assert_viewer_isolated
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"database-ui",enabled:true,provider:"phpmyadmin",yes:true}')"
  assert_database_viewer phpmyadmin
  pass 'Database viewers switch providers, disable and reenable on the selected site domain without changing Joomla data or another site'

  # Capture a message sent by Joomla's real mailer, then check that disabling
  # capture returns the exact original configuration, including SMTP secrets.
  # shellcheck disable=SC2016
  mail_digest_code='require "/var/www/html/configuration.php"; $c=new JConfig; $v=[]; foreach(["mailer","smtphost","smtpport","smtpauth","smtpsecure","smtpuser","smtppass","mailonline"] as $k) {if(property_exists($c,$k))$v[$k]=$c->$k;} echo hash("sha256",json_encode($v));'
  original_mail_digest=$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" php -r "${mail_digest_code}")
  api mail configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,enabled:true,mail_port:0,yes:true}')"
  api mail status "$(request_for_site "${TARGET_SITE}")"
  inbox=$(jq -er '.data.inbox' "${RESULT}")
  [ "${inbox}" = "https://${MAIL_HOST}:${TLS_HTTPS_PORT}" ] || fail 'Mail inbox URL does not use the selected site companion domain and HTTPS port.'
  companion_get "${MAIL_HOST}" / "${WORK}/mail-inbox.html"
  grep -qi mailpit "${WORK}/mail-inbox.html" || fail 'The mail domain did not serve the selected site inbox.'
  api mail test "$(request_for_site "${TARGET_SITE}")"
  companion_get "${MAIL_HOST}" /api/v1/messages "${WORK}/mail-messages.json"
  jq -e '.messages | length == 1 and .[0].Subject == "OctoJoom mail capture test"' "${WORK}/mail-messages.json" >/dev/null || fail 'The configured capture service did not receive the Joomla message.'
  message_id=$(jq -r '.messages[0].ID' "${WORK}/mail-messages.json")
  [[ "${message_id}" =~ ^[A-Za-z0-9-]+$ ]] || fail 'Mail capture returned an invalid message ID.'
  companion_get "${MAIL_HOST}" "/api/v1/message/${message_id}" "${WORK}/mail-message.json"
  jq -e '.Text | contains("This message verifies this Joomla sites configured mail transport.")' "${WORK}/mail-message.json" >/dev/null || fail 'Captured message body does not match Joomla mailer output.'
  api mail configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,enabled:false,yes:true}')"
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" php -r "${mail_digest_code}")" = "${original_mail_digest}" ] || fail 'Disabling capture did not restore the original mail configuration.'
  if "${DOCKER_BIN}" inspect "mailpit${TARGET_KEY}" >/dev/null 2>&1; then fail 'Disabling mail capture left its container behind.'; fi
  assert_companion_disabled "${MAIL_HOST}"
  pass 'Joomla delivers mail to its site-domain inbox and restores original settings when capture is disabled'

  api tls disable "$(jq -cn --arg site "${TARGET_SITE}" --arg hosts "${WORK}/hosts" '{site:$site,hosts_file:$hosts,yes:true}')"
  assert_installed "${TARGET_KEY}" nginx "${ENGINE}" "${PHP_TARGET_VERSION}"
  api site info "$(request_for_site "${TARGET_SITE}")"
  jq -e '.data.urls.database | test("^http://127\\.0\\.0\\.1:[0-9]+$")' "${RESULT}" >/dev/null || fail 'Disabling TLS did not restore the private database viewer URL.'

  api site joomla "$(request_for_site "${TARGET_SITE}")" -- --version
  jq -e --arg version "${JOOMLA_VERSION}" '.data.exit_code == 0 and (.data.stdout | contains($version))' "${RESULT}" >/dev/null || fail 'Joomla CLI did not execute in the installed release.'
  api site composer "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,composer_version:"2.10.3"}')" -- --version
  jq -e '.data.exit_code == 0 and (.data.stdout | contains("Composer version 2.10.3"))' "${RESULT}" >/dev/null || fail 'The verified Composer executable did not run in the PHP container.'
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"node",enabled:true,yes:true}')"
  timeout 15s "${DOCKER_BIN}" exec --user www-data "joomla${TARGET_KEY}" mkdir /var/www/html/octojoom-assets
  printf '%s\n' '{"private":true,"scripts":{"build":"node -e \"require('\''fs'\'').writeFileSync('\''octojoom-node-output.txt'\'','\''node works'\'')\""}}' \
    | timeout 15s "${DOCKER_BIN}" exec -i --user www-data "joomla${TARGET_KEY}" sh -c 'cat > /var/www/html/octojoom-assets/package.json'
  api site npm "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,workdir:"/var/www/html/octojoom-assets"}')" -- run build
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" cat /var/www/html/octojoom-assets/octojoom-node-output.txt)" = 'node works' ] || fail 'On-demand npm did not build inside the selected project mount.'
  if "${DOCKER_BIN}" ps --filter "label=com.docker.compose.project=octojoom${TARGET_KEY}" --filter "label=com.docker.compose.service=node${TARGET_KEY}" --format '{{.ID}}' | grep -q .; then
    fail 'The on-demand Node operation left an idle container.'
  fi
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"node",enabled:false,yes:true}')"
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"redis",enabled:true,yes:true}')"
  api site exec "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"redis"}')" -- redis-cli ping
  jq -e '.data.exit_code == 0 and .data.stdout == "PONG\n"' "${RESULT}" >/dev/null || fail 'The selected private Redis service did not respond.'
  "${DOCKER_BIN}" inspect --format '{{json .NetworkSettings.Ports}}' "redis${TARGET_KEY}" | jq -e 'all(.[]; . == null)' >/dev/null || fail 'Redis unexpectedly published a host port.'
  api service configure "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,service:"redis",enabled:false,yes:true}')"
  pass 'Joomla CLI, verified Composer, on-demand npm builds and private Redis execute through the shared command interface'

  timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" sh -c 'printf broken-owner > /var/www/html/images/octojoom-permissions.txt; chmod 600 /var/www/html/images/octojoom-permissions.txt'
  if timeout 15s "${DOCKER_BIN}" exec --user www-data "joomla${TARGET_KEY}" test -r /var/www/html/images/octojoom-permissions.txt; then fail 'Permissions fixture did not isolate the wrong owner.'; fi
  api site permissions "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,yes:true}')"
  jq -e '.data.owner == "www-data" and .data.configuration_private == true' "${RESULT}" >/dev/null || fail 'Permission repair did not report the Joomla web worker owner.'
  timeout 15s "${DOCKER_BIN}" exec --user www-data "joomla${TARGET_KEY}" test -w /var/www/html/images/octojoom-permissions.txt || fail 'Permission repair did not restore write access.'
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${TARGET_KEY}" stat -c '%a' /var/www/html/configuration.php)" = 600 ] || fail 'Permission repair left configuration.php readable by other container users.'
  assert_installed "${TARGET_KEY}" nginx "${ENGINE}" "${PHP_TARGET_VERSION}"
  pass 'Permission repair fixes container-owned files, protects configuration.php and resumes Joomla'

  api share start "$(jq -cn --arg site "${TARGET_SITE}" '{site:$site,timeout:120,yes:true}')"
  share_url=$(jq -er '.data.url' "${RESULT}")
  [[ "${share_url}" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]] || fail 'The sharing provider did not return an HTTPS review URL.'
  api share status "$(request_for_site "${TARGET_SITE}")"
  jq -e --arg url "${share_url}" '.data.running == true and .data.url == $url' "${RESULT}" >/dev/null || fail 'Sharing status does not describe the active review URL.'
  share_ready=false
  share_started=$SECONDS
  # The URL is issued before Cloudflare finishes route propagation. Retry only
  # the public readiness check; any remaining failure stays a real failed gate.
  while (( SECONDS - share_started < 180 )); do
    if curl -fsS --connect-timeout 5 --max-time 10 "${share_url}/octojoom-integration.txt" \
      >"${WORK}/share-marker" 2>"${WORK}/share-errors" && [ "$(cat "${WORK}/share-marker")" = after-snapshot ]; then
      share_ready=true; break
    fi
    sleep 2
  done
  [ "${share_ready}" = true ] || { cat "${WORK}/share-errors" >&2; fail 'Public review URL did not reach the selected fixture within the readiness deadline.'; }
  curl -fsS --connect-timeout 5 --max-time 20 "${share_url}/" >"${WORK}/share-homepage"
  grep -qi '<html' "${WORK}/share-homepage" || fail 'The public review URL did not render Joomla.'
  api share stop "$(request_for_site "${TARGET_SITE}")"
  if "${DOCKER_BIN}" inspect "octojoom-share-${TARGET_KEY}" >/dev/null 2>&1; then fail 'Stopping sharing left its tunnel container behind.'; fi
  api share status "$(request_for_site "${TARGET_SITE}")"
  jq -e '.data.running == false and .data.url == null' "${RESULT}" >/dev/null || fail 'Stopped sharing still reports an active review endpoint.'
  pass 'A temporary HTTPS review URL serves this Joomla project and stops without leaving a tunnel'
fi

if [ "${ENGINE}" = postgres ]; then
  expect_failure 2 database switch "$(jq -cn --arg site "${SOURCE_SITE}" --arg target "${BLOCKED_SITE}" --arg key "${BLOCKED_KEY}" \
    '{site:$site,target_site:$target,target_key:$key,database_engine:"mysql",database_version:"8.4",mode:"clone",yes:true}')"
  grep -qi 'Cross-family' "${ERROR_OUTPUT}" || fail 'Cross-family conversion failed for an unexpected reason.'
  [ ! -e "${REPO_PATH}/joomla/available/${BLOCKED_SITE}" ] || fail 'Rejected conversion created a destination.'
  [ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = source-changed ] || fail 'Rejected cross-family conversion changed the source.'
  pass 'Unsupported cross-family SQL conversion refuses safely before creating a destination'
else
  if [ "${ENGINE}" = mariadb ]; then NEXT_ENGINE=mysql; NEXT_VERSION="${MYSQL_VERSION}"
  else NEXT_ENGINE=mariadb; NEXT_VERSION="${MARIADB_VERSION}"; fi
  api database switch "$(jq -cn --arg site "${SOURCE_SITE}" --arg engine "${NEXT_ENGINE}" --arg version "${NEXT_VERSION}" \
    '{site:$site,database_engine:$engine,database_version:$version,mode:"replace",yes:true}')"
  jq -e '.data.restored == true and (.data.recovery_archive | length > 0) and (.data.retained_previous_project | length > 0)' "${RESULT}" >/dev/null || fail 'Database replacement did not retain a recovery path.'
  [ -s "$(jq -r '.data.recovery_archive' "${RESULT}")" ] || fail 'Database replacement recovery archive is missing.'
  [ -d "$(jq -r '.data.retained_previous_project' "${RESULT}")/db" ] || fail 'Database replacement did not retain original storage.'
  assert_installed "${SOURCE_KEY}" joomla "${NEXT_ENGINE}"
  [ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = source-changed ] || fail 'Database replacement lost site data.'
  [ "$(timeout 15s "${DOCKER_BIN}" exec "joomla${SOURCE_KEY}" cat /var/www/html/octojoom-integration.txt)" = source-changed ] || fail 'Database replacement lost site files.'
  [ "$(sql "${TARGET_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = target-only ] || fail 'Database replacement modified the independent restored project.'
  pass "Live ${ENGINE} to ${NEXT_ENGINE} logical replacement preserves Joomla and recovery data"
fi

api backup list "$(request_for_site "${SOURCE_SITE}")"
jq -e --arg file "${ARCHIVE}" '.data.backups | any(.file == $file)' "${RESULT}" >/dev/null || fail 'Portable backup is missing from the catalog.'
api snapshot delete "$(jq -cn --arg input "${SNAPSHOT}" '{input:$input,yes:true}')"
[ ! -e "${SNAPSHOT}" ] || fail 'Snapshot delete did not remove the selected archive.'
api site delete "$(jq -cn --arg site "${TARGET_SITE}" --arg hosts "${WORK}/hosts" '{site:$site,hosts_file:$hosts,delete_data:true,yes:true}')"
[ ! -e "${PROJECT_PATH}/${TARGET_KEY}" ] || fail 'Explicit site deletion retained project data.'
[ ! -e "${REPO_PATH}/joomla/available/${TARGET_SITE}" ] || fail 'Explicit site deletion retained its active definition.'
[ "$(sql "${SOURCE_KEY}" 'SELECT value FROM octojoom_integration_marker WHERE id=1')" = source-changed ] || fail 'Deleting a restored site affected its source.'
pass "V4 ${SCENARIO} acceptance completed; cleanup removes all remaining disposable resources"
