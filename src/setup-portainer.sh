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
[ -f "${VDM_REPO_PATH}/portainer/.env" ] && source "${VDM_REPO_PATH}/portainer/.env"

# set the local values
REMOVE_SECURE=''
ENTRY_POINT="websecure"
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
else
  # we add this switch to the env values
  grep -q "VDM_SECURE=\"n\"" "${VDM_SRC_PATH}/.env" || echo "export VDM_SECURE=\"n\"" >>"${VDM_SRC_PATH}/.env"
  # remove secure from build
  REMOVE_SECURE="#"
  ENTRY_POINT="web"
fi

# build function
function buildContainer() {
  # we build the yml file
  cat <<EOF
version: "3.3"

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    command: -H unix:///var/run/docker.sock
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
    labels:
      # Frontend
      - "traefik.enable=true"
      - "traefik.http.routers.portainer.rule=Host(\`port.${VDM_DOMAIN}\`)"
      - "traefik.http.routers.portainer.entrypoints=${ENTRY_POINT}"
${REMOVE_SECURE}      - "traefik.http.routers.portainer.tls.certresolver=vdmresolver"
      - "traefik.http.routers.portainer.service=portainer"
      - "traefik.http.services.portainer.loadbalancer.server.port=9000"

      # Edge
#      - "traefik.http.routers.portaineredge.rule=Host(\`edge.${VDM_DOMAIN}\`)"
#      - "traefik.http.routers.portaineredge.entrypoints=${ENTRY_POINT}"
#      - "traefik.http.routers.portaineredge.tls.certresolver=vdmresolver"
#      - "traefik.http.routers.portaineredge.service=portaineredge"
#      - "traefik.http.services.portaineredge.loadbalancer.server.port=8000"
    networks:
      - traefik

volumes:
  portainer_data:

networks:
  traefik:
    external:
      name: traefik_webgateway
EOF
}

# add to the host file if not already set
#if [ $VDM_UPDATE_HOST ]; then
#  grep -q "port.${VDM_DOMAIN}" /etc/hosts  || {
#    echo "[notice] Adding port.${VDM_DOMAIN} to the /etc/hosts file."
#    sudo -- sh -c "127.0.0.1       port.${VDM_DOMAIN} >> /etc/hosts"
#  }
#fi

## create the directory if it does not yet already exist
# shellcheck disable=SC2174
mkdir -p -m 700 "${VDM_REPO_PATH}/portainer"
## place this docker composer file in its place
buildContainer >"${VDM_REPO_PATH}/portainer/docker-compose.yml"
## set permissions
chmod 600 "${VDM_REPO_PATH}/portainer/docker-compose.yml"
[ -f "${VDM_REPO_PATH}/portainer/.env" ] && chmod 600 "${VDM_REPO_PATH}/portainer/.env" &&
  ENV_FILE="${VDM_REPO_PATH}/portainer/.env" || ENV_FILE="${VDM_REPO_PATH}/src/.env"
## saved the file
echo "[saved] portainer:docker-compose.yml"
echo "[setup] Completed!"

# now start the container
docker-compose --env-file "${ENV_FILE}" --file "${VDM_REPO_PATH}/portainer/docker-compose.yml" up -d
