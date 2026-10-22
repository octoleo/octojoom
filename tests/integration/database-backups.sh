#!/usr/bin/env bash
# Real Joomla/database acceptance for features 07–09. Each CI matrix row uses
# independent Docker resources, actual published images and the production
# setup, SQL, backup and database-change handlers. No daemon commands are mocked.
# Requires Linux, Docker Compose v2, jq, curl, ZIP/tar tools and passwordless sudo.
# shellcheck disable=SC2034,SC2016
set -E -e -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENGINE="${OCTOJOOM_DB_TEST_ENGINE:-mariadb}"
JOOMLA_IMAGE="${OCTOJOOM_DB_TEST_JOOMLA_IMAGE:-joomla:apache}"
PHASE=initialization
trap 'printf "Database integration failed: engine=%s phase=%s line=%s status=%s\n" "$ENGINE" "$PHASE" "$LINENO" "$?" >&2' ERR
for required in docker jq curl sha256sum tar gzip zip unzip script; do
  command -v "$required" >/dev/null || { printf 'Missing %s\n' "$required" >&2; exit 1; }
done
[[ "$OSTYPE" == linux* ]] || { echo 'This acceptance test requires Linux.' >&2; exit 1; }
docker info >/dev/null
docker compose version >/dev/null
if (( EUID != 0 )); then sudo -n true; fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/octojoom-database.XXXXXXXX")
RUN_ID=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr '0123456789' 'ghijklmnop')
NETWORK="octojoom-database-$RUN_ID"
LABEL="io.octojoom.integration=$RUN_ID"
DOMAIN="$RUN_ID.localhost"
SOURCE_KEY="source$RUN_ID"
VOLUME_KEY="volume$RUN_ID"
SOURCE="source.$DOMAIN"
VOLUME_SITE="volume.$DOMAIN"
VDM_HOME_PATH="$WORK/home"
VDM_SRC_PATH="$VDM_HOME_PATH/config"
VDM_REPO_PATH="$VDM_HOME_PATH/Docker"
VDM_PROJECT_PATH="$VDM_HOME_PATH/Projects"
ARCHIVES="$WORK/archives with spaces"
OS_NUMBER=1
PROGRAM_NAME=Octojoom
BACK_TITLE='Octojoom database integration'
VDM_TRAEFIK_GATEWAY="$NETWORK"
VDM_MULTI_DOMAIN=false VDM_UPDATE_HOST=false VDM_SECURE=false
VDM_EXPERT_MODE=false VDM_FORCE=false VDM_ARG_DOMAIN=false
OCTOJOOM_NON_INTERACTIVE=true OCTOJOOM_OUTPUT=text

privileged() { if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi; }
cleanup() {
  local status=$? compose directory site env_file resource
  trap - EXIT INT TERM ERR
  set +e
  for compose in "$VDM_REPO_PATH/joomla/available/"*/docker-compose.yml; do
    [ -f "$compose" ] || continue
    directory="${compose%/*}" site="${directory##*/}"
    env_file="$VDM_REPO_PATH/joomla/.env"
    [ ! -f "$directory/.env" ] || env_file="$directory/.env"
    if (( status != 0 )); then
      printf 'Runtime diagnostics: %s\n' "$site" >&2
      timeout 15s docker compose --env-file "$env_file" -f "$compose" ps --all >&2
      timeout 15s docker compose --env-file "$env_file" -f "$compose" logs --tail 40 >&2
    fi
    timeout 45s docker compose --env-file "$env_file" -f "$compose" down -v --remove-orphans >/dev/null
  done
  while IFS= read -r resource; do
    [ -z "$resource" ] || timeout 20s docker rm -fv "$resource" >/dev/null
  done < <(docker ps -aq --filter "label=$LABEL")
  # Successful and failed cutovers intentionally retain old/candidate volumes.
  # Their site keys contain this run's unique ID; remove only those fixtures.
  while IFS= read -r resource; do
    [[ "$resource" == *"$RUN_ID"* ]] || continue
    timeout 20s docker volume rm "$resource" >/dev/null
  done < <(docker volume ls --format '{{.Name}}')
  docker network rm "$NETWORK" >/dev/null 2>&1
  privileged rm -rf -- "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Load the executable's functions without installing it or changing host config.
# shellcheck disable=SC1090
source <(awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom")
mkdir -p "$VDM_SRC_PATH" "$VDM_PROJECT_PATH" "$VDM_REPO_PATH/joomla/available" "$VDM_REPO_PATH/joomla/enabled" "$ARCHIVES"
chmod 755 "$WORK" "$VDM_HOME_PATH" "$VDM_PROJECT_PATH"
printf 'VDM_DOMAIN="%s"\nVDM_MULTI_DOMAIN=false\nVDM_UPDATE_HOST=false\n' "$DOMAIN" > "$VDM_SRC_PATH/.env"
docker network create --label "$LABEL" "$NETWORK" >/dev/null

case "$ENGINE" in
  mariadb) DATABASE_IMAGE="${OCTOJOOM_DB_TEST_SOURCE_IMAGE:-mariadb:lts}"; CHANGE_IMAGE="${OCTOJOOM_DB_TEST_TARGET_IMAGE:-mariadb:latest}" ;;
  mysql) DATABASE_IMAGE="${OCTOJOOM_DB_TEST_SOURCE_IMAGE:-mysql:lts}"; CHANGE_IMAGE="${OCTOJOOM_DB_TEST_TARGET_IMAGE:-mysql:latest}" ;;
  postgres)
    CHANGE_IMAGE="${OCTOJOOM_DB_TEST_TARGET_IMAGE:-postgres:latest}"
    if [ -n "${OCTOJOOM_DB_TEST_SOURCE_IMAGE:-}" ]; then DATABASE_IMAGE="$OCTOJOOM_DB_TEST_SOURCE_IMAGE"
    else
      # Discover the published current major; exercise a logical major upgrade
      # from its predecessor without freezing a particular current release.
      docker pull "$CHANGE_IMAGE" >&2
      pg_major=$(docker image inspect "$CHANGE_IMAGE" | jq -er '.[0].Config.Env[] | select(startswith("PG_MAJOR=")) | split("=")[1]')
      [[ "$pg_major" =~ ^[0-9]+$ && "$pg_major" -gt 1 ]]
      DATABASE_IMAGE="postgres:$((pg_major - 1))"
    fi ;;
  *) printf 'Unsupported acceptance engine: %s\n' "$ENGINE" >&2; exit 1 ;;
esac

# Floating LTS/latest aliases sometimes converge. Inspect the real binaries and,
# if needed, discover a distinct maintained numeric tag from Docker's official
# image catalogue. Explicit overrides must themselves describe distinct versions.
PHASE=select-distinct-database-versions
joomlaDatabaseImageFacts "$CHANGE_IMAGE" "$ENGINE"
TARGET_VERSION="$VDM_DATABASE_IMAGE_VERSION"
joomlaDatabaseImageFacts "$DATABASE_IMAGE" "$ENGINE"
SOURCE_VERSION="$VDM_DATABASE_IMAGE_VERSION"
if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
  if [ -n "${OCTOJOOM_DB_TEST_SOURCE_IMAGE:-}" ]; then
    printf 'Source and target overrides resolve to the same server version: %s\n' "$SOURCE_VERSION" >&2
    exit 1
  fi
  curl --fail --silent --show-error --retry 3 \
    "https://raw.githubusercontent.com/docker-library/official-images/master/library/$ENGINE" > "$WORK/database-tags"
  found_version=false
  while IFS= read -r candidate; do
    [ "$candidate" != "$TARGET_VERSION" ] || continue
    [ "$(printf '%s\n' "$candidate" "$TARGET_VERSION" | sort -V | head -n 1)" = "$candidate" ] || continue
    if joomlaDatabaseImageFacts "$ENGINE:$candidate" "$ENGINE" &&
        [ "$VDM_DATABASE_IMAGE_VERSION" != "$TARGET_VERSION" ] &&
        joomlaDatabaseJoomlaCapability "$JOOMLA_IMAGE" "$ENGINE" "$VDM_DATABASE_IMAGE_VERSION" >/dev/null; then
      DATABASE_IMAGE="$ENGINE:$candidate" SOURCE_VERSION="$VDM_DATABASE_IMAGE_VERSION"
      found_version=true
      break
    fi
  done < <(sed -n 's/^Tags: //p' "$WORK/database-tags" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -E '^[0-9]+\.[0-9]+(\.[0-9]+)?$' | sort -Vu -r)
  "$found_version" || { echo 'No distinct supported published source version was found.' >&2; exit 1; }
fi
[ "$SOURCE_VERSION" != "$TARGET_VERSION" ]
printf 'Version acceptance: %s (%s) -> %s (%s)\n' "$DATABASE_IMAGE" "$SOURCE_VERSION" "$CHANGE_IMAGE" "$TARGET_VERSION"

# Every invocation receives real parser inputs in isolated request scope. No
# previous selected site, table list or destructive flag can leak into it.
request() (
  local task="$1"
  shift
  local VDM_CONTAINER='' VDM_ACTION='' VDM_FILE='' VDM_INPUT_FILE='' VDM_ALL=false
  local VDM_KEY='' VDM_ENV_KEY='' VDM_SUBDOMAIN='' VDM_JV='' VDM_J_REPO=''
  local VDM_CONFIRM=false VDM_PRE_BACKUP=false VDM_OVERWRITE=false VDM_DELETE_SOURCE=false
  local VDM_TIMESTAMP=false VDM_ENABLE=false VDM_TARGET='' VDM_DESTINATION=''
  local -a VDM_TABLES=() VDM_SITES=()
  parseCLI --type joomla --task "$task" --non-interactive "$@" || return $?
  "joomla__TRuST__$task"
)

create_site() {
  local key="$1" subdomain="$2" bind="$3" site="$2.$DOMAIN" compose service temporary
  request setup --key "$key" --env-key "${key^^}" --domain "$DOMAIN" --sub-domain "$subdomain" \
    --image-source "${JOOMLA_IMAGE%:*}" --image-tag "${JOOMLA_IMAGE##*:}" \
    --engine "$ENGINE" --database-image "$DATABASE_IMAGE" \
    --db-name "database_$key" --db-user "user_$key" \
    --db-password 'integration-Db-$literal#value' --db-root-password 'integration-root-password' \
    --auto-install true --site-name 'Octojoom database acceptance' \
    --admin-username integrationadmin --admin-user 'Integration Administrator' \
    --admin-email admin@example.invalid --admin-password integration-admin-password-2026 \
    --enable false --phpmyadmin false --mailcatcher false --secure false --cloudflare false \
    --update-hosts false --customize false --persistence "$bind" --db-persistence "$bind" >&2
  compose="$VDM_REPO_PATH/joomla/available/$site/docker-compose.yml"
  service="joomla$key"
  temporary="$WORK/$key.compose"
  # Use an actual host-only HTTP port; no external proxy or public DNS is needed.
  printf '    ports:\n      - "127.0.0.1::80"\n' > "$WORK/property"
  joomlaSetServiceProperty "$compose" "$temporary" "$service" ports "$WORK/property"
  mv "$temporary" "$compose"
  printf '    labels:\n      - "%s"\n      - "custom.application.label=preserved"\n' "$LABEL" > "$WORK/property"
  joomlaSetServiceProperty "$compose" "$temporary" "$service" labels "$WORK/property"
  mv "$temporary" "$compose"
  joomlaSetServiceProperty "$compose" "$temporary" "mariadb$key" labels "$WORK/property"
  mv "$temporary" "$compose"
  if [ "$bind" = true ]; then
    mkdir -p "$VDM_PROJECT_PATH/$key/joomla"
    chmod 755 "$VDM_PROJECT_PATH/$key" "$VDM_PROJECT_PATH/$key/joomla"
  fi
  joomlaSiteCompose "$site" up -d --wait --wait-timeout 300 >&2
  ln -s "$VDM_REPO_PATH/joomla/available/$site" "$VDM_REPO_PATH/joomla/enabled/$site"
  assert_application "$site"
}

assert_application() {
  local site="$1"
  readJoomlaSiteFacts "$site"
  [[ "$VDM_SITE_URL" == http://127.0.0.1:* || "$VDM_SITE_URL" == http://localhost:* ]]
  curl --fail --silent --show-error --retry 5 --retry-all-errors --max-time 30 "$VDM_SITE_URL/" > "$WORK/frontend.html"
  grep -q 'Octojoom database acceptance' "$WORK/frontend.html"
  joomlaSiteCompose "$site" config --format json |
    jq -e --arg service "$VDM_SITE_SERVICE" '.services[$service].labels["custom.application.label"]=="preserved"' >/dev/null
  joomlaDatabaseContext "$site"
}

write_sql() {
  case "$ENGINE" in
    postgres)
      cat > "$WORK/seed.sql" <<'SQL'
CREATE TABLE octojoom_marker(id INTEGER PRIMARY KEY, label VARCHAR(100), payload BYTEA);
INSERT INTO octojoom_marker VALUES(1,'Joomla Ω 日本語',decode('00ff4142','hex'));
CREATE TABLE octojoom_other(id INTEGER PRIMARY KEY, label VARCHAR(100));
INSERT INTO octojoom_other VALUES(1,'unrelated table retained');
SQL
      ;;
    *)
      cat > "$WORK/seed.sql" <<'SQL'
CREATE TABLE octojoom_marker(id INTEGER PRIMARY KEY, label VARCHAR(100), payload BLOB) CHARACTER SET utf8mb4;
INSERT INTO octojoom_marker VALUES(1,'Joomla Ω 日本語',UNHEX('00ff4142'));
CREATE TABLE octojoom_other(id INTEGER PRIMARY KEY, label VARCHAR(100)) CHARACTER SET utf8mb4;
INSERT INTO octojoom_other VALUES(1,'unrelated table retained');
SQL
      ;;
  esac
}

seed_site() {
  local site="$1"
  request database --container "$site" --action execute --file "$WORK/seed.sql" >/dev/null
  readJoomlaSiteFacts "$site"
  joomlaSiteCompose "$site" exec -T "$VDM_SITE_SERVICE" php -r \
    '$p=$argv[1]."/images/octojoom-upload.txt"; if(file_put_contents($p,"retained upload\n")===false) exit(1); exit(chmod($p,0640)&&chown($p,1337)&&chgrp($p,7331)?0:1);' "$VDM_SITE_DOCROOT"
}

# Read through the installed Joomla configuration, independently of the dump
# client, and compare Unicode and binary bytes after every restore/cutover.
site_state() {
  local site="$1"
  readJoomlaSiteFacts "$site"
  joomlaSiteCompose "$site" exec -T "$VDM_SITE_SERVICE" php -r '
    require $argv[1]."/configuration.php"; $c=new JConfig;
    $pg=in_array($c->dbtype,["pgsql","postgresql","pdo_pgsql"],true);
    $host=explode(":",$c->host,2); $port=$host[1]??($pg?5432:3306);
    $db=new PDO(($pg?"pgsql":"mysql").":host=".$host[0].";port=".$port.";dbname=".$c->db,$c->user,$c->password,[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
    $row=$db->query("SELECT label,".($pg?"encode(payload, chr(104)||chr(101)||chr(120))":"HEX(payload)")." AS bytes FROM octojoom_marker WHERE id=1")->fetch(PDO::FETCH_ASSOC);
    $other=$db->query("SELECT label FROM octojoom_other WHERE id=1")->fetchColumn();
    echo json_encode(["marker"=>$row["label"]??null,"bytes"=>strtolower($row["bytes"]??""),"other"=>$other,"upload"=>file_get_contents($argv[1]."/images/octojoom-upload.txt"),"mode"=>decoct(fileperms($argv[1]."/images/octojoom-upload.txt")&0777),"owner"=>fileowner($argv[1]."/images/octojoom-upload.txt"),"group"=>filegroup($argv[1]."/images/octojoom-upload.txt")],JSON_UNESCAPED_UNICODE),"\n";
  ' "$VDM_SITE_DOCROOT"
}

assert_state() {
  site_state "$1" | jq -e --arg marker "${2:-Joomla Ω 日本語}" \
    '.marker==$marker and .bytes=="00ff4142" and .other=="unrelated table retained" and .upload=="retained upload\n" and .mode=="640" and .owner==1337 and .group==7331' >/dev/null
}

database_version() (
  local output
  joomlaDatabaseContext "$1" || exit 1
  output=$(printf 'SELECT VERSION();\n' | joomlaDatabaseClient query) || exit 1
  [[ "$output" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?) ]] || exit 1
  printf '%s\n' "${BASH_REMATCH[1]}"
)

retire_site() {
  local site="$1"
  joomlaSiteCompose "$site" down -v --remove-orphans >&2
  rm -f "$VDM_REPO_PATH/joomla/enabled/$site"
  privileged rm -rf -- "$VDM_REPO_PATH/joomla/available/$site"
}

PHASE=real-joomla-installation
create_site "$SOURCE_KEY" source true
create_site "$VOLUME_KEY" volume false
write_sql
seed_site "$SOURCE"
seed_site "$VOLUME_SITE"
assert_state "$SOURCE"
assert_state "$VOLUME_SITE"

PHASE=logical-database-tools
selected_table=octojoom_marker
[ "$ENGINE" != postgres ] || selected_table=public.octojoom_marker
request database --container "$SOURCE" --action tables > "$WORK/tables"
grep -qxF "$selected_table" "$WORK/tables"
request database --container "$SOURCE" --action export --timestamp false --file "$ARCHIVES/database.sql" --compression none
request database --container "$SOURCE" --action export --timestamp false --file "$ARCHIVES/database.sql.gz" --compression gzip
gzip -t "$ARCHIVES/database.sql.gz"
export_hash=$(sha256sum "$ARCHIVES/database.sql.gz")
if request database --container "$SOURCE" --action export --timestamp false --file "$ARCHIVES/database.sql.gz" --compression gzip --overwrite false; then
  echo 'Export overwrote an existing destination without approval.' >&2; exit 1
fi
[ "$(sha256sum "$ARCHIVES/database.sql.gz")" = "$export_hash" ]
request database --container "$SOURCE" --action export --timestamp false --file "$ARCHIVES/selected.sql.gz" --compression gzip --table "$selected_table"
printf 'DELETE FROM octojoom_marker;\n' > "$WORK/delete-marker.sql"
request database --container "$SOURCE" --action execute --file "$WORK/delete-marker.sql" >/dev/null
request database --container "$SOURCE" --action import --file "$ARCHIVES/selected.sql.gz" --import-mode replace --confirm true
assert_state "$SOURCE"
cp "$ARCHIVES/selected.sql.gz" "$WORK/delete-after-import.sql.gz"
request database --container "$SOURCE" --action import --file "$WORK/delete-after-import.sql.gz" --import-mode replace --delete-source true --confirm true
[ ! -e "$WORK/delete-after-import.sql.gz" ]
assert_state "$SOURCE"
printf 'THIS IS INTENTIONALLY INVALID SQL;\n' > "$WORK/invalid.sql"
if request database --container "$SOURCE" --action import --file "$WORK/invalid.sql" --import-mode merge --delete-source true --confirm true; then
  echo 'Invalid SQL was reported as successful.' >&2; exit 1
fi
[ -f "$WORK/invalid.sql" ]
head -c 12 "$ARCHIVES/database.sql.gz" > "$WORK/truncated.sql.gz"
if request database --container "$SOURCE" --action import --file "$WORK/truncated.sql.gz" --import-mode merge --delete-source true --confirm true; then
  echo 'A truncated dump was reported as successful.' >&2; exit 1
fi
[ -f "$WORK/truncated.sql.gz" ]
assert_state "$SOURCE"

if [ "$ENGINE" = postgres ]; then
  PHASE=postgres-native-archive
  request database --container "$SOURCE" --action export --timestamp false --file "$ARCHIVES/selected.pgdump" --compression custom --table "$selected_table"
  request database --container "$SOURCE" --action execute --file "$WORK/delete-marker.sql" >/dev/null
  request database --container "$SOURCE" --action import --file "$ARCHIVES/selected.pgdump" --import-mode replace --confirm true
  assert_state "$SOURCE"
fi

if [ "$ENGINE" = mariadb ]; then
  PHASE=actual-interactive-sql-console
  # util-linux script creates a real controlling PTY. The query result is not a
  # substring of its echoed input, so a terminal echo cannot satisfy the check.
  awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' "$ROOT/src/octojoom" > "$WORK/console-functions.sh"
  cat > "$WORK/console.sh" <<'CONSOLE'
set -e -o pipefail
source "$OCTOJOOM_TEST_FUNCTIONS"
parseCLI --type joomla --task database --container "$OCTOJOOM_TEST_SITE" --action console
joomla__TRuST__database
CONSOLE
  printf "SELECT CONCAT('octojoom','-console-',6*7);\nquit;\n" |
    env VDM_HOME_PATH="$VDM_HOME_PATH" VDM_SRC_PATH="$VDM_SRC_PATH" VDM_REPO_PATH="$VDM_REPO_PATH" \
      VDM_PROJECT_PATH="$VDM_PROJECT_PATH" OS_NUMBER=1 OCTOJOOM_NON_INTERACTIVE=false \
      OCTOJOOM_TEST_FUNCTIONS="$WORK/console-functions.sh" OCTOJOOM_TEST_SITE="$SOURCE" \
      OCTOJOOM_TEST_CONSOLE="$WORK/console.sh" \
      timeout 90s script -q -e -c 'bash "$OCTOJOOM_TEST_CONSOLE"' /dev/null > "$WORK/console.transcript" 2>&1
  grep -qF 'octojoom-console-42' "$WORK/console.transcript"
fi

PHASE=portable-backup-creation
for format in tar.gz zip; do
  for scope in full website; do
    request backup --container "$SOURCE" --action create --scope "$scope" --format "$format" \
      --file "$ARCHIVES/$scope.$format" --timestamp false --overwrite false
    request backup --container "$SOURCE" --action verify --file "$ARCHIVES/$scope.$format"
  done
done
request backup --container "$VOLUME_SITE" --action create --scope full --format tar.gz --file "$ARCHIVES/named-volume.tar.gz"
assert_state "$SOURCE"
assert_state "$VOLUME_SITE"
if [ "$ENGINE" = mariadb ]; then
  # Preserve the original raw-project archive contract as an actual restore
  # input; its older activation requires a proxy, so activate the fixture below.
  exportJoomlaMigration "$SOURCE" "$ARCHIVES/legacy-raw.tar.gz"
fi
joomlaSiteCompose "$SOURCE" stop >&2
joomlaSiteCompose "$VOLUME_SITE" stop >&2

PHASE=independent-backup-restoration
restore_number=0
for archive in "$ARCHIVES/full.tar.gz" "$ARCHIVES/full.zip" "$ARCHIVES/website.tar.gz" "$ARCHIVES/website.zip" "$ARCHIVES/named-volume.tar.gz"; do
  restore_number=$((restore_number + 1))
  # Destination keys stay within the original alphabetic identity convention.
  suffix=$(printf '\\%03o' "$((96 + restore_number))")
  printf -v suffix '%b' "$suffix"
  target_key="restore${suffix}${RUN_ID}"
  target="restore${suffix}.$DOMAIN"
  request backup --container "$SOURCE" --action restore --target new --file "$archive" \
    --key "$target_key" --domain "$DOMAIN" --sub-domain "restore$suffix" --enable true --secure false
  assert_application "$target"
  assert_state "$target"
  [ -z "$(joomlaSiteCompose "$SOURCE" ps --status running --services)" ]
  [ -z "$(joomlaSiteCompose "$VOLUME_SITE" ps --status running --services)" ]
  printf "UPDATE octojoom_marker SET label='destination changed' WHERE id=1;\n" > "$WORK/change.sql"
  request database --container "$target" --action execute --file "$WORK/change.sql" >/dev/null
  assert_state "$target" 'destination changed'
  retire_site "$target"
done
if [ "$ENGINE" = mariadb ]; then
  PHASE=legacy-raw-archive-restoration
  target="legacy.$DOMAIN"
  request backup --container "$SOURCE" --action restore --target new --file "$ARCHIVES/legacy-raw.tar.gz" \
    --key "legacy$RUN_ID" --domain "$DOMAIN" --sub-domain legacy --enable false --secure false
  joomlaSiteCompose "$target" up -d --wait --wait-timeout 300 >&2
  assert_application "$target"
  assert_state "$target"
  [ -z "$(joomlaSiteCompose "$SOURCE" ps --status running --services)" ]
  retire_site "$target"
fi
joomlaSiteCompose "$SOURCE" up -d --wait --wait-timeout 300 >&2
joomlaSiteCompose "$VOLUME_SITE" up -d --wait --wait-timeout 300 >&2
assert_state "$SOURCE"
assert_state "$VOLUME_SITE"

PHASE=restore-current-and-pre-restore-backup
printf "UPDATE octojoom_marker SET label='before in-place restoration' WHERE id=1;\n" > "$WORK/change.sql"
request database --container "$SOURCE" --action execute --file "$WORK/change.sql" >/dev/null
archive_count_before=$(find "$ARCHIVES" -maxdepth 1 -type f | wc -l)
request backup --container "$SOURCE" --action restore --target current --file "$ARCHIVES/full.tar.gz" \
  --destination "$ARCHIVES" --pre-backup true --confirm true
assert_application "$SOURCE"
assert_state "$SOURCE"
archive_count_after=$(find "$ARCHIVES" -maxdepth 1 -type f | wc -l)
[ "$archive_count_after" -gt "$archive_count_before" ]

PHASE=batch-operations
mkdir -p "$ARCHIVES/batch-sql" "$ARCHIVES/batch-backup"
request database --container "$SOURCE" --container "$VOLUME_SITE" --action export --destination "$ARCHIVES/batch-sql" --compression gzip --timestamp false
[ "$(find "$ARCHIVES/batch-sql" -maxdepth 1 -type f -name '*.gz' | wc -l)" -eq 2 ]
request backup --all --action create --scope database --format tar.gz --destination "$ARCHIVES/batch-backup" --timestamp false
[ "$(find "$ARCHIVES/batch-backup" -maxdepth 1 -type f -name '*.tar.gz' | wc -l)" -eq 2 ]

PHASE=independent-database-change-clone
clone_target="dbclone.$DOMAIN"
request database --container "$SOURCE" --action change --engine "$ENGINE" --database-image "$CHANGE_IMAGE" \
  --data-mode clone --confirm true --pre-backup false --key "dbclone$RUN_ID" \
  --domain "$DOMAIN" --sub-domain dbclone --enable true --secure false
assert_application "$clone_target"
assert_state "$clone_target"
joomlaSiteCompose "$SOURCE" stop >&2
assert_application "$clone_target"
assert_state "$clone_target"
retire_site "$clone_target"
joomlaSiteCompose "$SOURCE" up -d --wait --wait-timeout 300 >&2
assert_state "$SOURCE"

PHASE=fresh-database-keeps-website-stopped
joomlaDatabaseContext "$VOLUME_SITE"
fresh_old_volume=$(docker inspect "$VDM_DB_SERVICE" | jq -er '.[0].Mounts[] | select(.Destination|startswith("/var/lib/")) | .Name' | head -n 1)
request database --container "$VOLUME_SITE" --action change --engine "$ENGINE" --database-image "$CHANGE_IMAGE" \
  --data-mode fresh --confirm true --pre-backup true
joomlaDatabaseContext "$VOLUME_SITE"
[ -z "$(joomlaDatabaseTables "$VOLUME_SITE")" ]
[ "$(docker inspect --format '{{.State.Running}}' "joomla$VOLUME_KEY")" = false ]
docker volume inspect "$fresh_old_volume" >/dev/null

PHASE=database-version-change-with-fresh-storage
before_version=$(database_version "$SOURCE")
[ "$before_version" = "$SOURCE_VERSION" ]
joomlaDatabaseContext "$SOURCE"
database_service="$VDM_DB_SERVICE"
old_mount=$(docker inspect "$database_service" | jq -ec '[.[0].Mounts[] | select(.Destination|startswith("/var/lib/"))][0]')
old_storage=$(jq -r .Source <<< "$old_mount")
request database --container "$SOURCE" --action change --engine "$ENGINE" --database-image "$CHANGE_IMAGE" \
  --data-mode preserve --confirm true --pre-backup true
assert_application "$SOURCE"
assert_state "$SOURCE"
joomlaDatabaseContext "$SOURCE"
after_version=$(database_version "$SOURCE")
[ "$after_version" = "$TARGET_VERSION" ] && [ "$after_version" != "$before_version" ]
printf 'Measured server version changed: %s -> %s\n' "$before_version" "$after_version"
new_storage=$(docker inspect "$VDM_DB_SERVICE" | jq -er '.[0].Mounts[] | select(.Destination|startswith("/var/lib/")) | .Source' | head -n 1)
[ "$new_storage" != "$old_storage" ]
if [ "$(jq -r .Type <<< "$old_mount")" = volume ]; then
  docker volume inspect "$(jq -r .Name <<< "$old_mount")" >/dev/null
else
  privileged test -d "$old_storage"
fi

if [ "$ENGINE" = mysql ]; then
  PHASE=successful-mysql-to-mariadb-engine-change
  request database --container "$SOURCE" --action change --engine mariadb --database-image mariadb:lts \
    --data-mode preserve --confirm true --pre-backup true
  assert_application "$SOURCE"
  assert_state "$SOURCE"
  joomlaDatabaseContext "$SOURCE"
  [ "$VDM_DB_ENGINE" = mariadb ]
fi

if [ "$ENGINE" = mariadb ]; then
  PHASE=failed-real-engine-import-rolls-back
  # INET6 is a MariaDB-native column type. MySQL cannot import this schema;
  # exercise the real candidate importer failing after source quiescence.
  printf 'CREATE TABLE octojoom_incompatible(address INET6);\n' > "$WORK/incompatible.sql"
  request database --container "$SOURCE" --action execute --file "$WORK/incompatible.sql" >/dev/null
  readJoomlaSiteFacts "$SOURCE"
  before_change=$(sha256sum "$VDM_SITE_COMPOSE" "$VDM_SITE_ENV")
  before_config=$(joomlaSiteCompose "$SOURCE" exec -T "$VDM_SITE_SERVICE" php -r 'echo hash_file("sha256",$argv[1]."/configuration.php");' "$VDM_SITE_DOCROOT")
  if request database --container "$SOURCE" --action change --engine mysql --database-image mysql:lts \
    --data-mode preserve --confirm true --pre-backup true > "$WORK/failed-change.stdout" 2> "$WORK/failed-change.stderr"; then
    echo 'An incompatible MariaDB-to-MySQL schema change unexpectedly succeeded.' >&2; exit 1
  fi
  # A refusal before cutover would not test rollback. Require the actual SQL
  # import failure marker produced only after the candidate database started.
  cat "$WORK/failed-change.stderr" >&2
  grep -qF 'The source SQL is not compatible with this target; rolling back.' "$WORK/failed-change.stderr"
  readJoomlaSiteFacts "$SOURCE"
  [ "$(joomlaSiteCompose "$SOURCE" exec -T "$VDM_SITE_SERVICE" php -r 'echo hash_file("sha256",$argv[1]."/configuration.php");' "$VDM_SITE_DOCROOT")" = "$before_config" ]
  [ "$(sha256sum "$VDM_SITE_COMPOSE" "$VDM_SITE_ENV")" = "$before_change" ]
  assert_application "$SOURCE"
  assert_state "$SOURCE"
  joomlaDatabaseContext "$SOURCE"
  [ "$VDM_DB_ENGINE" = mariadb ]
fi

printf 'Database integration passed: %s, real Joomla, logical SQL, selected tables, Unicode/binary data, ZIP/tar restores, named volumes, batch, and fresh-storage database change.\n' "$ENGINE"
