#!/bin/bash

# check that our enabled containers path is correct
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled" ] || {
  echo "[error] Enabled containers path ${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled does not exist."
  exit 1
}

# get container enabled selection
function getContainerEnabled() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select container to disable: "
  # Start our little Menu
  select menu in $(ls "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/"); do
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
# check that we have what we need
# shellcheck disable=SC2015
[ ${#CONTAINER} -ge 1 ] && [ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}" ] || {
  CONTAINER=$(getContainerEnabled)
  # make sure value was entered
  [ ${#CONTAINER} -ge 1 ] && [ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}" ] || exit
}

# make sure the docker image is stopped
docker-compose --file "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/docker-compose.yml" down
# then remove soft link
rm "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}"
