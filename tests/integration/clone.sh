#!/usr/bin/env bash
# Real Linux/Docker regression for cloneJoomlaContainer. Run from any directory:
#   bash tests/integration/clone.sh
# Requires Docker Compose v2, a running Linux daemon and root or passwordless sudo.
# Uses the official images' PHP/Apache and MariaDB with a minimal JConfig/SQL
# fixture. This tests cold database copying, not Joomla's web installer or routing.
# Resources belong to a unique label; cleanup never prunes the daemon or images.
# shellcheck disable=SC2034

set -e -o pipefail
# Do not enable nounset: the application's functions intentionally use unset globals.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../../src/octojoom"
JOOMLA_IMAGE='joomla:5.4.9-php8.3-apache'
MARIADB_IMAGE='mariadb:11.4.12'

die() { printf 'FAIL - %s\n' "$*" >&2; exit 1; }
pass() { printf 'ok   - %s\n' "$*"; }

[[ "${OSTYPE}" == linux* ]] || die 'This integration test requires Linux.'
(( BASH_VERSINFO[0] >= 4 )) || die 'This integration test requires Bash 4 or newer.'
for required in docker timeout awk sed sha256sum; do
  command -v "${required}" >/dev/null || die "Missing command: ${required}"
done
DOCKER_BIN="$(type -P docker)"
timeout 15s "${DOCKER_BIN}" info >/dev/null || die 'A running Docker daemon is required.'
timeout 15s "${DOCKER_BIN}" compose version >/dev/null || die 'Docker Compose v2 is required.'
if (( EUID != 0 )); then
  if ! command -v sudo >/dev/null || ! sudo -n true; then
    die 'Root or passwordless sudo is required for the bind-mounted database files.'
  fi
fi

host_privileged() {
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/octojoom-clone.XXXXXXXX")"
# Keys must be alphabetical in Octojoom; retain 48 random bits while mapping digits.
RUN_ID="$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')"
LABEL="io.octojoom.integration=${RUN_ID}"
NETWORK="octojoom-clone-${RUN_ID}"
SOURCE_KEY="source${RUN_ID}"
CLONE_KEY="clone${RUN_ID}"
SOURCE_ENV="${SOURCE_KEY^^}"
CLONE_ENV="${CLONE_KEY^^}"
SOURCE_CONTAINER="source.${RUN_ID}.invalid"
CLONE_CONTAINER="clone.${RUN_ID}.invalid"
SOURCE_DB="mariadb${SOURCE_KEY}"
SOURCE_WEB="joomla${SOURCE_KEY}"
CLONE_DB="mariadb${CLONE_KEY}"
CLONE_WEB="joomla${CLONE_KEY}"
TRACE="${WORK}/clone.trace"
ERRORS="${WORK}/clone.errors"
DIALOGS="${WORK}/dialogs"
: >"${TRACE}"
: >"${ERRORS}"

cleanup() {
  local status=$? resource
  trap - EXIT INT TERM
  set +e
  if (( status != 0 )); then
    printf '\nIntegration diagnostics:\n' >&2
    for resource in "${TRACE}" "${ERRORS}" "${WORK}/last-wait.log"; do
      if [ -f "${resource}" ]; then cat "${resource}" >&2; fi
    done
    while IFS= read -r resource; do
      [ -n "${resource}" ] || continue
      timeout 10s "${DOCKER_BIN}" inspect --format '{{.Name}} {{json .State}}' "${resource}" >&2
      timeout 10s "${DOCKER_BIN}" logs --tail 80 "${resource}" >&2
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

OCTOJOOM_HOME="${WORK}/home"
VDM_HOME_PATH="${OCTOJOOM_HOME}"
VDM_SRC_PATH="${OCTOJOOM_HOME}/config"
VDM_REPO_PATH="${OCTOJOOM_HOME}/Docker"
VDM_PROJECT_PATH="${OCTOJOOM_HOME}/Projects"
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
BACK_TITLE='Octojoom Docker integration'
_VERSION='integration'
_V='integration'
SOURCE_PROJECT="${VDM_PROJECT_PATH}/${SOURCE_KEY}"
CLONE_PROJECT="${VDM_PROJECT_PATH}/${CLONE_KEY}"
SOURCE_YML="${VDM_REPO_PATH}/joomla/available/${SOURCE_CONTAINER}/docker-compose.yml"
SOURCE_ENABLED_YML="${VDM_REPO_PATH}/joomla/enabled/${SOURCE_CONTAINER}/docker-compose.yml"
CLONE_YML="${VDM_REPO_PATH}/joomla/available/${CLONE_CONTAINER}/docker-compose.yml"
ENV_FILE="${VDM_REPO_PATH}/joomla/.env"
mkdir -p "${VDM_SRC_PATH}" "${SOURCE_PROJECT}/joomla" "${SOURCE_PROJECT}/db" \
  "${SOURCE_YML%/*}" "${VDM_REPO_PATH}/joomla/enabled"
ln -s "${SOURCE_YML%/*}" "${SOURCE_ENABLED_YML%/*}"
printf 'VDM_DOMAIN="%s"\nVDM_MULTI_DOMAIN=false\nVDM_UPDATE_HOST=false\n' "${VDM_DOMAIN}" >"${VDM_SRC_PATH}/.env"
cat >"${ENV_FILE}" <<ENV
VDM_PROJECT_PATH="${VDM_PROJECT_PATH}"
VDM_${SOURCE_ENV}_DB="octojoom_fixture"
VDM_${SOURCE_ENV}_DB_USER="octojoom_fixture"
VDM_${SOURCE_ENV}_DB_PASS="integration-database-password"
VDM_${SOURCE_ENV}_DB_ROOT="integration-root-password"
VDM_${SOURCE_ENV}_JOOMLA_DB_PREFIX="oj_"
ENV
chmod 600 "${ENV_FILE}"

# Keep the production service/container/env/mount syntax consumed by the clone
# parser. There is no Traefik, published port or host-file mutation in this test.
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
      io.octojoom.integration: "${RUN_ID}"
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
    labels:
      io.octojoom.integration: "${RUN_ID}"
networks:
  default:
    external: true
    name: ${NETWORK}
YAML

# Load application functions without executing its installers or interactive main.
awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "${SCRIPT}" >"${WORK}/functions.sh"
# shellcheck disable=SC1091
source "${WORK}/functions.sh"
declare -F cloneJoomlaContainer >/dev/null || die 'Could not load cloneJoomlaContainer.'
# Preserve the real privilege helper, then audit the actual background copy.
eval "$(declare -f runPrivileged | sed '1s/runPrivileged/integration_privileged/')"

container_running() {
  timeout 10s "${DOCKER_BIN}" inspect --format '{{.State.Running}}' "$1"
}

runPrivileged() {
  if [ "${1:-}" = cp ] && [ "${3:-}" = "${SOURCE_PROJECT}/." ]; then
    if [ "$(container_running "${SOURCE_DB}")" != false ] || [ "$(container_running "${SOURCE_WEB}")" != false ]; then
      printf 'Copy attempted while a source service was running.\n' >>"${ERRORS}"
      return 1
    fi
    printf 'copy\n' >>"${TRACE}"
  fi
  integration_privileged "$@"
}

# Forward every Docker operation to the real daemon and record the successful
# source stop/start transitions. Compose validation is real as well.
docker() {
  local action="${*: -1}" status=0
  timeout 90s "${DOCKER_BIN}" "$@" || status=$?
  if [ "${1:-}" = compose ] && [[ " $* " == *" ${SOURCE_ENABLED_YML} "* ]] &&
    { [ "${action}" = stop ] || [ "${action}" = start ]; }; then
    if (( status == 0 )); then printf '%s\n' "${action}" >>"${TRACE}"; fi
  fi
  return "${status}"
}

# Only dialog/terminal interaction is controlled. Identity rewriting, env copying,
# source lifecycle, privilege handling, filesystem copying and JConfig edits are real.
getSelectedDirectory() {
  case "${2:-}" in
    "${VDM_REPO_PATH}/joomla/available/") printf '%s' "${SOURCE_CONTAINER}" ;;
    "${VDM_PROJECT_PATH}") printf '%s' "${SOURCE_KEY}" ;;
    *) printf 'Unexpected directory selection: %s\n' "$*" >>"${ERRORS}"; return 1 ;;
  esac
}
getInput() {
  case "${3:-}" in
    'Enter Key') printf '%s' "${CLONE_KEY}" ;;
    'Enter ENV Key') printf '%s' "${CLONE_ENV}" ;;
    'Enter Sub-Domain') printf clone ;;
    *) printf 'Unexpected input dialog: %s\n' "$*" >>"${ERRORS}"; return 1 ;;
  esac
}
whiptail() {
  local title='' kind='' arg previous=''
  for arg in "$@"; do
    [ "${previous}" != --title ] || title="${arg}"
    case "${arg}" in --yesno | --msgbox) kind="${arg}" ;; esac
    previous="${arg}"
  done
  printf '%s %s\n' "${kind}" "${title}" >>"${DIALOGS}"
  case "${kind}:${title}" in
    '--yesno:Confirm Clone' | '--yesno:Give sudo Privileges' | '--msgbox:Clone Complete') return 0 ;;
    *) printf 'Unexpected whiptail dialog: %s\n' "$*" >>"${ERRORS}"; return 1 ;;
  esac
}
showError() { printf '%b\n' "$1" >>"${ERRORS}"; return 1; }
showNotice() { printf '%b\n' "$1" >>"${DIALOGS}"; }
getDialogHeight() { printf 24; }
showProgress() { :; }

compose() {
  local yml=$1
  shift
  timeout 120s "${DOCKER_BIN}" compose --env-file "${ENV_FILE}" --file "${yml}" "$@"
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
  # Expand the credentials inside the fixture container, never in the host shell.
  # shellcheck disable=SC2016
  timeout 15s "${DOCKER_BIN}" exec -i "$1" sh -c \
    'MYSQL_PWD="$MARIADB_PASSWORD" exec mariadb --batch --skip-column-names --user="$MARIADB_USER" "$MARIADB_DATABASE"'
}
web_probe() {
  # This single-quoted program contains PHP variables, not shell substitutions.
  # shellcheck disable=SC2016
  timeout 10s "${DOCKER_BIN}" exec "$1" php -r '
    $context = stream_context_create(["http" => ["timeout" => 5]]);
    $response = file_get_contents("http://127.0.0.1/clone-probe.php", false, $context);
    $data = json_decode($response, true, 512, JSON_THROW_ON_ERROR);
    foreach (["database_marker" => $argv[1], "host" => $argv[2], "file_marker" => $argv[3], "sitename" => "Octojoom integration"] as $key => $expected) {
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
timeout 300s "${DOCKER_BIN}" compose --env-file "${ENV_FILE}" --file "${SOURCE_YML}" pull
timeout 15s "${DOCKER_BIN}" network create --label "${LABEL}" "${NETWORK}" >/dev/null
compose "${SOURCE_YML}" up -d "${SOURCE_DB}"
wait_until 'source MariaDB' database_ready "${SOURCE_DB}"
compose "${SOURCE_YML}" up -d "${SOURCE_WEB}"
wait_until 'official Joomla files and PHP mysqli' files_ready "${SOURCE_WEB}"

database_sql "${SOURCE_DB}" <<SQL
CREATE TABLE oj_marker (id INT PRIMARY KEY, value VARCHAR(128) NOT NULL) ENGINE=InnoDB;
INSERT INTO oj_marker VALUES (1, '${RUN_ID}');
SQL
cat >"${WORK}/configuration.php" <<PHP
<?php
class JConfig {
    public \$sitename = 'Octojoom integration';
    public \$host = '${SOURCE_DB}:3306';
    public \$user = 'octojoom_fixture';
    public \$password = 'integration-database-password';
    public \$db = 'octojoom_fixture';
    public \$dbprefix = 'oj_';
    public \$secret = '${RUN_ID}';
    public \$live_site = '';
    public \$cookie_domain = '';
}
PHP
cat >"${WORK}/clone-probe.php" <<'PHP'
<?php
// A real Apache/PHP -> JConfig -> MariaDB probe, independent of Joomla installation.
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
    'file_marker' => file_get_contents(__DIR__ . '/.clone-marker'),
    'host' => $config->host,
    'sitename' => $config->sitename,
], JSON_THROW_ON_ERROR);
PHP
printf '%s' "${RUN_ID}" >"${WORK}/.clone-marker"
host_privileged cp "${WORK}/configuration.php" "${WORK}/clone-probe.php" "${WORK}/.clone-marker" "${SOURCE_PROJECT}/joomla/"
timeout 10s "${DOCKER_BIN}" exec "${SOURCE_WEB}" chown www-data:www-data \
  /var/www/html/configuration.php /var/www/html/clone-probe.php /var/www/html/.clone-marker
host_privileged chmod 444 "${SOURCE_PROJECT}/joomla/configuration.php"
host_privileged chmod 644 "${SOURCE_PROJECT}/joomla/clone-probe.php" "${SOURCE_PROJECT}/joomla/.clone-marker"
wait_until 'source Apache/PHP database probe' web_probe "${SOURCE_WEB}" "${RUN_ID}" "${SOURCE_DB}:3306"
web_hashes >"${WORK}/source-web.sha256"
cp "${SOURCE_YML}" "${WORK}/source-compose.before"
grep -F "VDM_${SOURCE_ENV}_" "${ENV_FILE}" >"${WORK}/source-env.before"

# The application handles failure/rollback itself, so do not change its semantics
# by activating errexit inside its function call.
if ! cloneJoomlaContainer; then die 'cloneJoomlaContainer returned a failure.'; fi
[ ! -s "${ERRORS}" ] || die 'The clone reported an error.'
if [ ! -f "${CLONE_YML}" ] || [ ! -d "${CLONE_PROJECT}/db" ]; then die 'The clone was not created.'; fi
grep -qx -- '--msgbox Clone Complete' "${DIALOGS}" || die 'The completion dialog was not reached.'
printf 'stop\ncopy\nstart\n' >"${WORK}/expected.trace"
cmp "${WORK}/expected.trace" "${TRACE}" || die 'Source services were not stopped, copied and restarted in order.'
if [ "$(container_running "${SOURCE_DB}")" != true ] || [ "$(container_running "${SOURCE_WEB}")" != true ]; then
  die 'The source services were not restarted.'
fi
pass 'real source services were stopped for the cold copy and restarted'
[ ! -e "${VDM_REPO_PATH}/joomla/enabled/${CLONE_CONTAINER}" ] || die 'The clone was automatically enabled.'
[ "$(getJoomlaConfigValue "${CLONE_PROJECT}/joomla/configuration.php" host)" = "${CLONE_DB}:3306" ] || die 'Clone JConfig still uses the source database.'
[ "$(host_privileged stat -c '%a:%u:%g' "${CLONE_PROJECT}/joomla/configuration.php")" = \
  "$(host_privileged stat -c '%a:%u:%g' "${SOURCE_PROJECT}/joomla/configuration.php")" ] || die 'Clone configuration ownership/mode changed.'
[ "$(host_privileged stat -c '%d:%i' "${CLONE_PROJECT}/db/ibdata1")" != \
  "$(host_privileged stat -c '%d:%i' "${SOURCE_PROJECT}/db/ibdata1")" ] || die 'Clone database storage is shared.'
pass 'clone has independent JConfig and physical database files with preserved permissions'

compose "${CLONE_YML}" config -q
compose "${CLONE_YML}" up -d "${CLONE_DB}"
wait_until 'cloned MariaDB storage' database_ready "${CLONE_DB}"
compose "${CLONE_YML}" up -d "${CLONE_WEB}"
wait_until 'clone Apache/PHP database probe' web_probe "${CLONE_WEB}" "${RUN_ID}" "${CLONE_DB}:3306"
if [ "$(mount_source "${SOURCE_DB}" /var/lib/mysql)" != "${SOURCE_PROJECT}/db" ] ||
  [ "$(mount_source "${CLONE_DB}" /var/lib/mysql)" != "${CLONE_PROJECT}/db" ] ||
  [ "$(mount_source "${SOURCE_WEB}" /var/www/html)" != "${SOURCE_PROJECT}/joomla" ] ||
  [ "$(mount_source "${CLONE_WEB}" /var/www/html)" != "${CLONE_PROJECT}/joomla" ]; then
  die 'A runtime bind mount points at the wrong project.'
fi
pass 'the started clone reads copied database/file markers through its own runtime mounts'

database_sql "${CLONE_DB}" <<SQL
UPDATE oj_marker SET value = 'clone-${RUN_ID}' WHERE id = 1;
SQL
timeout 10s "${DOCKER_BIN}" exec "${CLONE_WEB}" sh -c 'printf clone-only > /var/www/html/.clone-only'
[ ! -e "${SOURCE_PROJECT}/joomla/.clone-only" ] || die 'A clone file write changed the source.'
web_probe "${SOURCE_WEB}" "${RUN_ID}" "${SOURCE_DB}:3306"
web_probe "${CLONE_WEB}" "clone-${RUN_ID}" "${CLONE_DB}:3306"
timeout 45s "${DOCKER_BIN}" stop --time 30 "${SOURCE_DB}" >/dev/null
[ "$(container_running "${SOURCE_DB}")" = false ] || die 'The source database did not stop.'
web_probe "${CLONE_WEB}" "clone-${RUN_ID}" "${CLONE_DB}:3306"
pass 'clone writes are independent and the clone remains usable with the source database stopped'

timeout 30s "${DOCKER_BIN}" start "${SOURCE_DB}" >/dev/null
wait_until 'restarted source MariaDB' database_ready "${SOURCE_DB}"
web_probe "${SOURCE_WEB}" "${RUN_ID}" "${SOURCE_DB}:3306"
web_hashes >"${WORK}/source-web.after.sha256"
cmp "${WORK}/source-web.sha256" "${WORK}/source-web.after.sha256" || die 'The source site content changed.'
cmp "${WORK}/source-compose.before" "${SOURCE_YML}" || die 'The source Compose file changed.'
grep -F "VDM_${SOURCE_ENV}_" "${ENV_FILE}" >"${WORK}/source-env.after"
cmp "${WORK}/source-env.before" "${WORK}/source-env.after" || die 'The source environment values changed.'
pass 'source website files, configuration, Compose, credentials and database marker are unchanged'
printf '\nDocker clone integration passed.\n'
