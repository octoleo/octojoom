#!/bin/bash

# BOT name
BOT_NAME="docker-deploy v1.0"

# only install/setup docker once
command -v docker >/dev/null 2>&1 || {
  # remove old docker
  sudo apt-get remove docker docker-engine docker.io containerd runc
  # add docker repo
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  # make sure we have dependencies installed
  sudo apt-get update
  sudo apt-get install \
    ca-certificates \
    curl \
    gnupg \
    lsb-release
  # now install docker
  sudo apt-get install docker-ce docker-ce-cli containerd.io
  # start docker
  sudo systemctl enable docker.service
  # persist docker
  udo systemctl enable containerd.service
  # make sure the user is in the docker group
  sudo groupadd docker
  sudo usermod -aG docker "$USER"
}

# only install docker-compose once
command -v docker-compose >/dev/null 2>&1 || {
  sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  sudo chmod +x /usr/local/bin/docker-compose
}

# get script path
VDM_SRC_PATH="${BASH_SOURCE%/*}"
if [[ ! -d "$VDM_SRC_PATH" || "$VDM_SRC_PATH" == '.' ]]; then VDM_SRC_PATH="$PWD"; fi

# some globals
VDM_FORCE_INSTALL=false
VDM_UPDATE_HOST=false

# help message ʕ•ᴥ•ʔ
function show_help() {
  cat <<EOF
Usage: ${0##*/:-} [OPTION...]
	Options
	======================================================
   --src-path=<path>|--src=<path>
	set path to the script source folder
	example: ${0##*/:-} --src=/home/$USER/Docker/src
	example: ${0##*/:-} --src-path=/home/$USER/Docker/src
	======================================================
   --repo-path=<path>|--repo=<path>
	set path to the repository folder
	example: ${0##*/:-} --repo=/home/$USER/Docker
	example: ${0##*/:-} --repo-path=/home/$USER/Docker
	======================================================
   --project-path=<path>|--project=<path>
	set path to the projects folder
	example: ${0##*/:-} --project=/home/$USER/Projects
	example: ${0##*/:-} --project-path=/home/$USER/Projects
	======================================================
   -f|--force
	force installation
	example: ${0##*/:-} -f
	example: ${0##*/:-} --force
	======================================================
   --host
	always update your host file
	example: ${0##*/:-} --host
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
  -f | --force)
    VDM_FORCE_INSTALL=true
    shift
    ;;
  --host)
    VDM_UPDATE_HOST=true
    shift
    ;;
  --src-path | --src) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_SRC_PATH=$2
      shift
    else
      echo '[error] "--src-path" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --src-path=?* | --src=?*)
    VDM_SRC_PATH=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --src-path= | --src=) # Handle the case of an empty --src-path=
    echo '[error] "--src-path=" requires a non-empty option argument.'
    exit 17
    ;;
  --repo-path | --repo) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_REPO_PATH=$2
      shift
    else
      echo '[error] "--repo-path" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --repo-path=?* | --repo=?*)
    VDM_REPO_PATH=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --repo-path= | --repo=) # Handle the case of an empty --repo-path=
    echo '[error] "--repo-path=" requires a non-empty option argument.'
    exit 17
    ;;
  --project-path | --project) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_PROJECT_PATH=$2
      shift
    else
      echo '[error] "--project-path" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  --project-path=?* | --project=?*)
    VDM_PROJECT_PATH=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  --project-path= | --project=) # Handle the case of an empty --project-path=
    echo '[error] "---project-path=" requires a non-empty option argument.'
    exit 17
    ;;
  *) # Default case: No more options, so break out of the loop.
    break ;;
  esac
  shift
done

# make source path available to other scripts
export VDM_SRC_PATH="${VDM_SRC_PATH}"

# now we get the repository path
[ -e "${VDM_REPO_PATH}" ] || {
  echo "[notice] The repository full path is where the container .yml files will live."
  echo -n "[enter:${VDM_SRC_PATH%/src}] Repository Full Path: "
  read -r VDM_REPO_PATH
  # make sure it exist
  # shellcheck disable=SC2015
  [ ${#VDM_REPO_PATH} -ge 1 ] && [ -d "${VDM_REPO_PATH}" ] || {
    # we set the default
    VDM_REPO_PATH="${VDM_SRC_PATH%/src}"
    ## check if this exist
    [ -d "${VDM_REPO_PATH}" ] || {
      echo "[error] Repository path (${VDM_REPO_PATH}) does not exist."
      exit 1
    }
  }
}

# we set the repo path (easy)
grep -q "VDM_REPO_PATH=\"${VDM_REPO_PATH}\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_REPO_PATH=\"${VDM_REPO_PATH}\"" >"${VDM_SRC_PATH}/.env"
export VDM_REPO_PATH="${VDM_REPO_PATH}"

grep -q "VDM_UPDATE_HOST=${VDM_UPDATE_HOST}" "${VDM_SRC_PATH}/.env" || echo "export VDM_UPDATE_HOST=${VDM_UPDATE_HOST}" >>"${VDM_SRC_PATH}/.env"
export VDM_UPDATE_HOST

# notice about the repo path
echo "[notice] $VDM_REPO_PATH was set as the repository path in ${VDM_SRC_PATH}/.env"

# now we must set the Projects path
[ -e "${VDM_PROJECT_PATH}" ] || {
  echo -n "[enter:/home/${USER}/Projects] Projects Full Path: "
  read -r VDM_PROJECT_PATH
  # make sure it exist
  # shellcheck disable=SC2015
  [ ${#VDM_PROJECT_PATH} -ge 1 ] && [ -d "${VDM_PROJECT_PATH}" ] || {
    # we set the default
    VDM_PROJECT_PATH="/home/${USER}/Projects"
    ## check if this exist
    [ -d "${VDM_PROJECT_PATH}" ] || {
      echo "[error] Project path (${VDM_PROJECT_PATH}) does not exist."
      exit 1
    }
  }
}

# we set the projects path (easy)
grep -q "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\"" >>"${VDM_SRC_PATH}/.env"
export VDM_PROJECT_PATH="${VDM_PROJECT_PATH}"

# notice about the projects path
echo "[notice] $VDM_PROJECT_PATH was set as the project path in ${VDM_SRC_PATH}/.env"

# now we set the docker-deploy script in the executable path of this user
if [ ! $VDM_FORCE_INSTALL ]; then
  [ -f /usr/local/bin/docker-deploy ] && {
    echo "[error] /usr/local/bin/docker-deploy already exist! you can force installation:"
    echo "[fix] $ ${0##*/:-} -f"
    exit 1
  }
  sudo cp "${VDM_SRC_PATH}/docker-deploy.sh" /usr/local/bin/docker-deploy
else
  sudo cp -f "${VDM_SRC_PATH}/docker-deploy.sh" /usr/local/bin/docker-deploy
fi

# we need to add helper for our docker-deploy script to find the .env file
sudo sed -i -e "s|/home/update/this/path/to/src|${VDM_SRC_PATH}|g" /usr/local/bin/docker-deploy

# notice of the src path
echo "[notice] ${VDM_SRC_PATH} is the src path to all scripts, and should not be deleted."

# we first make sure run is executable
echo "[sudo] making the /usr/local/bin/docker-deploy script executable"
sudo chmod +x "/usr/local/bin/docker-deploy"

# Note: If the command docker-deploy fails after installation, check your path.
# You can also create a symbolic link to /usr/bin or any other directory in your path.
#   For example:
# $ sudo ln -s /usr/local/bin/docker-deploy /usr/bin/docker-deploy

# we load global environment values
# shellcheck disable=SC2015
[ -f "${VDM_SRC_PATH}/.env" ] && source "${VDM_SRC_PATH}/.env"

# check if we should setup traefik
echo -n "[enter:y] Setup Traefik (y/n): "
read -r VDM_SETUP_TRAEFIK
# make sure value was entered
if [ "${VDM_SETUP_TRAEFIK,,}" != 'n' ]; then
  # run that task type script
  # shellcheck disable=SC1090
  source "${VDM_SRC_PATH}/setup-traefik.sh"
fi
# check if we should setup portainer
echo -n "[enter:y] Setup Portainer (y/n): "
read -r VDM_SETUP_PORTAINER
# make sure value was entered
if [ "${VDM_SETUP_PORTAINER,,}" != 'n' ]; then
  # run that task type script
  # shellcheck disable=SC1090
  source "${VDM_SRC_PATH}/setup-portainer.sh"
fi

exit 0
