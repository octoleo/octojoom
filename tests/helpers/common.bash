# shellcheck shell=bash
#
# Shared setup for the Octojoom bats tests. Load it from a test file with:
#
#   load ../helpers/common
#   setup() { octojoom_setup; }
#
# octojoom_setup gives every test:
#   - all functions of src/octojoom, loaded without running the script
#   - a sandbox (${SANDBOX}) holding a fake home with the Octojoom paths:
#       VDM_SRC_PATH      ${SANDBOX}/home/.config/octojoom
#       VDM_REPO_PATH     ${SANDBOX}/home/Docker
#       VDM_PROJECT_PATH  ${SANDBOX}/home/Projects
#   - stand-ins for whiptail, docker, sudo, ssh, curl and the system tools,
#     first on PATH, with their state in ${STUB_DIR} (see tests/helpers/bin)
#
# Nothing outside the sandbox is ever changed: the sudo stand-in refuses paths
# outside it, curl never touches the network, and package managers only log.

# SC2034: the VDM_* globals are read by the loaded script functions.
# SC2154: status and output are set by bats "run".
# shellcheck disable=SC2034,SC2154

HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCTOJOOM_ROOT="$(cd "${HELPERS_DIR}/../.." && pwd)"
OCTOJOOM_SCRIPT="${OCTOJOOM_ROOT}/src/octojoom"

###############################################################################
# platform

is_windows() { [[ "${OSTYPE}" == "msys" || "${OSTYPE}" == "cygwin" ]]; }
is_macos() { [[ "${OSTYPE}" == "darwin"* ]]; }
is_linux() { [[ "${OSTYPE}" == "linux-gnu"* ]]; }

# file modes are not real on Windows (MSYS/Git Bash)
skip_on_windows() {
  if is_windows; then
    skip "${1:-not supported on Windows}"
  fi
}

# the mode of a file as three octal digits (GNU and BSD stat)
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

###############################################################################
# loading the script

# extract every function of the script once per bats run, then source it
octojoom_load() {
  local cache="${BATS_RUN_TMPDIR:-${TMPDIR:-/tmp}}/octojoom-functions.sh"
  if [ ! -s "${cache}" ]; then
    awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' \
      "${OCTOJOOM_SCRIPT}" >"${cache}.$$" && mv -f "${cache}.$$" "${cache}"
  fi
  # shellcheck disable=SC1090
  source "${cache}"
}

# the globals the script sets before any function runs
octojoom_globals() {
  _VERSION=$(sed -nE 's/^_VERSION="([^"]+)"$/\1/p' "${OCTOJOOM_SCRIPT}" | head -n 1)
  _V=$(sed -nE 's/^_V="([^"]+)"$/\1/p' "${OCTOJOOM_SCRIPT}" | head -n 1)
  PROGRAM_NAME="Octojoom"
  SERVER_HOSTNAME="test-host"
  USER="${USER:-tester}"
  BACK_TITLE="    Octoleo | ${USER}@${SERVER_HOSTNAME}"
  DOCKER_INSTALLED_THIS_SESSION=false
  OS_NUMBER=0
  if [[ "${OSTYPE}" == "linux-gnu"* ]]; then
    OS_NUMBER=1
  elif [[ "${OSTYPE}" == "darwin"* ]]; then
    OS_NUMBER=2
  elif [[ "${OSTYPE}" == "msys" || "${OSTYPE}" == "cygwin" ]]; then
    OS_NUMBER=3
  fi
  VDM_ARG_DOMAIN=false
  VDM_FORCE=false
  export LC_ALL=C
}

###############################################################################
# the sandbox

octojoom_setup() {
  SANDBOX="${BATS_TEST_TMPDIR}/sandbox"
  STUB_DIR="${SANDBOX}/stub"
  STUB_SANDBOX="${SANDBOX}"
  STUB_KILL_PID="${BASHPID}"
  OCTOJOOM_HOME="${SANDBOX}/home"
  mkdir -p "${STUB_DIR}/hooks" "${STUB_DIR}/fail" "${STUB_DIR}/docker" "${OCTOJOOM_HOME}"
  : >"${STUB_DIR}/answers"
  : >"${STUB_DIR}/commands.log"
  : >"${STUB_DIR}/dialogs.log"
  : >"${STUB_DIR}/dialogs.full"
  # the real docker (for "docker compose config"), found before the stand-ins shadow it
  REAL_DOCKER=''
  if [ -z "${OCTOJOOM_NO_REAL_DOCKER:-}" ]; then
    REAL_DOCKER="$(PATH="${PATH//${HELPERS_DIR}\/bin:/}" command -v docker 2>/dev/null || true)"
    [ -x "${REAL_DOCKER}" ] || REAL_DOCKER=''
  fi
  case ":${PATH}:" in
  *":${HELPERS_DIR}/bin:"*) ;;
  *) PATH="${HELPERS_DIR}/bin:${PATH}" ;;
  esac
  EDITOR="${HELPERS_DIR}/bin/fake-editor"
  export SANDBOX STUB_DIR STUB_SANDBOX STUB_KILL_PID OCTOJOOM_HOME REAL_DOCKER PATH EDITOR

  octojoom_load
  octojoom_globals

  VDM_HOME_PATH="${OCTOJOOM_HOME}"
  VDM_SRC_PATH="${VDM_HOME_PATH}/.config/octojoom"
  VDM_REPO_PATH="${VDM_HOME_PATH}/Docker"
  VDM_PROJECT_PATH="${VDM_HOME_PATH}/Projects"
  mkdir -p "${VDM_SRC_PATH}" "${VDM_REPO_PATH}" "${VDM_PROJECT_PATH}"
  export VDM_HOME_PATH VDM_SRC_PATH VDM_REPO_PATH VDM_PROJECT_PATH
}

# write the global config (${VDM_SRC_PATH}/.env) with the usual answers already given;
# extra KEY=value pairs are appended
octojoom_config() {
  {
    echo "VDM_REPO_PATH=\"${VDM_REPO_PATH}\""
    echo "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\""
    echo "VDM_DOMAIN=\"vdm.dev\""
    echo "VDM_MULTI_DOMAIN=false"
    echo "VDM_UPDATE_HOST=false"
    echo "VDM_SECURE=false"
    echo "VDM_EXPERT_MODE=false"
    local pair
    for pair in "$@"; do
      echo "${pair}"
    done
  } >"${VDM_SRC_PATH}/.env"
  chmod 600 "${VDM_SRC_PATH}/.env"
  # shellcheck disable=SC1091
  source "${VDM_SRC_PATH}/.env"
}

###############################################################################
# driving the stand-ins

# the answers whiptail gives, in order (see tests/helpers/bin/whiptail)
answers() {
  : >"${STUB_DIR}/answers"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"${STUB_DIR}/answers"
}

# fail the test when not every answer was used, or a dialog ran out of answers
assert_answers_used() {
  if [ -s "${STUB_DIR}/out_of_answers" ]; then
    echo "a dialog had no answer:" >&2
    cat "${STUB_DIR}/out_of_answers" >&2
    return 1
  fi
  if [ -s "${STUB_DIR}/answers" ]; then
    echo "answers left unused:" >&2
    cat "${STUB_DIR}/answers" >&2
    return 1
  fi
}

# the containers docker reports as running
running_containers() {
  printf '%s\n' "$@" >"${STUB_DIR}/docker/running"
}

# make a stand-in fail: fail_command <name> [status]   e.g. docker-compose-up, ssh, curl
fail_command() {
  echo "${2:-1}" >"${STUB_DIR}/fail/$1"
}

# replace a stand-in's behaviour for this test: hook_command <name> <<'EOF' ... EOF
hook_command() {
  cat >"${STUB_DIR}/hooks/$1"
}

###############################################################################
# assertions (bats "run" sets $status and $output)

assert_success() {
  if [ "${status}" -ne 0 ]; then
    echo "expected success, got status ${status}; output:" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_failure() {
  if [ "${status}" -eq 0 ]; then
    echo "expected failure, got status 0; output:" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_status() {
  if [ "${status}" -ne "$1" ]; then
    echo "expected status $1, got ${status}; output:" >&2
    echo "${output}" >&2
    return 1
  fi
}

assert_equal() {
  if [ "$1" != "$2" ]; then
    printf 'expected: %s\nactual:   %s\n' "$2" "$1" >&2
    return 1
  fi
}

assert_output_contains() {
  if [[ "${output}" != *"$1"* ]]; then
    printf 'output does not contain: %s\noutput:\n%s\n' "$1" "${output}" >&2
    return 1
  fi
}

refute_output_contains() {
  if [[ "${output}" == *"$1"* ]]; then
    printf 'output contains: %s\noutput:\n%s\n' "$1" "${output}" >&2
    return 1
  fi
}

assert_file_exists() {
  if [ ! -e "$1" ]; then
    echo "missing file: $1" >&2
    return 1
  fi
}

refute_file_exists() {
  if [ -e "$1" ]; then
    echo "unexpected file: $1" >&2
    return 1
  fi
}

# assert_file_contains <file> <fixed text>
assert_file_contains() {
  if ! grep -qF -- "$2" "$1" 2>/dev/null; then
    printf '%s does not contain: %s\n' "$1" "$2" >&2
    [ -f "$1" ] && cat "$1" >&2
    return 1
  fi
}

refute_file_contains() {
  if grep -qF -- "$2" "$1" 2>/dev/null; then
    printf '%s contains: %s\n' "$1" "$2" >&2
    return 1
  fi
}

# a dialog whose text contains the given words was shown
assert_dialog() {
  assert_file_contains "${STUB_DIR}/dialogs.full" "$1"
}

refute_dialog() {
  refute_file_contains "${STUB_DIR}/dialogs.full" "$1"
}

# a stand-in was called with a line matching the extended regular expression
assert_command() {
  if ! grep -qE -- "$1" "${STUB_DIR}/commands.log"; then
    printf 'no command matching: %s\ncommands:\n' "$1" >&2
    cat "${STUB_DIR}/commands.log" >&2
    return 1
  fi
}

refute_command() {
  if grep -qE -- "$1" "${STUB_DIR}/commands.log"; then
    printf 'unexpected command matching: %s\n' "$1" >&2
    grep -E -- "$1" "${STUB_DIR}/commands.log" >&2
    return 1
  fi
}

###############################################################################
# fixtures

# the docker-compose.yml joomla__TRuST__setup writes, for the common option sets
# gen_joomla_compose <key> <env key> <sub-domain> <domain> [secure] [mailcatcher]
gen_joomla_compose() {
  (
    VDM_KEY="$1"
    VDM_ENV_KEY="$2"
    VDM_SUBDOMAIN="$3"
    VDM_DOMAIN="$4"
    VDM_J_REPO='joomla'
    VDM_JV='5.3'
    VDM_PUID=''
    VDM_PGID=''
    VDM_VOLUMES=''
    VDM_EXTRA_CONTAINER_STUFF=''
    VDM_EXTRA_JOOMLA_ENV=''
    VDM_JOOMLA_SECURE_LABELS=''
    VDM_PHPMYADMIN_SECURE_LABELS=''
    VDM_JOOMLA_VOLUMES_MOUNT=$(getYMLine3 "- \"\${VDM_PROJECT_PATH}/${VDM_KEY}/joomla:/var/www/html\"")
    VDM_DB_VOLUMES_MOUNT=$(getYMLine3 "- \"\${VDM_PROJECT_PATH}/${VDM_KEY}/db:/var/lib/mysql\"")
    if [ "${5:-false}" = "true" ]; then
      VDM_JOOMLA_SECURE_LABELS=$(getYMLine3 "- \"traefik.http.routers.joomla${VDM_KEY}.entrypoints=websecure\"")
      VDM_JOOMLA_SECURE_LABELS+=$(getYMLine3 "- \"traefik.http.routers.joomla${VDM_KEY}.tls.certresolver=vdmresolver\"")
      VDM_PHPMYADMIN_SECURE_LABELS=$(getYMLine3 "- \"traefik.http.routers.phpmyadmin${VDM_KEY}.entrypoints=websecure\"")
    fi
    if [ "${6:-false}" = "true" ]; then
      VDM_EXTRA_CONTAINER_STUFF=$(getYMLine1 "mailcatcher${VDM_KEY}:")
      VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "image: schickling/mailcatcher")
      VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "container_name: mailcatcher${VDM_KEY}")
      VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine2 "labels:")
      VDM_EXTRA_CONTAINER_STUFF+=$(getYMLine3 "- \"traefik.http.routers.mailcatcher${VDM_KEY}.rule=Host(\`${VDM_SUBDOMAIN}mail.${VDM_DOMAIN}\`)\"")
      VDM_EXTRA_JOOMLA_ENV=$(getYMLine3 "- JOOMLA_SMTP_HOST=mailcatcher${VDM_KEY}:1025")
    fi
    joomlaContainer
  )
}

# create an available Joomla container (compose file, env values, project folder)
# make_joomla_container <key> <env key> <sub-domain> [domain]
make_joomla_container() {
  local key="$1" env="$2" sub="$3" domain="${4:-vdm.dev}"
  mkdir -p "${VDM_REPO_PATH}/joomla/available/${sub}.${domain}" \
    "${VDM_PROJECT_PATH}/${key}/joomla" "${VDM_PROJECT_PATH}/${key}/db"
  gen_joomla_compose "${key}" "${env}" "${sub}" "${domain}" >"${VDM_REPO_PATH}/joomla/available/${sub}.${domain}/docker-compose.yml"
  {
    echo "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\""
    echo "VDM_${env}_DB=\"${key}_db\""
    echo "VDM_${env}_DB_USER=\"${key}_user\""
    echo "VDM_${env}_DB_PASS=\"secret\""
    echo "VDM_${env}_DB_ROOT=\"rootsecret\""
  } >>"${VDM_REPO_PATH}/joomla/.env"
}

# enable an available container the way Octojoom does (a link, or a copy where links are not supported)
link_enabled() {
  local type="$1" container="$2"
  mkdir -p "${VDM_REPO_PATH}/${type}/enabled"
  ln -s "${VDM_REPO_PATH}/${type}/available/${container}" "${VDM_REPO_PATH}/${type}/enabled/${container}"
}

###############################################################################
# running the whole script

# run_octojoom [options...]: run src/octojoom as a user would, inside the sandbox
# (the home path comes from OCTOJOOM_HOME, stdin is closed)
run_octojoom() {
  run env OCTOJOOM_HOME="${OCTOJOOM_HOME}" TERM=dumb bash "${OCTOJOOM_SCRIPT}" "$@" </dev/null
}
