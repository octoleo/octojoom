#!/bin/bash

# BOT name
BOT_NAME="docker-deploy v1.0"

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

# check if we have global env file
# shellcheck disable=SC1090
# shellcheck disable=SC2015
[ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && source "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" || {
  touch "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  chmod 600 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
}

# we must get a random key
function getPass() {
  # simple basic random
  # shellcheck disable=SC2046
  echo $(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | dd bs="${1:-128}" count=1 status=none)
}

# help message ʕ•ᴥ•ʔ
function show_help() {
  cat <<EOF
Usage: ${0##*/:-} [OPTION...]
	Options
	======================================================
   -j|--joomla-version <version>
	set Joomla version number
	!! only number allowed !!
	example: ${0##*/:-} -j=3.10
	example: ${0##*/:-} --joomla-version=3.10
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
   -s|--sub-domain <domain.com>
	set key website sub domain
	!! no spaces allowed in the sub domain !!
	example: ${0##*/:-} -s="jcb"
	example: ${0##*/:-} --sub-domain="jcb"
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
  -j | --joomla-version) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_JV=$2
      shift
    else
      echo '[error] "--joomla-version" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -j=?* | --joomla-version=?*)
    VDM_JV=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -j= | --joomla-version=) # Handle the case of an empty --joomla-version=
    echo '[error] "--joomla-version=" requires a non-empty option argument.'
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
  -s | --sub-domain) # Takes an option argument; ensure it has been specified.
    if [ "$2" ]; then
      VDM_SUBDOMAIN=$2
      shift
    else
      echo '[error] "--sub-domain" requires a non-empty option argument.'
      exit 17
    fi
    ;;
  -s=?* | --sub-domain=?*)
    VDM_SUBDOMAIN=${1#*=} # Delete everything up to "=" and assign the remainder.
    ;;
  -s= | --sub-domain=) # Handle the case of an empty --sub-domain=
    echo '[error] "--sub-domain=" requires a non-empty option argument.'
    exit 17
    ;;
  *) # Default case: No more options, so break out of the loop.
    break ;;
  esac
  shift
done

# check that we have what we need
[ ${#VDM_JV} -ge 1 ] || {
  echo -n "[enter] Joomla Version: "
  read -r VDM_JV
  # make sure value was entered
  [ ${#VDM_JV} -ge 1 ] || exit
}
[ ${#VDM_KEY} -ge 1 ] || {
  echo -n "[enter] key: "
  read -r VDM_KEY
  # make sure value was entered
  [ ${#VDM_KEY} -ge 1 ] || exit
}
[ ${#VDM_ENV_KEY} -ge 1 ] || {
  echo -n "[enter:A] env key: "
  read -r VDM_ENV_KEY
  # make sure value was entered
  [ ${#VDM_ENV_KEY} -ge 1 ] || VDM_ENV_KEY="A"
}
[ ${#VDM_SUBDOMAIN} -ge 1 ] || {
  echo -n "[enter:${VDM_KEY}] Sub-domain: "
  read -r VDM_SUBDOMAIN
  # make sure value was entered
  [ ${#VDM_SUBDOMAIN} -ge 1 ] || VDM_SUBDOMAIN=${VDM_KEY}
}
[ ${#VDM_DOMAIN} -ge 1 ] || {
  VDM_DOMAIN="vdm.dev"
}
# check the security switch
REMOVE_SECURE=''
ENTRY_POINT="websecure"
# setup letsencrypt stuff
if [ "${VDM_SECURE,,}" == 'y' ]; then
  # we add this switch to the env values
  grep -q "VDM_SECURE=\"y\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_SECURE=\"y\"" >>"${VDM_SRC_PATH}/.env"
else
  # we add this switch to the env values
  grep -q "VDM_SECURE=\"n\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_SECURE=\"n\"" >>"${VDM_SRC_PATH}/.env"
  # remove secure from build
  REMOVE_SECURE="#"
  ENTRY_POINT="web"
fi
# check if env is already set
# shellcheck disable=SC2015
[ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && grep -q "VDM_${VDM_ENV_KEY}_DB=" "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" || {
  # add a space or create the file
  [ -f "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" ] && echo '' >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  # get the database name needed
  echo -n "[enter:vdm_io] Database name: "
  read -r vdm_database_name
  # make sure value was entered
  [ ${#vdm_database_name} -ge 1 ] || vdm_database_name="vdm_io"
  # add to env
  echo "VDM_${VDM_ENV_KEY}_DB=\"${vdm_database_name}\"" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  # get the database user name needed
  echo -n "[enter:vdm_user] Database user: "
  read -r vdm_database_user
  # make sure value was entered
  [ ${#vdm_database_user} -ge 1 ] || vdm_database_user="vdm_user"
  # add to env
  echo "VDM_${VDM_ENV_KEY}_DB_USER=\"${vdm_database_user}\"" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  # get the database user name needed
  echo -n "[enter:random] Database user password: "
  read -r vdm_database_pass
  # make sure value was entered
  [ ${#vdm_database_pass} -ge 1 ] || vdm_database_pass=$(getPass 20)
  # add to env
  echo "VDM_${VDM_ENV_KEY}_DB_PASS=\"${vdm_database_pass}\"" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  # get the database user name needed
  echo -n "[enter:random] Database root password: "
  read -r vdm_database_rootpass
  # make sure value was entered
  [ ${#vdm_database_rootpass} -ge 1 ] || vdm_database_rootpass=$(getPass 40)
  # add to env
  echo "VDM_${VDM_ENV_KEY}_DB_ROOT=\"${vdm_database_rootpass}\"" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  # add the projects path
  grep -q "VDM_PROJECT_PATH=" "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env" || {
    # add to env
    echo "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\"" >>"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/.env"
  }
}

# build function
function buildContainer() {
  # we build the yml file
  cat <<EOF
version: '2'
services:
  mariadb_${VDM_KEY}:
    image: mariadb:latest
    container_name: mariadb_${VDM_KEY}
    restart: unless-stopped
    environment:
      - MARIADB_DATABASE=\${VDM_${VDM_ENV_KEY}_DB}
      - MARIADB_USER=\${VDM_${VDM_ENV_KEY}_DB_USER}
      - MARIADB_PASSWORD=\${VDM_${VDM_ENV_KEY}_DB_PASS}
      - MARIADB_ROOT_PASSWORD=\${VDM_${VDM_ENV_KEY}_DB_ROOT}
    volumes:
      - "\${VDM_PROJECT_PATH}/${VDM_KEY}/db:/var/lib/mysql"
    networks:
      - traefik
  joomla_${VDM_KEY}:
    image: joomla:${VDM_JV}
    container_name: joomla_${VDM_KEY}
    restart: unless-stopped
    environment:
      - JOOMLA_DB_HOST=mariadb_${VDM_KEY}:3306
      - JOOMLA_DB_NAME=\${VDM_${VDM_ENV_KEY}_DB}
      - JOOMLA_DB_USER=\${VDM_${VDM_ENV_KEY}_DB_USER}
      - JOOMLA_DB_PASSWORD=\${VDM_${VDM_ENV_KEY}_DB_PASS}
    depends_on:
      - mariadb_${VDM_KEY}
    volumes:
      - "\${VDM_PROJECT_PATH}/${VDM_KEY}/joomla:/var/www/html"
    networks:
      - traefik
    labels:
      # joomla
      - "traefik.enable=true"
      - "traefik.http.routers.joomla_${VDM_KEY}.rule=Host(\`${VDM_SUBDOMAIN}.${VDM_DOMAIN}\`)"
      - "traefik.http.routers.joomla_${VDM_KEY}.entrypoints=${ENTRY_POINT}"
${REMOVE_SECURE}      - "traefik.http.routers.joomla_${VDM_KEY}.tls.certresolver=vdmresolver"
      - "traefik.http.routers.joomla_${VDM_KEY}.service=joomla_${VDM_KEY}"
      - "traefik.http.services.joomla_${VDM_KEY}.loadbalancer.server.port=80"
  phpmyadmin_${VDM_KEY}:
    image: phpmyadmin/phpmyadmin
    container_name: phpmyadmin_${VDM_KEY}
    restart: unless-stopped
    environment:
      PMA_HOST: mariadb_${VDM_KEY}
      PMA_PORT: 3306
      UPLOAD_LIMIT: 300M
    depends_on:
      - mariadb_${VDM_KEY}
    networks:
      - traefik
    labels:
      # phpmyadmin
      - "traefik.enable=true"
      - "traefik.http.routers.phpmyadmin_${VDM_KEY}.rule=Host(\`${VDM_SUBDOMAIN}db.${VDM_DOMAIN}\`)"
      - "traefik.http.routers.phpmyadmin_${VDM_KEY}.entrypoints=${ENTRY_POINT}"
${REMOVE_SECURE}      - "traefik.http.routers.phpmyadmin_${VDM_KEY}.tls.certresolver=vdmresolver"
      - "traefik.http.routers.phpmyadmin_${VDM_KEY}.service=phpmyadmin_${VDM_KEY}"
      - "traefik.http.services.phpmyadmin_${VDM_KEY}.loadbalancer.server.port=80"


networks:
  traefik:
    external:
      name: traefik_webgateway
EOF
}

# set host file if needed
source "${VDM_SRC_PATH}/host.sh"

# create the directory if it does not yet already exist
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_SUBDOMAIN}.${VDM_DOMAIN}"
# place this docker composer file in its place
buildContainer >"${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_SUBDOMAIN}.${VDM_DOMAIN}/docker-compose.yml"
# set permissions
chmod 600 "${VDM_REPO_PATH}/${VDM_CONTAINER_TYPE}/available/${VDM_SUBDOMAIN}.${VDM_DOMAIN}/docker-compose.yml"
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
      Yes ) source "${VDM_SRC_PATH}/enable.sh" "${VDM_SUBDOMAIN}.${VDM_DOMAIN}";;
  esac
  break
done
# restore the default
export PS3=$PS3_old
echo "[setup] Completed!"
