#!/usr/bin/env bats
# Each Bats test has an isolated shell; globals are consumed by loaded functions.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317

load ../helpers/common

setup() {
  octojoom_setup
  make_joomla_container source SOURCE source
  SRC="${VDM_REPO_PATH}/joomla/available/source.vdm.dev/docker-compose.yml"
}

@test "inline named database storage is refused before clone output or source mutation" {
  awk '
    /PROJECT_PATH.*\/source\/db:/ {print "      - {type: volume, source: original_database, target: /var/lib/mysql}"; next}
    {print}
  ' "$SRC" > "$SANDBOX/named.yml"
  cp "$SANDBOX/named.yml" "$SRC"
  cp "$SRC" "$SANDBOX/source-before.yml"
  run requireOriginalJoomlaDataLayout source.vdm.dev Clone
  assert_failure
  run rewriteJoomlaComposeIdentity "$SRC" "$SANDBOX/clone.yml" source target SOURCE TARGET source target vdm.dev vdm.dev
  assert_status 2
  refute_file_exists "$SANDBOX/clone.yml"
  cmp "$SRC" "$SANDBOX/source-before.yml"
  refute_command '^docker .* (stop|start|up)'
}

@test "project copy checks actual container mounts and refuses a shared named database" {
  hook_command docker <<'EOF'
if [ "$1" = inspect ]; then
  printf 'volume\toriginal_database\t/var/lib/mysql\n'
else
  exit 1
fi
EOF
  run joomlaVerifyProjectBindings source "$VDM_PROJECT_PATH" source
  assert_failure
  assert_output_contains 'does not use its expected persistent project folder'
  refute_command '^docker .* (stop|start|up)'
}

@test "project mount verification normalizes Windows host paths and rejects an unrelated bind" {
  OS_NUMBER=3
  cygpath() {
    local path="${*: -1}"
    case "$path" in
      C:/*) printf '/c/%s\n' "${path#C:/}";;
      *) printf '%s\n' "$path";;
    esac
  }
  docker() {
    case "${*: -1}" in
      mariadbsource) printf 'bind\tC:/Projects/source/db\t/var/lib/mysql\n';;
      joomlasource) printf 'bind\tC:/Projects/source/joomla\t/var/www/html\n';;
      *) return 1;;
    esac
  }
  run joomlaVerifyProjectBindings source /c/Projects source
  assert_success
  run joomlaVerifyProjectBindings source /c/Other source
  assert_failure
}

@test "persistent Nginx companion mounts can be copied without sharing configuration" {
  local work="$SANDBOX/nginx"
  mkdir -p "$work"
  joomlaRewriteWebserverCompose "$SRC" "$work/docker-compose.yml" joomlasource nginxsource nginx joomla:verified-fpm nginx:stable-alpine "$work"
  run migrationComposeLocalFiles "$work/docker-compose.yml" source
  assert_success
  assert_output_contains nginx.conf
  joomlaNginxConfiguration joomlasource /var/www/html/site > "$work/nginx.conf"
  cp "$work/nginx.conf" "$SANDBOX/source-nginx.conf"
  run joomlaRealignCompanionFiles "$work" source target
  assert_success
  assert_file_contains "$work/nginx.conf" 'fastcgi_pass joomlatarget:9000;'
  assert_file_contains "$work/nginx.conf" 'root /var/www/html/site;'
  assert_file_contains "$SANDBOX/source-nginx.conf" 'fastcgi_pass joomlasource:9000;'
}

@test "persistent project copies require a writable main web mount" {
  sed 's#source/joomla:/var/www/html#source/joomla:/var/www/html:ro#' "$SRC" > "$SANDBOX/readonly.yml"
  run migrationComposeLocalFiles "$SANDBOX/readonly.yml" source
  assert_failure
}

@test "nested project roots remain inside the persistent website directory" {
  local env="$VDM_REPO_PATH/joomla/.env"
  writeEnvVariable "$env" 'VDM_SOURCE_DOCROOT=site/public' true
  run joomlaProjectRelativeRoot "$env" SOURCE
  assert_success
  assert_equal "$output" 'joomla/site/public'
  writeEnvVariable "$env" 'VDM_SOURCE_DOCROOT=../other' true
  run joomlaProjectRelativeRoot "$env" SOURCE
  assert_failure
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
  joomlaVerifyProjectBindings() { return 0; }
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
