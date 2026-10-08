#!/usr/bin/env bats
#
# The docker-compose.yml templates (Traefik, Portainer, Joomla, Openssh), the
# docker networks, the running-container and free-port checks, and the
# whiptail, Docker and Docker Compose installers.
#
# Each compose file is validated with the real "docker compose config" when
# docker is installed (${REAL_DOCKER}); elsewhere only its key lines are checked.
# The installers run against the stand-ins: the tests check which commands they
# would run; the sudo stand-in keeps everything outside the sandbox untouched.

# SC2016: the compose files hold ${...} references that must stay literal.
# SC2034: the VDM_* globals are read by the loaded script functions.
# SC2317/SC2329: stand-in functions (open, dpkg, sleep) are called by the script.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329

load ../helpers/common

setup() {
  octojoom_setup
}

# write_compose <name> <command...>: write the command's output as
# ${SANDBOX}/<name>/docker-compose.yml, next to an env file
write_compose() {
  local dir="${SANDBOX}/$1"
  shift
  mkdir -p "${dir}"
  echo "VDM_PROJECT_PATH=\"${VDM_PROJECT_PATH}\"" >"${dir}/.env"
  "$@" >"${dir}/docker-compose.yml"
}

yml_of() { echo "${SANDBOX}/$1/docker-compose.yml"; }

# the real docker compose accepts the file (passes without docker)
compose_valid() {
  [ -n "${REAL_DOCKER}" ] || return 0
  "${REAL_DOCKER}" compose --env-file "${SANDBOX}/$1/.env" --file "$(yml_of "$1")" config -q
}

###############################################################################
# templates

@test "traefikContainer: without Let's Encrypt the resolvers are commented out" {
  VDM_REMOVE_SECURE='#'
  VDM_REMOVE_CLOUDFLARE_SERVICE='#'
  write_compose traefik traefikContainer
  assert_file_contains "$(yml_of traefik)" 'container_name: traefik'
  assert_file_contains "$(yml_of traefik)" '- "443:443"'
  run grep -v '^[[:space:]]*#' "$(yml_of traefik)"
  refute_output_contains 'certificatesresolvers'
  refute_output_contains 'CLOUDFLARE_DNS_API_TOKEN'
  compose_valid traefik
}

@test "traefikContainer: Let's Encrypt with Cloudflare adds the resolvers and the DNS token" {
  VDM_REMOVE_SECURE=''
  VDM_REMOVE_CLOUDFLARE_SERVICE=''
  write_compose traefik traefikContainer
  run grep -v '^[[:space:]]*#' "$(yml_of traefik)"
  assert_output_contains 'certificatesresolvers.vdmresolver'
  assert_output_contains 'CLOUDFLARE_DNS_API_TOKEN'
  compose_valid traefik
}

@test "portainerContainer: routes the sub-domain to portainer" {
  VDM_SUBDOMAIN='port'
  VDM_DOMAIN='vdm.dev'
  VDM_PORT_SECURE_LABELS=''
  VDM_REMOVE_SECURE='#'
  write_compose portainer portainerContainer
  assert_file_contains "$(yml_of portainer)" 'container_name: portainer'
  assert_file_contains "$(yml_of portainer)" 'Host(`port.vdm.dev`)'
  compose_valid portainer
}

@test "portainerContainer: Let's Encrypt adds the secure labels" {
  VDM_SUBDOMAIN='port'
  VDM_DOMAIN='vdm.dev'
  VDM_REMOVE_SECURE=''
  VDM_PORT_SECURE_LABELS=$(getYMLine3 '- "traefik.http.routers.portainer.entrypoints=websecure"')
  VDM_PORT_SECURE_LABELS+=$(getYMLine3 '- "traefik.http.routers.portainer.tls.certresolver=vdmresolver"')
  write_compose portainer portainerContainer
  assert_file_contains "$(yml_of portainer)" 'portainer.entrypoints=websecure'
  assert_file_contains "$(yml_of portainer)" 'portainer.tls.certresolver=vdmresolver'
  compose_valid portainer
}

@test "joomlaContainer: has the database, Joomla and phpMyAdmin services" {
  write_compose joomla gen_joomla_compose jtest JTEST jtest vdm.dev
  assert_file_contains "$(yml_of joomla)" 'container_name: mariadbjtest'
  assert_file_contains "$(yml_of joomla)" 'container_name: joomlajtest'
  assert_file_contains "$(yml_of joomla)" 'container_name: phpmyadminjtest'
  assert_file_contains "$(yml_of joomla)" 'Host(`jtest.vdm.dev`)'
  compose_valid joomla
}

@test "joomlaContainer: Let's Encrypt and mailcatcher still give a valid file" {
  write_compose joomla gen_joomla_compose jtest JTEST jtest vdm.dev true true
  assert_file_contains "$(yml_of joomla)" 'joomlajtest.tls.certresolver=vdmresolver'
  assert_file_contains "$(yml_of joomla)" 'container_name: mailcatcherjtest'
  assert_file_contains "$(yml_of joomla)" 'JOOMLA_SMTP_HOST=mailcatcherjtest:1025'
  compose_valid joomla
}

openssh_globals() {
  VDM_KEY='ssh1'
  VDM_DOMAIN='vdm.dev'
  VDM_USER_NAME='alice'
  VDM_PUID=33
  VDM_PGID=33
  VDM_PORT=2239
  VDM_VOLUMES_MOUNT=$(getYMLine3 '- ${VDM_SSH1_PUBLIC_KEY_DIR}:/config/ssh_public_keys')
}

@test "opensshContainer: the user, port and key folder" {
  openssh_globals
  write_compose openssh opensshContainer
  echo "VDM_SSH1_PUBLIC_KEY_DIR=\"${SANDBOX}/keys\"" >>"${SANDBOX}/openssh/.env"
  assert_file_contains "$(yml_of openssh)" 'container_name: openssh-server-ssh1'
  assert_file_contains "$(yml_of openssh)" '- USER_NAME=alice'
  assert_file_contains "$(yml_of openssh)" '- 2239:2222'
  assert_file_contains "$(yml_of openssh)" 'name: openssh_gateway'
  compose_valid openssh
}

@test "opensshContainer: time zone, sudo access and gateway can be set" {
  openssh_globals
  VDM_TZ='Europe/Berlin'
  VDM_SUDO_ACCESS=true
  VDM_OPENSSH_GATEWAY='ssh_net'
  write_compose openssh opensshContainer
  echo "VDM_SSH1_PUBLIC_KEY_DIR=\"${SANDBOX}/keys\"" >>"${SANDBOX}/openssh/.env"
  assert_file_contains "$(yml_of openssh)" '- TZ=Europe/Berlin'
  assert_file_contains "$(yml_of openssh)" '- SUDO_ACCESS=true'
  assert_file_contains "$(yml_of openssh)" 'name: ssh_net'
  compose_valid openssh
}

###############################################################################
# setNetworks

@test "setNetworks: creates the traefik and openssh networks" {
  run setNetworks
  assert_success
  assert_command '^docker network create .*traefik_webgateway$'
  assert_command '^docker network create .*openssh_gateway$'
  assert_file_contains "${STUB_DIR}/docker/networks" 'traefik_webgateway'
  assert_file_contains "${STUB_DIR}/docker/networks" 'openssh_gateway'
}

@test "setNetworks: existing networks are left alone" {
  printf '%s\n' traefik_webgateway openssh_gateway >"${STUB_DIR}/docker/networks"
  run setNetworks
  assert_success
  refute_command '^docker network create'
}

@test "setNetworks: fails when docker is not reachable" {
  fail_command docker-info
  run setNetworks
  assert_failure
  refute_command '^docker network'
}

###############################################################################
# isContainerRunning

@test "isContainerRunning: only an exactly named running container counts" {
  running_containers traefik2 mariadbjtest
  run isContainerRunning mariadbjtest
  assert_success
  run isContainerRunning traefik
  assert_failure
}

@test "isContainerRunning: false when docker ps fails" {
  running_containers traefik
  fail_command docker-ps
  run isContainerRunning traefik
  assert_failure
}

###############################################################################
# ensurePortsFree

# lsof (through sudo) reports nginx on port 80 until "sudo systemctl stop" runs
ports_used_by_nginx() {
  echo 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME' >"${STUB_DIR}/lsof-out"
  echo 'nginx 1234 root 6u IPv4 12345 0t0 TCP *:80 (LISTEN)' >>"${STUB_DIR}/lsof-out"
  hook_command sudo <<'EOF'
case "$1" in
lsof) [ -f "${STUB_DIR}/lsof-out" ] && cat "${STUB_DIR}/lsof-out" ;;
systemctl) [ "$2" = stop ] && rm -f "${STUB_DIR}/lsof-out" ;;
esac
exit 0
EOF
}

@test "ensurePortsFree: free ports pass without a question" {
  OS_NUMBER=1
  run ensurePortsFree
  assert_success
  assert_command '^sudo lsof '
  refute_command '^sudo systemctl'
}

@test "ensurePortsFree: a Linux web service is stopped when the user agrees" {
  OS_NUMBER=1
  ports_used_by_nginx
  sleep() { :; }
  answers yes
  run ensurePortsFree
  assert_success
  assert_command '^sudo systemctl stop nginx$'
  assert_command '^sudo systemctl disable nginx$'
}

@test "ensurePortsFree: declining leaves the service running and fails" {
  OS_NUMBER=1
  ports_used_by_nginx
  answers no
  run ensurePortsFree
  assert_failure
  refute_command '^sudo systemctl'
  assert_file_exists "${STUB_DIR}/lsof-out"
}

###############################################################################
# installers (the sudo stand-in skips every system change)

@test "install_whiptail_linux: installs whiptail with apt-get through sudo" {
  run install_whiptail_linux
  assert_success
  assert_command '^sudo apt-get install whiptail -y$'
  refute_command '^apt-get'
}

@test "install_whiptail_macos: installs newt with Homebrew" {
  run install_whiptail_macos
  assert_success
  assert_command '^brew install newt$'
}

@test "install_whiptail_windows: installs newt with Chocolatey" {
  run install_whiptail_windows
  assert_success
  assert_command '^choco install newt$'
}

@test "install_docker_linux: Debian adds the Docker repository and installs Docker" {
  printf '%s\n' 'ID=debian' 'VERSION_CODENAME=bookworm' >"${SANDBOX}/os-release"
  eval "$(declare -f install_docker_linux | sed "s|/etc/os-release|${SANDBOX}/os-release|g")"
  dpkg() { echo amd64; }
  run install_docker_linux
  assert_success
  assert_file_contains "${STUB_DIR}/sudo-tee.log" 'https://download.docker.com/linux/debian bookworm stable'
  assert_command '^sudo apt-get install -y docker-ce '
  assert_command '^sudo usermod -aG docker '
  assert_command '^sudo systemctl start docker\.service$'
  # nothing really ran outside the sandbox
  refute_command '^(apt-get|groupadd|usermod|systemctl|gpg) '
}

@test "install_docker_macos: installs Docker Desktop with Homebrew and starts it" {
  eval "$(declare -f install_docker_macos | sed "s|/Applications/Docker.app|${SANDBOX}/Docker.app|g")"
  open() { echo "open $*" >>"${STUB_DIR}/commands.log"; }
  run install_docker_macos
  assert_success
  assert_command '^brew install --cask docker$'
  assert_command '^open .*/Docker\.app$'
  refute_command '^(sudo|curl) '
}

@test "install_docker_compose_linux: installs the compose plugin with apt-get" {
  run install_docker_compose_linux
  assert_success
  assert_command '^sudo apt-get install -y docker-compose-plugin$'
  refute_command '^apt-get'
}

@test "install_docker_compose_macos: nothing to download when compose is available" {
  run install_docker_compose_macos
  assert_success
  refute_command '^curl'
}
