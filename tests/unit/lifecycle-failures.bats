#!/usr/bin/env bats
# Failure-path regressions: Docker errors must retain recovery configuration,
# and setup/permission/clone failures must not be reported as completion.
# shellcheck disable=SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE='joomla'
  unset VDM_CONTAINER VDM_PUID VDM_PGID
}

make_type_container() {
  local type="$1"
  local dir="${VDM_REPO_PATH}/${type}/available/abc.vdm.dev"
  mkdir -p "${dir}"
  printf 'services:\n  application:\n    container_name: appabc\n' >"${dir}/docker-compose.yml"
  echo 'TEST_VALUE="required"' >"${VDM_REPO_PATH}/${type}/.env"
}

make_single_container() {
  mkdir -p "${VDM_REPO_PATH}/$1"
  printf 'services:\n  %s:\n    container_name: %s\n' "$1" "$1" >"${VDM_REPO_PATH}/$1/docker-compose.yml"
  echo 'TEST_VALUE="required"' >"${VDM_REPO_PATH}/$1/.env"
}

@test "enable failures: Joomla and OpenSSH return the Docker status with one env-aware attempt" {
  local type
  fail_command docker-compose-up 7
  for type in joomla openssh; do
    make_type_container "${type}"
    VDM_CONTAINER_TYPE="${type}"
    VDM_CONTAINER='abc.vdm.dev'
    : >"${STUB_DIR}/commands.log"
    run "${type}__TRuST__enable"
    assert_status 7
    assert_equal "$(grep -c '^docker compose ' "${STUB_DIR}/commands.log")" 1
    assert_command "^docker compose --env-file ${VDM_REPO_PATH}/${type}/.env "
    refute_command '^docker compose --file '
    assert_dialog 'Docker Compose failed'
  done
}

@test "disable failures: Joomla and OpenSSH retain enabled links and running containers" {
  local type
  fail_command docker-compose-down 9
  for type in joomla openssh; do
    make_type_container "${type}"
    link_enabled "${type}" abc.vdm.dev
    running_containers appabc
    VDM_CONTAINER_TYPE="${type}"
    VDM_CONTAINER='abc.vdm.dev'
    : >"${STUB_DIR}/commands.log"
    run "${type}__TRuST__disable"
    assert_status 9
    [ -d "${VDM_REPO_PATH}/${type}/enabled/abc.vdm.dev" ]
    assert_file_exists "${VDM_REPO_PATH}/${type}/available/abc.vdm.dev/docker-compose.yml"
    assert_equal "$(cat "${STUB_DIR}/docker/running")" appabc
    assert_equal "$(grep -c '^docker compose ' "${STUB_DIR}/commands.log")" 1
  done
}

@test "delete failures: Joomla and OpenSSH preserve links and Compose files after failed shutdown" {
  local type
  fail_command docker-compose-down 9
  for type in joomla openssh; do
    make_type_container "${type}"
    link_enabled "${type}" abc.vdm.dev
    VDM_CONTAINER_TYPE="${type}"
    answers '"abc.vdm.dev"' yes
    run "${type}__TRuST__delete"
    assert_status 9
    [ -d "${VDM_REPO_PATH}/${type}/enabled/abc.vdm.dev" ]
    assert_file_exists "${VDM_REPO_PATH}/${type}/available/abc.vdm.dev/docker-compose.yml"
    refute_dialog 'Delete Docker Compose Yaml'
  done
}

@test "single-container failures: Traefik and Portainer never retry Compose without the selected env" {
  local type action
  fail_command docker-compose-up 8
  fail_command docker-compose-down 8
  for type in traefik portainer; do
    make_single_container "${type}"
    VDM_CONTAINER_TYPE="${type}"
    for action in enable disable delete; do
      : >"${STUB_DIR}/commands.log"
      run "${type}__TRuST__${action}"
      assert_status 8
      assert_equal "$(grep -c '^docker compose ' "${STUB_DIR}/commands.log")" 1
      assert_command "^docker compose --env-file ${VDM_REPO_PATH}/${type}/.env "
      refute_command '^docker compose --file '
      assert_file_exists "${VDM_REPO_PATH}/${type}/docker-compose.yml"
    done
  done
}

@test "bulk up and down failures: stop on the first failed Compose operation" {
  local type action
  fail_command docker-compose-up 6
  fail_command docker-compose-down 6
  for type in joomla openssh; do
    make_type_container "${type}"
    link_enabled "${type}" abc.vdm.dev
    VDM_CONTAINER_TYPE="${type}"
    for action in up down; do
      : >"${STUB_DIR}/commands.log"
      answers yes
      run "${type}__TRuST__${action}"
      assert_status 6
      assert_equal "$(grep -c '^docker compose ' "${STUB_DIR}/commands.log")" 1
      [ -d "${VDM_REPO_PATH}/${type}/enabled/abc.vdm.dev" ]
    done
  done
}

@test "Compose save failure: an existing configuration survives a generator error" {
  local file="${VDM_REPO_PATH}/joomla/available/site.vdm.dev/docker-compose.yml"
  mkdir -p "${file%/*}"
  printf 'previous configuration\n' >"${file}"
  fail_generator() { printf 'partial replacement\n'; return 4; }
  run saveContainerCompose fail_generator "${file}"
  assert_failure
  assert_equal "$(cat "${file}")" 'previous configuration'
  assert_equal "$(find "${file%/*}" -type f | wc -l | tr -d ' ')" 1
}

@test "setup: Traefik and Portainer surface immediate deployment failures" {
  local type
  fail_command docker-compose-up 7
  for type in traefik portainer; do
    VDM_CONTAINER_TYPE="${type}"
    unset VDM_SUBDOMAIN
    if [ "${type}" = portainer ]; then
      answers port yes
    else
      answers yes
    fi
    run "${type}__TRuST__setup"
    assert_status 7
    assert_file_exists "${VDM_REPO_PATH}/${type}/docker-compose.yml"
    assert_answers_used
  done
}

@test "setup: network creation failure stops before collecting container details" {
  fail_command docker-network-create 5
  run setupContainer joomla
  assert_failure
  refute_dialog 'Enter Key'
  refute_file_exists "${VDM_REPO_PATH}/joomla/available"
}

@test "permission repair: sudo authentication failure stops before changing owners" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  fail_command sudo-v 12
  answers '"abc"' yes
  run fixContainersPermissions
  assert_status 12
  refute_command '^sudo(-skipped)? chown '
  refute_dialog 'Permissions update completed'
}

@test "permission repair: failed background ownership changes are returned before later stages" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  VDM_PUID=1000
  VDM_PGID=1000
  hook_command sudo <<'EOF'
if [ "$1" = chown ]; then exit 13; fi
exit 0
EOF
  # The progress UI deliberately returns immediately, as a cancelled gauge can.
  showProgress() { return 0; }
  answers '"abc"' yes no no
  run fixContainersPermissions
  assert_status 13
  refute_command '^sudo find '
  refute_dialog 'Permissions update completed'
  refute_file_exists "${VDM_SRC_PATH}/.progress"
}

@test "permission repair: failed chmod stops subsequent file and database changes" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  hook_command sudo <<'EOF'
if [ "$1" = find ]; then exit 14; fi
exit 0
EOF
  showProgress() { return 0; }
  answers '"abc"' yes 1000 1000
  run fixContainersPermissions
  assert_status 14
  refute_command '^sudo chown -R 999:999 '
  refute_dialog 'Permissions update completed'
}

@test "clone wrapper: a failed clone operation remains a failure after clearing globals" {
  make_joomla_container abc ABC abc
  VDM_KEY='newkey'
  cloneJoomlaContainer() { return 15; }
  run joomla__TRuST__clone
  assert_status 15
}

@test "persistent deletion: a running database prevents removing its project files" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  running_containers mariadbabc
  answers '"abc"' yes
  run deletePersistentVolumes
  assert_failure
  [ -d "${VDM_PROJECT_PATH}/abc/db" ]
  refute_command '^sudo rm '
}

@test "persistent reset: a running database prevents resetting either filesystem mount" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  running_containers mariadbabc
  answers '"abc"' yes yes
  run resetPersistentJoomlaVolumes
  assert_failure
  [ -d "${VDM_PROJECT_PATH}/abc/joomla" ]
  [ -d "${VDM_PROJECT_PATH}/abc/db" ]
  refute_command '^sudo rm '
}

@test "persistent reset: removal failure stops before the next filesystem mount" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  hook_command sudo <<'EOF'
if [ "$1" = rm ]; then exit 16; fi
exit 0
EOF
  answers '"abc"' yes yes
  run resetPersistentJoomlaVolumes
  assert_status 16
  [ -d "${VDM_PROJECT_PATH}/abc/db" ]
  assert_equal "$(grep -c '^sudo rm ' "${STUB_DIR}/commands.log")" 1
}

@test "persistent clone: a failed copy removes only its newly created destination" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla"
  hook_command sudo <<'EOF'
if [ "$1" = cp ]; then exit 17; fi
exec "$@"
EOF
  answers abc abccopy
  run clonePersistentVolume
  assert_status 17
  [ -d "${VDM_PROJECT_PATH}/abc/joomla" ]
  refute_file_exists "${VDM_PROJECT_PATH}/abccopy"
}

@test "persistent clone: an escaped destination is refused before creating a folder" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla"
  answers abc ../escape abccopy
  run clonePersistentVolume
  assert_success
  refute_file_exists "${VDM_PROJECT_PATH}/../escape"
  [ -d "${VDM_PROJECT_PATH}/abccopy/joomla" ]
}

@test "persistent deletion: Docker inspection failure preserves the project" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  fail_command docker-ps 18
  answers '"abc"' yes
  run deletePersistentVolumes
  assert_failure
  [ -d "${VDM_PROJECT_PATH}/abc/db" ]
  refute_command '^sudo rm '
}

@test "preset containers: escaping identifiers are refused before Docker or filesystem changes" {
  local type action
  for type in joomla openssh; do
    make_type_container "${type}"
    link_enabled "${type}" abc.vdm.dev
    mkdir -p "${VDM_REPO_PATH}/${type}/escape"
    echo 'keep' >"${VDM_REPO_PATH}/${type}/escape/marker"
    for action in enable disable; do
      VDM_CONTAINER_TYPE="${type}"
      VDM_CONTAINER='../escape'
      run "${type}__TRuST__${action}"
      assert_failure
      assert_file_contains "${VDM_REPO_PATH}/${type}/escape/marker" keep
    done
  done
  refute_command '^docker compose '
}

@test "persistent deletion: detects running containers when the bind folder differs from the key" {
  make_joomla_container abc ABC abc
  local yml="${VDM_REPO_PATH}/joomla/available/abc.vdm.dev/docker-compose.yml"
  sed 's|/abc/|/storage/|g' "${yml}" >"${yml}.next"
  mv "${yml}.next" "${yml}"
  mkdir -p "${VDM_PROJECT_PATH}/storage/joomla" "${VDM_PROJECT_PATH}/storage/db"
  running_containers mariadbabc
  answers '"storage"' yes
  run deletePersistentVolumes
  assert_failure
  [ -d "${VDM_PROJECT_PATH}/storage/db" ]
  refute_command '^sudo rm '
}
