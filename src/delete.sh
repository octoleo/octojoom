#!/bin/bash

# check that our enabled containers path is correct
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available" ] || {
  echo "[error] Available containers path ${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available does not exist."
  exit 1
}

# action to delete
function askToDelete() {
  # some house cleaning
  PS3_old=$PS3
  # set the local value
  local question
  local path
  local target
  # now set the values
  question="$1"
  path="$2"
  target="$3"
  # some defaults
  echo "${question}"
  # set the terminal
  export PS3="[select]: "
  # Start our little Menu
  select yn in "Yes" "No"; do
    case $yn in
        Yes ) sudo rm -rf "${path}"; echo "[notice] ${target} was deleted.";;
        No ) echo "[notice] ${target} was not deleted.";;
    esac
    break
  done
  # restore the default
  export PS3=$PS3_old
}

# get container available for deletion
function getContainer() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select ${VDM_CONTAINER_TYPE} container deploy files to delete: "
  # Start our little Menu
  select menu in $(ls "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/"); do
    case $REPLY in
    *)
      SELECTED="$menu"
      ;;
    esac
    break
  done
  # restore the default
  export PS3=$PS3_old
  # return selection
  echo "$SELECTED"
}

# set the container
CONTAINER="${1:-$CONTAINER}"
[ ${#CONTAINER} -ge 1 ] && [ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" ] || {
  CONTAINER=$(getContainer)
  # make sure value was entered
  [ ${#CONTAINER} -ge 1 ] && [ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" ] || exit
}

# disable
if [ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}" ]; then
  # make sure the docker image is stopped
  docker-compose --file "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/docker-compose.yml" down
  # then remove soft link
  rm "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}"
fi

# remove the files with one last confirmation
askToDelete \
  "Are you absolutely sure you would like to complete delete the ${VDM_CONTAINER_TYPE} ${CONTAINER} deploy files?" \
  "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" \
  "${CONTAINER}"

# check that our project path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Project path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# make sites available selection
function getProjectsAvailable() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select persistent volume folder to delete: "
  # Start our little Menu
  select menu in $(ls "${VDM_PROJECT_PATH}"); do
    case $REPLY in
    *)
      SELECTED="$menu"
      ;;
    esac
    break
  done
  # restore the default
  export PS3=$PS3_old
  # return selection
  echo "$SELECTED"
}

# set the local values
VDM_PROJECT="${2:-$VDM_PROJECT}"
# check that we have what we need
# shellcheck disable=SC2015
[ ${#VDM_PROJECT} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${VDM_PROJECT}" ] || {
  VDM_PROJECT=$(getProjectsAvailable)
  # make sure value was entered
  [ ${#VDM_PROJECT} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}/${VDM_PROJECT}" ] || exit
}

# remove the files with one last confirmation
askToDelete \
  "Are you absolutely sure you would like to delete the ${VDM_PROJECT} persistent volume folders?" \
  "${VDM_PROJECT_PATH}/${VDM_PROJECT}" \
  "${VDM_PROJECT}"
