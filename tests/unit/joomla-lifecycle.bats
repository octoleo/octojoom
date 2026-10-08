#!/usr/bin/env bats
#
# The life of a Joomla container: edit, enable, disable, up, down, delete and
# reset, the persistent volume tasks (delete, reset, clone, fix permissions),
# the empty states of the clone task and one menu wrapper dispatch.
#
# The full container clone (cloneJoomlaContainer) is covered by tests/test-clone-flow.sh.

# SC2034: the VDM_* values are read by the loaded script functions.
# SC2317: the replacement functions are called by the script functions.
# shellcheck disable=SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  VDM_CONTAINER_TYPE='joomla'
  unset VDM_CONTAINER VDM_PUID VDM_PGID
}

# the enabled folder of a container
enabled() {
  echo "${VDM_REPO_PATH}/joomla/enabled/$1"
}

# the docker stand-in reports this container as running, or not
assert_running() {
  grep -qxF "$1" "${STUB_DIR}/docker/running" 2>/dev/null
}

refute_running() {
  ! grep -qxF "$1" "${STUB_DIR}/docker/running" 2>/dev/null
}

###############################################################################
# joomla__TRuST__edit

@test "joomla edit: opens the selected docker-compose.yml in the editor" {
  make_joomla_container abc ABC abc
  answers abc.vdm.dev
  run joomla__TRuST__edit
  assert_success
  assert_command '^editor .*/available/abc\.vdm\.dev/docker-compose\.yml$'
  refute_command '^docker compose'
}

@test "joomla edit: an enabled container is re-deployed when asked" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  answers abc.vdm.dev yes
  run joomla__TRuST__edit
  assert_success
  assert_command '^docker compose .*abc\.vdm\.dev/docker-compose\.yml up -d'
  assert_running joomlaabc
}

@test "joomla edit: nothing is opened when no container is selected" {
  make_joomla_container abc ABC abc
  answers '<cancel>'
  run joomla__TRuST__edit
  assert_success
  refute_command '^editor '
}

###############################################################################
# joomla__TRuST__enable

@test "joomla enable: a given container is enabled and started" {
  make_joomla_container abc ABC abc
  VDM_CONTAINER=abc.vdm.dev
  joomla__TRuST__enable
  [ -d "$(enabled abc.vdm.dev)" ]
  assert_command '^docker compose .*enabled/abc\.vdm\.dev/docker-compose\.yml up -d'
  assert_running joomlaabc
  # cleared after use
  [ -z "${VDM_CONTAINER:-}" ]
}

@test "joomla enable: only the selected containers are enabled and started" {
  make_joomla_container abc ABC abc
  make_joomla_container xyz XYZ xyz
  answers '"abc.vdm.dev"'
  run joomla__TRuST__enable
  assert_success
  assert_answers_used
  [ -d "$(enabled abc.vdm.dev)" ]
  [ ! -e "$(enabled xyz.vdm.dev)" ]
  assert_running joomlaabc
  refute_running joomlaxyz
}

@test "joomla enable: an unknown container is refused and nothing is started" {
  make_joomla_container abc ABC abc
  VDM_CONTAINER=nope.vdm.dev
  run joomla__TRuST__enable
  assert_failure
  [ ! -e "$(enabled nope.vdm.dev)" ]
  refute_command '^docker '
}

###############################################################################
# joomla__TRuST__disable

@test "joomla disable: a given container is taken down and unlinked, it stays available" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  running_containers mariadbabc joomlaabc phpmyadminabc
  VDM_CONTAINER=abc.vdm.dev
  run joomla__TRuST__disable
  assert_success
  assert_command '^docker compose .*abc\.vdm\.dev/docker-compose\.yml down'
  refute_running joomlaabc
  [ ! -e "$(enabled abc.vdm.dev)" ]
  assert_file_exists "${VDM_REPO_PATH}/joomla/available/abc.vdm.dev/docker-compose.yml"
}

@test "joomla disable: nothing selected, nothing changes" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  answers ''
  run joomla__TRuST__disable
  assert_success
  [ -d "$(enabled abc.vdm.dev)" ]
  refute_command '^docker '
}

###############################################################################
# joomla__TRuST__up / joomla__TRuST__down

@test "joomla up: starts every enabled container and no other" {
  make_joomla_container abc ABC abc
  make_joomla_container xyz XYZ xyz
  link_enabled joomla abc.vdm.dev
  run joomla__TRuST__up
  assert_success
  assert_running joomlaabc
  refute_running joomlaxyz
}

@test "joomla down: confirmed, every enabled container is taken down and stays enabled" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  running_containers mariadbabc joomlaabc phpmyadminabc
  answers yes
  run joomla__TRuST__down
  assert_success
  refute_running joomlaabc
  [ -d "$(enabled abc.vdm.dev)" ]
}

@test "joomla down: declined, nothing is taken down" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  running_containers joomlaabc
  answers no
  run joomla__TRuST__down
  assert_failure
  assert_running joomlaabc
  refute_command '^docker '
}

###############################################################################
# joomla__TRuST__delete / deletePersistentVolumes

@test "joomla delete: the container is taken down, unlinked and its folder removed, the project stays" {
  make_joomla_container abc ABC abc
  link_enabled joomla abc.vdm.dev
  running_containers mariadbabc joomlaabc phpmyadminabc
  answers '"abc.vdm.dev"' yes no
  run joomla__TRuST__delete
  assert_success
  assert_answers_used
  refute_running joomlaabc
  [ ! -e "$(enabled abc.vdm.dev)" ]
  refute_file_exists "${VDM_REPO_PATH}/joomla/available/abc.vdm.dev"
  [ -d "${VDM_PROJECT_PATH}/abc/joomla" ]
}

@test "joomla delete: the folder is kept when its removal is declined" {
  make_joomla_container abc ABC abc
  answers '"abc.vdm.dev"' no no
  run joomla__TRuST__delete
  assert_success
  assert_file_exists "${VDM_REPO_PATH}/joomla/available/abc.vdm.dev/docker-compose.yml"
}

@test "deletePersistentVolumes: removes only the confirmed volumes" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/xyz/db" "${VDM_PROJECT_PATH}/qrs/db"
  answers '"abc" "xyz"' yes no
  run deletePersistentVolumes
  assert_success
  assert_answers_used
  refute_file_exists "${VDM_PROJECT_PATH}/abc"
  [ -d "${VDM_PROJECT_PATH}/xyz/db" ]
  [ -d "${VDM_PROJECT_PATH}/qrs/db" ]
}

@test "deletePersistentVolumes: nothing selected, nothing removed" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla"
  answers ''
  run deletePersistentVolumes
  assert_success
  [ -d "${VDM_PROJECT_PATH}/abc/joomla" ]
  refute_command '^sudo '
}

###############################################################################
# joomla__TRuST__reset / resetPersistentJoomlaVolumes

@test "joomla reset: confirmed, the joomla and db volumes are removed, the project folder stays" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  echo x >"${VDM_PROJECT_PATH}/abc/joomla/index.php"
  answers yes '"abc"' yes yes
  run joomla__TRuST__reset
  assert_success
  assert_answers_used
  refute_file_exists "${VDM_PROJECT_PATH}/abc/joomla"
  refute_file_exists "${VDM_PROJECT_PATH}/abc/db"
  [ -d "${VDM_PROJECT_PATH}/abc" ]
}

@test "joomla reset: declined, the volumes stay" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  answers no
  run joomla__TRuST__reset
  assert_success
  [ -d "${VDM_PROJECT_PATH}/abc/joomla" ]
  [ -d "${VDM_PROJECT_PATH}/abc/db" ]
}

###############################################################################
# fixContainersPermissions

# a Joomla project folder with some files in the wrong modes
make_fix_project() {
  local p="${VDM_PROJECT_PATH}/$1"
  mkdir -p "${p}/joomla/images" "${p}/joomla/.git" "${p}/db/mysql"
  echo '<?php' >"${p}/joomla/index.php"
  echo '<?php class JConfig {}' >"${p}/joomla/configuration.php"
  echo 'data' >"${p}/db/mysql/ibdata1"
  chmod 600 "${p}/joomla/index.php"
  chmod 700 "${p}/joomla/images"
}

@test "fixContainersPermissions: sets the owners and modes of the selected project" {
  make_fix_project abc
  local p="${VDM_PROJECT_PATH}/abc"
  showProgress() { while inProgress; do sleep 0.05; done; }
  answers '"abc"' yes 4242 4343
  run fixContainersPermissions
  assert_success
  assert_answers_used
  # chown needs root: the sudo stand-in skips it, but it must have been asked for
  assert_command "^sudo-skipped chown -R 4242:4343 .*/abc/joomla$"
  assert_command "^sudo-skipped chown -R 999:999 .*/abc/db$"
  assert_command '^sudo find .*/abc/joomla -type f -exec chmod 644'
  assert_command '^sudo find .*/abc/db -type d -exec chmod 700'
  assert_file_contains "${p}/joomla/.git/.htaccess" "Require all denied"
}

@test "fixContainersPermissions: the files and folders get the Joomla modes" {
  skip_on_windows "file modes are not real on Windows"
  make_fix_project abc
  local p="${VDM_PROJECT_PATH}/abc"
  showProgress() { while inProgress; do sleep 0.05; done; }
  answers '"abc"' yes 4242 4343
  run fixContainersPermissions
  assert_success
  assert_equal "$(file_mode "${p}/joomla/index.php")" 644
  assert_equal "$(file_mode "${p}/joomla/configuration.php")" 444
  assert_equal "$(file_mode "${p}/joomla/images")" 755
  assert_equal "$(file_mode "${p}/db/mysql/ibdata1")" 660
  assert_equal "$(file_mode "${p}/db/mysql")" 700
}

@test "fixContainersPermissions: nothing happens without sudo consent" {
  make_fix_project abc
  answers '"abc"' no
  run fixContainersPermissions
  assert_success
  refute_command '^sudo'
}

###############################################################################
# joomla__TRuST__clonefiles / clonePersistentVolume / joomla__TRuST__clone

@test "joomla clonefiles: copies the selected project folder, hidden files included" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla" "${VDM_PROJECT_PATH}/abc/db"
  echo '<?php' >"${VDM_PROJECT_PATH}/abc/joomla/index.php"
  echo 'deny' >"${VDM_PROJECT_PATH}/abc/joomla/.htaccess"
  answers yes abc abccopy
  run joomla__TRuST__clonefiles
  assert_success
  assert_answers_used
  assert_file_contains "${VDM_PROJECT_PATH}/abccopy/joomla/index.php" '<?php'
  assert_file_contains "${VDM_PROJECT_PATH}/abccopy/joomla/.htaccess" 'deny'
  [ -d "${VDM_PROJECT_PATH}/abccopy/db" ]
  assert_file_exists "${VDM_PROJECT_PATH}/abc/joomla/index.php"
}

@test "clonePersistentVolume: a running database is not copied unless confirmed" {
  mkdir -p "${VDM_PROJECT_PATH}/abc/joomla"
  running_containers mariadbabc
  answers abc no
  run clonePersistentVolume
  assert_success
  assert_equal "$(ls "${VDM_PROJECT_PATH}")" "abc"
  refute_command '^sudo cp'
}

@test "joomla clone: without containers or project folders the clone is not started" {
  cloneJoomlaContainer() { echo called >>"${STUB_DIR}/clone.log"; }
  run joomla__TRuST__clone
  assert_failure
  mkdir -p "${VDM_REPO_PATH}/joomla/available/abc.vdm.dev"
  run joomla__TRuST__clone
  assert_failure
  refute_file_exists "${STUB_DIR}/clone.log"
}

###############################################################################
# the menu wrappers

@test "editContainer: dispatches to the task of the given type" {
  joomla__TRuST__edit() { echo "joomla edit ran"; }
  run editContainer joomla
  assert_success
  assert_output_contains "joomla edit ran"
}
