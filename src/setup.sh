#!/bin/bash

# check that our repository path is correct
[ -e "${VDM_SRC_PATH}" ] || {
  echo "[error] Source path (${VDM_SRC_PATH}) does not exist."
  exit 1
}
# check that our projects path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Projects path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# get container type
function getContainerType() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select the kind of container to setup: "
  # Start our little Menu (only these two for now)
  select menu in "joomla" "openssh"; do
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
VDM_CONTAINER_TYPE="${1:-$VDM_CONTAINER_TYPE}"
# check that we have what we need
[ ${#VDM_CONTAINER_TYPE} -ge 1 ] || {
  VDM_CONTAINER_TYPE=$(getContainerType)
  # make sure value was entered
  [ ${#VDM_CONTAINER_TYPE} -ge 1 ] || {
    echo "[error] Wrong container type selected"
    exit 1
  }
}

export VDM_CONTAINER_TYPE

# run that container setup script
# shellcheck disable=SC1090
source "${VDM_SRC_PATH}/setup-${VDM_CONTAINER_TYPE}.sh"
