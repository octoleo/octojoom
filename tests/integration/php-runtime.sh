#!/usr/bin/env bash
# Exercise real published PHP variants, effective INI changes and rollback with
# Apache, MariaDB and a minimal installed-manifest/JConfig/SQL fixture. This is
# runtime acceptance, not Joomla installer or extension compatibility coverage.
# Requires Linux, Docker Compose v2, jq, curl and root/passwordless sudo.
# shellcheck disable=SC2034,SC2016
set -E -e -o pipefail
# Preserve actionable CI failures without printing commands or credentials.
trap 'printf "PHP integration failed at line %s (exit %s).\\n" "$LINENO" "$?" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in docker jq curl sha256sum; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
docker info >/dev/null
docker compose version >/dev/null
WORK=$(mktemp -d "${TMPDIR:-/tmp}/octojoom-php.XXXXXXXX")
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')
PROJECT="octojoom-php-$RUN_ID"
VDM_HOME_PATH="$WORK/home"
VDM_SRC_PATH="$VDM_HOME_PATH/config"
VDM_REPO_PATH="$VDM_HOME_PATH/Docker"
VDM_PROJECT_PATH="$VDM_HOME_PATH/Projects"
VDM_CONTAINER_TYPE=joomla
VDM_CONTAINER="runtime.localhost"
SITE="$VDM_REPO_PATH/joomla/available/$VDM_CONTAINER"
COMPOSE="$SITE/docker-compose.yml"
ENV_FILE="$VDM_REPO_PATH/joomla/.env"
WEB="joomla$RUN_ID"
DB="mariadb$RUN_ID"
OCTOJOOM_NON_INTERACTIVE=true
OCTOJOOM_OUTPUT=text
OS_NUMBER=1
BACK_TITLE='Octojoom PHP integration'
# Floating source is inspected at runtime; no current Joomla release is frozen.
IMAGE="${OCTOJOOM_PHP_TEST_IMAGE:-joomla:php8.3-apache}"
TARGET_PHP="${OCTOJOOM_PHP_TEST_VERSION:-8.4}"

privileged() { if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi; }
cleanup() {
  local status=$?
  trap - EXIT INT TERM ERR
  set +e
  if [ -f "$COMPOSE" ]; then
    if (( status != 0 )); then docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE" logs --tail 60 >&2; fi
    docker compose --project-name "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE" down -v --remove-orphans >/dev/null
  fi
  docker rm -fv "octojoom-seed-$RUN_ID" >/dev/null 2>&1
  privileged rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Use the production functions without interactive startup or dependency setup.
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom")
mkdir -p "$SITE" "$VDM_SRC_PATH" "$VDM_PROJECT_PATH/$RUN_ID/joomla/administrator/manifests/files" "$VDM_REPO_PATH/joomla/enabled"
printf 'VDM_PROJECT_PATH="%s"\nVDM_%s_DB="runtime"\nVDM_%s_DB_USER="runtime"\nVDM_%s_DB_PASS="test-runtime-password"\nVDM_%s_DB_ROOT="test-root-password"\nVDM_OTHER_DB_PASS="must-not-copy"\n' \
  "$VDM_PROJECT_PATH" "${RUN_ID^^}" "${RUN_ID^^}" "${RUN_ID^^}" "${RUN_ID^^}" > "$ENV_FILE"
chmod 600 "$ENV_FILE"
printf 'VDM_memory_limit="128M"\n' > "$VDM_SRC_PATH/.env"

docker pull "$IMAGE"
probe=$(joomlaRuntimeProbeImage "$IMAGE")
version=$(jq -r '.joomla' <<< "$probe")
old_php=$(jq -r '.php' <<< "$probe")
[ "$version" != null ]
docker create --name "octojoom-seed-$RUN_ID" "$IMAGE" >/dev/null
docker cp "octojoom-seed-$RUN_ID:/usr/src/joomla/administrator/manifests/files/joomla.xml" "$VDM_PROJECT_PATH/$RUN_ID/joomla/administrator/manifests/files/joomla.xml"
docker rm -v "octojoom-seed-$RUN_ID" >/dev/null
cat > "$VDM_PROJECT_PATH/$RUN_ID/joomla/configuration.php" <<PHP
<?php
class JConfig {
 public \$host = '$DB';
 public \$user = 'runtime';
 public \$password = 'test-runtime-password';
 public \$db = 'runtime';
 public \$dbtype = 'mysqli';
}
PHP
cat > "$VDM_PROJECT_PATH/$RUN_ID/joomla/index.php" <<'PHP'
<?php
require __DIR__ . '/configuration.php';
$c = new JConfig;
$db = new mysqli($c->host, $c->user, $c->password, $c->db);
$result = $db->query('SELECT message FROM runtime_marker LIMIT 1');
echo $result->fetch_row()[0], ':', PHP_VERSION;
PHP
cat > "$COMPOSE" <<YAML
name: $PROJECT
services:
  $DB:
    image: mariadb:11.4
    container_name: $DB
    environment:
      - MARIADB_DATABASE=\${VDM_${RUN_ID^^}_DB}
      - MARIADB_USER=\${VDM_${RUN_ID^^}_DB_USER}
      - MARIADB_PASSWORD=\${VDM_${RUN_ID^^}_DB_PASS}
      - MARIADB_ROOT_PASSWORD=\${VDM_${RUN_ID^^}_DB_ROOT}
    volumes:
      - database:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 2s
      timeout: 5s
      retries: 60
  $WEB:
    image: $IMAGE
    container_name: $WEB
    entrypoint: ["/usr/local/bin/docker-php-entrypoint"]
    command: ["apache2-foreground"]
    environment:
      - JOOMLA_DB_HOST=$DB:3306
      - JOOMLA_DB_NAME=\${VDM_${RUN_ID^^}_DB}
      - JOOMLA_DB_USER=\${VDM_${RUN_ID^^}_DB_USER}
      - JOOMLA_DB_PASSWORD=\${VDM_${RUN_ID^^}_DB_PASS}
    volumes:
      - "\${VDM_PROJECT_PATH}/$RUN_ID/joomla:/var/www/html"
    ports:
      - "127.0.0.1::80"
    depends_on:
      $DB:
        condition: service_healthy
    labels:
      - "io.octojoom.integration=$RUN_ID"
      - "custom.label=preserved"
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/"]
      interval: 2s
      timeout: 5s
      retries: 60
volumes:
  database:
YAML
# Files are nonsecret fixtures but Apache needs traversal through private temp parents.
chmod 755 "$WORK" "$VDM_HOME_PATH" "$VDM_PROJECT_PATH" "$VDM_PROJECT_PATH/$RUN_ID" "$VDM_PROJECT_PATH/$RUN_ID/joomla"
chmod 644 "$VDM_PROJECT_PATH/$RUN_ID/joomla/"*.php
migrationRunCompose "$ENV_FILE" "$COMPOSE" up -d --wait "$DB"
docker exec "$DB" mariadb -uroot -ptest-root-password runtime -e "CREATE TABLE runtime_marker(message VARCHAR(100)); INSERT INTO runtime_marker VALUES('preserved-data');"
migrationRunCompose "$ENV_FILE" "$COMPOSE" up -d --wait "$WEB"
ln -s "$SITE" "$VDM_REPO_PATH/joomla/enabled/$VDM_CONTAINER"
original_hash=$(sha256sum "$VDM_PROJECT_PATH/$RUN_ID/joomla/configuration.php" | cut -d' ' -f1)
original_db=$(docker inspect --format '{{.Id}}' "$DB")

tags=$(joomlaRuntimeTags joomla)
VDM_JV=''
while IFS= read -r tag; do
  if [[ "$tag" == "$version-php$TARGET_PHP-apache"* ]]; then VDM_JV="$tag"; break; fi
done <<< "$tags"
[ -n "$VDM_JV" ] || { echo "No published $version PHP $TARGET_PHP Apache candidate is available." >&2; exit 1; }
OCTOJOOM_CLI_KEYS=(VDM_JV)
OCTOJOOM_CLI_VALUES=("$VDM_JV")
VDM_ACTION=switch
joomla__TRuST__php
new_php=$(joomlaSiteCompose "$VDM_CONTAINER" exec -T "$WEB" php -r 'echo PHP_VERSION;')
[[ "$new_php" == "$TARGET_PHP."* && "$new_php" != "$old_php" ]]
[ "$(joomlaRuntimeInstalledVersion "$VDM_CONTAINER")" = "$version" ]
[ "$(sha256sum "$VDM_PROJECT_PATH/$RUN_ID/joomla/configuration.php" | cut -d' ' -f1)" = "$original_hash" ]
[ "$(docker inspect --format '{{.Id}}' "$DB")" = "$original_db" ]
grep -q 'custom.label=preserved' "$COMPOSE"
if grep -q must-not-copy "$SITE/.env"; then echo "Unrelated secret copied" >&2; exit 1; fi

VDM_ACTION=settings
VDM_memory_limit=512M
VDM_max_execution_time=180
OCTOJOOM_CLI_KEYS=(VDM_memory_limit VDM_max_execution_time)
OCTOJOOM_CLI_VALUES=(512M 180)
joomla__TRuST__php
[ "$(joomlaSiteCompose "$VDM_CONTAINER" exec -T "$WEB" php -r 'echo get_cfg_var("memory_limit");')" = 512M ]
[ "$(joomlaSiteCompose "$VDM_CONTAINER" exec -T "$WEB" php -r 'echo get_cfg_var("max_execution_time");')" = 180 ]
grep -q 'VDM_memory_limit="128M"' "$VDM_SRC_PATH/.env"
[ "$(docker exec "$DB" mariadb -uroot -ptest-root-password --batch --skip-column-names runtime -e 'SELECT message FROM runtime_marker')" = preserved-data ]

# A second edit changes only the already-mounted file. PHP must reload the new
# startup value even when the Compose service definition itself is unchanged.
VDM_memory_limit=768M
OCTOJOOM_CLI_KEYS=(VDM_memory_limit)
OCTOJOOM_CLI_VALUES=(768M)
joomla__TRuST__php
[ "$(joomlaSiteCompose "$VDM_CONTAINER" exec -T "$WEB" php -r 'echo get_cfg_var("memory_limit");')" = 768M ]
[ "$(joomlaSiteCompose "$VDM_CONTAINER" exec -T "$WEB" php -r 'echo get_cfg_var("max_execution_time");')" = 180 ]
[ "$(docker inspect --format '{{.Id}}' "$DB")" = "$original_db" ]

# An invalid proposed image leaves every published configuration untouched.
previous=$(sha256sum "$COMPOSE" "$SITE/.env")
VDM_ACTION=switch
VDM_JV=octojoom-intentionally-missing-runtime
OCTOJOOM_CLI_KEYS=(VDM_JV)
OCTOJOOM_CLI_VALUES=("$VDM_JV")
if joomla__TRuST__php; then echo 'A nonexistent image unexpectedly succeeded.' >&2; exit 1; fi
[ "$(sha256sum "$COMPOSE" "$SITE/.env")" = "$previous" ]
printf 'PHP runtime integration passed: %s -> %s; installed Joomla %s, files and database retained.\n' "$old_php" "$new_php" "$version"
