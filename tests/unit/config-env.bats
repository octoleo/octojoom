#!/usr/bin/env bats
#
# The global config (.env in VDM_SRC_PATH), the container .env files and the
# small helpers around them: expert mode, editing the config, version checks,
# YAML lines, the bash version check, privileges and quitting.

# SC2034: the VDM_* and OS_NUMBER globals are read by the loaded script functions.
# SC2030/SC2031: bats runs each test in a subshell, so changing a global in one is intended.
# SC2016: adversarial dollar/substitution strings must remain literal test data.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
}

ENV_FILE() { echo "${VDM_SRC_PATH}/.env"; }

###############################################################################
# setEnvVariable

@test "setEnvVariable: appends a new key and keeps the other lines" {
  octojoom_config
  run setEnvVariable 'VDM_NEW_KEY="one"'
  assert_success
  assert_file_contains "$(ENV_FILE)" 'VDM_NEW_KEY="one"'
  assert_file_contains "$(ENV_FILE)" 'VDM_DOMAIN="vdm.dev"'
}

@test "setEnvVariable: never overwrites a key that is already set" {
  octojoom_config 'VDM_NEW_KEY="one"'
  run setEnvVariable 'VDM_NEW_KEY="two"'
  assert_success
  assert_file_contains "$(ENV_FILE)" 'VDM_NEW_KEY="one"'
  refute_file_contains "$(ENV_FILE)" 'VDM_NEW_KEY="two"'
}

@test "setEnvVariable: formatted export assignments remain one exact key" {
  printf '%s\n' ' export VDM_KEEP = "old"' > "$(ENV_FILE)"
  run setEnvVariable 'VDM_KEEP="new"'
  assert_success
  loadEnvFile "$(ENV_FILE)"
  assert_equal "$VDM_KEEP" old
  assert_equal "$(wc -l < "$(ENV_FILE)" | tr -d ' ')" 1
  setUniqueEnvVariable 'VDM_KEEP="replacement"'
  loadEnvFile "$(ENV_FILE)"
  assert_equal "$VDM_KEEP" replacement
  assert_equal "$(wc -l < "$(ENV_FILE)" | tr -d ' ')" 1
}

@test "setEnvVariable: creates a missing .env with mode 600 after a yes" {
  skip_on_windows "file modes are not real on Windows"
  rm -rf "${VDM_SRC_PATH}"
  answers yes
  run setEnvVariable 'VDM_FIRST="1"'
  assert_success
  assert_file_contains "$(ENV_FILE)" 'VDM_FIRST="1"'
  assert_equal "$(file_mode "$(ENV_FILE)")" 600
}

@test "setEnvVariable: returns 12 and creates nothing after a no" {
  rm -f "$(ENV_FILE)"
  answers no
  run setEnvVariable 'VDM_FIRST="1"'
  assert_status 12
  refute_file_exists "$(ENV_FILE)"
}

@test "setEnvVariable: rejects malformed keys and multiline values without changing config" {
  octojoom_config
  local before assignment
  before=$(cat "$(ENV_FILE)")
  for assignment in 'VDM_BAD.KEY="value"' 'PATH="bad"' 'VDM_NO_EQUALS' $'VDM_SECRET="one\ntwo"'; do
    run setEnvVariable "$assignment"
    assert_status 12
    assert_equal "$(cat "$(ENV_FILE)")" "$before"
  done
}

@test "setEnvVariable: failed permission changes are not reported as successful writes" {
  octojoom_config
  chmod() { return 1; }
  run setEnvVariable 'VDM_SECRET="do-not-disclose"'
  assert_status 12
  refute_file_contains "$(ENV_FILE)" VDM_SECRET
  refute_dialog do-not-disclose
}

@test "formatEnvAssignment and loadEnvFile: special characters round trip as literal data" {
  octojoom_config
  local secret
  printf -v secret 'cost$HOME "double" '\''single'\'' \\path\\ `touch %s` $(touch %s) # literal' "${SANDBOX}/backtick-executed" "${SANDBOX}/substitution-executed"
  run setEnvVariable "VDM_LITERAL=\"${secret}\""
  assert_success
  loadEnvFile "$(ENV_FILE)"
  assert_equal "$VDM_LITERAL" "$secret"
  refute_file_exists "${SANDBOX}/backtick-executed"
  refute_file_exists "${SANDBOX}/substitution-executed"
}

@test "loadEnvFile: legacy values and comments load without executing shell text" {
  printf ' # comment\r\nexport VDM_ONE="legacy value" # inline\r\nVDM_TWO=word # inline\r\nVDM_THREE=\x27literal$HOME\x27' > "$(ENV_FILE)"
  loadEnvFile "$(ENV_FILE)"
  assert_equal "$VDM_ONE" 'legacy value'
  assert_equal "$VDM_TWO" word
  assert_equal "$VDM_THREE" 'literal$HOME'
}

@test "decodeEnvValue: preserves escaped quoted values and rejects trailing shell syntax" {
  local decoded
  decodeEnvValue '"one\\two\"three\$four" # comment' decoded
  assert_equal "$decoded" 'one\two"three$four'
  decodeEnvValue "'Let\'s go'" decoded
  assert_equal "$decoded" "Let's go"
  run decodeEnvValue '"value"; echo unexpected' decoded
  assert_status 12
}

@test "loadEnvFile: invalid assignments and boolean commands apply no partial state" {
  VDM_REPO_PATH='unchanged'
  printf '%s\n' 'VDM_REPO_PATH="changed"' 'touch should-not-run' > "$(ENV_FILE)"
  run loadEnvFile "$(ENV_FILE)"
  assert_status 12
  if loadEnvFile "$(ENV_FILE)"; then
    echo 'expected malformed configuration to fail' >&2
    return 1
  fi
  assert_equal "$VDM_REPO_PATH" unchanged
  printf '%s\n' 'VDM_REPO_PATH="changed"' 'VDM_SECURE="touch should-not-run"' > "$(ENV_FILE)"
  # Calling directly is necessary to detect a partial change to caller globals.
  if loadEnvFile "$(ENV_FILE)"; then
    echo 'expected invalid configuration to fail' >&2
    return 1
  fi
  assert_equal "$VDM_REPO_PATH" unchanged
}

@test "literal configuration: real Compose keeps secret dollars, quotes and backslashes" {
  [ -n "${REAL_DOCKER:-}" ] || skip "Docker Compose is not installed"
  command -v jq >/dev/null 2>&1 || skip "jq is not installed"
  octojoom_config
  local secret compose_file rendered environment_value
  printf -v secret 'cost$HOME "double" '\''single'\'' \\path\\ `id` $(id) # literal'
  setEnvVariable "VDM_LITERAL=\"${secret}\""
  compose_file="${SANDBOX}/literal-compose.yml"
  cat > "$compose_file" <<'EOF'
services:
  check:
    image: busybox:latest
    environment:
      LITERAL: ${VDM_LITERAL}
EOF
  run docker compose --env-file "$(ENV_FILE)" --file "$compose_file" config --format json
  assert_success
  rendered=$(printf '%s' "$output" | jq -r '.services.check.environment.LITERAL')
  # config renders reusable Compose data and escapes literal dollars as $$.
  rendered="${rendered//\$\$/\$}"
  assert_equal "$rendered" "$secret"
  # Also check the actual dotenv value prior to that output serialization.
  # Filter before capture: unrelated host environment values never enter logs.
  environment_value=$(docker compose --env-file "$(ENV_FILE)" --file "$compose_file" config --environment | sed -n 's/^VDM_LITERAL=//p')
  assert_equal "$environment_value" "$secret"
}

###############################################################################
# deleteEnvVariable, setUniqueEnvVariable

@test "deleteEnvVariable: removes the key and keeps keys that only start the same" {
  octojoom_config 'VDM_GONE="a"' 'VDM_GONE_NOT="b"'
  run deleteEnvVariable VDM_GONE
  assert_success
  refute_file_contains "$(ENV_FILE)" 'VDM_GONE="a"'
  assert_file_contains "$(ENV_FILE)" 'VDM_GONE_NOT="b"'
  assert_file_contains "$(ENV_FILE)" 'VDM_DOMAIN="vdm.dev"'
}

@test "setUniqueEnvVariable: replaces the value of an existing key" {
  octojoom_config 'VDM_REPLACE="old"'
  run setUniqueEnvVariable 'VDM_REPLACE="new"'
  assert_success
  assert_file_contains "$(ENV_FILE)" 'VDM_REPLACE="new"'
  refute_file_contains "$(ENV_FILE)" 'VDM_REPLACE="old"'
  assert_file_contains "$(ENV_FILE)" 'VDM_DOMAIN="vdm.dev"'
}

@test "setUniqueEnvVariable: a failed replacement preserves the previous value" {
  octojoom_config 'VDM_REPLACE="old"'
  mv() { return 1; }
  run setUniqueEnvVariable 'VDM_REPLACE="new"'
  assert_status 12
  assert_file_contains "$(ENV_FILE)" 'VDM_REPLACE="old"'
  refute_file_contains "$(ENV_FILE)" 'VDM_REPLACE="new"'
  [ -z "$(find "${VDM_SRC_PATH}" -name '.env.tmp.*' -print)" ]
}

###############################################################################
# setContainerEnvVariable, getContainerEnvFile

@test "setContainerEnvVariable: adds a line to the container type .env only once" {
  VDM_CONTAINER_TYPE=joomla
  mkdir -p "${VDM_REPO_PATH}/joomla"
  echo 'VDM_PROJECT_PATH="/x"' >"${VDM_REPO_PATH}/joomla/.env"
  run setContainerEnvVariable 'VDM_JCB_DB="jcb_db"'
  assert_success
  run setContainerEnvVariable 'VDM_JCB_DB="jcb_db"'
  assert_success
  assert_equal "$(grep -c '^VDM_JCB_DB=' "${VDM_REPO_PATH}/joomla/.env")" 1
  assert_file_contains "${VDM_REPO_PATH}/joomla/.env" 'VDM_PROJECT_PATH="/x"'
}

@test "setContainerEnvVariable: creates a missing container .env with mode 600 after a yes" {
  skip_on_windows "file modes are not real on Windows"
  VDM_CONTAINER_TYPE=openssh
  answers yes
  run setContainerEnvVariable 'VDM_PUBLIC_KEY_GLOBAL_DIR="/keys"'
  assert_success
  assert_file_contains "${VDM_REPO_PATH}/openssh/.env" 'VDM_PUBLIC_KEY_GLOBAL_DIR="/keys"'
  assert_equal "$(file_mode "${VDM_REPO_PATH}/openssh/.env")" 600
}

@test "setContainerEnvVariable: returns 12 and creates nothing after a no" {
  VDM_CONTAINER_TYPE=traefik
  answers no
  run setContainerEnvVariable 'VDM_SECURE_EMAIL="a@b.c"'
  assert_status 12
  refute_file_exists "${VDM_REPO_PATH}/traefik/.env"
}

@test "setContainerEnvVariable: compares exact keys rather than password regular expressions" {
  VDM_CONTAINER_TYPE=joomla
  mkdir -p "${VDM_REPO_PATH}/joomla"
  printf '%s\n' 'VDM_LONGER_PASS="old"' > "${VDM_REPO_PATH}/joomla/.env"
  run setContainerEnvVariable 'VDM_PASS="[brackets].*$value"'
  assert_success
  run setContainerEnvVariable 'VDM_PASS="different"'
  assert_success
  assert_equal "$(grep -c '^VDM_PASS=' "${VDM_REPO_PATH}/joomla/.env")" 1
  loadEnvFile "${VDM_REPO_PATH}/joomla/.env"
  assert_equal "$VDM_PASS" '[brackets].*$value'
}

@test "getContainerEnvFile: prefers the container's own .env over the type .env" {
  mkdir -p "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
  touch "${VDM_REPO_PATH}/joomla/.env" "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev/.env"
  run getContainerEnvFile joomla jcb.vdm.dev
  assert_success
  assert_equal "${output}" "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev/.env"
}

@test "getContainerEnvFile: falls back to the type .env, then to nothing" {
  mkdir -p "${VDM_REPO_PATH}/openssh"
  touch "${VDM_REPO_PATH}/openssh/.env"
  run getContainerEnvFile openssh missing.vdm.dev
  assert_equal "${output}" "${VDM_REPO_PATH}/openssh/.env"
  run getContainerEnvFile joomla jcb.vdm.dev
  assert_success
  assert_equal "${output}" ''
}

###############################################################################
# hasDirectories, isExpert, setMode

@test "hasDirectories: true only for a folder that holds something" {
  run hasDirectories joomla/available/
  assert_failure
  mkdir -p "${VDM_REPO_PATH}/joomla/available"
  run hasDirectories joomla/available/
  assert_failure
  mkdir -p "${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev"
  run hasDirectories joomla/available/
  assert_success
}

@test "hasDirectories: files do not count, hidden directories and linked folders do" {
  mkdir -p "${VDM_REPO_PATH}/joomla/available"
  touch "${VDM_REPO_PATH}/joomla/available/config.txt"
  run hasDirectories joomla/available
  assert_failure
  mkdir -p "${VDM_REPO_PATH}/joomla/available/.hidden"
  run hasDirectories joomla/available
  assert_success
  rm -rf "${VDM_REPO_PATH}/joomla/available/.hidden"
  mkdir -p "${VDM_REPO_PATH}/target"
  ln -s "${VDM_REPO_PATH}/target" "${VDM_REPO_PATH}/joomla/available/linked"
  run hasDirectories joomla/available
  assert_success
}

@test "setNetworks: a failed first network creation prevents dependent setup" {
  fail_command docker-network-create 9
  run setNetworks
  assert_status 9
  refute_command '^docker network create .*openssh_gateway$'
}

@test "ensurePortsFree: scan errors fail closed while no listeners exit status passes" {
  OS_NUMBER=1
  hook_command sudo <<'EOF'
if [ "$1" = lsof ]; then
  echo 'lsof: permission denied' >&2
  exit 1
fi
exit 0
EOF
  run ensurePortsFree
  assert_failure
  refute_command '^sudo systemctl'
  hook_command sudo <<'EOF'
[ "$1" != lsof ] || exit 1
exit 0
EOF
  run ensurePortsFree
  assert_success
}

@test "ensurePortsFree: Windows queries native netstat without requiring sudo or lsof" {
  OS_NUMBER=3
  run ensurePortsFree
  assert_success
  assert_command '^netstat.exe -ano -p TCP$'
  refute_command '^sudo lsof'
  hook_command netstat.exe <<'EOF'
printf '%s\r\n' 'Active Connections' '  Proto Local Address Foreign Address State PID' \
  '  TCP 0.0.0.0:80 0.0.0.0:0 LISTENING 1234' \
  '  TCP [::]:443 [::]:0 LISTENING 4321' \
  '  TCP 127.0.0.1:8080 0.0.0.0:0 LISTENING 9999'
EOF
  run ensurePortsFree
  assert_failure
  assert_dialog 'netstat:1234:0.0.0.0:80'
  assert_dialog 'netstat:4321:[::]:443'
  refute_dialog '9999'
}

@test "getPortListeners: a Windows netstat failure is reported rather than empty ports" {
  OS_NUMBER=3
  fail_command netstat.exe 2
  run getPortListeners
  assert_failure
}

@test "ensurePortsFree: unknown Linux listeners are not treated as an empty service" {
  OS_NUMBER=1
  hook_command sudo <<'EOF'
if [ "$1" = lsof ]; then
  printf '%s\n' 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME' 'other 123 root 1u IPv4 1 0t0 TCP *:80 (LISTEN)'
fi
EOF
  run ensurePortsFree
  assert_failure
  refute_command '^sudo systemctl'
  assert_dialog 'cannot be managed automatically'
}

@test "ensurePortsFree: a failed service stop does not disable it or report free ports" {
  OS_NUMBER=1
  hook_command sudo <<'EOF'
case "$1" in
  lsof)
    printf '%s\n' 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME' 'nginx 123 root 1u IPv4 1 0t0 TCP *:80 (LISTEN)'
    ;;
  systemctl)
    [ "$2" != stop ] || exit 7
    ;;
esac
exit 0
EOF
  answers yes
  run ensurePortsFree
  assert_failure
  assert_command '^sudo systemctl stop nginx$'
  refute_command '^sudo systemctl disable nginx$'
  refute_dialog 'All conflicting services were disabled'
}

@test "isExpert: true only when VDM_EXPERT_MODE is true" {
  VDM_EXPERT_MODE=true
  run isExpert
  assert_success
  VDM_EXPERT_MODE=false
  run isExpert
  assert_failure
}

@test "setMode: expert and basic store the mode in the global config" {
  octojoom_config
  setMode expert
  assert_equal "${VDM_EXPERT_MODE}" true
  assert_file_contains "$(ENV_FILE)" 'VDM_EXPERT_MODE=true'
  setMode basic
  assert_equal "${VDM_EXPERT_MODE}" false
  assert_file_contains "$(ENV_FILE)" 'VDM_EXPERT_MODE=false'
  refute_file_contains "$(ENV_FILE)" 'VDM_EXPERT_MODE=true'
}

@test "setMode: an unknown mode fails and changes nothing" {
  octojoom_config
  local before
  before="$(cat "$(ENV_FILE)")"
  run setMode guru
  assert_failure
  assert_equal "$(cat "$(ENV_FILE)")" "${before}"
}

###############################################################################
# openEnv, editConfigFile

@test "openEnv: opens the container .env in the editor after a yes" {
  mkdir -p "${VDM_REPO_PATH}/joomla"
  touch "${VDM_REPO_PATH}/joomla/.env"
  answers yes
  run openEnv joomla
  assert_success
  assert_command "^editor ${VDM_REPO_PATH}/joomla/.env$"
}

@test "openEnv: does not open the editor after a no" {
  mkdir -p "${VDM_REPO_PATH}/joomla"
  touch "${VDM_REPO_PATH}/joomla/.env"
  answers no
  run openEnv joomla
  refute_command '^editor '
}

@test "editConfigFile: opens the global .env in the editor after a yes" {
  octojoom_config
  answers yes
  run editConfigFile
  assert_success
  assert_command "^editor ${VDM_SRC_PATH}/.env$"
}

@test "editConfigFile: does nothing without a global .env" {
  rm -f "$(ENV_FILE)"
  answers
  run editConfigFile
  assert_success
  refute_command '^editor '
}

###############################################################################
# isVersionAbove, getYMLine1-3, check_bash_version

@test "isVersionAbove: compares major and minor versions of a tag" {
  isVersionAbove 4.3 4.3
  isVersionAbove 5.1-php8.2-fpm 4.3
  isVersionAbove latest 4.3
  run isVersionAbove 4.2 4.3
  assert_failure
  run isVersionAbove 3.10-php7.4-apache 4.3
  assert_failure
}

@test "isVersionAbove: numeric prefixes and latest variants are safe comparisons" {
  run isVersionAbove 5 4.3
  assert_success
  run isVersionAbove 04.03.2-php8.2-apache 4.3
  assert_success
  run isVersionAbove latest-php8.3-fpm 4.3
  assert_success
  run isVersionAbove unknown 4.3
  assert_failure
  run isVersionAbove 999999999999999999999 4.3
  assert_failure
}

@test "isVersionAbove: malicious arithmetic tags never execute substitutions" {
  local tag
  printf -v tag 'probe[$(touch %s)]' "${SANDBOX}/arithmetic-executed"
  run isVersionAbove "$tag" 4.3
  assert_failure
  refute_file_exists "${SANDBOX}/arithmetic-executed"
}

@test "getYMLine1-3: joined lines build nested YAML" {
  local yml="services:"
  yml+=$(getYMLine1 'web:')
  yml+=$(getYMLine2 'labels:')
  yml+=$(getYMLine3 '- "a=b"')
  assert_equal "${yml}" 'services:
  web:
    labels:
      - "a=b"'
}

@test "check_bash_version: passes on this bash and exits 1 when a newer one is needed" {
  run check_bash_version 4
  assert_success
  run check_bash_version $((BASH_VERSINFO[0] + 1))
  assert_status 1
}

###############################################################################
# runPrivileged, quitProgram

@test "runPrivileged: runs the command through sudo on Linux and macOS" {
  OS_NUMBER=1
  run runPrivileged mkdir -p "${SANDBOX}/privileged"
  assert_success
  assert_command "^sudo mkdir -p ${SANDBOX}/privileged$"
  [ -d "${SANDBOX}/privileged" ]
}

@test "runPrivileged: runs the command directly on Windows" {
  OS_NUMBER=3
  run runPrivileged mkdir -p "${SANDBOX}/direct"
  assert_success
  refute_command '^sudo '
  [ -d "${SANDBOX}/direct" ]
}

@test "quitProgram: exits with status 0" {
  run quitProgram
  assert_success
}
