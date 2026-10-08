#!/usr/bin/env bats
# shellcheck disable=SC2317

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
