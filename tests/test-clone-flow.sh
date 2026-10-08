#!/usr/bin/env bash
#
# End-to-end test of the Joomla container clone flow in src/octojoom.
#
# Every function of the script is loaded into this shell, and whiptail, docker
# (except "docker compose config", which runs for real when docker is installed)
# and sudo are replaced by stubs. The clone is then driven with scripted
# answers against a throw-away Octojoom home, and the files it writes are
# checked. Run from anywhere:
#
#   bash tests/test-clone-flow.sh
#
# Needs bash 4+, sed, grep, awk, diff and cp. No whiptail or docker daemon required.
#
# SC2015: "A && pass || fail" is the intended check idiom (pass never fails).
# SC2016: single quoted ${...} are literal compose variables we grep for.
# SC2034: the VDM_* globals are read by the loaded script functions.
# shellcheck disable=SC2015,SC2016,SC2034

# no "set -u": the script under test is not written for it

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${TEST_DIR}/../src/octojoom"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

PASSED=0
FAILED=0

pass() {
  PASSED=$((PASSED + 1))
  echo "ok   - $1"
}

# file modes are not real on Windows (MSYS/Git Bash), so mode checks are skipped there
mode_is() {
  if [[ "${OSTYPE}" == "msys" || "${OSTYPE}" == "cygwin" ]]; then
    return 0
  fi
  [ "$(stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1")" = "$2" ]
}

fail() {
  FAILED=$((FAILED + 1))
  echo "FAIL - $1"
  [ -n "${2:-}" ] && echo "       $2"
}

# load every function of the script (the script itself is never run)
FUNCTIONS="${WORK}/functions.sh"
awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "${SCRIPT}" >"${FUNCTIONS}"
# shellcheck disable=SC1090
source "${FUNCTIONS}"

###############################################################################
# stubs

# answers are read in order from ${ANSWERS}; every dialog is logged to ${DIALOGS}
ANSWERS="${WORK}/answers"
DIALOGS="${WORK}/dialogs"
RUNNING="${WORK}/running"
COMPOSE_LOG="${WORK}/compose.log"

next_answer() {
  local answer
  answer=$(head -n 1 "${ANSWERS}")
  sed -i.bak '1d' "${ANSWERS}" && rm -f "${ANSWERS}.bak"
  printf '%s' "${answer}"
}

whiptail() {
  local kind=''
  local text=''
  local arg
  for arg in "$@"; do
    case "${arg}" in
    --yesno | --inputbox | --radiolist | --checklist | --menu | --passwordbox | --msgbox | --infobox | --gauge)
      kind="${arg}"
      ;;
    esac
  done
  # the text follows the dialog kind
  local take=false
  for arg in "$@"; do
    if ${take}; then
      text="${arg}"
      break
    fi
    [ "${arg}" = "${kind}" ] && take=true
  done
  printf '%s | %s\n' "${kind}" "$(printf '%b' "${text}" | head -n 1)" >>"${DIALOGS}"
  case "${kind}" in
  --gauge)
    cat >/dev/null
    return 0
    ;;
  --msgbox | --infobox)
    printf '%b\n-----\n' "${text}" >>"${DIALOGS}.full"
    return 0
    ;;
  --yesno)
    printf '%b\n-----\n' "${text}" >>"${DIALOGS}.full"
    [ "$(next_answer)" = "yes" ]
    return $?
    ;;
  *)
    # input, radiolist, menu: the answer goes to stderr like whiptail does
    next_answer >&2
    return 0
    ;;
  esac
}

docker() {
  case "${1:-}" in
  ps)
    cat "${RUNNING}" 2>/dev/null
    ;;
  info)
    return 0
    ;;
  compose)
    local action="${*: -1}"
    echo "$*" >>"${COMPOSE_LOG}"
    case "${action}" in
    -q)
      if command -v docker >/dev/null 2>&1 && [ -x "$(type -P docker)" ]; then
        command docker "$@"
      fi
      return $?
      ;;
    stop)
      [ -f "${WORK}/fail_stop" ] && return 1
      grep -vxE '(mariadb|joomla|phpmyadmin|mailcatcher)jcb' "${RUNNING}" >"${RUNNING}.tmp"
      mv "${RUNNING}.tmp" "${RUNNING}"
      ;;
    start)
      [ -f "${WORK}/fail_start" ] && return 1
      printf '%s\n' mariadbjcb joomlajcb phpmyadminjcb mailcatcherjcb >>"${RUNNING}"
      ;;
    esac
    return 0
    ;;
  esac
  return 0
}

sudo() {
  [ "${1:-}" = "-v" ] && return 0
  # like root, write into a read-only file (the tests run as a normal user)
  if [ "${1:-}" = "tee" ] && [ -f "${2:-}" ] && [ ! -w "${2:-}" ]; then
    chmod u+w "$2" && "$@"
    local rc=$?
    chmod u-w "$2"
    return "${rc}"
  fi
  "$@"
}

# no real terminal here
tput() { echo 50; }

###############################################################################
# a fake Octojoom home with one Joomla container (jcb.vdm.dev, key jcb, env key JCB)

setup_home() {
  rm -rf "${WORK:?}/home"
  mkdir -p "${WORK}/home/config" "${WORK}/home/Docker/joomla/available/jcb.vdm.dev" \
    "${WORK}/home/Docker/joomla/enabled" "${WORK}/home/Projects/jcb/joomla" "${WORK}/home/Projects/jcb/db/vdm_io"
  VDM_SRC_PATH="${WORK}/home/config"
  VDM_REPO_PATH="${WORK}/home/Docker"
  VDM_PROJECT_PATH="${WORK}/home/Projects"
  VDM_CONTAINER_TYPE='joomla'
  OS_NUMBER=1
  VDM_DOMAIN='vdm.dev'
  VDM_MULTI_DOMAIN=false
  VDM_UPDATE_HOST=false
  VDM_SECURE=true
  VDM_EXPERT_MODE="${1:-false}"
  VDM_FORCE=false
  VDM_ARG_DOMAIN=false
  BACK_TITLE='test'
  PROGRAM_NAME='Octojoom'
  _VERSION='test'
  _V='test'
  unset VDM_KEY VDM_ENV_KEY VDM_SUBDOMAIN VDM_PUID VDM_PGID
  printf 'VDM_REPO_PATH="%s"\nVDM_PROJECT_PATH="%s"\nVDM_DOMAIN="vdm.dev"\nVDM_MULTI_DOMAIN=false\nVDM_UPDATE_HOST=false\nVDM_SECURE=true\n' \
    "${VDM_REPO_PATH}" "${VDM_PROJECT_PATH}" >"${VDM_SRC_PATH}/.env"
  # the compose file exactly as setup writes it (secure, mailcatcher, php.ini)
  (
    VDM_KEY=jcb VDM_ENV_KEY=JCB VDM_SUBDOMAIN=jcb VDM_DOMAIN=vdm.dev VDM_J_REPO=joomla VDM_JV=5.3 VDM_PUID='' VDM_PGID=''
    VDM_JOOMLA_VOLUMES_MOUNT=$(getYMLine3 "- \"\${VDM_PROJECT_PATH}/jcb/joomla:/var/www/html\"")
    VDM_JOOMLA_VOLUMES_MOUNT+=$(getYMLine3 "- \"\${VDM_PROJECT_PATH}/jcb/php.ini:/var/www/html/php.ini\"")
    VDM_DB_VOLUMES_MOUNT=$(getYMLine3 "- \"\${VDM_PROJECT_PATH}/jcb/db:/var/lib/mysql\"")
    VDM_VOLUMES=''
    VDM_JOOMLA_SECURE_LABELS=$(getYMLine3 "- \"traefik.http.routers.joomlajcb.entrypoints=websecure\"")
    VDM_JOOMLA_SECURE_LABELS+=$(getYMLine3 "- \"traefik.http.routers.joomlajcb.tls.certresolver=vdmresolver\"")
    VDM_JOOMLA_SECURE_LABELS+=$(getYMLine3 "- \"traefik.http.routers.joomlajcb.service=joomlajcb\"")
    VDM_PHPMYADMIN_SECURE_LABELS=$(getYMLine3 "- \"traefik.http.routers.phpmyadminjcb.entrypoints=websecure\"")
    VDM_EXTRA_CONTAINER_STUFF=$(getYMLine1 "mailcatcherjcb:")
    VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "image: schickling/mailcatcher")
    VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "container_name: mailcatcherjcb")
    VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "labels:")
    VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine3 "- \"traefik.http.routers.mailcatcherjcb.rule=Host(\`jcbmail.vdm.dev\`)\"")
    VDM_EXTRA_JOOMLA_ENV=$(getYMLine3 "- JOOMLA_SMTP_HOST=mailcatcherjcb:1025")
    VDM_EXTRA_JOOMLA_ENV+=$(getYMLine3 "- JOOMLA_DB_PREFIX=\${VDM_JCB_JOOMLA_DB_PREFIX}")
    joomlaContainer
  ) >"${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev/docker-compose.yml"
  ln -s "${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev" "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
  # the shared env file, without a final new line (as some editors leave it)
  printf 'VDM_PROJECT_PATH="%s"\n\nVDM_JCB_DB="vdm_io"\nVDM_JCB_DB_USER="vdm_user"\nVDM_JCB_DB_PASS="secret"\nVDM_JCB_DB_ROOT="rootsecret"\nVDM_JCB_JOOMLA_DB_PREFIX="jcb_"' \
    "${VDM_PROJECT_PATH}" >"${VDM_REPO_PATH}/joomla/.env"
  chmod 600 "${VDM_REPO_PATH}/joomla/.env"
  cp "${VDM_REPO_PATH}/joomla/.env" "${WORK}/env.orig"
  # an installed Joomla site and its database files
  cat >"${VDM_PROJECT_PATH}/jcb/joomla/configuration.php" <<'PHP'
<?php
class JConfig {
	public $sitename = 'JCB Site';
	public $host = 'mariadbjcb:3306';
	public $user = 'vdm_user';
	public $password = 'secret';
	public $db = 'vdm_io';
	public $dbprefix = 'jcb_';
	public $smtphost = 'mailcatcherjcb';
	public $secret = 'keepme';
}
PHP
  chmod 444 "${VDM_PROJECT_PATH}/jcb/joomla/configuration.php"
  echo 'RewriteEngine On' >"${VDM_PROJECT_PATH}/jcb/joomla/.htaccess"
  echo 'ibdata' >"${VDM_PROJECT_PATH}/jcb/db/ibdata1"
  echo 'max_execution_time = 124' >"${VDM_PROJECT_PATH}/jcb/php.ini"
  rm -f "${WORK}/configuration.orig"
  cp "${VDM_PROJECT_PATH}/jcb/joomla/configuration.php" "${WORK}/configuration.orig"
  cp "${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev/docker-compose.yml" "${WORK}/compose.orig"
  # the source is running
  printf '%s\n' traefik mariadbjcb joomlajcb phpmyadminjcb mailcatcherjcb >"${RUNNING}"
  rm -f "${DIALOGS}" "${DIALOGS}.full" "${COMPOSE_LOG}" "${WORK}/fail_stop" "${WORK}/fail_start"
}

# the source must never change
check_source_untouched() {
  local name="$1"
  diff -q "${WORK}/configuration.orig" "${VDM_PROJECT_PATH}/jcb/joomla/configuration.php" >/dev/null &&
    pass "${name}: source configuration.php untouched" || fail "${name}: source configuration.php changed"
  diff -q "${WORK}/compose.orig" "${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev/docker-compose.yml" >/dev/null &&
    pass "${name}: source docker-compose.yml untouched" || fail "${name}: source docker-compose.yml changed"
  grep -qx 'VDM_JCB_JOOMLA_DB_PREFIX="jcb_"' "${VDM_REPO_PATH}/joomla/.env" &&
    pass "${name}: source env values intact" || fail "${name}: source env values damaged" "$(cat -A "${VDM_REPO_PATH}/joomla/.env" 2>/dev/null)"
}

###############################################################################
echo "# a full clone of a running, enabled container"

setup_home false
# container, project folder, key, env key, sub-domain, confirm, sudo
printf '%s\n' jcb.vdm.dev jcb test TEST test yes yes >"${ANSWERS}"
cloneJoomlaContainer
CLONE_YML="${VDM_REPO_PATH}/joomla/available/test.vdm.dev/docker-compose.yml"
CLONE_CONFIG="${VDM_PROJECT_PATH}/test/joomla/configuration.php"

[ -s "${ANSWERS}" ] && fail "full clone: not every answer was used" "$(cat "${ANSWERS}")" || pass "full clone: asked exactly the expected questions"
[ -f "${CLONE_YML}" ] && pass "full clone: compose file written to available/" || fail "full clone: no compose file"
[ -e "${VDM_REPO_PATH}/joomla/enabled/test.vdm.dev" ] && fail "full clone: clone was enabled" || pass "full clone: clone is not enabled"
grep -q 'container_name: mariadbtest' "${CLONE_YML}" && grep -q 'JOOMLA_DB_HOST=mariadbtest:3306' "${CLONE_YML}" &&
  grep -q 'Host(`test.vdm.dev`)' "${CLONE_YML}" && grep -q 'Host(`testmail.vdm.dev`)' "${CLONE_YML}" &&
  grep -q 'PROJECT_PATH}/test/db:/var/lib/mysql' "${CLONE_YML}" && grep -q 'VDM_TEST_DB}' "${CLONE_YML}" &&
  pass "full clone: compose file renamed" || fail "full clone: compose file" "$(grep -E 'container_name|HOST|Host|PROJECT_PATH|VDM_' "${CLONE_YML}")"
grep -qE 'jcb|JCB' "${CLONE_YML}" && fail "full clone: compose file still mentions the source" "$(grep -nE 'jcb|JCB' "${CLONE_YML}")" ||
  pass "full clone: nothing of the source left in the compose file"
if [ -d "${VDM_PROJECT_PATH}/test/db/vdm_io" ] && [ -f "${VDM_PROJECT_PATH}/test/db/ibdata1" ] &&
  [ -f "${VDM_PROJECT_PATH}/test/php.ini" ] && [ -f "${VDM_PROJECT_PATH}/test/joomla/.htaccess" ]; then
  pass "full clone: project folder copied with hidden files"
else
  fail "full clone: project folder copy" "$(find "${VDM_PROJECT_PATH}/test" | head)"
fi
[ "$(getJoomlaConfigValue "${CLONE_CONFIG}" host)" = "mariadbtest:3306" ] && pass "full clone: database host patched" ||
  fail "full clone: database host is $(getJoomlaConfigValue "${CLONE_CONFIG}" host)"
[ "$(getJoomlaConfigValue "${CLONE_CONFIG}" smtphost)" = "mailcatchertest" ] && pass "full clone: mailcatcher host patched" ||
  fail "full clone: mailcatcher host"
[ "$(getJoomlaConfigValue "${CLONE_CONFIG}" db)" = "vdm_io" ] && [ "$(getJoomlaConfigValue "${CLONE_CONFIG}" dbprefix)" = "jcb_" ] &&
  [ "$(getJoomlaConfigValue "${CLONE_CONFIG}" secret)" = "keepme" ] && [ "$(getJoomlaConfigValue "${CLONE_CONFIG}" sitename)" = "JCB Site" ] &&
  pass "full clone: database name, prefix, secret and site name kept" || fail "full clone: a kept value changed"
mode_is "${CLONE_CONFIG}" 444 && pass "full clone: configuration.php stays read only" ||
  fail "full clone: configuration.php mode changed"
grep -qx 'VDM_TEST_DB="vdm_io"' "${VDM_REPO_PATH}/joomla/.env" && grep -qx 'VDM_TEST_DB_ROOT="rootsecret"' "${VDM_REPO_PATH}/joomla/.env" &&
  grep -qx 'VDM_TEST_JOOMLA_DB_PREFIX="jcb_"' "${VDM_REPO_PATH}/joomla/.env" && pass "full clone: env values copied under TEST" ||
  fail "full clone: env values" "$(cat "${VDM_REPO_PATH}/joomla/.env")"
check_source_untouched "full clone"
grep -q 'enabled/jcb.vdm.dev/docker-compose.yml stop' "${COMPOSE_LOG}" && grep -q 'enabled/jcb.vdm.dev/docker-compose.yml start' "${COMPOSE_LOG}" &&
  pass "full clone: source stopped and started again" || fail "full clone: source stop/start" "$(cat "${COMPOSE_LOG}")"
grep -qx 'mariadbjcb' "${RUNNING}" && pass "full clone: source is running again" || fail "full clone: source left stopped"
grep -q 'was cloned to (test.vdm.dev)' "${DIALOGS}.full" && grep -q 'https://test.vdm.dev' "${DIALOGS}.full" &&
  pass "full clone: closing screen shows the clone" || fail "full clone: closing screen" "$(tail -n 20 "${DIALOGS}.full")"

###############################################################################
echo "# cancelling at the confirmation changes nothing"

setup_home false
printf '%s\n' jcb.vdm.dev jcb test TEST test no >"${ANSWERS}"
cloneJoomlaContainer
[ ! -e "${VDM_REPO_PATH}/joomla/available/test.vdm.dev" ] && [ ! -e "${VDM_PROJECT_PATH}/test" ] &&
  diff -q "${WORK}/env.orig" "${VDM_REPO_PATH}/joomla/.env" >/dev/null && pass "cancel: nothing written" || fail "cancel: something was written"
[ ! -s "${COMPOSE_LOG}" ] || ! grep -q ' stop' "${COMPOSE_LOG}" && pass "cancel: source not stopped" || fail "cancel: source was stopped"
check_source_untouched "cancel"

###############################################################################
echo "# a failed stop starts the source again and rolls back"

setup_home false
touch "${WORK}/fail_stop"
printf '%s\n' jcb.vdm.dev jcb test TEST test yes yes >"${ANSWERS}"
cloneJoomlaContainer
[ ! -e "${VDM_REPO_PATH}/joomla/available/test.vdm.dev" ] && [ ! -e "${VDM_PROJECT_PATH}/test" ] &&
  pass "failed stop: clone rolled back" || fail "failed stop: clone left behind"
# the final new line the clone added before appending may stay, every line must be as before
diff -q <(awk 1 "${WORK}/env.orig") <(awk 1 "${VDM_REPO_PATH}/joomla/.env") >/dev/null && pass "failed stop: env file restored" ||
  fail "failed stop: env file differs" "$(diff "${WORK}/env.orig" "${VDM_REPO_PATH}/joomla/.env")"
grep -q 'enabled/jcb.vdm.dev/docker-compose.yml start' "${COMPOSE_LOG}" && pass "failed stop: source started again" ||
  fail "failed stop: no start attempted"
check_source_untouched "failed stop"

###############################################################################
echo "# a failed restart is reported right away"

setup_home false
touch "${WORK}/fail_start"
printf '%s\n' jcb.vdm.dev jcb test TEST test yes yes >"${ANSWERS}"
cloneJoomlaContainer
grep -q 'could not be started again after the copy' "${DIALOGS}.full" && pass "failed start: error shown" || fail "failed start: no error shown"
[ -f "${VDM_REPO_PATH}/joomla/available/test.vdm.dev/docker-compose.yml" ] && pass "failed start: clone still completed" ||
  fail "failed start: clone missing"

###############################################################################
echo "# a used key, env key and host are refused"

setup_home false
mkdir -p "${VDM_PROJECT_PATH}/taken"
printf '\nVDM_USED_PUID="#1000"\n' >>"${VDM_REPO_PATH}/joomla/.env"
# key jcb (the source), key taken (folder exists), then test; env key USED, then TEST;
# sub-domain jcbmail (the source's mailcatcher host), then test
printf '%s\n' jcb.vdm.dev jcb jcb taken test USED TEST jcbmail test yes yes >"${ANSWERS}"
cloneJoomlaContainer
[ -s "${ANSWERS}" ] && fail "refusals: not every answer was used" "$(cat "${ANSWERS}")" || pass "refusals: every refused value was asked again"
grep -q 'The key:jcb is already used' "${DIALOGS}.full" && pass "refusals: source key refused" || fail "refusals: source key accepted"
grep -q 'The key:taken is already used' "${DIALOGS}.full" && pass "refusals: key of an existing folder refused" || fail "refusals: existing folder key accepted"
grep -q 'environment key (USED) already has values' "${DIALOGS}.full" &&
  pass "refusals: env key with values refused" || fail "refusals: env key with values accepted"
grep -q 'jcbmail.vdm.dev) is already used' "${DIALOGS}.full" && pass "refusals: host of the source mailcatcher refused" ||
  fail "refusals: colliding host accepted"
grep -qx 'VDM_USED_PUID="#1000"' "${VDM_REPO_PATH}/joomla/.env" && pass "refusals: other env values kept" || fail "refusals: other env values lost"

###############################################################################
echo "# expert mode asks for the site name"

setup_home true
printf '%s\n' jcb.vdm.dev jcb test TEST test 'JCB Test Copy' yes yes >"${ANSWERS}"
cloneJoomlaContainer
[ "$(getJoomlaConfigValue "${VDM_PROJECT_PATH}/test/joomla/configuration.php" sitename)" = "JCB Test Copy" ] &&
  pass "expert: site name of the clone set" || fail "expert: site name is $(getJoomlaConfigValue "${VDM_PROJECT_PATH}/test/joomla/configuration.php" sitename)"
check_source_untouched "expert"

###############################################################################
echo "# a disabled source is not touched"

setup_home false
# a link, or a copied folder where links are not supported (Windows)
rm -rf "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
printf '%s\n' traefik >"${RUNNING}"
printf '%s\n' jcb.vdm.dev jcb test TEST test yes yes >"${ANSWERS}"
cloneJoomlaContainer
[ -f "${VDM_REPO_PATH}/joomla/available/test.vdm.dev/docker-compose.yml" ] && pass "disabled source: clone completed" || fail "disabled source: clone missing"
[ ! -s "${COMPOSE_LOG}" ] || ! grep -qE ' (stop|start)$' "${COMPOSE_LOG}" && pass "disabled source: not stopped or started" ||
  fail "disabled source: compose was run" "$(cat "${COMPOSE_LOG}")"

###############################################################################
echo
echo "passed: ${PASSED}  failed: ${FAILED}"
[ "${FAILED}" -eq 0 ]
