#!/usr/bin/env bash
# Real cold compressed migration using separate source/destination Octojoom homes.
# Run: bash tests/integration/migration.sh
# Requires Docker Compose v2, Linux, GNU tar/gzip, and root or passwordless sudo.
# Uses official Joomla/PHP and MariaDB images with a minimal installed-site fixture.
# Only uniquely labeled resources are removed; the Docker daemon is never pruned.
# shellcheck disable=SC2034

set -e -o pipefail
# Application functions intentionally use unset globals; do not enable nounset.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../../src/octojoom"
JOOMLA_IMAGE='joomla:5.4.9-php8.3-apache'
MARIADB_IMAGE='mariadb:11.4.12'

die() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   - %s\n' "$*"; }

[[ "${OSTYPE}" == linux* ]] || die 'This integration test requires Linux.'
(( BASH_VERSINFO[0] >= 4 )) || die 'This integration test requires Bash 4 or newer.'
for required in docker timeout awk sed sha256sum tar gzip; do
  command -v "${required}" >/dev/null || die "Missing command: ${required}"
done
DOCKER_BIN="$(type -P docker)"
timeout 15s "${DOCKER_BIN}" info >/dev/null || die 'A running Docker daemon is required.'
timeout 15s "${DOCKER_BIN}" compose version >/dev/null || die 'Docker Compose v2 is required.'
if (( EUID != 0 )); then
  if ! command -v sudo >/dev/null || ! sudo -n true; then
    die 'Root or passwordless sudo is required for bind-mounted database files.'
  fi
fi
host_privileged() {
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/octojoom-migration.XXXXXXXX")"
RUN_ID="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')"
LABEL="io.octojoom.integration=${RUN_ID}"
SOURCE_NETWORK="octojoom-migration-source-${RUN_ID}"
TARGET_NETWORK="octojoom-migration-target-${RUN_ID}"
SOURCE_KEY="source${RUN_ID}"
TARGET_KEY="target${RUN_ID}"
SOURCE_ENV="${SOURCE_KEY^^}"
TARGET_ENV="${TARGET_KEY^^}"
SOURCE_CONTAINER="source.${RUN_ID}.invalid"
TARGET_CONTAINER="target.${RUN_ID}.invalid"
SOURCE_DB="mariadb${SOURCE_KEY}"
SOURCE_WEB="joomla${SOURCE_KEY}"
TARGET_DB="mariadb${TARGET_KEY}"
TARGET_WEB="joomla${TARGET_KEY}"
SOURCE_HOME="${WORK}/source"
TARGET_HOME="${WORK}/destination"
SOURCE_PROJECT="${SOURCE_HOME}/Projects/${SOURCE_KEY}"
TARGET_PROJECT="${TARGET_HOME}/Projects/${TARGET_KEY}"
SOURCE_YML="${SOURCE_HOME}/Docker/joomla/available/${SOURCE_CONTAINER}/docker-compose.yml"
TARGET_YML="${TARGET_HOME}/Docker/joomla/available/${TARGET_CONTAINER}/docker-compose.yml"
SOURCE_ENV_FILE="${SOURCE_HOME}/Docker/joomla/.env"
TARGET_ENV_FILE="${TARGET_YML%/*}/.env"
ARCHIVE="${WORK}/migration.tar.gz"
TRACE="${WORK}/migration.trace"
ERRORS="${WORK}/migration.errors"
: >"${TRACE}"
: >"${ERRORS}"

cleanup() {
  local status=$? resource
  trap - EXIT INT TERM
  set +e
  if (( status != 0 )); then
    printf '\nMigration integration diagnostics:\n' >&2
    for resource in "${TRACE}" "${ERRORS}" "${WORK}/last-wait.log"; do
      if [ -f "${resource}" ]; then cat "${resource}" >&2; fi
    done
    while IFS= read -r resource; do
      [ -n "${resource}" ] || continue
      timeout 10s "${DOCKER_BIN}" inspect --format '{{.Name}} {{json .State}}' "${resource}" >&2
      timeout 10s "${DOCKER_BIN}" logs --tail 60 "${resource}" >&2
    done < <(timeout 10s "${DOCKER_BIN}" ps -aq --filter "label=${LABEL}")
  fi
  while IFS= read -r resource; do
    [ -n "${resource}" ] || continue
    timeout 30s "${DOCKER_BIN}" rm --force --volumes "${resource}" >/dev/null
  done < <(timeout 10s "${DOCKER_BIN}" ps -aq --filter "label=${LABEL}")
  while IFS= read -r resource; do
    [ -n "${resource}" ] || continue
    timeout 15s "${DOCKER_BIN}" network rm "${resource}" >/dev/null
  done < <(timeout 10s "${DOCKER_BIN}" network ls -q --filter "label=${LABEL}")
  host_privileged rm -rf -- "${WORK}"
  exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

configure_host() {
  OCTOJOOM_HOME="$1"
  VDM_HOME_PATH="${OCTOJOOM_HOME}"
  VDM_SRC_PATH="${OCTOJOOM_HOME}/config"
  VDM_REPO_PATH="${OCTOJOOM_HOME}/Docker"
  VDM_PROJECT_PATH="${OCTOJOOM_HOME}/Projects"
  VDM_TRAEFIK_GATEWAY="$2"
  VDM_CONTAINER_TYPE='joomla'
  VDM_DOMAIN="${RUN_ID}.invalid"
  VDM_MULTI_DOMAIN=false
  VDM_UPDATE_HOST=false
  VDM_SECURE=false
  VDM_EXPERT_MODE=false
  VDM_FORCE=false
  VDM_ARG_DOMAIN=false
  VDM_KEY=''
  VDM_ENV_KEY=''
  VDM_SUBDOMAIN=''
  OS_NUMBER=1
  PROGRAM_NAME='Octojoom'
  BACK_TITLE='Octojoom migration integration'
  _VERSION='integration'
  _V='integration'
  mkdir -p "${VDM_SRC_PATH}" "${VDM_PROJECT_PATH}" \
    "${VDM_REPO_PATH}/joomla/available" "${VDM_REPO_PATH}/joomla/enabled"
  printf 'VDM_DOMAIN="%s"\nVDM_MULTI_DOMAIN=false\nVDM_UPDATE_HOST=false\n' "${VDM_DOMAIN}" >"${VDM_SRC_PATH}/.env"
}
configure_host "${SOURCE_HOME}" "${SOURCE_NETWORK}"
mkdir -p "${SOURCE_PROJECT}/joomla" "${SOURCE_PROJECT}/db" "${SOURCE_YML%/*}"
ln -s "${SOURCE_YML%/*}" "${VDM_REPO_PATH}/joomla/enabled/${SOURCE_CONTAINER}"
cat >"${SOURCE_ENV_FILE}" <<ENV
VDM_PROJECT_PATH="${VDM_PROJECT_PATH}"
VDM_${SOURCE_ENV}_DB="octojoom_fixture"
VDM_${SOURCE_ENV}_DB_USER="octojoom_fixture"
VDM_${SOURCE_ENV}_DB_PASS='integration-Db-\$p#word'
VDM_${SOURCE_ENV}_DB_ROOT="integration-root-password"
VDM_UNRELATED_DB_PASS="never-migrate-${RUN_ID}"
ENV
chmod 600 "${SOURCE_ENV_FILE}"

# Match the generated identity, mounts, labels, and external network layout.
# The probe uses Apache directly; no proxy or public port is needed.
cat >"${SOURCE_YML}" <<YAML
services:
  mariadb${SOURCE_KEY}:
    image: ${MARIADB_IMAGE}
    container_name: mariadb${SOURCE_KEY}
    stop_grace_period: 30s
    environment:
      - MARIADB_DATABASE=\${VDM_${SOURCE_ENV}_DB}
      - MARIADB_USER=\${VDM_${SOURCE_ENV}_DB_USER}
      - MARIADB_PASSWORD=\${VDM_${SOURCE_ENV}_DB_PASS}
      - MARIADB_ROOT_PASSWORD=\${VDM_${SOURCE_ENV}_DB_ROOT}
    volumes:
      - "\${VDM_PROJECT_PATH}/${SOURCE_KEY}/db:/var/lib/mysql"
    labels:
      - "io.octojoom.integration=${RUN_ID}"
    networks:
      - traefik
  joomla${SOURCE_KEY}:
    image: ${JOOMLA_IMAGE}
    container_name: joomla${SOURCE_KEY}
    environment:
      - JOOMLA_DB_HOST=mariadb${SOURCE_KEY}:3306
      - JOOMLA_DB_NAME=\${VDM_${SOURCE_ENV}_DB}
      - JOOMLA_DB_USER=\${VDM_${SOURCE_ENV}_DB_USER}
      - JOOMLA_DB_PASSWORD=\${VDM_${SOURCE_ENV}_DB_PASS}
    volumes:
      - "\${VDM_PROJECT_PATH}/${SOURCE_KEY}/joomla:/var/www/html"
      - "./migration.ini:/usr/local/etc/php/conf.d/migration.ini:ro"
    labels:
      - "io.octojoom.integration=${RUN_ID}"
      - "traefik.enable=true"
      - "traefik.http.routers.joomla${SOURCE_KEY}.rule=Host(\`${SOURCE_CONTAINER}\`)"
      - "traefik.http.routers.joomla${SOURCE_KEY}.entrypoints=websecure"
      - "traefik.http.routers.joomla${SOURCE_KEY}.tls.certresolver=vdmresolver"
    networks:
      - traefik
networks:
  traefik:
    external: true
    name: ${SOURCE_NETWORK}
YAML
printf '; migration fixture %s\nmemory_limit=256M\n' "${RUN_ID}" >"${SOURCE_YML%/*}/migration.ini"

awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "${SCRIPT}" >"${WORK}/functions.sh"
# shellcheck disable=SC1091
source "${WORK}/functions.sh"
for required in exportJoomlaMigration extractJoomlaMigration prepareJoomlaMigration; do
  declare -F "${required}" >/dev/null || die "Could not load ${required}."
done
eval "$(declare -f runPrivileged | sed '1s/runPrivileged/integration_privileged/')"
container_running() {
  timeout 10s "${DOCKER_BIN}" inspect --format '{{.State.Running}}' "$1"
}
runPrivileged() {
  if [ "${1:-}" = cp ] && [[ " $* " == *" ${SOURCE_PROJECT}/. "* ]]; then
    if [ "$(container_running "${SOURCE_DB}")" != false ] || [ "$(container_running "${SOURCE_WEB}")" != false ]; then
      printf 'Snapshot attempted while a source service was running.\n' >>"${ERRORS}"
      return 1
    fi
    printf 'snapshot\n' >>"${TRACE}"
  fi
  integration_privileged "$@"
}
docker() {
  timeout 120s "${DOCKER_BIN}" "$@"
}
showError() { printf '%b\n' "$1" >>"${ERRORS}"; return 1; }
showNotice() { printf '%b\n' "$1" >>"${TRACE}"; }
showProgress() { :; }
getInputYesNo() { printf 'Unexpected dialog: %s\n' "$2" >>"${ERRORS}"; return 1; }
whiptail() {
  if [[ " $* " == *' Give sudo Privileges '* ]]; then return 0; fi
  printf 'Unexpected terminal dialog.\n' >>"${ERRORS}"
  return 1
}

compose() {
  local env=$1 yml=$2
  shift 2
  timeout 120s "${DOCKER_BIN}" compose --env-file "${env}" --file "${yml}" "$@"
}
wait_until() {
  local description=$1 deadline=$((SECONDS + 180))
  shift
  until "$@" >"${WORK}/last-wait.log" 2>&1; do
    (( SECONDS < deadline )) || die "Timed out waiting for ${description}."
    sleep 2
  done
  pass "${description} is ready"
}
database_ready() {
  timeout 10s "${DOCKER_BIN}" exec "$1" healthcheck.sh --connect --innodb_initialized
}
files_ready() {
  timeout 10s "${DOCKER_BIN}" exec "$1" php -r \
    'exit(is_file("/var/www/html/libraries/src/Version.php") && function_exists("mysqli_init") ? 0 : 1);'
}
database_sql() {
  # shellcheck disable=SC2016
  timeout 15s "${DOCKER_BIN}" exec -i "$1" sh -c \
    'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb --batch --skip-column-names --user="$MARIADB_USER" "$MARIADB_DATABASE"'
}
web_probe() {
  # shellcheck disable=SC2016
  timeout 10s "${DOCKER_BIN}" exec "$1" php -r '
    $context = stream_context_create(["http" => ["timeout" => 5]]);
    $response = file_get_contents("http://127.0.0.1/migration-probe.php", false, $context);
    $data = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
    foreach (["database_marker" => $argv[1], "host" => $argv[2], "file_marker" => $argv[3], "database" => "octojoom_fixture"] as $key => $expected) {
        if (($data[$key] ?? null) !== $expected) { fwrite(STDERR, "$key did not match\n"); exit(1); }
    }
  ' "$2" "$3" "${RUN_ID}"
}
web_hashes() {
  host_privileged find "${SOURCE_PROJECT}/joomla" -type f -print0 |
    sort -z | host_privileged xargs -0 sha256sum
}
mount_source() {
  timeout 10s "${DOCKER_BIN}" inspect --format \
    '{{range .Mounts}}{{if eq .Destination "'"$2"'"}}{{.Source}}{{end}}{{end}}' "$1"
}

printf 'Pulling official fixtures: %s and %s\n' "${JOOMLA_IMAGE}" "${MARIADB_IMAGE}"
timeout 300s "${DOCKER_BIN}" compose --env-file "${SOURCE_ENV_FILE}" --file "${SOURCE_YML}" pull
timeout 15s "${DOCKER_BIN}" network create --label "${LABEL}" "${SOURCE_NETWORK}" >/dev/null
timeout 15s "${DOCKER_BIN}" network create --label "${LABEL}" "${TARGET_NETWORK}" >/dev/null
compose "${SOURCE_ENV_FILE}" "${SOURCE_YML}" up -d "${SOURCE_DB}"
wait_until 'source MariaDB' database_ready "${SOURCE_DB}"
compose "${SOURCE_ENV_FILE}" "${SOURCE_YML}" up -d "${SOURCE_WEB}"
wait_until 'official Joomla files and PHP mysqli' files_ready "${SOURCE_WEB}"
database_sql "${SOURCE_DB}" <<SQL
CREATE TABLE oj_marker (id INT PRIMARY KEY, value VARCHAR(128) NOT NULL) ENGINE=InnoDB;
INSERT INTO oj_marker VALUES (1, '${RUN_ID}');
SQL
cat >"${WORK}/configuration.php" <<PHP
<?php
class JConfig {
    public \$sitename = 'Octojoom migration integration';
    public \$host = '${SOURCE_DB}:3306';
    public \$user = 'octojoom_fixture';
    public \$password = 'integration-Db-\$p#word';
    public \$db = 'octojoom_fixture';
    public \$dbprefix = 'oj_';
    public \$secret = '${RUN_ID}';
    public \$live_site = 'https://${SOURCE_CONTAINER}';
    public \$cookie_domain = '${SOURCE_CONTAINER}';
    public \$force_ssl = 2;
}
PHP
cat >"${WORK}/migration-probe.php" <<'PHP'
<?php
mysqli_report(MYSQLI_REPORT_ERROR | MYSQLI_REPORT_STRICT);
require __DIR__ . '/configuration.php';
$config = new JConfig;
[$host, $port] = explode(':', $config->host) + [1 => '3306'];
$db = mysqli_init();
$db->options(MYSQLI_OPT_CONNECT_TIMEOUT, 3);
$db->real_connect($host, $config->user, $config->password, $config->db, (int) $port);
$marker = $db->query('SELECT value FROM ' . $config->dbprefix . 'marker WHERE id = 1')->fetch_row()[0];
header('Content-Type: application/json');
echo json_encode([
    'database_marker' => $marker,
    'file_marker' => file_get_contents(__DIR__ . '/.migration-marker'),
    'host' => $config->host,
    'database' => $config->db,
], JSON_THROW_ON_ERROR);
PHP
printf '%s' "${RUN_ID}" >"${WORK}/.migration-marker"
host_privileged cp "${WORK}/configuration.php" "${WORK}/migration-probe.php" "${WORK}/.migration-marker" "${SOURCE_PROJECT}/joomla/"
timeout 10s "${DOCKER_BIN}" exec "${SOURCE_WEB}" chown www-data:www-data \
  /var/www/html/configuration.php /var/www/html/migration-probe.php /var/www/html/.migration-marker
host_privileged chmod 444 "${SOURCE_PROJECT}/joomla/configuration.php"
host_privileged chmod 644 "${SOURCE_PROJECT}/joomla/migration-probe.php" "${SOURCE_PROJECT}/joomla/.migration-marker"
wait_until 'source Apache/PHP database probe' web_probe "${SOURCE_WEB}" "${RUN_ID}" "${SOURCE_DB}:3306"
web_hashes >"${WORK}/source-web.before"
cp "${SOURCE_YML}" "${WORK}/source-compose.before"
cp "${SOURCE_ENV_FILE}" "${WORK}/source-env.before"

if ! exportJoomlaMigration "${SOURCE_CONTAINER}" "${ARCHIVE}" 2>>"${ERRORS}"; then
  die 'Source compressed packaging failed.'
fi
[ -f "${ARCHIVE}" ] || die 'Source packaging did not create a compressed archive.'
[ "$(stat -c '%a' "${ARCHIVE}")" = 600 ] || die 'Credential-bearing archive is not private.'
grep -qx snapshot "${TRACE}" || die 'The cold project snapshot was not audited.'
if [ "$(container_running "${SOURCE_DB}")" != true ] || [ "$(container_running "${SOURCE_WEB}")" != true ]; then
  die 'The original running services were not restarted after packaging.'
fi
pass 'source project was snapshotted with its real services stopped and restarted'
mkdir -m 700 "${WORK}/inspected"
if ! extractJoomlaMigration "${ARCHIVE}" "${WORK}/inspected" 2>>"${ERRORS}"; then
  die 'Could not safely inspect the exported archive.'
fi
[ -f "${WORK}/inspected/manifest.env" ] || die 'Archive manifest is missing.'
[ -f "${WORK}/inspected/project/db/ibdata1" ] || die 'Archive database snapshot is missing.'
cmp "${SOURCE_YML%/*}/migration.ini" "${WORK}/inspected/compose/migration.ini" || die 'Compose companion file was not packaged.'
if grep -Fq "never-migrate-${RUN_ID}" "${WORK}/inspected/compose/.env"; then
  die 'An unrelated shared environment value leaked into the archive.'
fi
pass 'one archive contains Compose, its companion file, project data and scoped credentials'

# Destination handling uses its own paths, network and environment, just as the
# destination-side SSH command does. No further source access is required.
configure_host "${TARGET_HOME}" "${TARGET_NETWORK}"
printf 'VDM_UNRELATED_DB_PASS="destination-only"\n' >"${VDM_REPO_PATH}/joomla/.env"
cp "${VDM_REPO_PATH}/joomla/.env" "${WORK}/destination-env.before"
if ! prepareJoomlaMigration "${ARCHIVE}" "${TARGET_KEY}" "${TARGET_ENV}" "${TARGET_CONTAINER}" false '' '' '' 2>>"${ERRORS}"; then
  die 'Destination preparation failed.'
fi
if [ ! -f "${TARGET_YML}" ] || [ ! -f "${TARGET_ENV_FILE}" ]; then
  die 'Prepared Compose/environment are missing.'
fi
[ "$(stat -c '%a' "${TARGET_ENV_FILE}")" = 600 ] || die 'Destination project environment is not private.'
[ ! -e "${VDM_REPO_PATH}/joomla/enabled/${TARGET_CONTAINER}" ] || die 'Preparation enabled the destination automatically.'
cmp "${WORK}/destination-env.before" "${VDM_REPO_PATH}/joomla/.env" || die 'Destination shared environment was modified.'
cmp "${SOURCE_YML%/*}/migration.ini" "${TARGET_YML%/*}/migration.ini" || die 'Compose companion file was not retained.'
for property in user password db dbprefix secret; do
  [ "$(getJoomlaConfigValue "${SOURCE_PROJECT}/joomla/configuration.php" "${property}")" = \
    "$(getJoomlaConfigValue "${TARGET_PROJECT}/joomla/configuration.php" "${property}")" ] || die "Joomla ${property} changed during migration."
done
for property in DB DB_USER DB_PASS DB_ROOT; do
  source_value='' target_value=''
  migrationReadEnvValue "${SOURCE_ENV_FILE}" "VDM_${SOURCE_ENV}_${property}" source_value || die 'A source credential is missing.'
  migrationReadEnvValue "${TARGET_ENV_FILE}" "VDM_${TARGET_ENV}_${property}" target_value || die 'A destination credential is missing.'
  [ "${source_value}" = "${target_value}" ] || die "Migrated ${property} environment value changed."
done
unset source_value target_value
[ "$(getJoomlaConfigValue "${TARGET_PROJECT}/joomla/configuration.php" host)" = "${TARGET_DB}:3306" ] || die 'Destination Joomla still uses the source database hostname.'
if grep -Eq 'entrypoints=websecure|tls\.certresolver=' "${TARGET_YML}"; then
  die 'HTTPS router configuration survived an HTTP destination conversion.'
fi
# This matches the literal PHP property name, not a shell variable.
# shellcheck disable=SC2016
host_privileged grep -Eq 'public[[:space:]]+\$force_ssl[[:space:]]*=[[:space:]]*0;' "${TARGET_PROJECT}/joomla/configuration.php" || die 'Joomla still forces HTTPS on the HTTP destination.'
pass 'destination key, paths, HTTP policy and private environment were realigned without changing credentials'

# Remove the source database from reach before the destination is even started.
timeout 45s "${DOCKER_BIN}" stop --time 30 "${SOURCE_DB}" >/dev/null
[ "$(container_running "${SOURCE_DB}")" = false ] || die 'The source database did not stop.'
compose "${TARGET_ENV_FILE}" "${TARGET_YML}" config -q
compose "${TARGET_ENV_FILE}" "${TARGET_YML}" up -d "${TARGET_DB}"
wait_until 'migrated MariaDB storage' database_ready "${TARGET_DB}"
compose "${TARGET_ENV_FILE}" "${TARGET_YML}" up -d "${TARGET_WEB}"
wait_until 'migrated Apache/PHP database probe' web_probe "${TARGET_WEB}" "${RUN_ID}" "${TARGET_DB}:3306"
if [ "$(mount_source "${TARGET_DB}" /var/lib/mysql)" != "${TARGET_PROJECT}/db" ] ||
  [ "$(mount_source "${TARGET_WEB}" /var/www/html)" != "${TARGET_PROJECT}/joomla" ]; then
  die 'A destination runtime mount still points at the source project.'
fi
# Dollar-prefixed names belong to Docker's Go template.
# shellcheck disable=SC2016
if [ "$(timeout 10s "${DOCKER_BIN}" inspect --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}}{{end}}' "${TARGET_DB}")" != "${TARGET_NETWORK}" ]; then
  die 'The destination database did not join the destination network.'
fi
pass 'restored destination runs from its own files and database with the source database stopped'

database_sql "${TARGET_DB}" <<SQL
UPDATE oj_marker SET value = 'migrated-${RUN_ID}' WHERE id = 1;
SQL
timeout 10s "${DOCKER_BIN}" exec "${TARGET_WEB}" sh -c 'printf target-only > /var/www/html/.migration-only'
[ ! -e "${SOURCE_PROJECT}/joomla/.migration-only" ] || die 'A destination write changed the source filesystem.'
web_probe "${TARGET_WEB}" "migrated-${RUN_ID}" "${TARGET_DB}:3306"
timeout 30s "${DOCKER_BIN}" start "${SOURCE_DB}" >/dev/null
wait_until 'restarted source MariaDB' database_ready "${SOURCE_DB}"
web_probe "${SOURCE_WEB}" "${RUN_ID}" "${SOURCE_DB}:3306"
web_hashes >"${WORK}/source-web.after"
cmp "${WORK}/source-web.before" "${WORK}/source-web.after" || die 'Source website content changed.'
cmp "${WORK}/source-compose.before" "${SOURCE_YML}" || die 'Source Compose changed.'
cmp "${WORK}/source-env.before" "${SOURCE_ENV_FILE}" || die 'Source environment changed.'
pass 'source files, Compose, credentials and database content remain unchanged'
printf '\nDocker migration integration passed.\n'
