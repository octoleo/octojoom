#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
  FLOW_DIRECTION=push
  FLOW_CONFIRM=yes
  FLOW_IMPORT_STATUS=0
  FLOW_TRANSFER_STATUS=0
  FLOW_PROTOCOL=octojoom-migration-v1
  FLOW_DIGEST_MISMATCH=false
  FLOW_LOG="${SANDBOX}/migration-flow.log"
  FLOW_PAYLOAD="${SANDBOX}/source-package.tar.gz"
  FLOW_REMOTE="${SANDBOX}/remote/.config/octojoom/migrations/migration.REMOTE123"
  : >"${FLOW_LOG}"
  printf 'one private compressed package fixture\n' >"${FLOW_PAYLOAD}"
  getMigrationType() { printf '%s\n' "${FLOW_DIRECTION}"; }
  getRemoteSystem() { printf '%s\n' web; }
  getSelectedDirectory() { printf '%s\n' source.vdm.dev; }
  getInputYesNo() { [ "${FLOW_CONFIRM}" = yes ]; }
  exportJoomlaMigration() {
    printf 'source-export:%s\n' "$1" >>"${FLOW_LOG}"
    cp "${FLOW_PAYLOAD}" "$2"
  }
  importJoomlaMigration() {
    printf 'local-import:%s\n' "$1" >>"${FLOW_LOG}"
    return "${FLOW_IMPORT_STATUS}"
  }
  remoteMigrationWorker() {
    local action="$3"
    printf 'remote:%s\n' "${action}" >>"${FLOW_LOG}"
    case "${action}" in
    capabilities) printf '%s\n' "${FLOW_PROTOCOL}" ;;
    list) printf '%s\n' source.vdm.dev ;;
    receive)
      mkdir -p "${FLOW_REMOTE}"
      printf '%s\n' "${FLOW_REMOTE}"
      ;;
    export-to)
      [ "$2" = true ] && [ "$4" = source.vdm.dev ] && [ "$5" = "${FLOW_REMOTE}" ] || return 2
      cp "${FLOW_PAYLOAD}" "${FLOW_REMOTE}/package.tar.gz"
      ;;
    digest)
      if "${FLOW_DIGEST_MISMATCH}"; then
        printf '%064d\n' 0
      else
        migrationArchiveDigest "$4"
      fi
      ;;
    import) return "${FLOW_IMPORT_STATUS}" ;;
    cleanup) rm -rf -- "$4" ;;
    *) return 2 ;;
    esac
  }
  rsync() {
    printf 'transfer:%s\n' "$*" >>"${FLOW_LOG}"
    [ "$#" -eq 5 ] && [ "$1" = -az ] && [ "$2" = --protect-args ] && [ "$3" = -- ] || return 2
    local source="$4" destination="$5"
    cp "${source#web:}" "${destination#web:}" || return 1
    return "${FLOW_TRANSFER_STATUS}"
  }
}

flow_local_archive() {
  local candidate
  for candidate in "${VDM_SRC_PATH}/migrations/"migration.*/package.tar.gz; do
    [ -f "${candidate}" ] && printf '%s\n' "${candidate}"
  done
  return 0
}

@test "complete migration push sends exactly one archive then verifies imports and cleans recovery workspaces" {
  run joomla__TRuST__migrate
  assert_success
  [ "$(grep -c '^transfer:' "${FLOW_LOG}")" -eq 1 ]
  grep -q '^transfer:.*package.tar.gz web:.*package.tar.gz$' "${FLOW_LOG}"
  printf '%s\n' remote:capabilities source-export:source.vdm.dev remote:receive remote:digest remote:import remote:cleanup >"${SANDBOX}/expected-flow"
  sed '/^transfer:/d' "${FLOW_LOG}" >"${SANDBOX}/actual-flow"
  cmp "${SANDBOX}/expected-flow" "${SANDBOX}/actual-flow"
  [ -z "$(flow_local_archive)" ]
  refute_file_exists "${FLOW_REMOTE}"
  assert_file_exists "${FLOW_PAYLOAD}"
}

@test "complete migration pull discovers remote projects even with no available local projects" {
  FLOW_DIRECTION=pull
  answers source.vdm.dev
  refute_file_exists "${VDM_REPO_PATH}/joomla/available"
  run joomla__TRuST__migrate
  assert_success
  [ "$(grep -c '^transfer:' "${FLOW_LOG}")" -eq 1 ]
  grep -q '^remote:list$' "${FLOW_LOG}"
  grep -q '^remote:export-to$' "${FLOW_LOG}"
  grep -q '^transfer:.*web:.*package.tar.gz .*package.tar.gz$' "${FLOW_LOG}"
  grep -q '^local-import:' "${FLOW_LOG}"
  run grep -qE '^source-export:|^remote:import$' "${FLOW_LOG}"
  assert_status 1
  [ -z "$(flow_local_archive)" ]
  refute_file_exists "${FLOW_REMOTE}"
  assert_answers_used
}

@test "complete migration checksum mismatch blocks import and retains both recovery archives" {
  FLOW_DIGEST_MISMATCH=true
  run joomla__TRuST__migrate
  assert_failure
  assert_file_exists "$(flow_local_archive)"
  assert_file_exists "${FLOW_REMOTE}/package.tar.gz"
  run grep -qE '^remote:import$|^local-import:|^remote:cleanup$' "${FLOW_LOG}"
  assert_status 1
  grep -q 'Recovery archives are retained' "${STUB_DIR}/dialogs.full"
}

@test "complete migration failed archive transfer never attempts validation or import" {
  FLOW_TRANSFER_STATUS=23
  run joomla__TRuST__migrate
  assert_failure
  assert_file_exists "$(flow_local_archive)"
  assert_file_exists "${FLOW_REMOTE}/package.tar.gz"
  run grep -qE '^remote:digest$|^remote:import$|^remote:cleanup$' "${FLOW_LOG}"
  assert_status 1
}

@test "complete migration destination import failure retains both archives and leaves the source package unchanged" {
  FLOW_IMPORT_STATUS=1
  cp "${FLOW_PAYLOAD}" "${SANDBOX}/source-before"
  run joomla__TRuST__migrate
  assert_failure
  cmp "${FLOW_PAYLOAD}" "${SANDBOX}/source-before"
  cmp "${FLOW_PAYLOAD}" "$(flow_local_archive)"
  cmp "${FLOW_PAYLOAD}" "${FLOW_REMOTE}/package.tar.gz"
  run grep -q '^remote:cleanup$' "${FLOW_LOG}"
  assert_status 1
}

@test "complete migration confirmation cancellation never packages or transfers project data" {
  FLOW_CONFIRM=no
  run joomla__TRuST__migrate
  assert_success
  [ "$(cat "${FLOW_LOG}")" = remote:capabilities ]
  refute_file_exists "${VDM_SRC_PATH}/migrations"
  refute_file_exists "${FLOW_REMOTE}"
}

@test "complete migration destination cancellation keeps archives and does not report preparation success" {
  FLOW_IMPORT_STATUS=3
  run joomla__TRuST__migrate
  assert_status 3
  assert_file_exists "$(flow_local_archive)"
  assert_file_exists "${FLOW_REMOTE}/package.tar.gz"
  run grep -q '^remote:cleanup$' "${FLOW_LOG}"
  assert_status 1
  run grep -q 'transferred and prepared on the destination' "${STUB_DIR}/dialogs.full"
  assert_status 1
}

@test "complete migration rejects incompatible remote protocol before creating archives" {
  FLOW_PROTOCOL=octojoom-migration-v99
  run joomla__TRuST__migrate
  assert_failure
  [ "$(cat "${FLOW_LOG}")" = remote:capabilities ]
  refute_file_exists "${VDM_SRC_PATH}/migrations"
}

@test "remote worker arguments remain literal through a remote shell including apostrophes and shell metacharacters" {
  octojoom_load
  mkdir -p "${SANDBOX}/bin"
  cat >"${SANDBOX}/bin/octojoom" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${STUB_DIR}/worker-arguments"
SCRIPT
  chmod +x "${SANDBOX}/bin/octojoom"
  PATH="${SANDBOX}/bin:${PATH}"
  ssh() { printf '%s\n' "$1" "$2" >"${STUB_DIR}/ssh-arguments"; bash -c "${*: -1}"; }
  local argument="${SANDBOX}/migration.'; touch ${SANDBOX}/injected; #/package.tar.gz"
  run remoteMigrationWorker deploy@example.org false import "${argument}"
  assert_success
  printf '%s\n' --migration-worker import "${argument}" >"${SANDBOX}/expected-arguments"
  cmp "${SANDBOX}/expected-arguments" "${STUB_DIR}/worker-arguments"
  refute_file_exists "${SANDBOX}/injected"
  [ "$(sed -n '1p' "${STUB_DIR}/ssh-arguments")" = -- ]
  [ "$(sed -n '2p' "${STUB_DIR}/ssh-arguments")" = deploy@example.org ]
}

@test "worker imports only a private archive and does not load its host overrides into the destination" {
  octojoom_load
  local workspace
  workspace=$(createMigrationWorkspace)
  printf 'VDM_REPO_PATH="/untrusted/repository"\nVDM_SRC_PATH="/untrusted/config"\n' >"${workspace}/package.tar.gz"
  importJoomlaMigration() {
    printf '%s\n' "${VDM_REPO_PATH}" "${VDM_SRC_PATH}" "$1" >"${STUB_DIR}/import-host-context"
  }
  run migrationWorker import "${workspace}/package.tar.gz"
  assert_success
  printf '%s\n' "${VDM_REPO_PATH}" "${VDM_SRC_PATH}" "${workspace}/package.tar.gz" >"${SANDBOX}/expected-host-context"
  cmp "${SANDBOX}/expected-host-context" "${STUB_DIR}/import-host-context"
  run migrationWorker import "${FLOW_PAYLOAD}"
  assert_failure
}

@test "worker refuses extra arguments and cleanup outside its own private workspace" {
  octojoom_load
  local workspace
  workspace=$(createMigrationWorkspace)
  run migrationWorker receive extra
  assert_failure
  run migrationWorker cleanup "${VDM_PROJECT_PATH}"
  assert_failure
  [ -d "${VDM_PROJECT_PATH}" ]
  run migrationWorker cleanup "${workspace}"
  assert_success
  refute_file_exists "${workspace}"
}
