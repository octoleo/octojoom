#!/usr/bin/env bats
#
# The dialog helpers: input, yes/no, password and folder selection boxes, the
# message boxes, the progress switch, and the small "set" questions built on them.
#
# SC2034: the VDM_* globals are read by the loaded script functions.
# shellcheck disable=SC2034

load ../helpers/common

setup() {
  octojoom_setup
}

# image sources in the form getImageSource returns them (used as answers)
JOOMLA_IMAGE="joomla|https://hub.docker.com/_/joomla?tab=tags;https://raw.githubusercontent.com/joomla-docker/docker-joomla/master/docker-entrypoint.sh"
OCTOLEO_IMAGE="llewellyn/joomla|https://hub.docker.com/r/llewellyn/joomla/tags;https://raw.githubusercontent.com/octoleo/docker-joomla/refs/heads/octoleo/docker-entrypoint.sh"

###############################################################################
# input boxes

@test "getInput: returns the answer typed" {
  answers "my answer"
  run getInput "Your name?" '' 'Name'
  assert_success
  assert_equal "${output}" "my answer"
}

@test "getInputYesNo: returns 0 for yes and 1 for no" {
  answers yes no
  run getInputYesNo "Continue?"
  assert_status 0
  run getInputYesNo "Continue?"
  assert_status 1
}

@test "getInputYesNo: when forced answers without a dialog (yes, or no with defaultno)" {
  VDM_FORCE=true
  answers
  run getInputYesNo "Continue?"
  assert_status 0
  run getInputYesNo "Continue?" "Title" 8 50 defaultno
  assert_status 1
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "getInputNow: keeps asking until it gets an answer" {
  answers '' "joomla"
  run getInputNow "Enter a name" '' 'name'
  assert_success
  assert_equal "${output}" "joomla"
  assert_answers_used
}

@test "getPassword: returns the password typed" {
  answers "s3cret!"
  run getPassword "Password?"
  assert_success
  assert_equal "${output}" "s3cret!"
}

###############################################################################
# folder selection

@test "getSelectedDirectory: returns the sub-folder chosen" {
  mkdir -p "${SANDBOX}/sites/alpha" "${SANDBOX}/sites/beta"
  answers "beta"
  run getSelectedDirectory "Pick a folder" "${SANDBOX}/sites" "alpha"
  assert_success
  assert_equal "${output}" "beta"
}

@test "getSelectedDirectory: returns the current folder without a dialog when there are no sub-folders" {
  mkdir -p "${SANDBOX}/empty"
  answers
  run getSelectedDirectory "Pick a folder" "${SANDBOX}/empty" "current"
  assert_success
  assert_equal "${output}" "current"
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "getSelectedDirectories: returns the folders chosen" {
  mkdir -p "${SANDBOX}/sites/alpha" "${SANDBOX}/sites/beta" "${SANDBOX}/sites/gamma"
  answers '"alpha" "gamma"'
  run getSelectedDirectories "Pick folders" "${SANDBOX}/sites"
  assert_success
  assert_output_contains "alpha"
  assert_output_contains "gamma"
}

@test "getSelectedDirectories: returns nothing without a dialog when there are no sub-folders" {
  mkdir -p "${SANDBOX}/empty"
  answers
  run getSelectedDirectories "Pick folders" "${SANDBOX}/empty"
  assert_success
  assert_equal "${output}" ""
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

###############################################################################
# message boxes and progress

@test "showError and showNotice: show a message box" {
  run showError "Something broke"
  assert_success
  run showNotice "Just so you know"
  assert_success
  assert_dialog "Something broke"
  assert_dialog "Just so you know"
}

@test "progressSwitchOn and progressSwitchOff: toggle inProgress" {
  run inProgress
  assert_failure
  progressSwitchOn
  run inProgress
  assert_success
  progressSwitchOff
  run inProgress
  assert_failure
  # switching off twice is fine
  run progressSwitchOff
  assert_success
}

###############################################################################
# image source

@test "getImageSource: returns the official Joomla image without asking outside expert mode" {
  VDM_EXPERT_MODE=false
  answers
  run getImageSource
  assert_success
  # only the image name: the tag and entry-point URLs may change upstream
  assert_equal "${output%%|*}" "joomla"
  [ ! -s "${STUB_DIR}/dialogs.log" ]
}

@test "getImageSource: in expert mode returns the image chosen, including saved sources" {
  VDM_EXPERT_MODE=true
  local custom="custom/joomla|https://example.test/tags;https://example.test/docker-entrypoint.sh"
  echo "${custom},My custom image" >"${VDM_SRC_PATH}/.images-source"
  answers "${custom}"
  run getImageSource
  assert_success
  assert_equal "${output}" "${custom}"
}

@test "setImageSource: sets the image, entry-point and version tag" {
  VDM_EXPERT_MODE=true
  VDM_J_REPO=''
  VDM_JV=''
  answers "${OCTOLEO_IMAGE}" "5.3"
  setImageSource
  assert_equal "${VDM_J_REPO}" "llewellyn/joomla"
  assert_equal "${VDM_ENTRY_REPO}" "https://raw.githubusercontent.com/octoleo/docker-joomla/refs/heads/octoleo/docker-entrypoint.sh"
  assert_equal "${VDM_JV}" "5.3"
  assert_answers_used
}

@test "setImageSource: asks again for a source without an entry-point" {
  VDM_EXPERT_MODE=true
  VDM_J_REPO=''
  VDM_JV=''
  local broken="broken/joomla|https://example.test/tags;https://example.test/start.sh"
  echo "${broken},Broken image" >"${VDM_SRC_PATH}/.images-source"
  answers "${broken}" "${JOOMLA_IMAGE}" "latest"
  setImageSource
  assert_equal "${VDM_J_REPO}" "joomla"
  assert_equal "${VDM_JV}" "latest"
}

###############################################################################
# container questions

@test "setContainerUser: sets the user and group IDs typed" {
  VDM_CONTAINER_TYPE=joomla
  VDM_PUID=''
  VDM_PGID=''
  answers 1001 1002
  setContainerUser
  assert_equal "${VDM_PUID}" "1001"
  assert_equal "${VDM_PGID}" "1002"
  assert_answers_used
}

@test "setContainerUser: asks again for an ID that is not a number" {
  VDM_CONTAINER_TYPE=joomla
  VDM_PUID=''
  VDM_PGID=''
  answers "abc" 1000 1000
  setContainerUser
  assert_equal "${VDM_PUID}" "1000"
  assert_equal "${VDM_PGID}" "1000"
}

@test "setContainerUser: keeps the remembered IDs when the change is declined" {
  VDM_CONTAINER_TYPE=joomla
  VDM_PUID=33
  VDM_PGID=44
  answers no no
  setContainerUser
  assert_equal "${VDM_PUID}" "33"
  assert_equal "${VDM_PGID}" "44"
}

@test "setPersistence: returns 0 for yes and 1 for no" {
  answers yes no
  run setPersistence "container"
  assert_status 0
  run setPersistence "container"
  assert_status 1
}

@test "setNumberContainers: sets the number given" {
  answers 5
  setNumberContainers
  assert_equal "${VDM_NUMBER_CONTAINERS}" "5"
}

@test "setNumberContainers: asks again until the number is from 2 to 99" {
  answers "abc" 1 100 7
  setNumberContainers
  assert_equal "${VDM_NUMBER_CONTAINERS}" "7"
  assert_answers_used
}
