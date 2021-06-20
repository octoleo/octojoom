#!/bin/bash

# check that our repository path is correct
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled" ] || {
  echo "[error] Repository path (${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled) does not exist, first enable some containers."
  exit 1
}
# check that our projects path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Projects path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# the main function
main() {
  # get all zip files
  for yml in "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/"*/*.yml; do
    # get the vdm_container value
    vdm_container="${yml%/docker-compose.yml}"
    # check if image has its own env file also
    [ -f "${vdm_container}/.env" ] && ENV_FILE="${vdm_container}/.env" || ENV_FILE="${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
    docker-compose --env-file "${ENV_FILE}" --file "${yml}" up -d
  done
}

# run main
main
