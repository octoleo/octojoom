#!/bin/bash

# check that our repository path is correct
[ -e "${VDM_REPO_PATH}" ] || {
  echo "[error] Repository path (${VDM_REPO_PATH}) does not exist."
  exit 1
}
# check that our projects path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "[error] Projects path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}
# be sure to create the container type path
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}"
# be sure to .ssh path exist
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.ssh"

# check if we have global env file
# shellcheck disable=SC1090
# shellcheck disable=SC2015
[ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && source "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" || {
  touch "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  chmod 600 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
}

# help message ʕ•ᴥ•ʔ
function show_help() {
  cat <<EOF
Usage: ${0##*/:-} [OPTION...]
	Options
	======================================================
   -u|--username <username>
	set username of the container
	example: ${0##*/:-} -u="ubuntu"
	example: ${0##*/:-} --username="ubuntu"
	======================================================
   --uid <id>
	set container user id
	example: ${0##*/:-} --uid=1000
	======================================================
   --gid <id>
	set container user group id
	example: ${0##*/:-} --gid=1000
	======================================================
   -p|--port <port>
	set ssh port to use
	!! do not use 22 !!
	example: ${0##*/:-} -p=2239
	example: ${0##*/:-} --port=2239
	======================================================
   --ssh-dir <dir>
	set ssh directory name found in the .ssh dir
	of this repo for the container keys
		This directory has separate files for
		each public key allowed to access
		the container
	example: ${0##*/:-} --ssh-dir="teamname"
	======================================================
   --sudo
	switch to add the container user to the
	sudo group of the container
	example: ${0##*/:-} --sudo
	======================================================
   -k|--key <key>
	set key for the docker compose container naming
	!! no spaces allowed in the key !!
	example: ${0##*/:-} -k="vdm"
	example: ${0##*/:-} --key="vdm"
	======================================================
   -e|--env-key <key>
	set key for the environment variable naming
	!! no spaces allowed in the key & must be UPPERCASE !!
	example: ${0##*/:-} -e="VDM"
	example: ${0##*/:-} --env-key="VDM"
	======================================================
   -d|--domain <domain.com>
	set key website domain
	!! must be domain.tld !!
	example: ${0##*/:-} -d="vdm.dev"
	example: ${0##*/:-} --domain="vdm.dev"
	======================================================
   -t|--time-zone <time/zone>
	set time zone of the container
	!! must valid time zone !!
	example: ${0##*/:-} -t="Africa/Windhoek"
	example: ${0##*/:-} --time-zone="Africa/Windhoek"
	======================================================
   -h|--help
	display this help menu
	example: ${0##*/:-} -h
	example: ${0##*/:-} --help
	======================================================
			${BOT_NAME}
	======================================================
EOF
}

# set the local values
while :; do
  case $1 in
  -h | --help)
    show_help # Display a usage synopsis.
    exit
    ;;
  --sudo)
    VDM_SUDO_ACCESS=true
    shift
    ;;
  -u | --username) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_USER_NAME=$2
      shift
    else
      echo '[error] "--username" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -u=?* | --username=?*)
    VDM_USER_NAME=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -u= | --username=) # Handle the case of an empty --username=
    echo '[error] "--username=" requires a non-empty option argument.'
    exit 17
    ;;
  --uid) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_PUID=$2
      shift
    else
      echo '[error] "--uid" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --uid=?*)
    VDM_PUID=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --uid=) # Handle the case of an empty --uid=
    echo '[error] "--uid=" requires a non-empty option argument.'
    exit 17
    ;;
  --gid) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_PGID=$2
      shift
    else
      echo '[error] "--gid" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --gid=?*)
    VDM_PGID=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --gid=) # Handle the case of an empty --gid=
    echo '[error] "--gid=" requires a non-empty option argument.'
    exit 17
    ;;
  -p | --port) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_PORT=$2
      shift
    else
      echo '[error] "--port" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -p=?* | --port=?*)
    VDM_PORT=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -p= | --port=) # Handle the case of an empty --port=
    echo '[error] "--port=" requires a non-empty option argument.'
    exit 17
    ;;
  --ssh-dir) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_PUBLIC_KEY_DIR=$2
      shift
    else
      echo '[error] "--ssh-dir" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --ssh-dir=?*)
    VDM_PUBLIC_KEY_DIR=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -ssh-dir=) # Handle the case of an empty --ssh-dir=
    echo '[error] "--ssh-dir=" requires a non-empty option argument.'
    exit 17
    ;;
  -k | --key) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_KEY=$2
      shift
    else
      echo '[error] "--key" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -k=?* | --key=?*)
    VDM_KEY=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -k= | --key=) # Handle the case of an empty --key=
    echo '[error] "--key=" requires a non-empty option argument.'
    exit 17
    ;;
  -e | --env-key) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_ENV_KEY=$2
      shift
    else
      echo '[error] "--env-key" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -e=?* | --env-key=?*)
    VDM_ENV_KEY=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -e= | --env-key=) # Handle the case of an empty --env-key=
    echo '[error] "--env-key=" requires a non-empty option argument.'
    exit 17
    ;;
  -d | --domain) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_DOMAIN=$2
      shift
    else
      echo '[error] "--domain" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -d=?* | --domain=?*)
    VDM_DOMAIN=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -d= | --domain=) # Handle the case of an empty --domain=
    echo '[error] "--domain=" requires a non-empty option argument.'
    exit 17
    ;;
  -t | --time-zone) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_TZ=$2
      shift
    else
      echo '[error] "--time-zone" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -t=?* | --time-zone=?*)
    VDM_TZ=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -t= | --time-zone=) # Handle the case of an empty --time-zone=
    echo '[error] "--time-zone=" requires a non-empty option argument.'
    exit 17
    ;;
  *) # Default case: No more options, so break out of the loop.
    break ;;
  esac
  shift
done

# check that we have what we need
[ ${#VDM_PORT} -ge 1 ] || {
  echo -n "[enter] SSH Port: "
  read -r VDM_PORT
  # make sure value was entered
  [ ${#VDM_PORT} -ge 1 ] || exit
}
[ ${#VDM_USER_NAME} -ge 1 ] || {
  echo -n "[enter:ubuntu] UserName: "
  read -r VDM_USER_NAME
}
[ ${#VDM_KEY} -ge 1 ] || {
  echo -n "[enter:${VDM_USER_NAME:-ubuntu}] key: "
  read -r VDM_KEY
  # make sure value was entered
  [ ${#VDM_KEY} -ge 1 ] || VDM_KEY="${VDM_USER_NAME:-ubuntu}"
}
[ ${#VDM_ENV_KEY} -ge 1 ] || {
  echo -n "[enter:A] env key: "
  read -r VDM_ENV_KEY
  # make sure value was entered
  [ ${#VDM_ENV_KEY} -ge 1 ] || VDM_ENV_KEY="A"
}
# we must get the global public key path
VDM_ENV_PUBLIC_KEY_GLOBAL_DIR="VDM_${VDM_ENV_KEY^^}_PUBLIC_KEY_GLOBAL_DIR"
VDM_PUBLIC_KEY_GLOBAL_DIR=${!VDM_ENV_PUBLIC_KEY_GLOBAL_DIR}
# shellcheck disable=SC2015
[ ${#VDM_PUBLIC_KEY_GLOBAL_DIR} -ge 1 ] && [ -d "${VDM_PUBLIC_KEY_GLOBAL_DIR}" ] || {
  VDM_PUBLIC_KEY_GLOBAL_DIR="${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.ssh"
  # make sure value was entered
  [ ${#VDM_PUBLIC_KEY_GLOBAL_DIR} -ge 1 ] && [ -d "${VDM_PUBLIC_KEY_GLOBAL_DIR}" ] || exit
  # add to env file
  echo "${VDM_ENV_PUBLIC_KEY_GLOBAL_DIR}=${VDM_PUBLIC_KEY_GLOBAL_DIR}" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
}
# get available public dir
function getPublicKeyDir() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="[select] Public ssh key directory: "
  # we start the selection array
  local SELECTED
  # Start our little Menu
  select public_dir in $(ls "${VDM_PUBLIC_KEY_GLOBAL_DIR}"); do
    case $REPLY in
    *)
      SELECTED="${public_dir}"
      ;;
    esac
    break
  done
  # restore the default
  export PS3=$PS3_old
  # return selection
  echo "${SELECTED}"
}

[ ${#VDM_PUBLIC_KEY_DIR} -ge 1 ] || {
  VDM_PUBLIC_KEY_DIR=$(getPublicKeyDir)
  # make sure value was entered
  [ ${#VDM_PUBLIC_KEY_DIR} -ge 1 ] && [ -d "${VDM_PUBLIC_KEY_GLOBAL_DIR}/${VDM_PUBLIC_KEY_DIR}" ] || exit
}
# set the global key env string for the ssh keys
VDM_ENV_PUBLIC_KEY_U_DIR="VDM_${VDM_ENV_KEY^^}_PUBLIC_KEY_${VDM_PUBLIC_KEY_DIR^^}_DIR"
VDM_PUBLIC_KEY_U_DIR=${!VDM_ENV_PUBLIC_KEY_U_DIR}
# check if env is already set
# shellcheck disable=SC2015
[ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && grep -q "${VDM_ENV_PUBLIC_KEY_U_DIR}=" "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" || {
  # add to env if not exist
  [ ${#VDM_PUBLIC_KEY_U_DIR} -ge 1 ] && [ -d "${VDM_PUBLIC_KEY_U_DIR}" ] || {
    echo "${VDM_ENV_PUBLIC_KEY_U_DIR}=${VDM_PUBLIC_KEY_GLOBAL_DIR}/${VDM_PUBLIC_KEY_DIR}" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  }
}
# we must get the project path
VDM_ENV_PROJECT_DIR="VDM_${VDM_ENV_KEY^^}_PROJECT_DIR"
VDM_PROJECT_DIR=${!VDM_ENV_PROJECT_DIR}
# shellcheck disable=SC2015
[ ${#VDM_PROJECT_DIR} -ge 1 ] && [ -d "${VDM_PROJECT_DIR}" ] || {
  VDM_PROJECT_DIR="${VDM_PROJECT_PATH}"
  # make sure value was entered
  [ ${#VDM_PROJECT_DIR} -ge 1 ] && [ -d "${VDM_PROJECT_DIR}" ] || exit
  # add to env file
  echo "VDM_${VDM_ENV_KEY^^}_PROJECT_DIR=${VDM_PROJECT_DIR}" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
}
# return volume line
function getVolumeLine() {
  # get the projects to mount
  local line="$1"
  # return line
  cat <<EOF

      - ${line}
EOF
}
# get available mounting projects
function getMountingProjects() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  # some defaults
  export PS3="[select] Projects to mount: "
  # some buckets
  FINISHED="n"
  SELECTED=$(getVolumeLine "\${${VDM_ENV_PUBLIC_KEY_U_DIR}}:/config/ssh_public_keys")
  until [ "${FINISHED}" = "y" ]; do
    # Start our little Menu
    select key in $(ls "${VDM_PROJECT_DIR}"); do
      case $REPLY in
      q | quit)
        FINISHED="y"
        ;;
      *)
        SELECTED+=$(getVolumeLine "\${VDM_${VDM_ENV_KEY^^}_PROJECT_DIR}/${key}/joomla:/app/${key}")
        FINISHED="n"
        ;;
      esac
      break
    done
  done
  # restore the default
  export PS3=$PS3_old
  # return selection
  echo "${SELECTED}"
}
# now load the projects
[ ${#VDM_MOUNT_PROJECTS} -ge 1 ] || {
  echo "[enter] q to quit selecting"
  # get the projects to mount
  VDM_MOUNT_PROJECTS=$(getMountingProjects)
  # get the mounting options
  [ ${#VDM_MOUNT_PROJECTS} -ge 1 ] || exit 1
}

# all values loaded notice
echo "[All value loaded]"

# build function
function buildContainer() {
  # get the projects to mount
  local mount_projects="$1"
  # we build the yml file
  # we use 33 as this is the www-data ID
  cat <<EOF
version: "2.1"
services:
  openssh-server-${VDM_KEY}:
    image: lscr.io/linuxserver/openssh-server
    container_name: openssh-server-${VDM_KEY}
    restart: unless-stopped
    hostname: ${VDM_DOMAIN:-vdm.dev}
    environment:
      - PUID=${VDM_PUID:-33}
      - PGID=${VDM_PGID:-33}
      - TZ=${VDM_TZ:-Africa/Windhoek}
      - PUBLIC_KEY_DIR=/config/ssh_public_keys
      - SUDO_ACCESS=${VDM_SUDO_ACCESS:-false}
      - USER_NAME=${VDM_USER_NAME:-ubuntu}
    volumes:${mount_projects}
    ports:
      - ${VDM_PORT}:2222
    networks:
      - openssh

networks:
  openssh:
    external:
      name: openssh_gateway
EOF
}

# create the directory if it does not yet already exist
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_USER_NAME:-ubuntu}.${VDM_DOMAIN:-vdm.dev}"
# place this docker composer file in its place
buildContainer "${VDM_MOUNT_PROJECTS}" >"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_USER_NAME:-ubuntu}.${VDM_DOMAIN:-vdm.dev}/docker-compose.yml"
# set permissions
chmod 600 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_USER_NAME:-ubuntu}.${VDM_DOMAIN:-vdm.dev}/docker-compose.yml"
# saved the file
echo "[save] ${VDM_CONTAINER_TYPE}:docker-compose.yml"
# some house cleaning
PS3_old=$PS3
# ask if we should right now enable the container
echo "[question] Would you like to enable this new ${VDM_CONTAINER_TYPE} container?"
# set the terminal
export PS3="[select]: "
# shellcheck disable=SC1090
select yn in "Yes" "No"; do
  case $yn in
      Yes ) source "${VDM_SRC_PATH}/enable.sh" "${VDM_USER_NAME:-ubuntu}.${VDM_DOMAIN:-vdm.dev}";;
  esac
  break
done
# restore the default
export PS3=$PS3_old
echo "[setup] Completed!"
