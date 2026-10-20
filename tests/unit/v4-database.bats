#!/usr/bin/env bats
# shellcheck shell=bash
# Fixture literals and dynamically loaded function overrides are intentional.
# shellcheck disable=SC1090,SC2016
# shellcheck disable=SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  export TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR" "$SANDBOX/backups"
  VDM_BACKUP_PATH="$SANDBOX/backups"
  V4_RESULT_FILE=''
  V4_REQUEST='{"site":"source.test","yes":true}'
  database_fixture source.test source
  v4LoadSite source.test
  printf 'joomlasource\nmariadbsource\n' > "$SANDBOX/running"
  printf 'CREATE TABLE original (id INT);\n' > "$SANDBOX/current.sql"
  : > "$SANDBOX/operations"
  v4RunHook() { printf 'hook %s\n' "$1" >> "$SANDBOX/operations"; }
  v4DatabaseDump() { [ ! -f "$SANDBOX/fail-dump" ] || return 1; cat "$SANDBOX/current.sql"; }
  v4DatabaseReset() { printf 'reset\n' >> "$SANDBOX/operations"; : > "$SANDBOX/current.sql"; }
  v4DatabaseProbe() { return 0; }
  v4WaitReady() { return 0; }
  v4DatabaseImportSql() {
    local sql
    sql=$(cat)
    printf 'import\n' >> "$SANDBOX/operations"
    if [[ "$sql" = *BROKEN* ]] || [ -f "$SANDBOX/fail-import" ]; then return 1; fi
    printf '%s\n' "$sql" > "$SANDBOX/current.sql"
  }
  v4Compose() {
    printf 'compose %s\n' "$*" >> "$SANDBOX/operations"
    local action="$1" service line
    shift
    case "$action" in
      ps) cat "$SANDBOX/running" ;;
      down) : > "$SANDBOX/running" ;;
      stop)
        if [ "$#" -eq 0 ]; then : > "$SANDBOX/running"; fi
        for service in "$@"; do
          while IFS= read -r line; do [ "$line" = "$service" ] || printf '%s\n' "$line"; done < "$SANDBOX/running" > "$SANDBOX/next-running"
          mv "$SANDBOX/next-running" "$SANDBOX/running"
        done ;;
      start|up)
        [ "${1:-}" != -d ] || shift
        if [ "$#" -eq 0 ]; then set -- "$V4_WEB_SERVICE" "$V4_DB_SERVICE"; fi
        for service in "$@"; do
          if ! grep -qxF "$service" "$SANDBOX/running"; then printf '%s\n' "$service" >> "$SANDBOX/running"; fi
        done ;;
      *) return 0 ;;
    esac
  }
  v4Exec() { printf 'exec %s\n' "$*" >> "$SANDBOX/operations"; }
}

database_fixture() {
  local host="$1" key="$2" dir="$VDM_REPO_PATH/joomla/available/$1" project="$VDM_PROJECT_PATH/$2"
  mkdir -p "$dir" "$project/joomla" "$project/db"
  jq -n --arg host "$host" --arg key "$key" --arg root "$project" '{schema_version:1,host:$host,key:$key,env_key:($key|ascii_upcase),project_dir:$root,docroot:"joomla",image:"joomla:5.4-php8.3-apache",joomla_version:"5.4",php_version:"8.3",webserver:"apache",profile:"local",http_port:0,database:{engine:"mariadb",version:"11.4",name:"joomla",user:"joomla"},tls:{mode:"none",resolver:"vdmresolver"},services:{mail:false,redis:false,node:false},hooks:{}}' > "$dir/project.json"
  printf 'VDM_PROJECT_PATH="%s"\nVDM_%s_DB="joomla"\nVDM_%s_DB_USER="joomla"\nVDM_%s_DB_PASS="project-secret"\nVDM_%s_DB_ROOT="root-secret"\nVDM_OTHER_DB_PASS="unrelated-secret"\n' "$VDM_PROJECT_PATH" "${key^^}" "${key^^}" "${key^^}" "${key^^}" > "$dir/.env"
  printf 'services:\n  joomla%s:\n    image: joomla:5.4-php8.3-apache\n    environment:\n      JOOMLA_DB_NAME: ${VDM_%s_DB}\n      JOOMLA_DB_USER: ${VDM_%s_DB_USER}\n      JOOMLA_DB_PASSWORD: ${VDM_%s_DB_PASS}\n    volumes:\n      - ${VDM_PROJECT_PATH}/%s/joomla:/var/www/html\n  mariadb%s:\n    environment:\n      MARIADB_ROOT_PASSWORD: ${VDM_%s_DB_ROOT}\n' "$key" "${key^^}" "${key^^}" "${key^^}" "$key" "$key" "${key^^}" > "$dir/docker-compose.yml"
  printf '<?php class JConfig { public $dbprefix = "original_"; }\n' > "$project/joomla/configuration.php"
  printf 'project content\n' > "$project/joomla/index.php"
  printf 'private raw database bytes\n' > "$project/db/ibdata1"
  printf 'custom companion\n' > "$project/README.md"
}

package_fixture() {
  local directory="$1" scope="${2:-database}" created="${3:-2026-01-01T00:00:00Z}"
  mkdir -p "$directory"
  printf 'CREATE TABLE example (id INT);\n' | gzip > "$directory/database.sql.gz"
  jq -n --argjson site "$V4_META" --arg scope "$scope" --arg created "$created" '{schema_version:1,format:"octojoom-logical",scope:$scope,created:$created,label:"unit",site:$site}' > "$directory/manifest.json"
  v4PackageChecksums "$directory"
}

restore_dependencies() {
  v4ProvisionMetadata() {
    local metadata="$1" env="$2" host key
    [ ! -f "$SANDBOX/fail-provision" ] || return 1
    host=$(jq -r '.host' <<< "$metadata"); key=$(jq -r '.key' <<< "$metadata")
    mkdir -p "$VDM_REPO_PATH/joomla/available/$host" "$VDM_PROJECT_PATH/$key/joomla" "$VDM_PROJECT_PATH/$key/db"
    printf '%s\n' "$metadata" > "$VDM_REPO_PATH/joomla/available/$host/project.json"
    cp "$env" "$VDM_REPO_PATH/joomla/available/$host/.env"
    printf 'services: {}\n' > "$VDM_REPO_PATH/joomla/available/$host/docker-compose.yml"
    v4LoadSite "$host"
  }
  v4GenerateCompose() { printf 'regenerate %s\n' "$V4_HOST" >> "$SANDBOX/operations"; }
  v4RealignConfiguration() {
    printf 'realign %s %s\n' "$V4_HOST" "$V4_PROJECT" >> "$SANDBOX/operations"
    [ ! -f "$SANDBOX/fail-realign" ]
  }
}

@test "v4 checksum inventory handles spaces, quotes and thousands of files" {
  package_fixture "$SANDBOX/package"
  mkdir "$SANDBOX/package/files"
  local i
  for i in {1..2500}; do printf '%s\n' "$i" > "$SANDBOX/package/files/a long filename $i.txt"; done
  printf 'quoted\n' > "$SANDBOX/package/files/a\"quoted file.txt"
  v4PackageChecksums "$SANDBOX/package"
  run v4PackageVerify "$SANDBOX/package"
  [ "$status" -eq 0 ]
  [ "$(jq length "$SANDBOX/package/checksums.json")" -eq 2503 ]
}

@test "v4 checksum verification rejects changed, extra and missing files" {
  package_fixture "$SANDBOX/package"
  printf x > "$SANDBOX/package/extra"
  run v4PackageVerify "$SANDBOX/package"
  [ "$status" -ne 0 ]
  rm "$SANDBOX/package/extra"
  printf 'changed' >> "$SANDBOX/package/manifest.json"
  run v4PackageVerify "$SANDBOX/package"
  [ "$status" -ne 0 ]
  rm "$SANDBOX/package/manifest.json"
  run v4PackageVerify "$SANDBOX/package"
  [ "$status" -ne 0 ]
}

@test "v4 archive validation rejects symlinks and duplicate paths" {
  mkdir "$SANDBOX/unsafe"
  printf x > "$SANDBOX/unsafe/file"
  ln -s /etc/passwd "$SANDBOX/unsafe/link"
  tar -czf "$SANDBOX/symlink.tar.gz" -C "$SANDBOX/unsafe" .
  run v4ArchiveValidate "$SANDBOX/symlink.tar.gz"
  [ "$status" -ne 0 ]
  tar -czf "$SANDBOX/duplicate.tar.gz" -C "$SANDBOX/unsafe" file file
  run v4ArchiveValidate "$SANDBOX/duplicate.tar.gz"
  [ "$status" -ne 0 ]
}

@test "v4 archive extraction refuses nonempty target" {
  package_fixture "$SANDBOX/package"
  tar -czf "$SANDBOX/good.tar.gz" -C "$SANDBOX/package" .
  run v4ArchiveExtract "$SANDBOX/good.tar.gz" "$SANDBOX/package"
  [ "$status" -ne 0 ]
}

@test "v4 backup root rejects public paths and symlink parents" {
  V4_REQUEST=$(jq -n --arg root "$V4_DOCROOT/backups" '{backup_path:$root}')
  run v4BackupRoot
  [ "$status" -ne 0 ]
  ln -s "$SANDBOX/backups" "$SANDBOX/linked"
  V4_REQUEST=$(jq -n --arg root "$SANDBOX/linked/nested" '{backup_path:$root}')
  run v4BackupRoot
  [ "$status" -ne 0 ]
}

@test "v4 table selection accepts JSON array and rejects SQL syntax" {
  V4_REQUEST='{"tables":["jos_content","jos_users"]}'
  v4DatabaseTables
  [ "${V4_DB_TABLES[1]}" = jos_users ]
  V4_REQUEST='{"tables":"jos_users; DROP DATABASE joomla"}'
  run v4DatabaseTables
  [ "$status" -eq 2 ]
}

@test "v4 failed export leaves no published dump" {
  touch "$SANDBOX/fail-dump"
  run v4DatabaseWriteDump "$SANDBOX/backups/failed.sql.gz"
  [ "$status" -ne 0 ]
  [ ! -e "$SANDBOX/backups/failed.sql.gz" ]
  [ -z "$(find "$SANDBOX/backups" -type f -print -quit)" ]
}

@test "v4 export refuses overwriting existing backup" {
  printf retained > "$SANDBOX/backups/exists.sql"
  run v4DatabaseWriteDump "$SANDBOX/backups/exists.sql"
  [ "$status" -eq 2 ]
  [ "$(cat "$SANDBOX/backups/exists.sql")" = retained ]
}

@test "v4 export of stopped site restores stopped database state" {
  : > "$SANDBOX/running"
  run v4DbExport
  [ "$status" -eq 0 ]
  [ ! -s "$SANDBOX/running" ]
  grep -q 'compose up -d mariadbsource' "$SANDBOX/operations"
  grep -q 'compose stop mariadbsource' "$SANDBOX/operations"
}

@test "v4 invalid batch fails before starting any export" {
  V4_REQUEST='{"sites":["source.test","../../outside"]}'
  run v4DbExport
  [ "$status" -ne 0 ]
  [ -z "$(find "$SANDBOX/backups" -type f -print -quit)" ]
}

@test "v4 batch export reports per-site failures and nonzero overall" {
  V4_REQUEST='{"sites":["source.test","missing.test"]}'
  run v4DbExport
  [ "$status" -ne 0 ]
  [[ "$output" = *'"site":"source.test"'* ]]
  [[ "$output" = *'"site":"missing.test","ok":false'* ]]
  [ "$(find "$SANDBOX/backups" -name '*.sql.gz' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "v4 full archive excludes raw database and unrelated environment secrets" {
  ln -s /tmp/never-follow "$V4_PROJECT/db/database.sock"
  run v4BackupCreate
  [ "$status" -eq 0 ]
  local archive
  archive=$(jq -r '.file' <<< "$output")
  mkdir "$SANDBOX/extracted"
  v4ArchiveExtract "$archive" "$SANDBOX/extracted"
  v4PackageVerify "$SANDBOX/extracted"
  [ -f "$SANDBOX/extracted/project/README.md" ]
  [ -f "$SANDBOX/extracted/project/joomla/configuration.php" ]
  [ ! -e "$SANDBOX/extracted/project/db" ]
  grep -q 'project-secret' "$SANDBOX/extracted/compose/.env"
  run ! grep -q 'unrelated-secret' "$SANDBOX/extracted/compose/.env"
  [ "$(file_mode "$archive")" = 600 ]
  grep -qx joomlasource "$SANDBOX/running"
}

@test "v4 ZIP backup is validated and can be extracted" {
  command -v zip >/dev/null || skip 'zip unavailable'
  command -v unzip >/dev/null || skip 'unzip unavailable'
  V4_REQUEST='{"site":"source.test","format":"zip"}'
  run v4BackupCreate
  [ "$status" -eq 0 ]
  local archive
  archive=$(jq -r '.file' <<< "$output")
  mkdir "$SANDBOX/extracted"
  v4ArchiveExtract "$archive" "$SANDBOX/extracted"
  v4PackageVerify "$SANDBOX/extracted"
}

@test "v4 backup failure resumes exactly the previously running application services" {
  printf 'joomlasource\nmariadbsource\nworkersource\n' > "$SANDBOX/running"
  touch "$SANDBOX/fail-dump"
  run v4BackupCreate
  [ "$status" -ne 0 ]
  [ "$(sort "$SANDBOX/running")" = $'joomlasource\nmariadbsource\nworkersource' ]
  [ ! -d "$V4_DIR/.operation.lock" ]
}

@test "v4 failed SQL import rolls back and resumes application" {
  printf BROKEN > "$SANDBOX/bad.sql"
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/bad.sql" '{site:"source.test",input:$input,yes:true}')
  run v4DbImport
  [ "$status" -eq 1 ]
  [[ "$output" = *'previous database was restored'* ]]
  grep -q 'CREATE TABLE original' "$SANDBOX/current.sql"
  grep -qx joomlasource "$SANDBOX/running"
  [ "$(find "$SANDBOX/backups" -name '*.sql.gz' | wc -l | tr -d ' ')" -eq 1 ]
}

@test "v4 failed SQL import and rollback keep application stopped" {
  printf BROKEN > "$SANDBOX/bad.sql"
  touch "$SANDBOX/fail-import"
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/bad.sql" '{site:"source.test",input:$input,yes:true}')
  run v4DbImport
  [ "$status" -eq 1 ]
  [[ "$output" = *'Application services remain stopped'* ]]
  run ! grep -qx joomlasource "$SANDBOX/running"
}

@test "v4 destructive import requires explicit yes before stopping anything" {
  printf 'SELECT 1;' > "$SANDBOX/query.sql"
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/query.sql" '{site:"source.test",input:$input}')
  run v4DbImport
  [ "$status" -ne 0 ]
  [ ! -s "$SANDBOX/operations" ]
}

@test "v4 restore creates independent project and renamed scoped environment" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",yes:true}')
  run v4BackupRestore
  [ "$status" -eq 0 ]
  [ -f "$VDM_PROJECT_PATH/source/joomla/configuration.php" ]
  [ -f "$VDM_PROJECT_PATH/clone2/joomla/configuration.php" ]
  grep -q 'VDM_CLONE2_DB_PASS=' "$VDM_REPO_PATH/joomla/available/clone.test/.env"
  run ! grep -q 'VDM_SOURCE_' "$VDM_REPO_PATH/joomla/available/clone.test/.env"
  grep -q 'realign clone.test' "$SANDBOX/operations"
  grep -q 'chown joomlaclone2 -R www-data:www-data' "$SANDBOX/operations"
}

@test "v4 restore failure removes only newly reserved destination" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  touch "$SANDBOX/fail-realign"
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",yes:true}')
  run v4BackupRestore
  [ "$status" -ne 0 ]
  [ ! -e "$VDM_PROJECT_PATH/clone2" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/clone.test" ]
  [ -f "$VDM_PROJECT_PATH/source/joomla/index.php" ]
}

@test "v4 replacement provisioning failure restores original directories and running services" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  touch "$SANDBOX/fail-provision"
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"source.test",target_key:"source",replace:true,yes:true}')
  run v4BackupRestore
  [ "$status" -ne 0 ]
  [ -f "$VDM_PROJECT_PATH/source/joomla/index.php" ]
  [ -f "$VDM_REPO_PATH/joomla/available/source.test/project.json" ]
  grep -qx joomlasource "$SANDBOX/running"
  [ ! -d "$VDM_REPO_PATH/joomla/available/source.test/.operation.lock" ]
}

@test "v4 database switch refuses cross-family replacement before backup" {
  V4_REQUEST='{"site":"source.test","database_engine":"postgres","database_version":"17","mode":"replace","yes":true}'
  run v4DbSwitch
  [ "$status" -eq 2 ]
  [[ "$output" = *'Cross-family SQL conversion is unsupported'* ]]
  [ -z "$(find "$SANDBOX/backups" -type f -print -quit)" ]
}

@test "v4 restore metadata preserves local TLS intent without copying certificates" {
  V4_META=$(jq '.tls.mode="local" | .tls.private_key="host-private-key" | .http_port=8080' <<< "$V4_META")
  V4_REQUEST='{"target_site":"clone.test","target_key":"clone2"}'
  run v4RestoreTargetMetadata "$V4_META"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.tls.mode' <<< "$output")" = none ]
  [ "$(jq -r '.http_port' <<< "$output")" = 0 ]
  [ "$(jq -r 'has("private_key")' <<< "$(jq '.tls' <<< "$output")")" = false ]
}

@test "v4 snapshot is database-only and rejects incompatible engine restore" {
  run v4SnapshotCreate
  [ "$status" -eq 0 ]
  local archive
  archive=$(jq -r '.file' <<< "$output")
  mkdir "$SANDBOX/snapshot"
  v4ArchiveExtract "$archive" "$SANDBOX/snapshot"
  [ ! -e "$SANDBOX/snapshot/project" ]
  [ "$(jq -r '.scope' "$SANDBOX/snapshot/manifest.json")" = database ]
  jq '.site.database.engine="postgres"' "$SANDBOX/snapshot/manifest.json" > "$SANDBOX/new-manifest"
  mv "$SANDBOX/new-manifest" "$SANDBOX/snapshot/manifest.json"
  v4PackageChecksums "$SANDBOX/snapshot"
  tar -czf "$SANDBOX/postgres.tar.gz" -C "$SANDBOX/snapshot" .
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/postgres.tar.gz" '{site:"source.test",input:$input,yes:true}')
  run v4SnapshotRestore
  [ "$status" -eq 2 ]
}

@test "v4 retention sorts archive timestamps and defaults to dry run" {
  package_fixture "$SANDBOX/old" database 2025-01-01T00:00:00Z
  package_fixture "$SANDBOX/new" database 2026-01-01T00:00:00Z
  tar -czf "$SANDBOX/backups/source.test-z-old.tar.gz" -C "$SANDBOX/old" .
  tar -czf "$SANDBOX/backups/source.test-a-new.tar.gz" -C "$SANDBOX/new" .
  V4_REQUEST='{"site":"source.test","keep":1}'
  run v4BackupCleanup
  [ "$status" -eq 0 ]
  [[ "$output" = *source.test-z-old.tar.gz* ]]
  [[ "$output" != *source.test-a-new.tar.gz* ]]
  [ -f "$SANDBOX/backups/source.test-z-old.tar.gz" ]
  V4_REQUEST='{"site":"source.test","keep":1,"dry_run":false,"yes":true}'
  run v4BackupCleanup
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/backups/source.test-z-old.tar.gz" ]
  [ -f "$SANDBOX/backups/source.test-a-new.tar.gz" ]
}

@test "v4 backup deletion refuses files outside managed backup directory" {
  printf retained > "$SANDBOX/outside.sql"
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/outside.sql" '{input:$input,yes:true}')
  run v4BackupDelete
  [ "$status" -eq 2 ]
  [ -f "$SANDBOX/outside.sql" ]
}

@test "v4 remote command rejects option and shell injection destinations" {
  run v4RemoteCommand '-oProxyCommand=evil' site list
  [ "$status" -eq 2 ]
  run v4RemoteCommand 'user@host;evil' site list
  [ "$status" -eq 2 ]
}

@test "v4 batch export survives a database client consuming stdin" {
  database_fixture second.test second
  v4DatabaseDump() { cat >/dev/null; printf 'SELECT 1;\n'; }
  V4_REQUEST='{"sites":["source.test","second.test"]}'
  run v4DbExport
  [ "$status" -eq 0 ]
  [ "$(jq '.results|length' <<< "$output")" -eq 2 ]
}

@test "v4 database reset failure enters recovery instead of restarting an empty database" {
  printf 'SELECT 1;\n' > "$SANDBOX/query.sql"
  v4DatabaseReset() {
    : > "$SANDBOX/current.sql"
    if [ ! -f "$SANDBOX/reset-attempted" ]; then touch "$SANDBOX/reset-attempted"; return 1; fi
  }
  V4_REQUEST=$(jq -n --arg input "$SANDBOX/query.sql" '{site:"source.test",input:$input,yes:true}')
  run v4DbImport
  [ "$status" -eq 1 ]
  grep -q 'CREATE TABLE original' "$SANDBOX/current.sql"
  grep -qx joomlasource "$SANDBOX/running"
}

@test "v4 MySQL import removes only the MariaDB sandbox directive" {
  # Reload the real implementation instead of this suite's SQL failure double.
  source <(awk '/^function v4DatabaseImportSql\(\) \{$/ {p=1} p {print} p && /^}$/ {exit}' "$OCTOJOOM_SCRIPT")
  v4Exec() { cat > "$SANDBOX/client.sql"; printf '%s\n' "$*" > "$SANDBOX/client.argv"; }
  V4_DB_ENGINE=mysql
  printf '/*M!999999\\- enable the sandbox mode */\nCREATE TABLE safe (id INT);\n/* a SQL comment */\n' | v4DatabaseImportSql
  [ "$(cat "$SANDBOX/client.sql")" = $'CREATE TABLE safe (id INT);\n/* a SQL comment */' ]
  grep -q '\$MYSQL_PASSWORD' "$SANDBOX/client.argv"
  run ! grep -q 'project-secret\|root-secret' "$SANDBOX/client.argv"
}

@test "v4 export credentials are expanded inside container only" {
  source <(awk '/^function v4DatabaseDump\(\) \{$/ {p=1} p {print} p && /^}$/ {exit}' "$OCTOJOOM_SCRIPT")
  v4Exec() { printf '%s\n' "$*"; }
  V4_DB_ENGINE=mysql
  V4_DB_TABLES=(jos_content)
  MYSQL_ROOT_PASSWORD='never-expand-on-host'
  run v4DatabaseDump
  [ "$status" -eq 0 ]
  [[ "$output" = *'MYSQL_PWD="$MYSQL_ROOT_PASSWORD"'* ]]
  [[ "$output" != *never-expand-on-host* ]]
  [[ "$output" = *'jos_content'* ]]
}

@test "v4 restore leaves archived hooks inactive until explicitly trusted" {
  jq '.hooks={"post-restore":[["sh","-c","echo archived-hook"]]}' "$V4_DIR/project.json" > "$SANDBOX/metadata"
  mv "$SANDBOX/metadata" "$V4_DIR/project.json"
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",yes:true}')
  run v4BackupRestore
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks|length' "$VDM_REPO_PATH/joomla/available/clone.test/project.json")" -eq 0 ]
  [ -f "$VDM_REPO_PATH/joomla/available/clone.test/imported-hooks.json" ]
  grep -q archived-hook "$VDM_REPO_PATH/joomla/available/clone.test/imported-hooks.json"
}

@test "v4 healthy restored target remains available after post-restore hook failure" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  v4RunHook() { [ "$1" != post-restore ]; }
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",yes:true}')
  run v4BackupRestore
  [ "$status" -ne 0 ]
  [[ "$output" = *'restored and retained'* ]]
  [ -f "$VDM_PROJECT_PATH/clone2/joomla/configuration.php" ]
  [ -f "$VDM_REPO_PATH/joomla/available/clone.test/project.json" ]
}

@test "v4 external import prepares stopped target and removes it on SQL failure" {
  local input="$V4_DOCROOT"
  printf BROKEN > "$SANDBOX/external.sql"
  v4SiteCreate() {
    [ "$(v4Get activate)" = false ] || return 9
    database_fixture "$(v4Get site)" "$(v4Get key)"
    printf '{"prepared":true}\n'
  }
  v4RealignConfiguration() { return 0; }
  V4_REQUEST=$(jq -n --arg input "$input" --arg sql "$SANDBOX/external.sql" '{input:$input,database_input:$sql,target_site:"external.test",target_key:"external",joomla_version:"5.4",php_version:"8.3",yes:true}')
  run v4SiteImport
  [ "$status" -eq 1 ]
  [ ! -e "$VDM_PROJECT_PATH/external" ]
  [ ! -e "$VDM_REPO_PATH/joomla/available/external.test" ]
  [ -f "$VDM_PROJECT_PATH/source/joomla/index.php" ]
}

@test "v4 push migration transfers exactly one verified logical archive" {
  mkdir "$SANDBOX/remote"
  ssh() {
    case "${*: -1}" in
      *mktemp*) printf '%s\n' "$SANDBOX/remote" ;;
      *sha256sum*) printf '%s  project.tar.gz\n' "$(v4Digest "$SANDBOX/remote/project.tar.gz")" ;;
      *) return 1 ;;
    esac
  }
  rsync() {
    printf 'transfer\n' >> "$SANDBOX/transfers"
    local arguments=("$@") source target
    source="${arguments[${#arguments[@]}-2]}"; target="${arguments[${#arguments[@]}-1]}"
    cp "$source" "${target#*:}"
  }
  v4RemoteCommand() {
    printf '%s\n' "$*" > "$SANDBOX/remote-command"
    printf '{"ok":true,"data":{"restored":true}}\n'
  }
  V4_REQUEST='{"site":"source.test","remote":"user@example.test","target_site":"destination.test","target_key":"destination","direction":"push","yes":true}'
  run v4SiteMigrate
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$SANDBOX/transfers" | tr -d ' ')" -eq 1 ]
  grep -q 'backup restore --target-site destination.test --target-key destination' "$SANDBOX/remote-command"
  v4ArchiveValidate "$SANDBOX/remote/project.tar.gz"
  [ -f "$VDM_PROJECT_PATH/source/joomla/index.php" ]
}

@test "v4 stopped restore runs posthook with database available then honors inactive state" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  v4RunHook() {
    if [ "$1" = post-restore ]; then
      grep -qx mariadbclone2 "$SANDBOX/running" || return 8
      printf 'hook-had-db\n' > "$SANDBOX/hook-state"
      return 1
    fi
  }
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",activate:false,yes:true}')
  run v4BackupRestore
  [ "$status" -eq 1 ]
  [ -f "$SANDBOX/hook-state" ]
  [ ! -s "$SANDBOX/running" ]
  [ -f "$VDM_PROJECT_PATH/clone2/joomla/configuration.php" ]
}

@test "v4 backup paths cannot bypass public directory protection with dot segments" {
  V4_REQUEST=$(jq -n --arg root "$V4_PROJECT/joomla/../joomla/backups" '{backup_path:$root}')
  run v4BackupRoot
  [ "$status" -eq 2 ]
  run v4DatabaseWriteDump "$V4_PROJECT/joomla/../joomla/public.sql"
  [ "$status" -eq 2 ]
  [ ! -e "$V4_DOCROOT/public.sql" ]
}

@test "v4 failed replacement restores destination-local TLS route and key" {
  local archive tls_root="$VDM_SRC_PATH/local-tls"
  mkdir -p "$tls_root/routes" "$tls_root/certs" "$tls_root/hosts"
  printf old-route > "$tls_root/routes/source.test.json"
  printf old-key > "$tls_root/certs/source.test-key.pem"
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  v4RealignConfiguration() {
    printf wrong-route > "$VDM_SRC_PATH/local-tls/routes/source.test.json"
    printf wrong-key > "$VDM_SRC_PATH/local-tls/certs/source.test-key.pem"
    return 1
  }
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"source.test",target_key:"source",replace:true,yes:true}')
  run v4BackupRestore
  [ "$status" -ne 0 ]
  [ "$(cat "$tls_root/routes/source.test.json")" = old-route ]
  [ "$(cat "$tls_root/certs/source.test-key.pem")" = old-key ]
  [ -f "$VDM_PROJECT_PATH/source/joomla/index.php" ]
}

@test "v4 failed new restore removes its destination-local TLS artifacts" {
  local archive
  archive=$(v4BackupCreate | jq -r '.file')
  restore_dependencies
  v4RealignConfiguration() { return 1; }
  v4LocalRemoveSite() { printf '%s\n' "$V4_HOST" > "$SANDBOX/tls-cleaned"; }
  V4_REQUEST=$(jq -n --arg input "$archive" '{input:$input,target_site:"clone.test",target_key:"clone2",yes:true}')
  run v4BackupRestore
  [ "$status" -ne 0 ]
  [ "$(cat "$SANDBOX/tls-cleaned")" = clone.test ]
}
