#!/usr/bin/env bats
# Independent Bats cases reset these globals in setup.
# shellcheck disable=SC2034,SC2317,SC2016,SC2030,SC2031
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  OCTOJOOM_NON_INTERACTIVE=true
  OCTOJOOM_OUTPUT=text
  VDM_QUIET=true
  VDM_DB_ENGINE=mariadb VDM_DB_SERVICE=database VDM_DB_NAME=joomla VDM_DB_USER=application
  VDM_DB_PASSWORD='private!"\\$password' VDM_DB_PORT=3306 VDM_DB_CLIENT=mariadb VDM_DB_DUMP=mariadb-dump
  VDM_DB_SITE=example.test
  VDM_TABLES=() VDM_SITES=()
}

stub_context() {
  joomlaDatabaseContext() { VDM_DB_SITE="$1"; }
}

context_fixture() {
  readJoomlaSiteFacts() {
    VDM_SITE_SERVICE=web VDM_SITE_DIR="$SANDBOX/site" VDM_SITE_COMPOSE="$SANDBOX/site/docker-compose.yml"
    VDM_SITE_ENV="$SANDBOX/shared.env" VDM_SITE_DOCROOT=/var/www/html VDM_SITE_ENV_KEY=EXAMPLE
  }
  joomlaDatabaseCompose() { cat "$SANDBOX/model.json"; }
  joomlaDatabaseReadConfiguration() { cat "$SANDBOX/config.json"; }
  joomlaDatabaseDiscoverClients() { printf '%s\n' "$VDM_DB_SERVICE" > "$SANDBOX/discovered"; }
  cat > "$SANDBOX/model.json" <<'JSON'
{"services":{"web":{"environment":{"JOOMLA_DB_HOST":"site-database:3306","JOOMLA_DB_NAME":"joomla","JOOMLA_DB_USER":"application","JOOMLA_DB_PASSWORD":"private-secret"}},"database":{"image":"mariadb:published","container_name":"site-database"},"unrelated":{"image":"mariadb:published"}}}
JSON
  cat > "$SANDBOX/config.json" <<'JSON'
{"installed":true,"host":"site-database","name":"joomla","user":"application","password":"private-secret","driver":"mysqli","prefix":"abc_"}
JSON
}

stub_native_client() {
  joomlaDatabaseCompose() {
    case "$*" in
      *'mktemp /tmp/octojoom-database.'*) printf '/tmp/octojoom-database.test123\n';;
      *'cat > "$1"'*) cat > "$SANDBOX/credential";;
      *'rm -f -- /tmp/octojoom-database.'*) touch "$SANDBOX/credential-removed";;
      *)
        printf '%s\n' "$@" > "$SANDBOX/client-arguments"
        cat > "$SANDBOX/client-input"
        [ -z "${NATIVE_ERROR:-}" ] || printf '%s\n' "$NATIVE_ERROR" >&2
        return "${NATIVE_STATUS:-0}";;
    esac
  }
}

@test "database context selects the exact connected service and normalizes its default port" {
  context_fixture
  joomlaDatabaseContext example.test
  assert_equal "$VDM_DB_SERVICE" database
  assert_equal "$VDM_DB_NAME" joomla
  assert_equal "$VDM_DB_PREFIX" abc_
  assert_equal "$VDM_DB_IMAGE" mariadb:published
  assert_equal "$VDM_DB_ENV" "$SANDBOX/shared.env"
  assert_equal "$(cat "$SANDBOX/discovered")" database
}

@test "database disagreement reports actionable selected paths without exposing credentials" {
  context_fixture
  sed -i 's/private-secret/different-private-secret/' "$SANDBOX/config.json"
  run joomlaDatabaseContext example.test
  assert_failure
  assert_output_contains 'Database password differs'
  assert_output_contains "$SANDBOX/shared.env"
  refute_file_exists "$SANDBOX/discovered"
  [[ "$output" != *private-secret* ]]
}

@test "database context refuses an unrelated or external service" {
  context_fixture
  sed -i 's/site-database/external-database/g' "$SANDBOX/config.json"
  sed -i 's/site-database:3306/external-database:3306/g' "$SANDBOX/model.json"
  run joomlaDatabaseContext example.test
  assert_failure
  assert_output_contains 'does not identify one database service'
  refute_file_exists "$SANDBOX/discovered"
}

@test "stopped database client discovery probes the published image without starting the service" {
  VDM_DB_IMAGE=mariadb:published
  joomlaDatabaseCompose() { [ "$1" = ps ]; }
  docker() { printf '%s\n' "$@" > "$SANDBOX/inspection"; printf 'mariadb\nmariadb-dump\n'; }
  run joomlaDatabaseDiscoverClients
  assert_success
  assert_file_contains "$SANDBOX/inspection" --read-only
  assert_file_contains "$SANDBOX/inspection" --network
  assert_file_contains "$SANDBOX/inspection" --entrypoint
  refute_file_contains "$SANDBOX/inspection" up
}

@test "PostgreSQL password fields cannot terminate early when equal to earlier fields" {
  VDM_DB_ENGINE=postgres VDM_DB_PORT=5432 VDM_DB_NAME=site VDM_DB_USER=application
  for VDM_DB_PASSWORD in 127.0.0.1 5432 site application; do
    run joomlaDatabasePasswordContent
    assert_success
    assert_equal "$output" "127.0.0.1:5432:site:application:$VDM_DB_PASSWORD"
  done
  VDM_DB_PASSWORD='colon:and\backslash'
  run joomlaDatabasePasswordContent
  assert_equal "$output" '127.0.0.1:5432:site:application:colon\:and\\backslash'
}

@test "native credentials travel on stdin, keep literal quoting, and are removed" {
  stub_native_client
  printf 'SELECT 1;\n' > "$SANDBOX/input.sql"
  run joomlaDatabaseClient import "$SANDBOX/input.sql"
  assert_success
  assert_file_contains "$SANDBOX/credential" 'password="private!\"\\\\$password"'
  refute_file_contains "$SANDBOX/client-arguments" "$VDM_DB_PASSWORD"
  assert_file_contains "$SANDBOX/client-arguments" --defaults-file=/tmp/octojoom-database.test123
  assert_file_contains "$SANDBOX/client-arguments" --binary-mode
  assert_equal "$(cat "$SANDBOX/client-input")" 'SELECT 1;'
  assert_file_exists "$SANDBOX/credential-removed"
}

@test "native SQL failures provide safe guidance without exposing query contents" {
  stub_native_client
  NATIVE_STATUS=1 NATIVE_ERROR="ERROR 1064 near 'customer-sensitive-payload' password=$VDM_DB_PASSWORD"
  run joomlaDatabaseClient sql < /dev/null
  assert_failure
  assert_output_contains 'client rejected SQL syntax'
  [[ "$output" != *customer-sensitive-payload* && "$output" != *"$VDM_DB_PASSWORD"* ]]
  assert_file_exists "$SANDBOX/credential-removed"
}

@test "PostgreSQL clients stop on errors and read piped SQL without user startup files" {
  stub_native_client
  VDM_DB_ENGINE=postgres VDM_DB_CLIENT=psql VDM_DB_PORT=5432 VDM_DB_NAME="name='not-connection-options'"
  run joomlaDatabaseClient sql --single-transaction < /dev/null
  assert_success
  assert_file_contains "$SANDBOX/client-arguments" --file=-
  assert_file_contains "$SANDBOX/client-arguments" --set=ON_ERROR_STOP=1
  assert_file_contains "$SANDBOX/client-arguments" --no-psqlrc
  assert_file_contains "$SANDBOX/client-arguments" --single-transaction
  refute_file_contains "$SANDBOX/client-arguments" "$VDM_DB_PASSWORD"
}

@test "export preserves an existing destination when the native dump fails" {
  stub_context
  joomlaDatabaseDumpResolved() { printf 'incomplete SQL'; return 8; }
  printf 'original file\n' > "$SANDBOX/backup.sql"
  run joomlaDatabaseExport example.test "$SANDBOX/backup.sql" none true
  assert_failure
  assert_equal "$(cat "$SANDBOX/backup.sql")" 'original file'
  [ -z "$(find "$SANDBOX" -name 'backup.sql.tmp.*' -print)" ]
}

@test "export catches compressor failures and publishes literal private filenames" {
  stub_context
  joomlaDatabaseDumpResolved() { printf 'CREATE TABLE marker(id INT);\n'; }
  gzip() { cat >/dev/null; return 7; }
  run joomlaDatabaseExport example.test "$SANDBOX/broken.sql.gz" gzip false
  assert_failure
  refute_file_exists "$SANDBOX/broken.sql.gz"
  local literal="$SANDBOX/quoted \"name\" \$(never-run).sql"
  run joomlaDatabaseExport example.test "$literal" none false
  assert_success
  assert_equal "$(file_mode "$literal")" 600
  assert_file_contains "$literal" 'CREATE TABLE marker'
}

@test "export requires explicit overwrite and refuses unavailable destination directories" {
  stub_context
  joomlaDatabaseDumpResolved() { printf 'new SQL'; }
  printf old > "$SANDBOX/exists.sql"
  run joomlaDatabaseExport example.test "$SANDBOX/exists.sql" none false
  assert_failure
  assert_equal "$(cat "$SANDBOX/exists.sql")" old
  run joomlaDatabaseExport example.test "$SANDBOX/missing/export.sql" none false
  assert_failure
  refute_file_exists "$SANDBOX/missing/export.sql"
}

@test "table names are validated against the actual database and passed as literal arguments" {
  joomlaDatabaseTablesResolved() { printf 'normal\ncomma, quote" space\n'; }
  joomlaDatabaseCompose() { printf 'single-transaction quick hex-blob routines events triggers no-tablespaces\n'; }
  joomlaDatabaseClient() { printf '%s\n' "$@" > "$SANDBOX/dump-arguments"; printf 'SQL\n'; }
  run joomlaDatabaseDumpResolved 'comma, quote" space'
  assert_success
  assert_file_contains "$SANDBOX/dump-arguments" 'comma, quote" space'
  refute_file_contains "$SANDBOX/dump-arguments" --all-databases
  run joomlaDatabaseDumpResolved unrelated_table
  assert_failure
}

@test "an empty interactive table selection returns without claiming a backup" {
  joomlaDatabaseTables() { printf 'first\nsecond\n'; }
  whiptail() { return 0; }
  run joomlaDatabaseSelectTables example.test
  assert_equal "$status" 3
}

@test "truncated gzip import fails before connection or source deletion" {
  printf 'not SQL' | gzip -c > "$SANDBOX/input.sql.gz"
  local size
  size=$(wc -c < "$SANDBOX/input.sql.gz")
  head -c "$((size - 5))" "$SANDBOX/input.sql.gz" > "$SANDBOX/truncated.gz"
  joomlaDatabaseContext() { touch "$SANDBOX/connected"; }
  run joomlaDatabaseImport example.test "$SANDBOX/truncated.gz" replace true
  assert_failure
  assert_file_exists "$SANDBOX/truncated.gz"
  refute_file_exists "$SANDBOX/connected"
}

@test "failed import and failed application verification both retain their source" {
  stub_context
  printf 'invalid SQL;\n' > "$SANDBOX/input.sql"
  joomlaDatabaseTablesResolved() { printf 'marker\n'; }
  joomlaDatabaseClient() { cat >/dev/null; return 3; }
  run joomlaDatabaseImport example.test "$SANDBOX/input.sql" replace true
  assert_failure
  assert_file_exists "$SANDBOX/input.sql"
  joomlaDatabaseClient() { cat >/dev/null; }
  joomlaDatabaseVerifyConnection() { return 1; }
  run joomlaDatabaseImport example.test "$SANDBOX/input.sql" replace true
  assert_failure
  assert_file_exists "$SANDBOX/input.sql"
}

@test "fresh import refuses a nonempty database without running input" {
  stub_context
  printf 'SQL\n' > "$SANDBOX/input.sql"
  joomlaDatabaseTablesResolved() { printf 'existing\n'; }
  joomlaDatabaseClient() { touch "$SANDBOX/modified"; }
  run joomlaDatabaseImport example.test "$SANDBOX/input.sql" fresh false
  assert_failure
  refute_file_exists "$SANDBOX/modified"
}

@test "successful import deletes only after table and application checks succeed" {
  stub_context
  printf 'SQL\n' > "$SANDBOX/input.sql"
  joomlaDatabaseTablesResolved() { printf 'marker\n'; }
  joomlaDatabaseClient() { cat >/dev/null; }
  joomlaDatabaseVerifyConnection() { [ -f "$SANDBOX/input.sql" ]; }
  run joomlaDatabaseImport example.test "$SANDBOX/input.sql" replace true
  assert_success
  refute_file_exists "$SANDBOX/input.sql"
}

@test "native console rejects a noninteractive request before creating credentials" {
  stub_native_client
  run joomlaDatabaseClient console
  assert_failure
  assert_output_contains 'interactive terminal'
  refute_file_exists "$SANDBOX/credential"
}

@test "explicit output paths stay deterministic and repeated site results remain independent" {
  VDM_ACTION='export' VDM_CONTAINER=first.test VDM_FILE="$SANDBOX/exact.sql"
  OCTOJOOM_CLI_KEYS=(VDM_INPUT_FILE)
  joomlaDatabasePreference() { case "$2" in EXPORT_DIR) echo "$SANDBOX";; COMPRESSION) echo gzip;; TIMESTAMP) echo true;; esac; }
  joomlaDatabaseExport() { printf '%s\n' "$@" > "$SANDBOX/export-arguments"; touch "$2"; }
  joomlaDatabaseSavePreferences() { return 0; }
  run joomla__TRuST__database
  assert_success
  assert_file_exists "$SANDBOX/exact.sql"
  assert_file_contains "$SANDBOX/export-arguments" none
  VDM_FILE='' VDM_SITES=(first.test second.test) OCTOJOOM_OUTPUT=json
  joomlaDatabaseExport() { [ "$1" != second.test ]; }
  run joomla__TRuST__database
  assert_failure
  [ "$(jq '.sites | length' <<< "$output")" = 2 ]
  [ "$(jq -r '.sites[0].success' <<< "$output")" = true ]
  [ "$(jq -r '.sites[1].success' <<< "$output")" = false ]
}

@test "all-sites export enumerates discovered sites and quiet JSON retains machine results" {
  VDM_ACTION='export' VDM_ALL=true OCTOJOOM_OUTPUT=json
  listJoomlaSites() { printf 'one.test\ntwo.test\n'; }
  joomlaDatabasePreference() { case "$2" in EXPORT_DIR) echo "$SANDBOX";; COMPRESSION) echo none;; TIMESTAMP) echo false;; esac; }
  joomlaDatabaseExport() { printf '%s\n' "$1" >> "$SANDBOX/export-sites"; }
  joomlaDatabaseSavePreferences() { return 0; }
  run joomla__TRuST__database
  assert_success
  assert_equal "$(cat "$SANDBOX/export-sites")" $'one.test\ntwo.test'
  [ "$(jq '.sites | length' <<< "$output")" = 2 ]
}

@test "database preferences preserve required values and recognized site settings only" {
  mkdir -p "$SANDBOX/site"
  printf 'services:\n  web:\n    image: joomla:latest\n    environment:\n      - JOOMLA_DB_NAME=${VDM_EXAMPLE_DB}\n      - JOOMLA_DB_PASSWORD=${VDM_EXAMPLE_DB_PASS}\n' > "$SANDBOX/site/docker-compose.yml"
  printf 'VDM_EXAMPLE_DB=joomla\nVDM_EXAMPLE_DB_PASS=selected-secret\nVDM_EXAMPLE_SMTP_PASSWORD=saved-mail\nVDM_OTHER_DB_PASS=unrelated-secret\n' > "$SANDBOX/shared.env"
  readJoomlaSiteFacts() {
    VDM_SITE_DIR="$SANDBOX/site" VDM_SITE_COMPOSE="$SANDBOX/site/docker-compose.yml" VDM_SITE_ENV="$SANDBOX/shared.env" VDM_SITE_ENV_KEY=EXAMPLE
    if [ -f "$VDM_SITE_DIR/.env" ]; then VDM_SITE_ENV="$VDM_SITE_DIR/.env"; fi
  }
  run joomlaDatabaseSavePreferences example.test "$SANDBOX/export directory" gzip false
  assert_success
  assert_file_contains "$SANDBOX/site/.env" selected-secret
  assert_file_contains "$SANDBOX/site/.env" saved-mail
  assert_file_contains "$SANDBOX/site/.env" DATABASE_TIMESTAMP=false
  refute_file_contains "$SANDBOX/site/.env" unrelated-secret
  run joomlaDatabaseSaveImportPreference example.test "$SANDBOX/import directory"
  assert_success
  local saved_compression
  migrationReadEnvValue "$SANDBOX/site/.env" VDM_EXAMPLE_DATABASE_COMPRESSION saved_compression
  assert_equal "$saved_compression" gzip
  assert_file_contains "$SANDBOX/site/.env" "VDM_EXAMPLE_DATABASE_IMPORT_DIR=\"$SANDBOX/import directory\""
  assert_file_contains "$VDM_SRC_PATH/.env" "VDM_DATABASE_IMPORT_DIR=\"$SANDBOX/import directory\""
}

@test "table listing is read-only and machine-safe" {
  VDM_ACTION=tables VDM_CONTAINER=example.test OCTOJOOM_OUTPUT=json
  joomlaDatabaseTables() { printf 'comma,name\nspace name\n'; }
  joomlaDatabaseSavePreferences() { touch "$SANDBOX/unrequested-write"; }
  run joomla__TRuST__database
  assert_success
  [ "$(jq -r '.[0]' <<< "$output")" = comma,name ]
  refute_file_exists "$SANDBOX/unrequested-write"
}

@test "gzip export rejects an empty successful client output" {
  stub_context
  joomlaDatabaseDumpResolved() { return 0; }
  run joomlaDatabaseExport example.test "$SANDBOX/empty.sql.gz" gzip false
  assert_failure
  refute_file_exists "$SANDBOX/empty.sql.gz"
}

@test "row-count verification quotes native identifiers without executing table content" {
  joomlaDatabaseTablesResolved() { printf 'odd` name;SELECT 99\nnormal\n'; }
  joomlaDatabaseClient() { cat > "$SANDBOX/count-query"; }
  run joomlaDatabaseRowCountsResolved
  assert_success
  assert_file_contains "$SANDBOX/count-query" 'SELECT 0, COUNT(*) FROM `odd`` name;SELECT 99`;'
  assert_file_contains "$SANDBOX/count-query" 'SELECT 1, COUNT(*) FROM `normal`;'
}

@test "file chooser returns quoted names literally and supports manual paths" {
  local selected="$SANDBOX/quoted \"file\", name.sql"
  printf SQL > "$selected"
  whiptail() { printf 0 >&2; }
  run joomlaDatabaseChooseFile "$SANDBOX"
  assert_success
  assert_equal "$output" "$selected"
  whiptail() { printf manual >&2; }
  getInput() { printf '%s' "$SANDBOX/other file.sql"; }
  run joomlaDatabaseChooseFile "$SANDBOX"
  assert_equal "$output" "$SANDBOX/other file.sql"
}

@test "timestamp naming retains the selected format suffix" {
  date() { printf '20300102T030405Z\n'; }
  run joomlaDatabaseTimestampPath '/backups/site with spaces.sql.gz'
  assert_success
  assert_equal "$output" '/backups/site with spaces-20300102T030405Z.sql.gz'
}

@test "explicit import backup completes before the shared importer is invoked" {
  VDM_ACTION=import VDM_CONTAINER=example.test VDM_FILE="$SANDBOX/input.sql" VDM_IMPORT_MODE=replace VDM_PRE_BACKUP=true
  printf SQL > "$VDM_FILE"
  joomla__TRuST__backup() { [ "$VDM_ACTION" = create ] && [ -z "$VDM_FILE" ] && touch "$SANDBOX/backup-first"; }
  joomlaDatabaseImport() { [ -f "$SANDBOX/backup-first" ] && touch "$SANDBOX/imported"; }
  joomlaDatabaseSaveImportPreference() { printf '%s\n' "$@" > "$SANDBOX/import-preference"; }
  run joomla__TRuST__database
  assert_success
  assert_file_exists "$SANDBOX/imported"
  assert_file_contains "$SANDBOX/import-preference" "$SANDBOX"
}

@test "menu export delegates to the same handler and keeps engine inspection local" {
  OCTOJOOM_NON_INTERACTIVE=false VDM_DB_ENGINE=mysql
  joomlaDatabaseContext() { VDM_DB_ENGINE=mariadb VDM_DB_NAME=site VDM_DB_SERVICE=db; }
  whiptail() {
    printf '%s\n' "$@" >> "$SANDBOX/menu-arguments"
    if [ -f "$SANDBOX/menu-visited" ]; then printf back >&2; else touch "$SANDBOX/menu-visited"; printf export >&2; fi
  }
  joomlaDatabaseExportQuestions() { VDM_DATABASE_OPTIONS_READY=true VDM_DESTINATION="$SANDBOX" VDM_COMPRESSION=none VDM_TIMESTAMP=false VDM_FILE="$SANDBOX/from-menu.sql"; }
  joomlaDatabaseExport() { printf '%s\n' "$@" > "$SANDBOX/menu-export"; }
  joomlaDatabaseSavePreferences() { return 0; }
  showNotice() { return 0; }
  showJoomlaDatabaseTools example.test
  assert_file_contains "$SANDBOX/menu-export" example.test
  assert_file_contains "$SANDBOX/menu-export" "$SANDBOX/from-menu.sql"
  assert_equal "$VDM_DB_ENGINE" mysql
  assert_file_contains "$SANDBOX/menu-arguments" 112
}

@test "PHP runtime capabilities follow the installed PostgreSQL driver" {
  VDM_SITE_MOUNT_SOURCE=/selected/website
  joomlaDatabaseReadConfiguration() { printf '{"installed":true,"driver":"pgsql"}\n'; }
  run joomlaRuntimeDatabaseExtensions '{"extensions":["mysqli","pdo_pgsql"]}' example.test
  assert_success
  assert_equal "$output" '["pdo_pgsql"]'
  run joomlaRuntimeDatabaseExtensions '{"extensions":["pgsql"]}'
  assert_success
  assert_equal "$output" '["pgsql"]'
}

@test "an empty successful database menu response cannot recurse into the handler" {
  joomlaDatabaseContext() { return 0; }
  whiptail() { return 0; }
  joomla__TRuST__database() { touch "$SANDBOX/recursive-handler"; }
  run showJoomlaDatabaseTools example.test
  assert_equal "$status" 17
  refute_file_exists "$SANDBOX/recursive-handler"
}

@test "configuration inspection normalizes Git Bash mounts and protects container paths" {
  VDM_SITE_MOUNT_TYPE=bind VDM_SITE_MOUNT_SOURCE=/c/sites/joomla
  VDM_SITE_MOUNT_TARGET=/var/www/html VDM_SITE_DOCROOT=/var/www/html/public VDM_SITE_IMAGE=joomla:published
  joomlaWebHostPath() { printf 'C:/sites/joomla\n'; }
  docker() {
    [ "$MSYS_NO_PATHCONV" = 1 ] && [ "$MSYS2_ARG_CONV_EXCL" = '*' ] || return 1
    printf '%s\n' "$@" > "$SANDBOX/probe-args"
    printf '{"installed":false}\n'
  }
  run joomlaDatabaseReadConfiguration
  assert_success
  assert_file_contains "$SANDBOX/probe-args" 'type=bind,source=C:/sites/joomla,target=/octojoom-site,readonly'
  assert_file_contains "$SANDBOX/probe-args" '/octojoom-site/public'
}
