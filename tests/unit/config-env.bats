#!/usr/bin/env bats
#
# The global config (.env in VDM_SRC_PATH), the container .env files and the
# small helpers around them: expert mode, editing the config, version checks,
# YAML lines, the bash version check, privileges and quitting.

# SC2034: the VDM_* and OS_NUMBER globals are read by the loaded script functions.
# SC2030/SC2031: bats runs each test in a subshell, so changing a global in one is intended.
# shellcheck disable=SC2030,SC2031,SC2034

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
