#!/usr/bin/env bash
# Real trusted HTTPS through the existing Traefik file provider. Needs Linux, Docker Compose v2, jq, curl, and root/passwordless sudo.
# Only this run's unique project/network/paths are removed; no daemon pruning.
# shellcheck disable=SC2034,SC2016
set -E -e -o pipefail
# Preserve actionable CI failures without printing commands or credentials.
trap 'printf "HTTPS integration failed at line %s (exit %s).\\n" "$LINENO" "$?" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in docker jq curl sha256sum mkcert openssl; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
docker info >/dev/null
docker compose version >/dev/null
WORK=$(mktemp -d "${TMPDIR:-/tmp}/octojoom-web.XXXXXXXX")
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')
SITE_NAME="web.${RUN_ID}.localhost"
NETWORK="octojoom-web-${RUN_ID}"
KEY="web${RUN_ID}"
WEB="joomla${KEY}"
DB="mariadb${KEY}"
HTTP="nginx${KEY}"
IMAGE="${OCTOJOOM_WEB_TEST_IMAGE:-joomla:5-php8.3-apache}"
VDM_HOME_PATH="$WORK/home"
VDM_SRC_PATH="$VDM_HOME_PATH/config"
VDM_REPO_PATH="$VDM_HOME_PATH/Docker"
VDM_PROJECT_PATH="$VDM_HOME_PATH/Projects"
SITE="$VDM_REPO_PATH/joomla/available/$SITE_NAME"
COMPOSE="$SITE/docker-compose.yml"
ENV_FILE="$VDM_REPO_PATH/joomla/.env"
DATA="$VDM_PROJECT_PATH/$KEY/joomla"

privileged() { if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi; }
cleanup() {
  local status=$?
  trap - EXIT INT TERM ERR
  set +e
  if [ -f "$COMPOSE" ]; then
    local effective="$ENV_FILE"
    [ ! -f "$SITE/.env" ] || effective="$SITE/.env"
    if (( status != 0 )); then
      docker compose --env-file "$effective" -f "$COMPOSE" logs --tail 70 >&2
      # A failed transaction restores Apache; its stopped Nginx companion is
      # then absent from Compose logs but still useful for fixture diagnosis.
      local companion
      for companion in $(docker ps -aq --filter "label=com.docker.compose.service=$HTTP"); do docker logs --tail 35 "$companion" >&2; done
    fi
    docker compose --env-file "$effective" -f "$COMPOSE" down -v --remove-orphans >/dev/null
  fi
  if [ -f "$VDM_REPO_PATH/traefik/docker-compose.yml" ]; then
    docker logs "tls-$RUN_ID" --tail 50 >&2
    docker compose --env-file "$VDM_REPO_PATH/traefik/.env" -f "$VDM_REPO_PATH/traefik/docker-compose.yml" down >/dev/null
  fi
  [ ! -d "${CAROOT:-/nonexistent}" ] || mkcert -uninstall >/dev/null 2>&1
  docker network rm "$NETWORK" >/dev/null 2>&1
  privileged rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom")

mkdir -p "$VDM_SRC_PATH" "$VDM_PROJECT_PATH" "$VDM_REPO_PATH/joomla/enabled"
OS_NUMBER=1
PROGRAM_NAME=Octojoom
BACK_TITLE='Octojoom web runtime integration'
VDM_CONTAINER_TYPE=joomla
VDM_TASK=setup
VDM_KEY="$KEY"
VDM_ENV_KEY="${KEY^^}"
VDM_DOMAIN="$RUN_ID.localhost"
VDM_SUBDOMAIN=web
VDM_J_REPO="${IMAGE%:*}"
VDM_JV="${IMAGE##*:}"
VDM_AUTO_INSTALL=true
VDM_J_EMAIL='admin@example.invalid'
VDM_J_SITE_NAME='Octojoom integration site'
VDM_J_USERNAME='integrationadmin'
VDM_J_USER='Integration Administrator'
VDM_J_PASSWORD='integration-admin-password-2026'
VDM_ENABLE=false
VDM_PHPMYADMIN=false
VDM_SECURE=false
VDM_SECURE_CLOUDFLARE=false
VDM_UPDATE_HOST=false
VDM_MULTI_DOMAIN=false
VDM_CUSTOMIZE=false
VDM_EXPERT_MODE=false
VDM_FORCE=false
VDM_ARG_DOMAIN=false
VDM_TRAEFIK_GATEWAY="$NETWORK"
OCTOJOOM_NON_INTERACTIVE=true
OCTOJOOM_OUTPUT=text
OCTOJOOM_CLI_KEYS=(VDM_KEY VDM_ENV_KEY VDM_DOMAIN VDM_SUBDOMAIN VDM_J_REPO VDM_JV VDM_AUTO_INSTALL VDM_J_EMAIL VDM_J_SITE_NAME VDM_J_USERNAME VDM_J_USER VDM_J_PASSWORD VDM_ENABLE VDM_PHPMYADMIN VDM_SECURE VDM_UPDATE_HOST VDM_MULTI_DOMAIN VDM_CUSTOMIZE)
OCTOJOOM_CLI_VALUES=("$VDM_KEY" "$VDM_ENV_KEY" "$VDM_DOMAIN" "$VDM_SUBDOMAIN" "$VDM_J_REPO" "$VDM_JV" true "$VDM_J_EMAIL" "$VDM_J_SITE_NAME" "$VDM_J_USERNAME" "$VDM_J_USER" "$VDM_J_PASSWORD" false false false false false false)
# The actual headless questionnaire/generator writes the site's Compose and ENV.
cliRememberValue VDM_PHPMYADMIN true
cliRememberValue VDM_MAILCATCHER true
cliApplyValues
joomla__TRuST__setup
[ -f "$COMPOSE" ]
[ ! -e "$VDM_REPO_PATH/joomla/enabled/$SITE_NAME" ]
[ -f "$SITE/.env" ] && ENV_FILE="$SITE/.env"
OCTOJOOM_CLI_KEYS=()
OCTOJOOM_CLI_VALUES=()
mkdir -p "$VDM_PROJECT_PATH/traefik/conf" "$VDM_REPO_PATH/traefik" "$DATA"
chmod 755 "$WORK" "$VDM_HOME_PATH" "$VDM_PROJECT_PATH" "$VDM_PROJECT_PATH/$KEY" "$DATA"
export CAROOT="$WORK/local-ca"
mkcert -install
joomlaTLSTrusted "$CAROOT/rootCA.pem"
# Use the real generator and file provider, with nondefault host ports and a
# unique container name so cleanup cannot affect any existing proxy.
VDM_REMOVE_SECURE='#'
VDM_REMOVE_CLOUDFLARE_SERVICE='#'
traefikContainer | sed -e "s/container_name: traefik/container_name: tls-$RUN_ID/" \
  -e 's/"80:80"/"127.0.0.1:18080:80"/' -e 's/"443:443"/"127.0.0.1:18443:443"/' > "$VDM_REPO_PATH/traefik/docker-compose.yml"
printf 'VDM_PROJECT_PATH="%s"\n' "$VDM_PROJECT_PATH" > "$VDM_REPO_PATH/traefik/.env"
# Existing non-TLS custom labels must survive the full operation.
joomlaServiceProperty "$COMPOSE" "$WEB" labels > "$WORK/property"
printf '      - "custom.application.label=preserved"\n' >> "$WORK/property"
joomlaSetServiceProperty "$COMPOSE" "$WORK/next.yml" "$WEB" labels "$WORK/property"
cp "$WORK/next.yml" "$COMPOSE"
docker network create "$NETWORK" >/dev/null
migrationRunCompose "$VDM_REPO_PATH/traefik/.env" "$VDM_REPO_PATH/traefik/docker-compose.yml" up -d
migrationRunCompose "$ENV_FILE" "$COMPOSE" up -d --wait --wait-timeout 240
ln -s "$SITE" "$VDM_REPO_PATH/joomla/enabled/$SITE_NAME"
for attempt in $(seq 1 60); do
  if docker exec "$WEB" test -f /var/www/html/configuration.php; then break; fi
  sleep 2
done
docker exec "$WEB" test -f /var/www/html/configuration.php
original_db=$(docker inspect --format '{{.Id}}' "$DB")
original_index=$(sha256sum "$DATA/index.php" | cut -d' ' -f1)
cp "$ENV_FILE" "$WORK/shared-original.env"
proxy_id=$(docker inspect --format '{{.Id}}' "tls-$RUN_ID")

verify_https() {
  local attempt hostname
  for hostname in "$SITE_NAME" "webdb.$RUN_ID.localhost" "webmail.$RUN_ID.localhost"; do
    for attempt in $(seq 1 30); do
      if curl --noproxy '*' --fail --silent --show-error "https://$hostname:18443/" > "$WORK/page.html"; then
        grep -qi '<html' "$WORK/page.html" && break
      fi
      sleep 2
    done
    [ "$attempt" -lt 30 ] || return 1
  done
}
VDM_CONTAINER="$SITE_NAME"
VDM_ACTION='set'
VDM_MODE=local
joomla__TRuST__ssl
verify_https
cmp "$ENV_FILE" "$WORK/shared-original.env"
[ "$(docker inspect --format '{{.Id}}' "$DB")" = "$original_db" ]
[ "$(docker inspect --format '{{.Id}}' "tls-$RUN_ID")" = "$proxy_id" ]
[ "$(sha256sum "$DATA/index.php" | cut -d' ' -f1)" = "$original_index" ]
joomlaSiteCompose "$SITE_NAME" config --format json | jq -e --arg service "$WEB" '.services[$service].labels["custom.application.label"]=="preserved"' >/dev/null
OCTOJOOM_OUTPUT=json
VDM_ACTION=status
joomla__TRuST__ssl > "$WORK/status.json"
jq -e '.mode=="local" and .host_trust=="trusted" and .certificate=="valid" and .endpoint=="verified"' "$WORK/status.json"
OCTOJOOM_OUTPUT=text
VDM_ACTION='set'
before=$(docker inspect --format '{{.Id}}' "$WEB")
joomla__TRuST__ssl
[ "$(docker inspect --format '{{.Id}}' "$WEB")" = "$before" ]
# Renewal is hot-loaded; no application or proxy container is recreated.
first=$(jq -r '.tls.certificates[0].certFile' "$VDM_PROJECT_PATH/traefik/conf/octojoom-$SITE_NAME.yaml")
VDM_ACTION=renew
joomla__TRuST__ssl
second=$(jq -r '.tls.certificates[0].certFile' "$VDM_PROJECT_PATH/traefik/conf/octojoom-$SITE_NAME.yaml")
[ "$first" != "$second" ]
verify_https
[ "$(docker inspect --format '{{.Id}}' "$WEB")" = "$before" ]
# Nginx takes over the same labels; HTTPS must remain effective after switching.
VDM_ACTION='set'
VDM_WEBSERVER=nginx
joomla__TRuST__webserver
verify_https
VDM_MODE=http
joomla__TRuST__ssl
[ ! -e "$VDM_PROJECT_PATH/traefik/conf/octojoom-$SITE_NAME.yaml" ]
for attempt in $(seq 1 30); do
  if curl --noproxy '*' --fail --silent "http://$SITE_NAME:18080/" > "$WORK/page.html"; then break; fi
  sleep 2
done
grep -qi '<html' "$WORK/page.html"
# Re-enable local HTTPS for a stopped site without starting it.
joomlaSiteCompose "$SITE_NAME" stop
VDM_MODE=local
joomla__TRuST__ssl
[ -z "$(joomlaSiteCompose "$SITE_NAME" ps --status running --services)" ]
joomlaSiteCompose "$SITE_NAME" up -d --wait --wait-timeout 180
verify_https
# No CA or leaf key is mounted in the Joomla/FPM container.
docker inspect "$WEB" | jq -e '.[0].Mounts | all(.Destination | startswith("/conf") | not)' >/dev/null
printf 'Local HTTPS acceptance passed: trusted Joomla HTTPS, renewal, idempotence, Apache/Nginx, HTTP return, stopped site, independent data and proxy.\n'
