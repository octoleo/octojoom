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
  export TMPDIR="${SANDBOX}"
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
'[ -d '*']') [ -f "${STUB_DIR}/remote_has_folder" ] ;;
esac
EOF
}

# an available Joomla container folder with a compose file
make_available() {
  mkdir -p "${VDM_REPO_PATH}/joomla/available/$1"
  echo "services: {}" >"${VDM_REPO_PATH}/joomla/available/$1/docker-compose.yml"
}

# Execute remote shell commands against a second home inside the sandbox.
# rsync still uses its real file-copy and checksum engine, with both endpoints
# mapped to sandbox paths so these tests cannot initiate a network connection.
local_remote() {
  mkdir -p "${SANDBOX}/remote/.config/octojoom" "${SANDBOX}/remote/Projects" "${SANDBOX}/remote/Docker"
  {
    printf 'VDM_REPO_PATH="%s"\n' "${SANDBOX}/remote/Docker"
    printf 'VDM_PROJECT_PATH="%s"\n' "${SANDBOX}/remote/Projects"
  } >"${SANDBOX}/remote/.config/octojoom/.env"
  hook_command ssh <<'EOF'
HOME="${SANDBOX}/remote" bash -c "${*: -1}"
EOF
  hook_command rsync <<'EOF'
arguments=()
for argument in "${@:1:$#-2}"; do
  [ "${argument}" = --protect-args ] || arguments+=("${argument}")
done
source_path="${@: -2:1}"
destination_path="${*: -1}"
exec /usr/bin/rsync "${arguments[@]}" "${source_path#web:}" "${destination_path#web:}"
EOF
}

require_local_rsync() {
  [ -x /usr/bin/rsync ] || skip "a local rsync executable is required for sandbox transfer integration"
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

@test "migration-remote: pushContainerMigration sends one compressed archive to the remote repo path" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command '^rsync -av --protect-args -- .*octojoom-archive.* web:.*\.migration\.[[:alnum:]]+/archive.tar.gz$'
  refute_command '^rsync .*--delete'
  refute_command "rm -Irf"
  assert_dialog "success"
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
}

@test "migration-remote: pushContainerMigration backs up an existing remote container when asked" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  answers yes
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command "mv -- '${remote_path}' '${remote_path}_backup_[0-9_]+'.*exit 20"
  assert_command '^rsync -av --protect-args -- .*octojoom-archive.* web:.*archive.tar.gz$'
}

@test "migration-remote: pushContainerMigration reports a failed transfer" {
  local_remote
  make_available site.vdm.dev
  hook_command rsync <<'EOF'
exit 23
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

@test "migration-remote: pullContainerMigration stages and verifies the remote container" {
  require_local_rsync
  local_remote
  mkdir -p "${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  printf 'downloaded\n' >"${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev/docker-compose.yml"
  run pullContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_success
  assert_command '^ssh .*VDM_REPO_PATH'
  assert_dialog "PULL"
  assert_command '^rsync -av --protect-args -- web:.*octojoom-pull\.[[:alnum:]]+/archive.tar.gz '
  assert_command 'sha256sum|shasum'
  assert_file_exists "${LOCAL_PATH}"
}

###############################################################################
# migrate tasks

@test "migration-remote: joomla__TRuST__migratefiles pushes the selected container to the selected remote" {
  require_local_rsync
  local_remote
  ssh_config alpha web
  make_available other.vdm.dev
  make_available site.vdm.dev
  answers site.vdm.dev push web yes
  run joomla__TRuST__migratefiles
  assert_success
  assert_answers_used
  assert_command '^rsync -av --protect-args -- .*octojoom-archive.* web:.*site.vdm.dev.*archive.tar.gz$'
  refute_command "other.vdm.dev"
}

@test "migration-remote: joomla__TRuST__migratefiles does nothing when the confirmation is declined" {
  remote_octojoom
  ssh_config web
  make_available site.vdm.dev
  answers site.vdm.dev push web no
  run joomla__TRuST__migratefiles
  assert_success
  refute_command '^(ssh|rsync|scp)'
}

@test "migration-remote: joomla__TRuST__migratefiles is cancelled when no remote is selected" {
  ssh_config web
  make_available site.vdm.dev
  answers site.vdm.dev push "<cancel>"
  run joomla__TRuST__migratefiles
  assert_success
  assert_dialog "cancelled"
  refute_command '^(ssh|rsync|scp)'
}

@test "migration-remote: directory__TRuST__migrate runs the pull for the selected project directory" {
  require_local_rsync
  local_remote
  mkdir -p "${SANDBOX}/remote/Projects/site1"
  printf 'downloaded\n' >"${SANDBOX}/remote/Projects/site1/index.php"
  ssh_config web
  mkdir -p "${VDM_PROJECT_PATH}/site1" "${VDM_PROJECT_PATH}/site2"
  answers site1 pull web yes no
  run directory__TRuST__migrate
  assert_success
  assert_answers_used
  assert_command '^ssh .*VDM_PROJECT_PATH'
  assert_dialog "PULL"
  assert_command '^rsync -av --protect-args -- web:.*octojoom-pull.*archive.tar.gz '
  assert_command 'sha256sum|shasum'
}

@test "migration-remote: directory__TRuST__migrate does nothing when the confirmation is declined" {
  ssh_config web
  mkdir -p "${VDM_PROJECT_PATH}/site1"
  answers site1 push web no
  run directory__TRuST__migrate
  assert_success
  refute_command '^(ssh|rsync|scp|sudo)'
}

###############################################################################
# failure propagation and preservation of existing data

@test "migration-remote: HostName alone is not a configured host" {
  mkdir -p "${VDM_HOME_PATH}/.ssh"
  printf 'HostName web.example.org\n' >"${VDM_HOME_PATH}/.ssh/config"
  run hasRemoteSystemSet
  assert_failure
}

@test "migration-remote: remote environment lookup rejects an injected key" {
  run getRemoteEnvValue web 'VDM_REPO_PATH; touch injected'
  assert_failure
  assert_equal "${output}" none_found
  refute_command '^ssh'
}

@test "migration-remote: remote environment lookup preserves embedded quotes and equals" {
  hook_command ssh <<'EOF'
case "${*: -1}" in
grep*) printf '%s\n' 'VDM_REPO_PATH="/home/remote/a\"b=c"' ;;
esac
EOF
  run getRemoteEnvValue web VDM_REPO_PATH
  assert_success
  assert_equal "${output}" '/home/remote/a"b=c'
}

@test "migration-remote: remote environment lookup decodes escaped dollar signs as literal data" {
  hook_command ssh <<'EOF'
case "${*: -1}" in
grep*) printf 'VDM_REPO_PATH="/home/remote/\\$(touch %s/injected)"\n' "${SANDBOX}" ;;
esac
EOF
  run getRemoteEnvValue web VDM_REPO_PATH
  assert_success
  assert_equal "${output}" "/home/remote/\$(touch ${SANDBOX}/injected)"
  refute_file_exists "${SANDBOX}/injected"
}

@test "migration-remote: remote environment lookup rejects malformed quoted values" {
  hook_command ssh <<'EOF'
case "${*: -1}" in
grep*) printf '%s\n' 'VDM_REPO_PATH="unterminated' ;;
esac
EOF
  run getRemoteEnvValue web VDM_REPO_PATH
  assert_failure
  assert_equal "${output}" none_found
}

@test "migration-remote: SSH failure cannot masquerade as a matching transfer" {
  fail_command rsync 23
  run transferWasSuccessful "${LOCAL_PATH}" "${REMOTE_PATH}" web
  assert_failure
}

@test "migration-remote: verification detects ordinary itemized rsync file changes" {
  hook_command rsync <<'EOF'
printf '%s\n' '>f.st...... docker-compose.yml'
EOF
  run transferWasSuccessful "${LOCAL_PATH}" "${REMOTE_PATH}" web
  assert_failure
}

@test "migration-remote: a failed remote mkdir prevents copying" {
  fail_command ssh 255
  run syncWithRemote "${LOCAL_PATH}" "${REMOTE_PATH}" web
  assert_failure
  refute_command '^rsync'
}

@test "migration-remote: a failed push never publishes or removes the existing remote directory" {
  remote_octojoom
  make_available site.vdm.dev
  fail_command rsync 23
  run pushContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  refute_command "mv -- '${REMOTE_PATH}'"
  refute_command "rm -rf -- '${REMOTE_PATH}'"
  refute_dialog 'success'
}

@test "migration-remote: push refuses traversal in the destination" {
  remote_octojoom
  make_available site.vdm.dev
  run pushContainerMigration "${LOCAL_PATH}" '../outside' web
  assert_failure
  refute_command '^rsync'
  refute_command 'mkdir -p'
}

@test "migration-remote: pull refuses a missing remote source before modifying local files" {
  remote_octojoom
  make_available site.vdm.dev
  run pullContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
  refute_command '^rsync'
}

@test "migration-remote: failed pull preserves existing local files and removes its staging directory" {
  local_remote
  mkdir -p "${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  printf 'new\n' >"${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev/new.php"
  make_available site.vdm.dev
  hook_command rsync <<'EOF'
exit 23
EOF
  run pullContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
  refute_dialog 'success'
  run find "$(dirname "${LOCAL_PATH}")" -maxdepth 1 -name '*.migration.*'
  assert_equal "${output}" ''
}

@test "migration-remote: incomplete pull verification preserves the original directory" {
  local_remote
  make_available site.vdm.dev
  mkdir -p "${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  printf 'new\n' >"${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev/new.php"
  hook_command rsync <<'EOF'
printf 'corrupt archive\n' >"${*: -1}"
EOF
  run pullContainerMigration "${LOCAL_PATH}" "joomla/available/site.vdm.dev" web
  assert_failure
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
  refute_dialog 'success'
}

@test "migration-remote: archive verification fails for a missing local archive" {
  run transferTarWasSuccessful "${SANDBOX}/missing.tar.gz" '/remote/missing.tar.gz' web
  assert_failure
  refute_command '^ssh'
}

@test "migration-remote: archive verification fails on an SSH error instead of matching empty checksums" {
  printf 'archive\n' >"${SANDBOX}/archive.tar.gz"
  fail_command ssh 255
  run transferTarWasSuccessful "${SANDBOX}/archive.tar.gz" '/remote/archive.tar.gz' web
  assert_failure
}

@test "migration-remote: remote archive extraction failure preserves the archive" {
  local_remote
  printf 'invalid gzip\n' >"${SANDBOX}/remote/archive.tar.gz"
  run remoteUntarGz "${SANDBOX}/remote/archive.tar.gz" "${SANDBOX}/remote/extracted" web
  assert_failure
  assert_file_exists "${SANDBOX}/remote/archive.tar.gz"
}

@test "migration-remote: remote shell paths with apostrophes and metacharacters are literal" {
  local_remote
  local remote_path="${SANDBOX}/remote/a'b; touch ${SANDBOX}/injected"
  run prepRemoteFolder "${remote_path}" web
  assert_success
  assert_file_exists "${remote_path}"
  refute_file_exists "${SANDBOX}/injected"
}

@test "migration-remote: root and traversal paths cannot be remotely removed" {
  run removeRemoteFolder / web
  assert_failure
  run removeRemoteFolder '/safe/../outside' web
  assert_failure
  refute_command '^ssh'
}

@test "migration-remote: root backup copy failure cannot return a usable backup path" {
  mkdir -p "${SANDBOX}/source"
  hook_command sudo <<'EOF'
case "$1" in
cp) exit 1 ;;
*) exec "$@" ;;
esac
EOF
  # shellcheck disable=SC2016
  run env TMPDIR="${SANDBOX}" bash -c 'source "$1"; createTempBackup "$2"' \
    bash "${BATS_RUN_TMPDIR}/octojoom-functions.sh" "${SANDBOX}/source"
  assert_failure
  assert_equal "${output}" ''
  run find "${SANDBOX}" -maxdepth 1 -name 'octojoom-backup.*'
  assert_equal "${output}" ''
}

@test "migration-remote: tar creation failure removes the incomplete archive" {
  mkdir -p "${SANDBOX}/source" "${SANDBOX}/backup"
  tar() { return 1; }
  TMPDIR="${SANDBOX}"
  run tarAndMoveTempBackup "${SANDBOX}/source" "${SANDBOX}/backup"
  assert_failure
  assert_equal "${output}" ''
  run find "${SANDBOX}" -maxdepth 1 -name 'octojoom-archive.*'
  assert_equal "${output}" ''
}

@test "migration-remote: real sandbox push verifies and publishes contents and retains requested backup" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'previous\n' >"${remote_path}/old.txt"
  answers yes
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_success
  assert_answers_used
  assert_file_exists "${remote_path}/docker-compose.yml"
  refute_file_exists "${remote_path}/old.txt"
  run find "$(dirname "${remote_path}")" -path '*_backup_*/old.txt'
  assert_output_contains '_backup_'
  run find "$(dirname "${remote_path}")" -maxdepth 1 -name '*.migration.*'
  assert_equal "${output}" ''
}

@test "migration-remote: real sandbox pull copies contents and retains requested local backup" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'downloaded\n' >"${remote_path}/downloaded.php"
  answers yes
  run pullContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_success
  assert_answers_used
  assert_file_contains "${LOCAL_PATH}/downloaded.php" downloaded
  refute_file_exists "${LOCAL_PATH}/docker-compose.yml"
  run find "$(dirname "${LOCAL_PATH}")" -path '*_backup_*/docker-compose.yml'
  assert_output_contains '_backup_'
}

@test "migration-remote: real sandbox directory push verifies SHA-256 before extraction and publication" {
  require_local_rsync
  local_remote
  mkdir -p "${VDM_PROJECT_PATH}/site1"
  printf 'project contents\n' >"${VDM_PROJECT_PATH}/site1/index.php"
  TMPDIR="${SANDBOX}"
  answers no
  run pushDirectoryMigration "${VDM_PROJECT_PATH}/site1" site1 web
  assert_success
  assert_answers_used
  assert_file_contains "${SANDBOX}/remote/Projects/site1/index.php" 'project contents'
  assert_command 'sha256sum|shasum'
  assert_command 'tar --no-same-owner -xzf'
  run find "${SANDBOX}" -maxdepth 1 -name 'octojoom-archive.*'
  assert_equal "${output}" ''
}

@test "migration-remote: directory push keeps its recovery archive and original remote on extraction error" {
  local_remote
  mkdir -p "${VDM_PROJECT_PATH}/site1"
  printf 'project contents\n' >"${VDM_PROJECT_PATH}/site1/index.php"
  TMPDIR="${SANDBOX}"
  transferTarWasSuccessful() { return 0; }
  remoteUntarGz() { return 1; }
  run pushDirectoryMigration "${VDM_PROJECT_PATH}/site1" site1 web
  assert_failure
  assert_dialog 'local archive was retained'
  refute_dialog 'success'
  refute_command "mv -- '/home/remote/Projects/site1'"
  run find "${SANDBOX}" -maxdepth 1 -name 'octojoom-archive.*'
  assert_output_contains 'octojoom-archive.'
}

@test "migration-remote: remote publication failure rolls back the original contents" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'previous\n' >"${remote_path}/old.txt"
  hook_command ssh <<'EOF'
mv() {
  case "${@: -2:1}" in
  *.migration.*) return 1 ;;
  esac
  command mv "$@"
}
export -f mv
HOME="${SANDBOX}/remote" bash -c "${*: -1}"
EOF
  answers yes
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_file_contains "${remote_path}/old.txt" previous
  refute_file_exists "${remote_path}/docker-compose.yml"
  refute_dialog 'success'
  run find "$(dirname "${remote_path}")" -maxdepth 1 -name '*_backup_*'
  assert_equal "${output}" ''
}

@test "migration-remote: local pull publication failure restores the original contents" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'new\n' >"${remote_path}/new.php"
  # Invoked by the sourced helper under bats run.
  # shellcheck disable=SC2317
  mv() {
    case "${@: -2:1}" in
    *.migration.*) return 1 ;;
    esac
    command mv "$@"
  }
  answers yes
  run pullContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
  refute_file_exists "${LOCAL_PATH}/new.php"
  refute_dialog 'success'
}

@test "migration-remote: successful remote archive extraction removes only its verified archive" {
  local_remote
  mkdir -p "${SANDBOX}/archive-source"
  printf 'content\n' >"${SANDBOX}/archive-source/index.php"
  tar -czf "${SANDBOX}/remote/archive.tar.gz" -C "${SANDBOX}/archive-source" .
  run remoteUntarGz "${SANDBOX}/remote/archive.tar.gz" "${SANDBOX}/remote/extracted" web
  assert_success
  assert_file_contains "${SANDBOX}/remote/extracted/index.php" content
  refute_file_exists "${SANDBOX}/remote/archive.tar.gz"
}

@test "migration-remote: archive checksums reject an invalid or mismatched remote digest" {
  printf 'archive\n' >"${SANDBOX}/archive.tar.gz"
  hook_command ssh <<'EOF'
printf '%064d  /remote/archive.tar.gz\n' 0
EOF
  run transferTarWasSuccessful "${SANDBOX}/archive.tar.gz" '/remote/archive.tar.gz' web
  assert_failure
  hook_command ssh <<'EOF'
printf 'no checksum\n'
EOF
  run transferTarWasSuccessful "${SANDBOX}/archive.tar.gz" '/remote/archive.tar.gz' web
  assert_failure
}

@test "migration-remote: failed remote Octojoom sessions return failure" {
  hook_command ssh <<'EOF'
case "${*: -1}" in
'bash octojoom') exit 255 ;;
esac
EOF
  answers yes
  run connectToRemoteSystem web
  assert_failure
  assert_dialog 'session failed'
}

@test "migration-remote: migration dispatcher returns the failed push status" {
  remote_octojoom
  ssh_config web
  make_available site.vdm.dev
  fail_command rsync 23
  answers site.vdm.dev push web yes
  run joomla__TRuST__migratefiles
  assert_failure
  assert_dialog 'failed'
}

@test "migration-remote: publishing a user-owned remote folder needs no sudo" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'previous\n' >"${remote_path}/old.txt"
  answers no
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_success
  assert_file_exists "${remote_path}/docker-compose.yml"
  refute_file_exists "${remote_path}/old.txt"
  refute_command '^sudo'
  run find "$(dirname "${remote_path}")" -maxdepth 1 -name '*_backup_*'
  assert_equal "${output}" ''
}

@test "migration-remote: ownership repair uses the remote account IDs and quotes its path" {
  local_remote
  local remote_path="${SANDBOX}/remote/owner's project"
  hook_command ssh <<'EOF'
id() {
  case "$1" in
  -u) printf '501\n' ;;
  -g) printf '502\n' ;;
  esac
}
export -f id
HOME="${SANDBOX}/remote" bash -c "${*: -1}"
EOF
  run chownRemoteFolder "${remote_path}" web
  assert_success
  assert_command "^sudo chown -R 501:502 -- ${remote_path}$"
}

@test "migration-remote: backupRemoteFolder preserves contents under a unique backup name" {
  local_remote
  local remote_path="${SANDBOX}/remote/project"
  mkdir -p "${remote_path}"
  printf 'old contents\n' >"${remote_path}/old.txt"
  run backupRemoteFolder "${remote_path}" web
  assert_success
  refute_file_exists "${remote_path}"
  run find "${SANDBOX}/remote" -path '*_backup_*/old.txt'
  assert_output_contains 'project_backup_'
}

@test "migration-remote: failed remote backups return failure" {
  fail_command ssh 255
  run backupRemoteFolder '/home/remote/project' web
  assert_failure
}

@test "migration-remote: duplicate remote settings use the last definition" {
  hook_command ssh <<'EOF'
case "${*: -1}" in
grep*) printf '%s\n' 'VDM_REPO_PATH="/old/path"' 'VDM_REPO_PATH="/new/path"' ;;
esac
EOF
  run getRemoteEnvValue web VDM_REPO_PATH
  assert_success
  assert_equal "${output}" /new/path
}

@test "migration-remote: remote rollback failure reports the retained recovery directory" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'previous\n' >"${remote_path}/old.txt"
  hook_command ssh <<'EOF'
mv() {
  case "${@: -2:1}" in
  *.migration.* | *_backup_*) return 1 ;;
  esac
  command mv "$@"
}
export -f mv
HOME="${SANDBOX}/remote" bash -c "${*: -1}"
EOF
  answers yes
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_dialog 'original directory is retained'
  assert_dialog "${remote_path}_backup_"
  refute_file_exists "${remote_path}"
  run find "$(dirname "${remote_path}")" -path '*_backup_*/old.txt'
  assert_output_contains '_backup_'
}

@test "migration-remote: local rollback failure reports the retained recovery directory" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'new\n' >"${remote_path}/new.php"
  # Invoked by the sourced helper under bats run.
  # shellcheck disable=SC2317
  mv() {
    case "${@: -2:1}" in
    *.migration.* | *_backup_*) return 1 ;;
    esac
    command mv "$@"
  }
  answers yes
  run pullContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_dialog 'original directory is retained'
  assert_dialog "${LOCAL_PATH}_backup_"
  refute_file_exists "${LOCAL_PATH}"
  run find "$(dirname "${LOCAL_PATH}")" -path '*_backup_*/docker-compose.yml'
  assert_output_contains '_backup_'
}

@test "migration-remote: failed remote backup cleanup reports publication and recovery location" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Docker/joomla/available/site.vdm.dev"
  mkdir -p "${remote_path}"
  printf 'previous\n' >"${remote_path}/old.txt"
  hook_command ssh <<'EOF'
rm() {
  case "${*: -1}" in
  *_backup_*) return 1 ;;
  esac
  command rm "$@"
}
export -f rm
HOME="${SANDBOX}/remote" bash -c "${*: -1}"
EOF
  hook_command sudo <<'EOF'
exit 1
EOF
  answers no
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_dialog 'verified migration was published'
  assert_dialog "${remote_path}_backup_"
  assert_file_exists "${remote_path}/docker-compose.yml"
  run find "$(dirname "${remote_path}")" -path '*_backup_*/old.txt'
  assert_output_contains '_backup_'
}

@test "migration-remote: pull packages privately on the source and transfers one archive" {
  require_local_rsync
  local_remote
  local remote_path="${SANDBOX}/remote/Projects/site1"
  mkdir -p "${remote_path}"
  printf 'private project contents\n' >"${remote_path}/index.php"
  hook_command rsync <<'HOOK'
source_path="${@: -2:1}"
destination_path="${*: -1}"
source_path="${source_path#web:}"
if [[ "${OSTYPE}" != msys* && "${OSTYPE}" != cygwin* ]]; then
  file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
  [ "$(file_mode "${source_path%/*}")" = 700 ] || exit 90
  [ "$(file_mode "${source_path}")" = 600 ] || exit 91
  [ "$(file_mode "${destination_path%/*}")" = 700 ] || exit 92
fi
exec /usr/bin/rsync -a -- "${source_path}" "${destination_path}"
HOOK
  run pullRemoteFolder "${VDM_PROJECT_PATH}/site1" "${remote_path}" web
  assert_success
  assert_file_contains "${VDM_PROJECT_PATH}/site1/index.php" 'private project contents'
  assert_command '^rsync -av --protect-args -- web:.*archive.tar.gz .*archive.tar.gz$'
  run awk '$1 == "rsync" { count++ } END { print count }' "${STUB_DIR}/commands.log"
  assert_equal "${output}" 1
  run find "${SANDBOX}" -type d -name 'octojoom-pull.*'
  assert_equal "${output}" ''
}

@test "migration-remote: push archive and remote workspace are private during transfer" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  hook_command rsync <<'HOOK'
source_path="${@: -2:1}"
destination_path="${*: -1}"
destination_path="${destination_path#web:}"
if [[ "${OSTYPE}" != msys* && "${OSTYPE}" != cygwin* ]]; then
  file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
  [ "$(file_mode "${source_path}")" = 600 ] || exit 90
  [ "$(file_mode "${destination_path%/*}")" = 700 ] || exit 91
fi
exec /usr/bin/rsync -a -- "${source_path}" "${destination_path}"
HOOK
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_success
  run awk '$1 == "rsync" { count++ } END { print count }' "${STUB_DIR}/commands.log"
  assert_equal "${output}" 1
}

@test "migration-remote: pull rejects links before replacing the existing local directory" {
  require_local_rsync
  local_remote
  make_available site.vdm.dev
  local remote_path="${SANDBOX}/remote/Projects/unsafe"
  mkdir -p "${remote_path}"
  ln -s "${SANDBOX}/outside" "${remote_path}/escape"
  run pullRemoteFolder "${LOCAL_PATH}" "${remote_path}" web
  assert_failure
  assert_file_exists "${LOCAL_PATH}/docker-compose.yml"
  refute_file_exists "${LOCAL_PATH}/escape"
  refute_file_exists "${SANDBOX}/outside"
}

@test "migration-remote: push rejects hard links before transferring an archive" {
  local_remote
  make_available site.vdm.dev
  ln "${LOCAL_PATH}/docker-compose.yml" "${LOCAL_PATH}/duplicate.yml"
  run pushContainerMigration "${LOCAL_PATH}" 'joomla/available/site.vdm.dev' web
  assert_failure
  assert_dialog 'unsafe entry'
  refute_command '^rsync'
}

@test "migration-remote: remote extraction refuses an archive with traversal entries" {
  local_remote
  mkdir -p "${SANDBOX}/archive-source"
  printf 'do not extract\n' >"${SANDBOX}/archive-source/payload"
  if tar --version | grep -q 'GNU tar'; then
    tar -czf "${SANDBOX}/remote/archive.tar.gz" --transform='s|payload|../outside|' -C "${SANDBOX}/archive-source" payload
  else
    tar -s ',payload,../outside,' -czf "${SANDBOX}/remote/archive.tar.gz" -C "${SANDBOX}/archive-source" payload
  fi
  run remoteUntarGz "${SANDBOX}/remote/archive.tar.gz" "${SANDBOX}/remote/extracted" web
  assert_failure
  assert_file_exists "${SANDBOX}/remote/archive.tar.gz"
  refute_file_exists "${SANDBOX}/remote/outside"
  refute_file_exists "${SANDBOX}/remote/extracted"
}
