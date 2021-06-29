#!/bin/bash

# BOT name
BOT_NAME="docker-deploy v1.0"

# the src folder path (where all the script are found)
export VDM_SRC_PATH="/home/update/this/path/to/src"

# we load global environment values
# shellcheck disable=SC2015
[ -f "${VDM_SRC_PATH}/.env" ] && source "${VDM_SRC_PATH}/.env" || {
  echo "${VDM_SRC_PATH}/.env file not found, please run install."
  exit 1
}

# check that our repository path is correct
[ -e "${VDM_REPO_PATH}" ] || {
  echo "Repository path (${VDM_REPO_PATH}) does not exist."
  exit 1
}
# check that our projects path is correct
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo "Projects path (${VDM_PROJECT_PATH}) does not exist."
  exit 1
}

# help message ʕ•ᴥ•ʔ
function show_help() {
  cat <<EOF
Usage: ${0##*/:-} [OPTION...]
	Options
	======================================================
   --type <type>
	set type you would like to work with
	example: ${0##*/:-} --type joomla
	======================================================
   --task <task>
	set type of task you would like to perform
	example: ${0##*/:-} --task setup
	======================================================
   --update
	to update your install
	example: ${0##*/:-} --update
	======================================================
   --uninstall
	to uninstall this script
	example: ${0##*/:-} --uninstall
	======================================================
	AVAILABLE FOR TO ANY CONTAINER
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
	AVAILABLE FOR JOOMLA CONTAINER
	======================================================
   -j|--joomla-version <version>
	set Joomla version number
	!! only number allowed !!
	example: ${0##*/:-} -j=3.10
	example: ${0##*/:-} --joomla-version=3.10
	======================================================
   -s|--sub-domain <domain.com>
	set key website sub domain
	!! no spaces allowed in the sub domain !!
	example: ${0##*/:-} -s="jcb"
	example: ${0##*/:-} --sub-domain="jcb"
	======================================================
	AVAILABLE FOR OPENSSH CONTAINER
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
   -t|--time-zone <time/zone>
	set time zone of the container
	!! must valid time zone !!
	example: ${0##*/:-} -t="Africa/Windhoek"
	example: ${0##*/:-} --time-zone="Africa/Windhoek"
	======================================================
	HELP ʕ•ᴥ•ʔ
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

# check if we have options
while :; do
  case $1 in
  -h | --help)
    show_help # Display a usage synopsis.
    exit
    ;;
  --update)
    VDM_CONTAINER_TYPE="update"
    shift
    ;;
  --uninstall)
    VDM_CONTAINER_TYPE="uninstall"
    shift
    ;;
  --type) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_CONTAINER_TYPE=$2
      shift
    else
      echo '[error] "--type" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --type=?*)
    VDM_CONTAINER_TYPE=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --type=) # Handle the case of an empty --src-path=
    echo '[error] "--type=" requires a non-empty option argument.'
    exit 17
    ;;
  --task) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_TASK=$2
      shift
    else
      echo '[error] "--task" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --task=?*)
    VDM_TASK=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --task=) # Handle the case of an empty --src-path=
    echo '[error] "--task=" requires a non-empty option argument.'
    exit 17
    ;;
  -j | --joomla-version) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_JV=$2
      shift
    else
      echo '[error] "--joomla-version" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -j=?* | --joomla-version=?*)
    export VDM_JV=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -j= | --joomla-version=) # Handle the case of an empty --joomla-version=
    echo '[error] "--joomla-version=" requires a non-empty option argument.'
    exit 17
    ;;
  -k | --key) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_KEY=$2
      shift
    else
      echo '[error] "--key" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -k=?* | --key=?*)
    export VDM_KEY=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -k= | --key=) # Handle the case of an empty --key=
    echo '[error] "--key=" requires a non-empty option argument.'
    exit 17
    ;;
  -e | --env-key) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_ENV_KEY=$2
      shift
    else
      echo '[error] "--env-key" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -e=?* | --env-key=?*)
    export VDM_ENV_KEY=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -e= | --env-key=) # Handle the case of an empty --env-key=
    echo '[error] "--env-key=" requires a non-empty option argument.'
    exit 17
    ;;
  -d | --domain) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_DOMAIN=$2
      shift
    else
      echo '[error] "--domain" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -d=?* | --domain=?*)
    export VDM_DOMAIN=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -d= | --domain=) # Handle the case of an empty --domain=
    echo '[error] "--domain=" requires a non-empty option argument.'
    exit 17
    ;;
  -s | --sub-domain) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_SUBDOMAIN=$2
      shift
    else
      echo '[error] "--sub-domain" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -s=?* | --sub-domain=?*)
    export VDM_SUBDOMAIN=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -s= | --sub-domain=) # Handle the case of an empty --sub-domain=
    echo '[error] "--sub-domain=" requires a non-empty option argument.'
    exit 17
    ;;
  --sudo)
    export VDM_SUDO_ACCESS=true
    shift
    ;;
  -u | --username) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_USER_NAME=$2
      shift
    else
      echo '[error] "--username" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -u=?* | --username=?*)
    export VDM_USER_NAME=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -u= | --username=) # Handle the case of an empty --username=
    echo '[error] "--username=" requires a non-empty option argument.'
    exit 17
    ;;
  --uid) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_PUID=$2
      shift
    else
      echo '[error] "--uid" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --uid=?*)
    export VDM_PUID=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --uid=) # Handle the case of an empty --uid=
    echo '[error] "--uid=" requires a non-empty option argument.'
    exit 17
    ;;
  --gid) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_PGID=$2
      shift
    else
      echo '[error] "--gid" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --gid=?*)
    export VDM_PGID=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --gid=) # Handle the case of an empty --gid=
    echo '[error] "--gid=" requires a non-empty option argument.'
    exit 17
    ;;
  -p | --port) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_PORT=$2
      shift
    else
      echo '[error] "--port" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -p=?* | --port=?*)
    export VDM_PORT=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -p= | --port=) # Handle the case of an empty --port=
    echo '[error] "--port=" requires a non-empty option argument.'
    exit 17
    ;;
  --ssh-dir) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_PUBLIC_KEY_DIR=$2
      shift
    else
      echo '[error] "--ssh-dir" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --ssh-dir=?*)
    export VDM_PUBLIC_KEY_DIR=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -ssh-dir=) # Handle the case of an empty --ssh-dir=
    echo '[error] "--ssh-dir=" requires a non-empty option argument.'
    exit 17
    ;;
  -t | --time-zone) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      export VDM_TZ=$2
      shift
    else
      echo '[error] "--time-zone" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -t=?* | --time-zone=?*)
    export VDM_TZ=${1#*=} # Delete everything up to "=" and assign the remainder.
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

# get container type
function getContainerType() {
  # some house cleaning
  PS3_old=$PS3
  # some defaults
  export PS3="Please select the type: "
  # Start our little Menu
  select menu in "joomla" "openssh" "traefik" "portainer" "update" "uninstall"; do
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

# check that we have what we need
[ ${#VDM_CONTAINER_TYPE} -ge 1 ] || {
  VDM_CONTAINER_TYPE=$(getContainerType)
  # make sure value was entered
  [ ${#VDM_CONTAINER_TYPE} -ge 1 ] || {
    echo "[error] Wrong type selected"
    exit 1
  }
}

export VDM_CONTAINER_TYPE

# get task type
function getTaskType() {
  # some house cleaning
  PS3_old=$PS3
  # build the selection based on the VDM_CONTAINER_TYPE
  case "$VDM_CONTAINER_TYPE" in
  "joomla")
    options=("setup" "enable" "disable" "up" "down" "fix")
    shift
    ;;
  "openssh")
    options=("setup" "enable" "disable" "up" "down")
    shift
    ;;
  *)
    echo "[error] Wrong type selected (${VDM_CONTAINER_TYPE})"
    exit 1
    ;;
  esac
  # some defaults
  export PS3="Please select the kind of task to perform on ${VDM_CONTAINER_TYPE}: "
  # Start our little Menu
  select menu in "${options[@]}"; do
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

case "$VDM_CONTAINER_TYPE" in
"traefik")
  VDM_TASK="setup-traefik"
  ;;
"portainer")
  VDM_TASK="setup-portainer"
  ;;
"update")
  VDM_TASK="install"
  ;;
"uninstall")
  VDM_TASK="uninstall"
  ;;
esac

# check that we have what we need
[ ${#VDM_TASK} -ge 1 ] || {
  VDM_TASK=$(getTaskType)
  # make sure value was entered
  [ ${#VDM_TASK} -ge 1 ] || {
    echo "[error] Wrong task type selected for ${VDM_CONTAINER_TYPE}"
    exit 1
  }
}

# run that task type script
# shellcheck disable=SC1090
source "${VDM_SRC_PATH}/${VDM_TASK}.sh"

exit 0
