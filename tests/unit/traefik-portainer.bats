#!/usr/bin/env bats
#
# The Traefik and Portainer containers: setup (plain and with Let's Encrypt),
# enable, disable and delete. Enabling Traefik first checks that ports 80 and
# 443 are free with lsof on Unix or native netstat on Windows. Their stand-ins
# report free ports unless a test says otherwise (ports_held_by).

# SC2016: the compose files hold ${...} references that must stay literal.
# SC2034: the VDM_* globals are read by the loaded script functions.
# SC2030/SC2031: Bats isolates each test's intentional platform override.
# shellcheck disable=SC2016,SC2030,SC2031,SC2034

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  unset VDM_SECURE_EMAIL VDM_CLOUDFLARE_DNS_API_TOKEN VDM_SUBDOMAIN VDM_TRAEFIK_GATEWAY
  GLOBAL_ENV="${VDM_SRC_PATH}/.env"
  TRAEFIK_YML="${VDM_REPO_PATH}/traefik/docker-compose.yml"
  TRAEFIK_ENV="${VDM_REPO_PATH}/traefik/.env"
  PORTAINER_YML="${VDM_REPO_PATH}/portainer/docker-compose.yml"
  ACME_DIR="${VDM_PROJECT_PATH}/traefik"
}

# a compose file for the container type, as setup would leave it
make_compose() {
  mkdir -p "${VDM_REPO_PATH}/$1"
  printf 'services:\n  %s:\n    container_name: %s\n' "$1" "$1" >"${VDM_REPO_PATH}/$1/docker-compose.yml"
}

# "sudo lsof" reports this process on port 80 (every other sudo call only logs)
ports_held_by() {
  hook_command sudo <<EOF
if [ "\$1" = "lsof" ]; then
  echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
  echo "$1 1234 root 4u IPv6 1 0t0 TCP *:80 (LISTEN)"
fi
exit 0
EOF
}

###############################################################################
# traefik setup

@test "traefik setup: without Let's Encrypt it writes the compose file only" {
  VDM_CONTAINER_TYPE='traefik'
  answers no
  run traefik__TRuST__setup
  assert_success
  assert_answers_used
  assert_file_contains "${TRAEFIK_YML}" "container_name: traefik"
  # the Let's Encrypt lines are there, but commented out
  grep -qE '^#.*acme\.httpchallenge=true' "${TRAEFIK_YML}"
  refute_file_exists "${ACME_DIR}/acme.json"
  refute_file_exists "${TRAEFIK_ENV}"
  refute_command '^docker '
}

@test "traefik setup: the compose file and its folder are private" {
  skip_on_windows "file modes are not real on Windows"
  VDM_CONTAINER_TYPE='traefik'
  answers no
  run traefik__TRuST__setup
  assert_success
  assert_equal "$(file_mode "${TRAEFIK_YML}")" "600"
  assert_equal "$(file_mode "${VDM_REPO_PATH}/traefik")" "700"
}

@test "traefik setup: with Let's Encrypt it saves the email and creates the acme files" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  # Cloudflare: no, email, create the traefik .env: yes, enable: no
  answers no "admin@vdm.dev" yes no
  run traefik__TRuST__setup
  assert_success
  assert_answers_used
  assert_file_contains "${TRAEFIK_ENV}" 'VDM_SECURE_EMAIL="admin@vdm.dev"'
  assert_equal "$(cat "${ACME_DIR}/acme.json")" "{}"
  assert_equal "$(cat "${ACME_DIR}/acme-cloudflare.json")" "{}"
  # the Let's Encrypt lines are active, the Cloudflare ones are not
  grep -qE '^ +- --certificatesresolvers\.vdmresolver\.acme\.httpchallenge=true' "${TRAEFIK_YML}"
  grep -qE '^#.*CLOUDFLARE_DNS_API_TOKEN' "${TRAEFIK_YML}"
}

@test "traefik setup: numeric root ownership works without a host root group name" {
  octojoom_config 'VDM_SECURE=true'
  VDM_CONTAINER_TYPE=traefik
  OS_NUMBER=2
  hook_command sudo <<'EOF'
if [ "$1" = chown ]; then
  [ "$3" = 0:0 ] || exit 7
  exit 0
fi
exec "$@"
EOF
  answers no admin@vdm.dev yes no
  run traefik__TRuST__setup
  assert_success
  assert_answers_used
  assert_command "^sudo chown -R 0:0 ${ACME_DIR}$"
  refute_command '^sudo chown -R root:root '
  assert_file_exists "$TRAEFIK_YML"
}

@test "traefik setup: numeric ownership failure stops before Compose publication or launch" {
  octojoom_config 'VDM_SECURE=true'
  VDM_CONTAINER_TYPE=traefik
  hook_command sudo <<'EOF'
[ "$1" != chown ] || exit 7
exec "$@"
EOF
  answers no admin@vdm.dev yes
  run traefik__TRuST__setup
  assert_failure
  assert_answers_used
  assert_command "^sudo chown -R 0:0 ${ACME_DIR}$"
  refute_file_exists "$TRAEFIK_YML"
  refute_command '^docker compose'
}

@test "traefik setup: with Cloudflare it saves the API token and turns on the Cloudflare lines" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  # Cloudflare: yes, email, create the traefik .env: yes, token, enable: no
  answers yes "admin@vdm.dev" yes "cf-token-123" no
  run traefik__TRuST__setup
  assert_success
  assert_file_contains "${TRAEFIK_ENV}" 'VDM_CLOUDFLARE_DNS_API_TOKEN="cf-token-123"'
  grep -qE '^ +- CLOUDFLARE_DNS_API_TOKEN=' "${TRAEFIK_YML}"
}

@test "traefik setup: an empty email is refused and asked again" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  answers no "" "admin@vdm.dev" yes no
  run traefik__TRuST__setup
  assert_success
  assert_file_contains "${TRAEFIK_ENV}" 'VDM_SECURE_EMAIL="admin@vdm.dev"'
}

@test "traefik setup: enabling right after setup starts the container" {
  VDM_CONTAINER_TYPE='traefik'
  answers yes
  run traefik__TRuST__setup
  assert_success
  assert_answers_used
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${TRAEFIK_YML} up -d"
}

###############################################################################
# traefik enable, disable and delete

@test "traefik enable: with free ports it starts the container" {
  make_compose traefik
  VDM_CONTAINER_TYPE='traefik'
  run traefik__TRuST__enable
  assert_success
  if [ "$OS_NUMBER" -eq 3 ]; then
    assert_command '^netstat.exe -ano -p TCP$'
    refute_command '^sudo lsof '
  else
    assert_command '^sudo lsof '
  fi
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${TRAEFIK_YML} up -d"
  run isContainerRunning traefik
  assert_success
}

@test "traefik enable: the traefik .env is used when there is one" {
  make_compose traefik
  echo 'VDM_SECURE_EMAIL="admin@vdm.dev"' >"${TRAEFIK_ENV}"
  VDM_CONTAINER_TYPE='traefik'
  run traefik__TRuST__enable
  assert_success
  assert_command "^docker compose --env-file ${TRAEFIK_ENV} --file ${TRAEFIK_YML} up -d"
}

@test "traefik enable: without a compose file nothing is started" {
  VDM_CONTAINER_TYPE='traefik'
  run traefik__TRuST__enable
  assert_dialog "setup"
  refute_command '^docker compose'
}

@test "traefik enable: when the user will not free the ports Traefik is not started" {
  make_compose traefik
  OS_NUMBER=1
  ports_held_by apache2
  VDM_CONTAINER_TYPE='traefik'
  answers no
  run traefik__TRuST__enable
  assert_answers_used
  refute_command 'systemctl (stop|disable)'
  refute_command '^docker compose'
}

@test "traefik disable: takes only the Traefik container down and keeps its compose file" {
  make_compose traefik
  running_containers traefik portainer
  VDM_CONTAINER_TYPE='traefik'
  run traefik__TRuST__disable
  assert_success
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${TRAEFIK_YML} down"
  run isContainerRunning traefik
  assert_failure
  run isContainerRunning portainer
  assert_success
  assert_file_exists "${TRAEFIK_YML}"
}

@test "traefik delete: takes the container down and removes the compose file when confirmed" {
  make_compose traefik
  echo 'VDM_SECURE_EMAIL="admin@vdm.dev"' >"${TRAEFIK_ENV}"
  running_containers traefik
  VDM_CONTAINER_TYPE='traefik'
  answers yes
  run traefik__TRuST__delete
  assert_success
  assert_command "^docker compose --env-file ${TRAEFIK_ENV} --file ${TRAEFIK_YML} down"
  refute_file_exists "${TRAEFIK_YML}"
  # the settings are kept for a later setup
  assert_file_exists "${TRAEFIK_ENV}"
}

@test "traefik delete: declining keeps the compose file" {
  make_compose traefik
  VDM_CONTAINER_TYPE='traefik'
  answers no
  run traefik__TRuST__delete
  assert_success
  assert_file_exists "${TRAEFIK_YML}"
}

###############################################################################
# portainer setup

@test "portainer setup: writes the compose file for the sub-domain" {
  VDM_CONTAINER_TYPE='portainer'
  answers "port" no
  run portainer__TRuST__setup
  assert_success
  assert_answers_used
  assert_file_contains "${PORTAINER_YML}" "container_name: portainer"
  assert_file_contains "${PORTAINER_YML}" 'Host(`port.vdm.dev`)'
  refute_file_contains "${PORTAINER_YML}" "routers.portainer.tls.certresolver"
  refute_command '^docker '
}

@test "portainer setup: with Let's Encrypt behind Cloudflare it uses the secure entry point and the Cloudflare resolver" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='portainer'
  # Cloudflare: yes, sub-domain, enable: no
  answers yes "port" no
  run portainer__TRuST__setup
  assert_success
  assert_file_contains "${PORTAINER_YML}" "traefik.http.routers.portainer.entrypoints=websecure"
  assert_file_contains "${PORTAINER_YML}" "traefik.http.routers.portainer.tls.certresolver=cfresolver"
}

@test "portainer setup: a sub-domain already used by a Joomla container is refused" {
  mkdir -p "${VDM_REPO_PATH}/joomla/available/abc.vdm.dev"
  VDM_CONTAINER_TYPE='portainer'
  answers "abc" "port" no
  run portainer__TRuST__setup
  assert_success
  assert_file_contains "${PORTAINER_YML}" 'Host(`port.vdm.dev`)'
  refute_file_contains "${PORTAINER_YML}" 'Host(`abc.vdm.dev`)'
}

###############################################################################
# portainer enable, disable and delete

@test "portainer enable: starts the container without a port check" {
  make_compose portainer
  VDM_CONTAINER_TYPE='portainer'
  run portainer__TRuST__enable
  assert_success
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${PORTAINER_YML} up -d"
  refute_command 'lsof'
  run isContainerRunning portainer
  assert_success
}

@test "portainer enable: without a compose file nothing is started" {
  VDM_CONTAINER_TYPE='portainer'
  run portainer__TRuST__enable
  assert_dialog "setup"
  refute_command '^docker compose'
}

@test "portainer disable: takes only the Portainer container down and keeps its compose file" {
  make_compose portainer
  running_containers traefik portainer
  VDM_CONTAINER_TYPE='portainer'
  run portainer__TRuST__disable
  assert_success
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${PORTAINER_YML} down"
  run isContainerRunning portainer
  assert_failure
  run isContainerRunning traefik
  assert_success
  assert_file_exists "${PORTAINER_YML}"
}

@test "portainer delete: takes the container down and removes the compose file when confirmed" {
  make_compose portainer
  running_containers portainer
  VDM_CONTAINER_TYPE='portainer'
  answers yes
  run portainer__TRuST__delete
  assert_success
  assert_command "^docker compose --env-file ${GLOBAL_ENV} --file ${PORTAINER_YML} down"
  refute_file_exists "${PORTAINER_YML}"
}

@test "portainer delete: declining keeps the compose file" {
  make_compose portainer
  VDM_CONTAINER_TYPE='portainer'
  answers no
  run portainer__TRuST__delete
  assert_success
  assert_file_exists "${PORTAINER_YML}"
}

@test "traefik setup: existing ACME certificates and account keys survive repeated setup" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  mkdir -p "${VDM_REPO_PATH}/traefik" "${ACME_DIR}"
  echo 'VDM_SECURE_EMAIL="admin@vdm.dev"' >"${TRAEFIK_ENV}"
  printf '{"Account":"existing-private-key"}\n' >"${ACME_DIR}/acme.json"
  printf '{"Account":"existing-cloudflare-key"}\n' >"${ACME_DIR}/acme-cloudflare.json"
  answers no no
  run traefik__TRuST__setup
  assert_success
  assert_answers_used
  assert_equal "$(cat "${ACME_DIR}/acme.json")" '{"Account":"existing-private-key"}'
  assert_equal "$(cat "${ACME_DIR}/acme-cloudflare.json")" '{"Account":"existing-cloudflare-key"}'
}

@test "traefik setup: HTTP redirect uses the Traefik v3 regexp syntax" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  VDM_SECURE_EMAIL='admin@vdm.dev'
  answers no yes no
  run traefik__TRuST__setup
  assert_success
  assert_file_contains "${TRAEFIK_YML}" 'rule=HostRegexp(`.+`)'
  refute_file_contains "${TRAEFIK_YML}" '{host:.+}'
  run grep -qE '^[[:space:]]+- --certificatesresolvers\.cfresolver\.' "${TRAEFIK_YML}"
  assert_failure
}

@test "traefik setup: Cloudflare resolver uses DNS challenge without an HTTP challenge" {
  octojoom_config "VDM_SECURE=true"
  VDM_CONTAINER_TYPE='traefik'
  VDM_SECURE_EMAIL='admin@vdm.dev'
  VDM_CLOUDFLARE_DNS_API_TOKEN='test-token'
  answers yes yes no
  run traefik__TRuST__setup
  assert_success
  assert_file_contains "${TRAEFIK_YML}" '--certificatesresolvers.cfresolver.acme.dnschallenge.provider=cloudflare'
  refute_file_contains "${TRAEFIK_YML}" '--certificatesresolvers.cfresolver.acme.httpchallenge=true'
}
