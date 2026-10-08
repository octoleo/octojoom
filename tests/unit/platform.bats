#!/usr/bin/env bats
#
# Behaviour that differs between Linux, macOS and Windows (Git Bash).
#
# SC2034: OS_NUMBER is read by the loaded script functions.
# SC2317/SC2329: mkdir stand-ins are called by the loaded script.
# shellcheck disable=SC2034,SC2317,SC2329

load ../helpers/common

setup() {
  octojoom_setup
}

@test "createPrivateDirectory: new Unix directories and parents use mode 700" {
  skip_on_windows 'Windows inherits native ACLs rather than Unix file modes'
  umask 022
  run createPrivateDirectory -p "${SANDBOX}/private parent/private child"
  assert_success
  assert_equal "$(file_mode "${SANDBOX}/private parent")" 700
  assert_equal "$(file_mode "${SANDBOX}/private parent/private child")" 700
}

@test "createPrivateDirectory: the caller keeps its original umask" {
  local caller_umask
  umask 022
  caller_umask=$(umask)
  createPrivateDirectory "${SANDBOX}/private"
  assert_equal "$(umask)" "$caller_umask"
  assert_file_exists "${SANDBOX}/private"
}

@test "createPrivateDirectory: Git Bash creation never supplies mode-changing flags" {
  OS_NUMBER=3
  mkdir() {
    local argument
    for argument in "$@"; do
      case "$argument" in -m*|--mode*) return 77 ;; esac
    done
    command mkdir "$@"
  }
  run createPrivateDirectory -p "${SANDBOX}/Windows compatible/private"
  assert_success
  assert_file_exists "${SANDBOX}/Windows compatible/private"
}

@test "createPrivateDirectory: genuine mkdir failures retain their exact status" {
  mkdir() { return 42; }
  run createPrivateDirectory -p "${SANDBOX}/uncreated"
  assert_status 42
  refute_file_exists "${SANDBOX}/uncreated"
}

@test "createPrivateDirectory: exclusive clone directory creation rejects an existing destination" {
  mkdir -p "${SANDBOX}/existing"
  printf 'keep\n' >"${SANDBOX}/existing/data"
  run createPrivateDirectory "${SANDBOX}/existing"
  assert_failure
  assert_file_contains "${SANDBOX}/existing/data" keep
}

@test "check_bash_version: accepts the current and lower required major version" {
  run check_bash_version "${BASH_VERSINFO[0]}"
  assert_success
  run check_bash_version 4
  assert_success
}

@test "check_bash_version: fails when the required major version is newer" {
  run check_bash_version "$((BASH_VERSINFO[0] + 1))"
  assert_failure
  assert_output_contains 'requires Bash version'
}

@test "check_bash_version: rejects an empty or nonnumeric requirement" {
  local value
  for value in '' invalid '4+1' '4.0'; do
    run check_bash_version "$value"
    assert_failure
  done
}

# a configuration.php as Joomla leaves it: read only
write_readonly_config() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'PHP'
<?php
class JConfig {
	public $sitename = 'Site';
	public $host = 'mariadbold:3306';
	public $smtphost = 'mailcatcherold';
}
PHP
  chmod 444 "$1"
}

@test "USER: Git Bash on Windows has only USERNAME, so USER falls back to it" {
  local line
  line=$(grep -E '^: "\$\{USER:=' "${OCTOJOOM_SCRIPT}")
  [ -n "${line}" ]
  run env -u USER USERNAME=winuser bash -c "${line}; echo \"\${USER}\""
  assert_success
  assert_equal "${output}" "winuser"
}

@test "USER: an existing USER is kept" {
  local line
  line=$(grep -E '^: "\$\{USER:=' "${OCTOJOOM_SCRIPT}")
  run env USER=linuxuser USERNAME=winuser bash -c "${line}; echo \"\${USER}\""
  assert_success
  assert_equal "${output}" "linuxuser"
}

@test "USER: without USER and USERNAME the login name is used" {
  local line
  line=$(grep -E '^: "\$\{USER:=' "${OCTOJOOM_SCRIPT}")
  run env -u USER -u USERNAME bash -c "${line}; echo \"\${USER}\""
  assert_success
  assert_equal "${output}" "$(id -un)"
}

@test "cloneJoomlaConfiguration: patches a read-only file where there is no sudo (Windows)" {
  local file="${SANDBOX}/site/configuration.php"
  write_readonly_config "${file}"
  OS_NUMBER=3
  run cloneJoomlaConfiguration "${file}" old new ''
  assert_success
  assert_equal "$(getJoomlaConfigValue "${file}" host)" "mariadbnew:3306"
  assert_equal "$(getJoomlaConfigValue "${file}" smtphost)" "mailcatchernew"
  refute_command '^sudo '
}

@test "cloneJoomlaConfiguration: a read-only file stays read-only after the patch without sudo" {
  skip_on_windows "file modes are not kept on Windows"
  local file="${SANDBOX}/site/configuration.php"
  write_readonly_config "${file}"
  OS_NUMBER=3
  run cloneJoomlaConfiguration "${file}" old new ''
  assert_success
  assert_equal "$(file_mode "${file}")" "444"
}

@test "cloneJoomlaConfiguration: patches a read-only file through sudo on Linux and macOS" {
  if is_windows; then
    skip "sudo is never used on Windows"
  fi
  if [ "$(id -u)" = "0" ]; then
    skip "root writes a read-only file directly"
  fi
  local file="${SANDBOX}/site/configuration.php"
  write_readonly_config "${file}"
  run cloneJoomlaConfiguration "${file}" old new ''
  assert_success
  assert_equal "$(getJoomlaConfigValue "${file}" host)" "mariadbnew:3306"
  assert_command "^sudo tee ${file}"
  assert_equal "$(file_mode "${file}")" "444"
}

@test "deleteEnvVariable: the global config keeps mode 600 (no GNU-only chmod --reference)" {
  skip_on_windows "file modes are not kept on Windows"
  octojoom_config 'VDM_EXTRA="one"'
  run deleteEnvVariable VDM_EXTRA
  assert_success
  refute_file_contains "${VDM_SRC_PATH}/.env" 'VDM_EXTRA='
  assert_equal "$(file_mode "${VDM_SRC_PATH}/.env")" "600"
  refute_output_contains "illegal option"
}

@test "setUniqueEnvVariable: replacing a setting keeps the global config at mode 600" {
  skip_on_windows "file modes are not kept on Windows"
  octojoom_config
  run setUniqueEnvVariable 'VDM_DOMAIN="example.org"'
  assert_success
  assert_file_contains "${VDM_SRC_PATH}/.env" 'VDM_DOMAIN="example.org"'
  refute_file_contains "${VDM_SRC_PATH}/.env" 'VDM_DOMAIN="vdm.dev"'
  assert_equal "$(file_mode "${VDM_SRC_PATH}/.env")" "600"
}

@test "isContainerRunning: uses docker.exe on Windows and docker elsewhere" {
  running_containers mariadbjcb
  OS_NUMBER=3
  run isContainerRunning mariadbjcb
  assert_success
  OS_NUMBER=1
  run isContainerRunning mariadbjcb
  assert_success
  run isContainerRunning mariadbother
  assert_failure
}
