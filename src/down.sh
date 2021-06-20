#!/bin/bash

# check that our enabled containers path is correct
[ -e "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled" ] || {
  echo "[error] Enabled containers path ${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled does not exist. This means no container is enabled."
  exit 1
}

# the main function
main() {
	# get all zip files
	for yml in "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/enabled/"*/*.yml; do
		docker-compose --file "${yml}" down
	done
}

# run main
main