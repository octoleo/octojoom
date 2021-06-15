#!/bin/bash

# check that our repository path is correct
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/" ] || {
  echo "[error] The path ${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/ does not exist, first run setup."
  exit 1
}
# check that our projects path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Projects path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# get container available selection
function getContainerAvailable() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select container to enable: "
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
# check that we have what we need
# shellcheck disable=SC2015
[ ${#CONTAINER} -ge 1 ] && [ -d "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" ] || {
  CONTAINER=$(getContainerAvailable)
  # make sure value was entered
  [ ${#CONTAINER} -ge 1 ] && [ -d "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" ] || exit
}

# create the folder as needed
mkdir -p "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/"

# create the soft link
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}" ] || ln -s "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${CONTAINER}" "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}"
# check if image has its own env file also
ENV_FILE=''
# shellcheck disable=SC2015
[ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/.env" ] && ENV_FILE="${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/.env" || {
  [ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && ENV_FILE="${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
}

# make sure the docker image is started
# shellcheck disable=SC2015
[ ${#ENV_FILE} -ge 1 ] && docker-compose --env-file "${ENV_FILE}" --file "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/docker-compose.yml" up -d || {
  docker-compose --file "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/${CONTAINER}/docker-compose.yml" up -d
}
# show env path used
echo "[notice] EVN PATH: ${ENV_FILE}"
