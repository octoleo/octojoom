#!/bin/bash

# check that our source path is correct
[ -e "${VDM_SRC_PATH}" ] || {
  echo "[error] Source path (${VDM_SRC_PATH}) does not exist."
  exit 1
}
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
# be sure to create the container type path for traefik (just one container really)
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/traefik"

# check if we have global env file
[ -f "${VDM_REPO_PATH}/traefik/.env" ] && source "${VDM_REPO_PATH}/traefik/.env"

# set the local values
REMOVE_SECURE=''
# check that we have what we need
if [ "${VDM_SECURE,,}" != 'y' ] && [ "${VDM_SECURE,,}" != 'n' ]; then
  echo -n "[enter] Use letsencrypt (y/n): "
  read -r VDM_SECURE
  # make sure value was entered
  if [ "${VDM_SECURE,,}" != 'y' ] && [ "${VDM_SECURE,,}" != 'n' ]; then
    echo "[error] you must choose y or n"
    exit 1
  fi
fi
# get the domain if not set
[ ${#VDM_DOMAIN} -ge 1 ] || {
  echo -n "[enter:localhost] Domain: "
  read -r VDM_DOMAIN
  # make sure value was entered
  [ ${#VDM_DOMAIN} -ge 1 ] || exit
  # we add the domain to the env (may have the VDM_DOMAIN value, but not the same domain)
  grep -q "VDM_DOMAIN=\"${VDM_DOMAIN}\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_DOMAIN=\"${VDM_DOMAIN}\"" >>"${VDM_SRC_PATH}/.env"
}
# setup letsencrypt stuff
if [ "${VDM_SECURE,,}" == 'y' ]; then
  # we add this switch to the env values
  grep -q "VDM_SECURE=\"y\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_SECURE=\"y\"" >>"${VDM_SRC_PATH}/.env"
  # get the email if not set
  [ ${#VDM_SECURE_EMAIL} -ge 1 ] || {
    echo -n "[enter] Email: "
    read -r VDM_SECURE_EMAIL
    # make sure value was entered
    [ ${#VDM_SECURE_EMAIL} -ge 1 ] || exit
  }
else
  # we add this switch to the env values
  grep -q "VDM_SECURE=\"n\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_SECURE=\"n\"" >>"${VDM_SRC_PATH}/.env"
  # remove secure from build
  REMOVE_SECURE="#"
fi

# build function
function buildContainer() {
  # we build the yml file
  cat <<EOF
version: "3.3"

services:
  traefik:
    container_name: traefik
    image: "traefik:latest"
    command:
      - --entrypoints.web.address=:80
${REMOVE_SECURE}      - --entrypoints.websecure.address=:443
#      - --api.dashboard=true
#      - --api.insecure=true
      - --providers.docker
      - --log.level=ERROR
${REMOVE_SECURE}      - --certificatesresolvers.vdmresolver.acme.httpchallenge=true
${REMOVE_SECURE}      - --certificatesresolvers.vdmresolver.acme.keytype=RSA4096
${REMOVE_SECURE}      - --certificatesresolvers.vdmresolver.acme.email=${VDM_SECURE_EMAIL:-user@demo.com}
${REMOVE_SECURE}      - --certificatesresolvers.vdmresolver.acme.storage=/acme.json
${REMOVE_SECURE}      - --certificatesresolvers.vdmresolver.acme.httpchallenge.entrypoint=web
#      - --providers.file.directory=/conf
#      - --providers.file.watch=true
    restart: unless-stopped
    ports:
      - "80:80"
${REMOVE_SECURE}      - "443:443"
#      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
#      - "\${VDM_PROJECT_PATH}/traefik/conf:/conf"
${REMOVE_SECURE}      - "\${VDM_PROJECT_PATH}/traefik/acme.json:/acme.json"
      - "\${VDM_PROJECT_PATH}/traefik/errors:/errors"
    labels:
      # settings for all containers
      - "traefik.http.routers.http-catchall.rule=hostregexp(\`{host:.+}\`)"
      - "traefik.http.routers.http-catchall.entrypoints=web"
${REMOVE_SECURE}      - "traefik.http.routers.http-catchall.middlewares=redirect-to-https"
${REMOVE_SECURE}      - "traefik.http.middlewares.redirect-to-https.redirectscheme.scheme=https"
    networks:
      - traefik

networks:
  traefik:
    external:
      name: traefik_webgateway
EOF
}

## create the directory if it does not yet already exist
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/traefik"
## place this docker composer file in its place
buildContainer >"${VDM_REPO_PATH}/traefik/docker-compose.yml"
## set permissions
chmod 600 "${VDM_REPO_PATH}/traefik/docker-compose.yml"
[ -f "${VDM_REPO_PATH}/traefik/.env" ] && chmod 600 "${VDM_REPO_PATH}/traefik/.env" &&
  ENV_FILE="${VDM_REPO_PATH}/traefik/.env" || ENV_FILE="${VDM_REPO_PATH}/src/.env"
## saved the file
echo "[saved] traefik:docker-compose.yml"
echo "[setup] Completed!"

# we create the networks
docker network inspect traefik_webgateway >/dev/null 2>&1 ||
  docker network create traefik_webgateway
docker network inspect openssh_gateway >/dev/null 2>&1 ||
  docker network create openssh_gateway
# make sure port 80 is not used by apache
command -v apache2 >/dev/null 2>&1 && [[ $(service apache2 status) == *"active (running)"* ]] && {
  sudo systemctl stop apache2.service
  sudo systemctl disable apache2.service
}
# now start the container
docker-compose --env-file "${ENV_FILE}" --file "${VDM_REPO_PATH}/traefik/docker-compose.yml" up -d
