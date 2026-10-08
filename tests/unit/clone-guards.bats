#!/usr/bin/env bats
# Each Bats test has an isolated shell; globals are consumed by loaded functions.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  make_joomla_container source SOURCE source
  SRC="${VDM_REPO_PATH}/joomla/available/source.vdm.dev/docker-compose.yml"
}

@test "compose rewrite refuses the source path and aliases without changing its contents" {
  cp "${SRC}" "${SANDBOX}/before.yml"
  run rewriteJoomlaComposeIdentity "${SRC}" "${SRC}" source target SOURCE TARGET source target vdm.dev vdm.dev
  assert_failure
  cmp "${SRC}" "${SANDBOX}/before.yml"
  if is_windows; then return 0; fi
  ln -s "${SRC}" "${SANDBOX}/alias.yml"
  run rewriteJoomlaComposeIdentity "${SRC}" "${SANDBOX}/alias.yml" source target SOURCE TARGET source target vdm.dev vdm.dev
  assert_failure
  cmp "${SRC}" "${SANDBOX}/before.yml"
}

@test "compose rewrite refuses invalid identity before creating a target" {
  run rewriteJoomlaComposeIdentity "${SRC}" "${SANDBOX}/target.yml" source 'bad/key' SOURCE TARGET source target vdm.dev vdm.dev
  assert_failure
  refute_file_exists "${SANDBOX}/target.yml"
}

@test "per-container env clone refuses source aliases before truncating secrets" {
  local env="${VDM_REPO_PATH}/joomla/.env"
  cp "${env}" "${SANDBOX}/before.env"
  run cloneContainerEnvFile "${env}" "${env}" SOURCE TARGET
  assert_failure
  cmp "${env}" "${SANDBOX}/before.env"
  if is_windows; then return 0; fi
  ln -s "${env}" "${SANDBOX}/alias.env"
  run cloneContainerEnvFile "${env}" "${SANDBOX}/alias.env" SOURCE TARGET
  assert_failure
  cmp "${env}" "${SANDBOX}/before.env"
}

@test "env helpers refuse keys that would broaden the variable match" {
  local env="${VDM_REPO_PATH}/joomla/.env"
  cp "${env}" "${SANDBOX}/before.env"
  run cloneContainerEnvVariables "${env}" '.*' TARGET
  assert_failure
  run hasContainerEnvVariables "${env}" '.*'
  assert_failure
  run cloneContainerEnvFile "${env}" "${SANDBOX}/target.env" SOURCE 'BAD/KEY'
  assert_failure
  refute_file_exists "${SANDBOX}/target.env"
  cmp "${env}" "${SANDBOX}/before.env"
}

@test "env clone propagates a permissions failure" {
  chmod() { return 9; }
  run cloneContainerEnvFile "${VDM_REPO_PATH}/joomla/.env" "${SANDBOX}/target.env" SOURCE TARGET
  assert_status 9
}

@test "clone lock prevents a second source stop and copy cycle" {
  mkdir "${VDM_REPO_PATH}/joomla/.clone.lock"
  cloneJoomlaContainerUnlocked() { touch "${SANDBOX}/unexpected-copy"; }
  run cloneJoomlaContainer
  assert_failure
  refute_file_exists "${SANDBOX}/unexpected-copy"
  [ -d "${VDM_REPO_PATH}/joomla/.clone.lock" ]
}

@test "clone lock is held during the operation and released after failure" {
  cloneJoomlaContainerUnlocked() {
    [ -d "${VDM_REPO_PATH}/joomla/.clone.lock" ] || return 8
    return 7
  }
  run cloneJoomlaContainer
  assert_status 7
  refute_file_exists "${VDM_REPO_PATH}/joomla/.clone.lock"
}

@test "key collision inventory distinguishes a free key from a Docker inspection failure" {
  run isJoomlaKeyInUse target
  assert_status 1
  fail_command docker-ps 17
  run isJoomlaKeyInUse target
  assert_status 2
  assert_output_contains 'Could not inspect Docker containers'
}

@test "key collision inventory checks stopped containers and existing project paths" {
  printf '%s\n' mariadbtarget >"${STUB_DIR}/docker/all"
  run isJoomlaKeyInUse target
  assert_success
  : >"${STUB_DIR}/docker/all"
  touch "${VDM_PROJECT_PATH}/target"
  run isJoomlaKeyInUse target
  assert_success
}

@test "key collision inventory refuses invalid keys and Compose scan failures" {
  run isJoomlaKeyInUse '.*'
  assert_status 2
  grep() { return 2; }
  run isJoomlaKeyInUse target
  assert_status 2
  assert_output_contains 'Could not inspect an existing Joomla Compose file'
}

@test "key collision inventory refuses a missing project root or invalid Compose directory" {
  local project_root="${VDM_PROJECT_PATH}"
  VDM_PROJECT_PATH="${SANDBOX}/missing-project-root"
  run isJoomlaKeyInUse target
  assert_status 2
  assert_output_contains 'Could not inspect the project or repository directory'
  VDM_PROJECT_PATH="${project_root}"
  mv "${VDM_REPO_PATH}/joomla/available" "${SANDBOX}/available-before"
  touch "${VDM_REPO_PATH}/joomla/available"
  run isJoomlaKeyInUse target
  assert_status 2
  assert_output_contains 'Could not inspect the Joomla Compose directory'
}

@test "clone aborts before writing or prompting for environment values when collision inspection fails" {
  VDM_CONTAINER_TYPE=joomla
  printf "<?php\nclass JConfig {\n    public \$host = 'mariadbsource';\n}\n" >"${VDM_PROJECT_PATH}/source/joomla/configuration.php"
  getSelectedDirectory() {
    case "${2}" in
    */available/) printf '%s' source.vdm.dev ;;
    *) printf '%s' source ;;
    esac
  }
  setUniqueKey() { VDM_KEY=target; }
  setEnvironmentKey() { touch "${SANDBOX}/unexpected-env"; return 1; }
  fail_command docker-ps 17
  run cloneJoomlaContainerUnlocked
  assert_failure
  refute_file_exists "${SANDBOX}/unexpected-env"
  refute_file_exists "${VDM_PROJECT_PATH}/target"
  refute_command 'docker compose .* (stop|start)'
  grep -q 'clone was cancelled without changing any files' "${STUB_DIR}/dialogs.full"
}
