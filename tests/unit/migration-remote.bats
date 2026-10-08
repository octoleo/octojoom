#!/usr/bin/env bats
#
# Migration to and from remote systems: finding the remote systems in the
# sandbox ~/.ssh/config, the migration type choice, the container and project
# directory migrate tasks, and the push and pull of a container folder.
# ssh and rsync are the stand-ins in tests/helpers/bin; remote_octojoom (below)
# makes ssh answer like a remote system with Octojoom installed.

# SC2034: the VDM_* globals are read by the loaded script functions.
# shellcheck disable=SC2034

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE='joomla'
  LOCAL_PATH="${VDM_REPO_PATH}/joomla/available/site.vdm.dev"
  REMOTE_PATH="/home/remote/Docker/joomla/available/site.vdm.dev"
}

# an ssh config with the given Host entries
ssh_config() {
  mkdir -p "${VDM_HOME_PATH}/.ssh"
  local host
  for host in "$@"; do
    printf 'Host %s\n  HostName %s.example.com\n\n' "${host}" "${host}"
  done >"${VDM_HOME_PATH}/.ssh/config"
}

# ssh answers like a remote with Octojoom installed; the remote container
# folder exists only when ${STUB_DIR}/remote_has_folder exists
remote_octojoom() {
  hook_command ssh <<'EOF'
case "${*: -1}" in
'grep "^VDM_REPO_PATH='*) echo 'VDM_REPO_PATH="/home/remote/Docker"' ;;
'grep "^VDM_PROJECT_PATH='*) echo 'VDM_PROJECT_PATH="/home/remote/Projects"' ;;
'[ -d '*) [ -f "${STUB_DIR}/remote_has_folder" ] ;;
esac
EOF
}

# an available Joomla container folder with a compose file
make_available() {
  mkdir -p "${VDM_REPO_PATH}/joomla/available/$1"
  echo "services: {}" >"${VDM_REPO_PATH}/joomla/available/$1/docker-compose.yml"
}

###############################################################################
# remote systems

@test "migration-remote: hasRemoteSystemSet succeeds with a Host entry in the ssh config" {
  ssh_config web
  run hasRemoteSystemSet
  assert_success
}

@test "migration-remote: hasRemoteSystemSet fails without an ssh config" {
  run hasRemoteSystemSet
  assert_failure
  assert_dialog "ssh/config"
}

@test "migration-remote: getRemoteSystem returns the host chosen from the ssh config" {
  ssh_config alpha web
  answers web
  run getRemoteSystem
  assert_success
  assert_equal "${output}" "web"
}

@test "migration-remote: getRemoteSystem asks for the host when 'Enter manually' is chosen" {
  ssh_config web
  answers "Enter manually" "backup.example.org"
  run getRemoteSystem
  assert_success
  assert_equal "${output}" "backup.example.org"
}

@test "migration-remote: getRemoteSystem asks for the host when there is no ssh config" {
  answers "deploy@10.0.0.9"
  run getRemoteSystem
  assert_success
  assert_equal "${output}" "deploy@10.0.0.9"
}

@test "migration-remote: getRemoteSystem returns none_selected when the list is cancelled" {
  ssh_config web
  answers "<cancel>"
  run getRemoteSystem
  assert_equal "${output}" "none_selected"
}

###############################################################################
# migration type

@test "migration-remote: getMigrationType returns the chosen type" {
  answers pull
  run getMigrationType
  assert_success
  assert_equal "${output}" "pull"
}

@test "migration-remote: getMigrationType falls back to push when the dialog is escaped" {
  answers "<esc>"
  run getMigrationType
  assert_equal "${output}" "push"
}

###############################################################################
# transfer check

@test "migration-remote: transferWasSuccessful passes when the rsync dry run lists no change" {
  run transferWasSuccessful "${LOCAL_PATH}" "${REMOTE_PATH}" web
  assert_success
  assert_command "^rsync .*--dry-run.* ${LOCAL_PATH}/ web:${REMOTE_PATH}/$"
}

@test "migration-remote: transferWasSuccessful fails when the rsync dry run lists changes" {
  hook_command rsync <<'EOF'
printf 'sending incremental file list\ndeleting stale.txt\n'
EOF
  run transferWasSuccessful "${LOCAL_PATH}" "${REMOTE_PATH}" web
  assert_failure
}

###############################################################################
# push and pull of a container folder

@test "migration-remote: pushContainerMigration syncs the container folder to the remote repo path" {
  remote_octojoom
  make_available site.vdm.dev
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command "^ssh web mkdir -p ${REMOTE_PATH}$"
  assert_command "^rsync -avz --delete ${LOCAL_PATH}/ web:${REMOTE_PATH}$"
  refute_command "rm -Irf"
  assert_dialog "success"
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
}

@test "migration-remote: pushContainerMigration backs up an existing remote container when asked" {
  remote_octojoom
  make_available site.vdm.dev
  touch "${STUB_DIR}/remote_has_folder"
  answers yes
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command "mv '${REMOTE_PATH}' '${REMOTE_PATH}_backup_[0-9]+'"
  assert_command "^rsync -avz --delete ${LOCAL_PATH}/ web:${REMOTE_PATH}$"
}

@test "migration-remote: pushContainerMigration reports a failed transfer" {
  remote_octojoom
  make_available site.vdm.dev
  # the check after the sync finds the remote copy incomplete
  hook_command rsync <<'EOF'
case " $* " in
*" --dry-run "*) printf 'sending incremental file list\ndeleting partial.tmp\n' ;;
esac
EOF
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  assert_dialog "failed"
  refute_dialog "success"
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
}

@test "migration-remote: pushContainerMigration is cancelled when the remote has no Octojoom" {
  fail_command ssh
  make_available site.vdm.dev
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  refute_command '^rsync'
}

@test "migration-remote: pullContainerMigration reads the remote repo path and copies nothing yet" {
  remote_octojoom
  run pullContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command '^ssh .*VDM_REPO_PATH'
  assert_dialog "PULL"
  refute_command '^(rsync|scp)'
}

###############################################################################
# migrate tasks

@test "migration-remote: joomla__TRuST__migrate pushes the selected container to the selected remote" {
  remote_octojoom
  ssh_config alpha web
  make_available other.vdm.dev
  make_available site.vdm.dev
  answers site.vdm.dev push web yes
  run joomla__TRuST__migrate
  assert_success
  assert_answers_used
  assert_command "^rsync -avz --delete ${LOCAL_PATH}/ web:${REMOTE_PATH}$"
  refute_command "other.vdm.dev"
}

@test "migration-remote: joomla__TRuST__migrate does nothing when the confirmation is declined" {
  remote_octojoom
  ssh_config web
  make_available site.vdm.dev
  answers site.vdm.dev push web no
  run joomla__TRuST__migrate
  assert_success
  refute_command '^(ssh|rsync|scp)'
}

@test "migration-remote: joomla__TRuST__migrate is cancelled when no remote is selected" {
  ssh_config web
  make_available site.vdm.dev
  answers site.vdm.dev push "<cancel>"
  run joomla__TRuST__migrate
  assert_success
  assert_dialog "cancelled"
  refute_command '^(ssh|rsync|scp)'
}

@test "migration-remote: directory__TRuST__migrate runs the pull for the selected project directory" {
  remote_octojoom
  ssh_config web
  mkdir -p "${VDM_PROJECT_PATH}/site1" "${VDM_PROJECT_PATH}/site2"
  answers site1 pull web yes
  run directory__TRuST__migrate
  assert_success
  assert_answers_used
  assert_command '^ssh .*VDM_PROJECT_PATH'
  assert_dialog "PULL"
  refute_command '^(rsync|scp)'
}

@test "migration-remote: directory__TRuST__migrate does nothing when the confirmation is declined" {
  ssh_config web
  mkdir -p "${VDM_PROJECT_PATH}/site1"
  answers site1 push web no
  run directory__TRuST__migrate
  assert_success
  refute_command '^(ssh|rsync|scp|sudo)'
}
