#!/usr/bin/env bats
#
# The Openssh container type: the compose file (opensshContainer), the setup
# (end to end and with CLI presets), and the edit, enable, disable, up, down,
# delete and migrate tasks.

# SC2016: the compose files hold ${...} references that must stay literal.
# SC2034: the VDM_* globals are read by the loaded script functions.
# shellcheck disable=SC2016,SC2034

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE='openssh'
  SSH_DIR="${VDM_REPO_PATH}/openssh/.ssh"
  OPENSSH_ENV="${VDM_REPO_PATH}/openssh/.env"
  ENABLED="${VDM_REPO_PATH}/openssh/enabled"
}

# the compose file of an available container
compose_of() {
  echo "${VDM_REPO_PATH}/openssh/available/$1/docker-compose.yml"
}

# create an available Openssh container the way setup does
# make_openssh_container <user> <key> <env key>
make_openssh_container() {
  local user="$1" key="$2" env="$3"
  local dir="${VDM_REPO_PATH}/openssh/available/${user}.vdm.dev"
  mkdir -p "${dir}" "${SSH_DIR}/${key}" "${VDM_PROJECT_PATH}/${key}"
  (
    VDM_KEY="${key}"
    VDM_USER_NAME="${user}"
    VDM_PUID=1000
    VDM_PGID=1000
    VDM_PORT=2239
    VDM_VOLUMES_MOUNT=$(getYMLine3 "- \${VDM_${env}_PUBLIC_KEY_DIR}:/config/ssh_public_keys")
    opensshContainer
  ) >"${dir}/docker-compose.yml"
  {
    echo "VDM_${env}_PROJECT_DIR=\"${VDM_PROJECT_PATH}\""
    echo "VDM_PUBLIC_KEY_GLOBAL_DIR=\"${SSH_DIR}\""
    echo "VDM_${env}_PUBLIC_KEY_DIR=\"${SSH_DIR}/${key}\""
  } >>"${OPENSSH_ENV}"
}

###############################################################################
# opensshContainer

@test "opensshContainer: writes the service with its user, port and keys volume" {
  VDM_KEY='team'
  VDM_PUID=1001
  VDM_PGID=1002
  VDM_PORT=2250
  VDM_USER_NAME='dev'
  VDM_VOLUMES_MOUNT=$(getYMLine3 '- ${VDM_TEAM_PUBLIC_KEY_DIR}:/config/ssh_public_keys')
  run opensshContainer
  assert_success
  assert_output_contains "container_name: openssh-server-team"
  assert_output_contains "- PUID=1001"
  assert_output_contains "- USER_NAME=dev"
  assert_output_contains "- 2250:2222"
  assert_output_contains '${VDM_TEAM_PUBLIC_KEY_DIR}:/config/ssh_public_keys'
}

@test "opensshContainer: falls back to default values when they are not set" {
  unset VDM_TZ VDM_SUDO_ACCESS VDM_USER_NAME VDM_OPENSSH_GATEWAY
  VDM_KEY='x'
  VDM_PORT=2239
  run opensshContainer
  assert_success
  assert_output_contains "- SUDO_ACCESS=false"
  assert_output_contains "- USER_NAME=ubuntu"
  assert_output_contains "name: openssh_gateway"
}

###############################################################################
# openssh__TRuST__setup

@test "openssh setup: writes the compose file and env values without enabling it" {
  mkdir -p "${VDM_PROJECT_PATH}/alpha" "${VDM_PROJECT_PATH}/beta"
  # port, user, user ID, group ID, key, env key, ssh path, create it, create key folder,
  # parent path, folders to mount, create the env file, enable now
  answers 2239 llewellyn 33 33 sshkey SSHKEY "${SSH_DIR}" yes yes \
    "${VDM_PROJECT_PATH}" '"alpha" "beta"' yes no
  run openssh__TRuST__setup
  assert_success
  assert_answers_used
  local yml
  yml=$(compose_of llewellyn.vdm.dev)
  assert_file_contains "${yml}" "container_name: openssh-server-sshkey"
  assert_file_contains "${yml}" "- USER_NAME=llewellyn"
  assert_file_contains "${yml}" "- 2239:2222"
  assert_file_contains "${yml}" '- ${VDM_SSHKEY_PROJECT_DIR}/alpha:/app/alpha'
  assert_file_contains "${yml}" '- ${VDM_SSHKEY_PROJECT_DIR}/beta:/app/beta'
  assert_file_contains "${OPENSSH_ENV}" "VDM_SSHKEY_PROJECT_DIR=\"${VDM_PROJECT_PATH}\""
  assert_file_contains "${OPENSSH_ENV}" "VDM_SSHKEY_PUBLIC_KEY_DIR=\"${SSH_DIR}/sshkey\""
  [ -d "${SSH_DIR}/sshkey" ]
  refute_file_exists "${ENABLED}/llewellyn.vdm.dev"
  refute_command '^docker compose'
}

@test "openssh setup: the compose and env files are private" {
  skip_on_windows "file modes are not real on Windows"
  mkdir -p "${VDM_PROJECT_PATH}/alpha"
  answers 2239 llewellyn 33 33 sshkey SSHKEY "${SSH_DIR}" yes yes \
    "${VDM_PROJECT_PATH}" '"alpha"' yes no
  run openssh__TRuST__setup
  assert_success
  assert_equal "$(file_mode "$(compose_of llewellyn.vdm.dev)")" 600
  assert_equal "$(file_mode "${OPENSSH_ENV}")" 600
}

@test "openssh setup: CLI presets are used in the compose file" {
  mkdir -p "${SSH_DIR}/dev" "${VDM_PROJECT_PATH}/alpha"
  VDM_USER_NAME='dev'
  VDM_PORT=2240
  VDM_PUBLIC_KEY_DIR="${SSH_DIR}"
  VDM_TZ='Europe/Berlin'
  VDM_SUDO_ACCESS=true
  VDM_PUID=1000
  VDM_PGID=1000
  # keep user and group ID, key, env key, key folder, parent path, mounts, create env, enable
  answers no no devkey DEVKEY dev "${VDM_PROJECT_PATH}" '"alpha"' yes no
  run openssh__TRuST__setup
  assert_success
  assert_answers_used
  local yml
  yml=$(compose_of dev.vdm.dev)
  assert_file_contains "${yml}" "- 2240:2222"
  assert_file_contains "${yml}" "- TZ=Europe/Berlin"
  assert_file_contains "${yml}" "- SUDO_ACCESS=true"
  assert_file_contains "${yml}" "- USER_NAME=dev"
  assert_file_contains "${OPENSSH_ENV}" "VDM_DEVKEY_PUBLIC_KEY_DIR=\"${SSH_DIR}/dev\""
}

@test "openssh setup: a user name already in use is refused" {
  mkdir -p "${VDM_REPO_PATH}/openssh/available/ubuntu.vdm.dev" "${SSH_DIR}/team" "${VDM_PROJECT_PATH}/alpha"
  {
    echo "VDM_TEAM_PROJECT_DIR=\"${VDM_PROJECT_PATH}\""
    echo "VDM_PUBLIC_KEY_GLOBAL_DIR=\"${SSH_DIR}\""
    echo "VDM_TEAM_PUBLIC_KEY_DIR=\"${SSH_DIR}/team\""
  } >"${OPENSSH_ENV}"
  answers 2239 ubuntu other 33 33 devkey TEAM '"alpha"' no
  run openssh__TRuST__setup
  assert_success
  assert_file_exists "$(compose_of other.vdm.dev)"
  refute_file_exists "$(compose_of ubuntu.vdm.dev)"
}

@test "openssh setup: enables and starts the container when asked" {
  mkdir -p "${VDM_PROJECT_PATH}/alpha"
  answers 2239 llewellyn 33 33 sshkey SSHKEY "${SSH_DIR}" yes yes \
    "${VDM_PROJECT_PATH}" '"alpha"' yes yes
  run openssh__TRuST__setup
  assert_success
  [ -d "${ENABLED}/llewellyn.vdm.dev" ]
  assert_command "--file ${ENABLED}/llewellyn.vdm.dev/docker-compose.yml up -d$"
}

@test "openssh setup: invalid ports and escaping usernames are refused before writing Compose" {
  mkdir -p "${SSH_DIR}/team" "${VDM_PROJECT_PATH}/alpha"
  mkdir -p "${VDM_REPO_PATH}/openssh"
  {
    echo "VDM_TEAM_PROJECT_DIR=\"${VDM_PROJECT_PATH}\""
    echo "VDM_PUBLIC_KEY_GLOBAL_DIR=\"${SSH_DIR}\""
    echo "VDM_TEAM_PUBLIC_KEY_DIR=\"${SSH_DIR}/team\""
  } >"${OPENSSH_ENV}"
  answers invalid 22 65536 2239 ../escape dev 33 33 devkey TEAM '"alpha"' no
  run openssh__TRuST__setup
  assert_success
  assert_answers_used
  assert_file_contains "$(compose_of dev.vdm.dev)" '- 2239:2222'
  refute_file_exists "${VDM_REPO_PATH}/openssh/escape.vdm.dev"
}

###############################################################################
# openssh__TRuST__edit

@test "openssh edit: opens the selected compose file in the editor" {
  make_openssh_container dev team TEAM
  answers dev.vdm.dev
  run openssh__TRuST__edit
  assert_success
  assert_command "^editor $(compose_of dev.vdm.dev)$"
}

###############################################################################
# openssh__TRuST__enable

@test "openssh enable: a preset container is enabled and started" {
  make_openssh_container dev team TEAM
  VDM_CONTAINER='dev.vdm.dev'
  run openssh__TRuST__enable
  assert_success
  [ -d "${ENABLED}/dev.vdm.dev" ]
  assert_command "^docker compose --env-file ${OPENSSH_ENV} --file ${ENABLED}/dev.vdm.dev/docker-compose.yml up -d$"
}

@test "openssh enable: enables only the selected containers" {
  make_openssh_container dev team TEAM
  make_openssh_container idle idle IDLE
  answers '"dev.vdm.dev"'
  run openssh__TRuST__enable
  assert_success
  [ -d "${ENABLED}/dev.vdm.dev" ]
  refute_file_exists "${ENABLED}/idle.vdm.dev"
  run isContainerRunning openssh-server-team
  assert_success
}

@test "openssh enable: selecting nothing changes nothing" {
  make_openssh_container dev team TEAM
  answers ''
  run openssh__TRuST__enable
  assert_success
  refute_file_exists "${ENABLED}/dev.vdm.dev"
  refute_command '^docker'
}

###############################################################################
# openssh__TRuST__disable

@test "openssh disable: a preset container is taken down and unlinked" {
  make_openssh_container dev team TEAM
  link_enabled openssh dev.vdm.dev
  running_containers openssh-server-team
  VDM_CONTAINER='dev.vdm.dev'
  run openssh__TRuST__disable
  assert_success
  refute_file_exists "${ENABLED}/dev.vdm.dev"
  assert_file_exists "$(compose_of dev.vdm.dev)"
  assert_command "--file ${ENABLED}/dev.vdm.dev/docker-compose.yml down"
  run isContainerRunning openssh-server-team
  assert_failure
}

@test "openssh disable: a preset container that is not enabled is left alone" {
  make_openssh_container dev team TEAM
  make_openssh_container ops ops OPS
  link_enabled openssh dev.vdm.dev
  VDM_CONTAINER='ops.vdm.dev'
  run openssh__TRuST__disable
  assert_success
  refute_command '^docker'
  [ -e "${ENABLED}/dev.vdm.dev" ]
}

###############################################################################
# openssh__TRuST__up

@test "openssh up: starts every enabled container and no other" {
  make_openssh_container dev team TEAM
  make_openssh_container ops ops OPS
  make_openssh_container idle idle IDLE
  link_enabled openssh dev.vdm.dev
  link_enabled openssh ops.vdm.dev
  run openssh__TRuST__up
  assert_success
  run isContainerRunning openssh-server-team
  assert_success
  run isContainerRunning openssh-server-ops
  assert_success
  run isContainerRunning openssh-server-idle
  assert_failure
}

@test "openssh up: without enabled containers nothing is started" {
  make_openssh_container dev team TEAM
  run openssh__TRuST__up
  assert_success
  refute_command '^docker'
}

###############################################################################
# openssh__TRuST__down

@test "openssh down: takes down every enabled container when confirmed" {
  make_openssh_container dev team TEAM
  make_openssh_container ops ops OPS
  link_enabled openssh dev.vdm.dev
  link_enabled openssh ops.vdm.dev
  running_containers openssh-server-team openssh-server-ops
  answers yes
  run openssh__TRuST__down
  assert_success
  run isContainerRunning openssh-server-team
  assert_failure
  run isContainerRunning openssh-server-ops
  assert_failure
  # still enabled
  [ -e "${ENABLED}/dev.vdm.dev" ]
}

@test "openssh down: nothing is taken down when not confirmed" {
  make_openssh_container dev team TEAM
  link_enabled openssh dev.vdm.dev
  running_containers openssh-server-team
  answers no
  run openssh__TRuST__down
  assert_failure
  refute_command '^docker compose'
  run isContainerRunning openssh-server-team
  assert_success
}

###############################################################################
# openssh__TRuST__delete

@test "openssh delete: an enabled container is taken down and its folder deleted" {
  make_openssh_container dev team TEAM
  link_enabled openssh dev.vdm.dev
  running_containers openssh-server-team
  answers '"dev.vdm.dev"' yes
  run openssh__TRuST__delete
  assert_success
  assert_answers_used
  refute_file_exists "${ENABLED}/dev.vdm.dev"
  refute_file_exists "${VDM_REPO_PATH}/openssh/available/dev.vdm.dev"
  run isContainerRunning openssh-server-team
  assert_failure
  # the key folder and project folder are not touched
  [ -d "${SSH_DIR}/team" ]
  [ -d "${VDM_PROJECT_PATH}/team" ]
}

@test "openssh delete: the folder is kept when its deletion is declined" {
  make_openssh_container dev team TEAM
  answers '"dev.vdm.dev"' no
  run openssh__TRuST__delete
  assert_success
  assert_file_exists "$(compose_of dev.vdm.dev)"
}

###############################################################################
# openssh__TRuST__migrate

@test "openssh migrate: declining the confirmation changes nothing" {
  make_openssh_container dev team TEAM
  answers dev.vdm.dev push remote1 no
  run openssh__TRuST__migrate
  assert_success
  refute_command '^(ssh|rsync)'
}
