#!/usr/bin/env bats
#
# The command line and the menus: the help, the option parsing, main (which
# runs a type__TRuST__task or shows the main menu), mainMenu and showJoomla.
# Whole-script runs use run_octojoom; the menus are called directly with the
# task functions replaced by a recorder.
#
# SC2034: the VDM_* globals are read by the loaded script functions.
# shellcheck disable=SC2034

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
}

# replace the given functions with one that records its name in ${SANDBOX}/calls
record_calls() {
  local name
  for name in "$@"; do
    eval "${name}() { echo ${name} >>\"\${SANDBOX}/calls\"; }"
  done
}

@test "cli: -h and --help show the usage and exit 0" {
  local option
  for option in -h --help; do
    run_octojoom "${option}"
    assert_success
    assert_output_contains "Usage: octojoom"
  done
}

@test "cli: an option given as -s x, -s=x and --sub-domain=x reaches the task" {
  make_joomla_container jcb JCB jcb
  local enabled="${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
  local form
  for form in "-s jcb" "-s=jcb" "--sub-domain=jcb"; do
    rm -rf "${VDM_REPO_PATH}/joomla/enabled"
    # shellcheck disable=SC2086
    run_octojoom --type joomla --task enable -d vdm.dev ${form}
    assert_success
    [ -e "${enabled}" ] || {
      echo "not enabled with: ${form}" >&2
      return 1
    }
  done
}

@test "cli: an empty option value exits 17" {
  local option
  for option in --key= -k= --type= --task= --container= --access-token= \
    --joomla-version= -j= --env-key= -e= --domain= -d= --sub-domain= -s= \
    --username= -u= --uid= --gid= --port= -p= --ssh-dir= --time-zone= -t=; do
    run_octojoom "${option}"
    assert_status 17
  done
  refute_command 'docker compose .* up'
}

@test "cli: a missing value cannot consume the next option" {
  local option
  for option in --key --type --task --container --access-token -j -e -d -s -u --uid --gid -p --ssh-dir -t; do
    run_octojoom "${option}" --help
    assert_status 17
    assert_output_contains "requires a non-empty option argument"
  done
}

@test "cli: unknown flags and positional arguments are rejected" {
  local argument
  for argument in --typo stray --sudo=true; do
    run_octojoom "${argument}"
    assert_status 17
    refute_file_contains "${STUB_DIR}/dialogs.log" "--menu"
  done
}

@test "parseCLI: --sudo preserves the following flag and task options" {
  parseCLI --sudo --yes --type joomla --task up
  assert_equal "${VDM_SUDO_ACCESS}" true
  assert_equal "${VDM_FORCE}" true
  assert_equal "${VDM_CONTAINER_TYPE}" joomla
  assert_equal "${VDM_TASK}" up
}

@test "parseCLI: update parses its remaining arguments before executing" {
  parseCLI --update --access-token tokenvalue --yes
  assert_equal "${OCTOJOOM_CLI_ACTION}" update
  assert_equal "${VDM_ACCESS_TOKEN}" tokenvalue
  assert_equal "${VDM_FORCE}" true
}

@test "parseCLI: conflicting maintenance actions fail" {
  run parseCLI --update --uninstall
  assert_status 17
}

@test "cli: an explicit domain overrides the saved global domain" {
  make_joomla_container jcb JCB jcb custom.dev
  run_octojoom --type joomla --task enable --domain custom.dev --sub-domain jcb
  assert_success
  assert_file_exists "${VDM_REPO_PATH}/joomla/enabled/jcb.custom.dev"
  refute_file_exists "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
}

@test "cli: a subdomain target uses the saved domain without interactive selection" {
  make_joomla_container jcb JCB jcb
  run_octojoom --type joomla --task enable --sub-domain jcb
  assert_success
  assert_file_exists "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev"
  refute_file_contains "${STUB_DIR}/dialogs.log" "--checklist"
  assert_answers_used
}

@test "cli: startup cancels cleanly when the repository input is interrupted" {
  printf '%s\n' 'VDM_REPO_PATH=""' >>"${VDM_SRC_PATH}/.env"
  answers '<esc>'
  run_octojoom
  assert_status 255
  assert_answers_used
  refute_command 'docker network create'
}

@test "cli: startup stops when its config directory cannot be created" {
  mkdir() { return 23; }
  export -f mkdir
  run_octojoom --type joomla --task up
  assert_failure
  refute_command 'docker compose .* up'
}

@test "cli: saved config cannot replace internal action or path state" {
  make_joomla_container jcb JCB jcb
  link_enabled joomla jcb.vdm.dev
  printf '%s\n' 'VDM_CLI_ACTION=uninstall' 'VDM_CLI_KEYS=ignored' \
    'VDM_CLI_VALUES=ignored' "VDM_SRC_PATH=\"${SANDBOX}/redirected\"" \
    'VDM_FIRST_RUN=true' >>"${VDM_SRC_PATH}/.env"
  run_octojoom --type joomla --task up
  assert_success
  assert_command '^docker compose .* up -d'
  refute_file_exists "${SANDBOX}/redirected"
  refute_file_contains "${STUB_DIR}/dialogs.full" 'Uninstalling'
}

@test "cli: --type joomla --task up brings the enabled containers up" {
  make_joomla_container jcb JCB jcb
  link_enabled joomla jcb.vdm.dev
  run_octojoom --type joomla --task up
  assert_success
  assert_command '^docker compose .*jcb\.vdm\.dev/docker-compose\.yml up -d'
}

@test "cli: --container <name> enables that container" {
  make_joomla_container jcb JCB jcb
  run_octojoom --container jcb.vdm.dev
  assert_success
  [ -e "${VDM_REPO_PATH}/joomla/enabled/jcb.vdm.dev" ]
  assert_command '^docker compose .*enabled/jcb\.vdm\.dev/docker-compose\.yml up -d'
}

@test "cli: --container with an unknown name fails without enabling anything" {
  make_joomla_container jcb JCB jcb
  run_octojoom --container nothere.vdm.dev
  assert_failure
  refute_file_exists "${VDM_REPO_PATH}/joomla/enabled/nothere.vdm.dev"
  refute_command 'docker compose .* up'
}

@test "cli: without options the main menu is shown and quit exits 0" {
  answers quit
  run_octojoom
  assert_success
  assert_answers_used
}

@test "cli: an unknown task fails without opening the main menu" {
  run_octojoom --type joomla --task nonsense
  assert_status 17
  assert_output_contains "Unsupported container type or task"
  refute_file_contains "${STUB_DIR}/dialogs.log" "--menu"
  refute_command 'docker compose .* up'
}

@test "main: runs the task function of the type" {
  record_calls joomla__TRuST__up mainMenu
  VDM_CONTAINER_TYPE=joomla
  VDM_TASK=up
  run main
  assert_success
  assert_equal "$(cat "${SANDBOX}/calls")" "joomla__TRuST__up"
}

@test "main: shows the main menu without a type and task" {
  record_calls mainMenu
  VDM_CONTAINER_TYPE=''
  VDM_TASK=''
  run main
  assert_success
  assert_equal "$(cat "${SANDBOX}/calls")" "mainMenu"
}

@test "main: preserves a task failure status" {
  joomla__TRuST__up() { return 19; }
  VDM_CONTAINER_TYPE=joomla
  VDM_TASK=up
  run main
  assert_status 19
}

@test "main: incomplete type and task fail without showing a menu" {
  record_calls mainMenu
  VDM_CONTAINER_TYPE=joomla
  VDM_TASK=''
  run main
  assert_status 17
  refute_file_exists "${SANDBOX}/calls"
}

@test "mainMenu: an interrupted menu exits instead of reopening forever" {
  answers '<esc>'
  run mainMenu
  assert_status 255
  assert_answers_used
}

@test "showJoomla: an interrupted menu returns its failure status" {
  answers '<esc>'
  run showJoomla
  assert_status 255
  assert_answers_used
}

@test "showJoomla: setup runs the Joomla setup task, then back returns" {
  record_calls joomla__TRuST__setup
  answers setup back
  run showJoomla
  assert_success
  assert_equal "$(cat "${SANDBOX}/calls")" "joomla__TRuST__setup"
}

@test "showJoomla: up runs the Joomla up task" {
  make_joomla_container jcb JCB jcb
  link_enabled joomla jcb.vdm.dev
  record_calls joomla__TRuST__up
  answers up back
  run showJoomla
  assert_success
  assert_equal "$(cat "${SANDBOX}/calls")" "joomla__TRuST__up"
}

@test "showJoomla: back runs no task" {
  record_calls joomla__TRuST__setup joomla__TRuST__up
  answers back
  run showJoomla
  assert_success
  refute_file_exists "${SANDBOX}/calls"
}

@test "mainMenu: joomla, setup, back, quit runs the setup task once and exits 0" {
  record_calls joomla__TRuST__setup
  answers joomla setup back quit
  run mainMenu
  assert_success
  assert_equal "$(cat "${SANDBOX}/calls")" "joomla__TRuST__setup"
  assert_answers_used
}
