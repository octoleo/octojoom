#!/usr/bin/env bash
# Real Joomla installation, Apache/Nginx round-trip and explicit document-root
# move. Needs Linux, Docker Compose v2, jq, curl, and root/passwordless sudo.
# Only this run's unique project/network/paths are removed; no daemon pruning.
# shellcheck disable=SC2034,SC2016
set -e -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in docker jq curl sha256sum; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
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
  trap - EXIT INT TERM
  set +e
  if [ -f "$COMPOSE" ]; then
    local effective="$ENV_FILE"
    [ ! -f "$SITE/.env" ] || effective="$SITE/.env"
    if (( status != 0 )); then docker compose --env-file "$effective" -f "$COMPOSE" logs --tail 70 >&2; fi
    docker compose --env-file "$effective" -f "$COMPOSE" down -v --remove-orphans >/dev/null
  fi
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
joomla__TRuST__setup
[ -f "$COMPOSE" ]
[ ! -e "$VDM_REPO_PATH/joomla/enabled/$SITE_NAME" ]
[ -f "$SITE/.env" ] && ENV_FILE="$SITE/.env"
# Use a host-only ephemeral HTTP port so the test needs no public proxy or DNS.
printf '    ports:\n      - "127.0.0.1::80"\n' > "$WORK/property"
joomlaSetServiceProperty "$COMPOSE" "$WORK/compose.next" "$WEB" ports "$WORK/property"
cp "$WORK/compose.next" "$COMPOSE"
printf '    labels:\n      - "custom.application.label=preserved"\n' > "$WORK/property"
joomlaSetServiceProperty "$COMPOSE" "$WORK/compose.next" "$WEB" labels "$WORK/property"
cp "$WORK/compose.next" "$COMPOSE"
# Keep installer output inside this unique test home, then wait for real health.
mkdir -p "$DATA"
chmod 755 "$WORK" "$VDM_HOME_PATH" "$VDM_PROJECT_PATH" "$VDM_PROJECT_PATH/$KEY" "$DATA"
docker network create "$NETWORK" >/dev/null
migrationRunCompose "$ENV_FILE" "$COMPOSE" up -d --wait --wait-timeout 240
ln -s "$SITE" "$VDM_REPO_PATH/joomla/enabled/$SITE_NAME"
VDM_CONTAINER="$SITE_NAME"
OCTOJOOM_CLI_KEYS=()
OCTOJOOM_CLI_VALUES=()
unset VDM_JV
for attempt in $(seq 1 60); do
  if docker exec "$WEB" test -f /var/www/html/configuration.php; then break; fi
  sleep 2
done
docker exec "$WEB" test -f /var/www/html/configuration.php
installed=$(joomlaRuntimeInstalledVersion "$SITE_NAME")
old_php=$(joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php -r 'echo PHP_VERSION;')
old_db=$(docker inspect --format '{{.Id}}' "$DB")
original_index=$(sha256sum "$DATA/index.php" | cut -d' ' -f1)
# Create a real application database marker without exposing DB credentials.
joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php -r '
 require "/var/www/html/configuration.php"; $c=new JConfig;
 $db=new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
 $db->query("CREATE TABLE octojoom_marker(message VARCHAR(80))");
 $db->query("INSERT INTO octojoom_marker VALUES(\"retained website data\")");
'
printf 'retained upload\n' | privileged tee "$DATA/images/octojoom-upload.txt" >/dev/null
# Enable ordinary Joomla SEF routing using its own native CLI.
joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php cli/joomla.php config:set sef=true
joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php cli/joomla.php config:set sef_rewrite=true

http_acceptance() {
  local url token code
  readJoomlaSiteFacts "$SITE_NAME"
  url="$VDM_SITE_URL"
  [[ "$url" = http://127.0.0.1:* || "$url" = http://localhost:* ]]
  curl --fail --silent --show-error "$url/" > "$WORK/frontend.html"
  grep -q 'Octojoom integration site' "$WORK/frontend.html"
  curl --fail --silent --show-error --location "$url/component/users/login" > "$WORK/sef.html"
  grep -q 'name="username"' "$WORK/sef.html"
  [ "$(curl --fail --silent --show-error "$url/images/octojoom-upload.txt")" = 'retained upload' ]
  curl --fail --silent --show-error "$url/media/system/js/core.min.js" > /dev/null
  # API authentication is a useful expected response, not a webserver 404 page.
  code=$(curl --silent --show-error -o "$WORK/api.json" -w '%{http_code}' "$url/api/index.php/v1/content/articles")
  [[ "$code" = 200 || "$code" = 401 || "$code" = 403 ]]
  jq -e 'has("data") or has("errors") or has("links")' "$WORK/api.json" >/dev/null
  code=$(curl --silent --show-error -o "$WORK/missing.html" -w '%{http_code}' "$url/octojoom-missing-script.php")
  [ "$code" = 404 ]
  curl --silent --show-error "$url/configuration.php" > "$WORK/config-output"
  if grep -q 'class JConfig' "$WORK/config-output"; then echo 'PHP configuration source was served' >&2; return 1; fi
  # Submit a real administrator session with Joomla's generated CSRF token.
  curl --fail --silent --show-error -c "$WORK/cookies" "$url/administrator/" > "$WORK/login.html"
  token=$(sed -nE 's/.*name="([a-f0-9]{32})"[[:space:]]+value="1".*/\1/p' "$WORK/login.html" | head -n 1)
  [ -n "$token" ]
  curl --fail --silent --show-error --location -b "$WORK/cookies" -c "$WORK/cookies" \
    --data-urlencode 'username=integrationadmin' --data-urlencode 'passwd=integration-admin-password-2026' \
    --data-urlencode 'option=com_login' --data-urlencode 'task=login' --data-urlencode "$token=1" \
    "$url/administrator/index.php" > "$WORK/admin.html"
  grep -Eq 'task=logout|task=login.logout|com_cpanel' "$WORK/admin.html"
  joomlaRuntimeValidatePublished "$SITE_NAME"
}

http_acceptance
VDM_ACTION='set'
VDM_WEBSERVER=nginx
joomla__TRuST__webserver
http_acceptance
joomlaVerifyWebConfiguration "$SITE_NAME"
[ "$(joomlaRuntimeInstalledVersion "$SITE_NAME")" = "$installed" ]
[ "$(joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php -r 'echo PHP_VERSION;')" = "$old_php" ]
[ "$(docker inspect --format '{{.Id}}' "$DB")" = "$old_db" ]
[ "$(sha256sum "$DATA/index.php" | cut -d' ' -f1)" = "$original_index" ]
# Root move is explicit and requires a stopped website. DB storage is untouched.
joomlaSiteCompose "$SITE_NAME" stop
VDM_DOCROOT=site
VDM_MOVE_FILES=true
joomla__TRuST__docroot
[ "$(getJoomlaDocumentRoot "$SITE_NAME")" = /var/www/html/site ]
[ -f "$DATA/site/configuration.php" ]
[ ! -f "$DATA/index.php" ]
VDM_MOVE_FILES=false
joomlaSiteCompose "$SITE_NAME" up -d --wait "$WEB" "$HTTP"
http_acceptance
VDM_WEBSERVER=apache
joomla__TRuST__webserver
http_acceptance
[ "$(docker inspect --format '{{.Id}}' "$DB")" = "$old_db" ]
[ "$(sha256sum "$DATA/site/index.php" | cut -d' ' -f1)" = "$original_index" ]
joomlaSiteCompose "$SITE_NAME" exec -T "$WEB" php -r '
 require "/var/www/html/site/configuration.php"; $c=new JConfig;
 $db=new mysqli(explode(":",$c->host)[0],$c->user,$c->password,$c->db);
 exit($db->query("SELECT message FROM octojoom_marker")->fetch_row()[0] === "retained website data" ? 0 : 1);
'
printf 'Web runtime integration passed: Joomla %s; Apache -> Nginx -> nested root -> Apache; files, DB, API, SEF, admin login and assets retained.\n' "$installed"
