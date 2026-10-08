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
  for option in --key= -k= --type= --container=; do
    run_octojoom "${option}"
    assert_status 17
  done
  refute_command 'docker compose .* up'
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

@test "cli: --container with an unknown name enables nothing" {
  make_joomla_container jcb JCB jcb
  run_octojoom --container nothere.vdm.dev
  assert_success
  refute_file_exists "${VDM_REPO_PATH}/joomla/enabled/nothere.vdm.dev"
  refute_command 'docker compose .* up'
}

@test "cli: without options the main menu is shown and quit exits 0" {
  answers quit
  run_octojoom
  assert_success
  assert_answers_used
}

@test "cli: an unknown task falls back to the main menu" {
  answers quit
  run_octojoom --type joomla --task nonsense
  assert_success
  assert_answers_used
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
