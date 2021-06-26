#!/bin/bash

# BOT name
BOT_NAME="docker-deploy v1.0"

# we load global environment values
# shellcheck disable=SC2015
[ -f "${VDM_SRC_PATH}/.env" ] && source "${VDM_SRC_PATH}/.env" || {
  echo "${VDM_SRC_PATH}/.env file not found, please run install."
  exit 1
}

# take down all containers
# shellcheck disable=SC1090
# ----------------------------------------------------- MULTI CONTAINERS
# check if we have possible joomla containers
if [ -e "${VDM_REPO_PATH}/joomla/enabled" ]; then
  echo -n "[enter:y] Take down Joomla containers [y/n]: "
  read -r VDM_DOWN_JOOMLA
  # set the default if empty
  VDM_DOWN_JOOMLA="${VDM_DOWN_JOOMLA:-y}"
  # make sure it exist
  if [ "${VDM_DOWN_JOOMLA,,}" != 'n' ]; then
    export VDM_CONTAINER_TYPE="joomla"
    source "${VDM_SRC_PATH}/down.sh"
  fi
  # remove all enabled
  rm -fr "${VDM_REPO_PATH}/joomla/enabled"
fi
# check if we have possible openssh containers
if [ -e "${VDM_REPO_PATH}/openssh/enabled" ]; then
  echo -n "[enter:y] Take down Openssh containers [y/n]: "
  read -r VDM_DOWN_OPENSSH
  # set the default if empty
  VDM_DOWN_OPENSSH="${VDM_DOWN_OPENSSH:-y}"
  # make sure it exist
  if [ "${VDM_DOWN_OPENSSH,,}" != 'n' ]; then
    export VDM_CONTAINER_TYPE="openssh"
    source "${VDM_SRC_PATH}/down.sh"
  fi
  # remove all enabled
  rm -fr "${VDM_REPO_PATH}/openssh/enabled"
fi
# ----------------------------------------------------- SINGLE CONTAINER
# check if we have possible portainer container
if [ -f "${VDM_REPO_PATH}/portainer/docker-compose.yml" ]; then
  echo -n "[enter:y] Take down Portainer container [y/n]: "
  read -r VDM_DOWN_PORTAINER
  # set the default if empty
  VDM_DOWN_PORTAINER="${VDM_DOWN_PORTAINER:-y}"
  # make sure it exist
  if [ "${VDM_DOWN_PORTAINER,,}" != 'n' ]; then
    docker-compose --file "${VDM_REPO_PATH}/portainer/docker-compose.yml" down
  fi
  # we just have one yml file here (so dont remove it for now)
  # rm -fr "${VDM_REPO_PATH}/portainer"
fi
# check if we have possible traefik container
if [ -f "${VDM_REPO_PATH}/traefik/docker-compose.yml" ]; then
  echo -n "[enter:y] Take down Traefik container [y/n]: "
  read -r VDM_DOWN_TRAEFIK
  # set the default if empty
  VDM_DOWN_TRAEFIK="${VDM_DOWN_TRAEFIK:-y}"
  # make sure it exist
  if [ "${VDM_DOWN_TRAEFIK,,}" != 'n' ]; then
    docker-compose --file "${VDM_REPO_PATH}/traefik/docker-compose.yml" down
  fi
  # we just have one yml file here (so dont remove it for now)
  # rm -fr "${VDM_REPO_PATH}/traefik"
fi
# ----------------------------------------------------- REMOVE SCRIPT
# now remove the docker-deploy script
sudo rm /usr/local/bin/docker-deploy

echo "[notice] ${BOT_NAME} has been uninstalled."

exit 0
