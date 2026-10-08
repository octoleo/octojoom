#!/usr/bin/env bats
#
# Checks of the test harness itself: the sandbox, the stand-ins and the loader.
# If these fail, every other test result is meaningless.

load ../helpers/common

setup() {
  octojoom_setup
}

@test "harness: every function of the script is loaded" {
  isFunc main
  isFunc joomla__TRuST__setup
  isFunc cloneJoomlaContainer
}

@test "harness: the Octojoom paths live inside the sandbox" {
  [[ "${VDM_SRC_PATH}" == "${SANDBOX}"/* ]]
  [[ "${VDM_REPO_PATH}" == "${SANDBOX}"/* ]]
  [[ "${VDM_PROJECT_PATH}" == "${SANDBOX}"/* ]]
  [ -d "${VDM_REPO_PATH}" ]
  [ -d "${VDM_PROJECT_PATH}" ]
}

@test "harness: whiptail answers in order and logs every dialog" {
  answers "first" yes no
  run getInput "Question one" '' 'Title'
  assert_output_contains "first"
  run getInputYesNo "Question two"
  assert_success
  run getInputYesNo "Question three"
  assert_failure
  assert_answers_used
  assert_dialog "Question two"
}

@test "harness: a dialog without an answer returns ESC and is recorded" {
  answers
  # without a test to stop, the stand-in just answers like ESC
  STUB_KILL_PID='' run bash -c 'whiptail --inputbox "nobody answers" 8 40 3>&1 1>&2 2>&3'
  assert_status 255
  assert_file_contains "${STUB_DIR}/out_of_answers" "nobody answers"
}

@test "harness: a prompt loop without answers is stopped" {
  answers
  # setUniqueKey asks until it gets a key: the stand-in must stop it instead of letting it loop
  run bash -c '
    trap "exit 143" TERM
    export STUB_KILL_PID=$BASHPID
    source "$1"
    VDM_KEY=""
    setUniqueKey
  ' _ "${BATS_RUN_TMPDIR}/octojoom-functions.sh"
  assert_status 143
  assert_file_contains "${STUB_DIR}/out_of_answers" "Enter key"
}

@test "harness: sudo never touches anything outside the sandbox" {
  run sudo rm -f /usr/local/bin/octojoom-test-never-exists
  assert_success
  assert_command '^sudo-skipped rm -f /usr/local/bin/'
  run bash -c 'echo "127.0.0.1 x.vdm.dev" | sudo tee -a /etc/hosts'
  assert_success
  assert_file_contains "${STUB_DIR}/sudo-tee.log" "127.0.0.1 x.vdm.dev"
  # inside the sandbox it really runs
  run sudo mkdir -p "${SANDBOX}/made-by-sudo"
  [ -d "${SANDBOX}/made-by-sudo" ]
}

@test "harness: docker compose up and down change the running containers" {
  make_joomla_container jcb JCB jcb
  local yml="${VDM_REPO_PATH}/joomla/available/jcb.vdm.dev/docker-compose.yml"
  run docker compose --file "${yml}" up -d
  assert_success
  run isContainerRunning mariadbjcb
  assert_success
  run docker compose --file "${yml}" down
  run isContainerRunning mariadbjcb
  assert_failure
}

@test "harness: a stand-in can be made to fail" {
  fail_command docker-compose-up 3
  run docker compose --file x.yml up -d
  assert_status 3
}

@test "harness: the whole script runs inside the sandbox and shows its help" {
  octojoom_config
  run_octojoom --help
  assert_success
  assert_output_contains "Usage: octojoom"
  # it used the sandbox home, never the real one
  assert_file_exists "${OCTOJOOM_HOME}/.config/octojoom/.env"
}
