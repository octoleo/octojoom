#!/usr/bin/env bats
# shellcheck shell=bash
# Fixture literals and dynamically loaded function overrides are intentional.
# shellcheck disable=SC2016,SC2030,SC2031,SC2317
# shellcheck disable=SC2034,SC2154

load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  V4_REQUEST='{}'
  V4_RESULT_FILE=''
  V4_ERROR_FILE=''
}

v4_cli_fixture() {
  local site=alpha.test
  V4_DIR="$VDM_REPO_PATH/joomla/available/$site"
  mkdir -p "$V4_DIR" "$VDM_PROJECT_PATH/alpha/joomla"
  printf '%s\n' 'services: {}' > "$V4_DIR/docker-compose.yml"
  printf 'VDM_PROJECT_PATH="%s"\nVDM_ALPHA_DB="joomla"\n' "$VDM_PROJECT_PATH" > "$V4_DIR/.env"
  jq -cn --arg project "$VDM_PROJECT_PATH/alpha" '{schema_version:1,host:"alpha.test",key:"alpha",env_key:"ALPHA",project_dir:$project,docroot:"joomla",image:"joomla:6.0-php8.3-apache",joomla_version:"6.0",php_version:"8.3",webserver:"apache",profile:"local",database:{engine:"mariadb",version:"11.4",name:"joomla",user:"joomla"},tls:{mode:"none",resolver:"vdmresolver"},services:{mail:false,redis:false,node:false},hooks:{}}' > "$V4_DIR/project.json"
}

v4_cli_limit_native_arguments() {
  V4_TEST_REAL_JQ=$(type -P jq)
  export V4_TEST_REAL_JQ
  mkdir -p "$SANDBOX/limited-native"
  cat > "$SANDBOX/limited-native/jq" <<'SH'
#!/usr/bin/env bash
bytes=0
for argument in "$@"; do bytes=$((bytes + ${#argument} + 1)); done
if [ "$bytes" -gt 16000 ]; then printf 'Native command-line size exceeded\n' >&2; exit 86; fi
exec "$V4_TEST_REAL_JQ" "$@"
SH
  chmod +x "$SANDBOX/limited-native/jq"
  PATH="$SANDBOX/limited-native:$PATH"
  export PATH
}

@test "v4 schema is discoverable without Docker or dialogs" {
  run v4Main site schema --json
  assert_success
  [ "$(jq -r .ok <<< "$output")" = true ]
  [ "$(jq -r '.data.actions.site | index("php") != null' <<< "$output")" = true ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "v4 flags override JSON and normalize aliases before precedence" {
  printf '%s\n' '{"schema_version":1,"database_engine":"mariadb","activate":true,"site":"alpha.test"}' > "$SANDBOX/request.json"
  v4Parse site create --config "$SANDBOX/request.json" --db-engine mysql --start=false --json
  [ "$(v4Get db_engine)" = mysql ]
  [ "$(v4Get database_engine)" = mysql ]
  [ "$(v4Get start)" = false ]
  [ "$(v4Get site)" = alpha.test ]
}

@test "v4 reads one JSON request from stdin without executing strings" {
  local literal='$(touch SHOULD_NOT_EXIST)'
  printf '%s\n' '{"schema_version":1,"site":"alpha.test","admin_password":"$(touch SHOULD_NOT_EXIST)"}' > "$SANDBOX/input.json"
  v4Parse site create --config - < "$SANDBOX/input.json"
  [ "$(v4Get admin_password)" = "$literal" ]
  [ ! -e SHOULD_NOT_EXIST ]
}

@test "v4 preserves literal trailing argument boundaries and empty arguments" {
  v4Parse site exec --site alpha.test -- printf '%s\n' 'a b' '' '$(not-a-command)' '--json'
  [ "${#V4_ARGS[@]}" -eq 6 ]
  [ "${V4_ARGS[2]}" = 'a b' ]
  [ "${V4_ARGS[3]}" = '' ]
  [ "${V4_ARGS[4]}" = '$(not-a-command)' ]
  [ "${V4_ARGS[5]}" = '--json' ]
  [ "$V4_JSON" = false ]
}

@test "v4 getter preserves false zero and empty string values" {
  V4_REQUEST='{"enabled":false,"port":0,"label":""}'
  [ "$(v4Get enabled true)" = false ]
  [ "$(v4Get port 443)" = 0 ]
  [ "$(v4Get label fallback)" = '' ]
  [ "$(v4Get missing fallback)" = fallback ]
}

@test "v4 rejects schema versions unknown fields and multiple JSON documents" {
  printf '%s\n' '{"schema_version":2}' > "$SANDBOX/request.json"
  run v4Main site list --config "$SANDBOX/request.json" --json
  assert_status 2
  printf '%s\n' '{"schema_version":1,"db_pasword":"secret-never-echoed"}' > "$SANDBOX/request.json"
  run v4Main site create --config "$SANDBOX/request.json" --json
  assert_status 2
  [[ "$output" != *secret-never-echoed* ]]
  printf '%s\n' '{}' '{}' > "$SANDBOX/request.json"
  run v4Main site list --config "$SANDBOX/request.json" --json
  assert_status 2
}

@test "v4 rejects control characters in any nested request string" {
  V4_REQUEST='{"schema_version":1,"site":"alpha.test","settings":{"one":"valid","two":"bad\nvalue","three":"valid"}}'
  run v4ValidateRequest
  assert_status 2
  V4_REQUEST='{"schema_version":1,"site":"alpha.test","settings":{"one":"valid","two":"valid"}}'
  run v4ValidateRequest
  assert_success
}

@test "v4 validates scalar and array types rather than coercing configuration" {
  V4_REQUEST='{"yes":"false"}'
  run v4ValidateRequest
  assert_status 2
  V4_REQUEST='{"args":["literal",42]}'
  run v4ValidateRequest
  assert_status 2
  run v4Main site list --tail=-1 --json
  assert_status 2
}

@test "v4 missing arguments fail before dialogs or Docker calls" {
  run v4Main site list --site --json
  assert_status 2
  [ ! -s "$STUB_DIR/dialogs.log" ]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "v4 confirmation never prompts and only explicit true permits mutation" {
  V4_REQUEST='{"yes":false}'
  run v4Confirm 'Delete this selected site.'
  assert_status 2
  V4_REQUEST='{"yes":true}'
  run v4Confirm 'Delete this selected site.'
  assert_success
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "v4 routes canonical and new aliases without hijacking legacy menu tasks" {
  run v4ShouldHandle site list
  assert_success
  run v4ShouldHandle --type joomla --task info
  assert_success
  run v4ShouldHandle --type joomla --task setup
  assert_failure
  run v4ShouldHandle --type joomla --task setup --no-interaction
  assert_success
  v4Parse --type joomla --task setup --container alpha.test --json
  [ "$V4_GROUP:$V4_ACTION" = site:create ]
  [ "$(v4Get site)" = alpha.test ]
  v4Parse --type joomla --task db-export --container alpha.test
  [ "$V4_GROUP:$V4_ACTION" = database:export ]
}

@test "v4 JSON response contains one result and preserves failure status" {
  function v4SiteExec() {
    v4Result '{"stdout":"first\n","stderr":"second\n","exit_code":9}'
    return 9
  }
  run v4Main site exec --site alpha.test --json -- false
  assert_status 9
  [ "$(jq -s length <<< "$output")" -eq 1 ]
  [ "$(jq -r .ok <<< "$output")" = false ]
  [ "$(jq -r .data.exit_code <<< "$output")" -eq 9 ]
  [ "$(jq -r .error.code <<< "$output")" -eq 9 ]
}

@test "v4 JSON envelope remains parseable when a handler writes diagnostics" {
  function v4SiteInfo() {
    printf '%s\n' 'ordinary tool output'
    v4Result '{"host":"alpha.test"}'
  }
  v4Main site info --site alpha.test --json > "$SANDBOX/result" 2> "$SANDBOX/diagnostics"
  [ "$(jq -s length "$SANDBOX/result")" -eq 1 ]
  [ "$(jq -r .data.host "$SANDBOX/result")" = alpha.test ]
  [ "$(cat "$SANDBOX/diagnostics")" = 'ordinary tool output' ]
}

@test "v4 initialization uses explicit absolute paths without creating them" {
  local physical_sandbox
  physical_sandbox=$(cd "$SANDBOX" && pwd -P)
  V4_REQUEST=$(jq -cn --arg repo "$SANDBOX/new repo" --arg project "$SANDBOX/new projects" '{repo_path:$repo,project_path:$project}')
  v4Init
  [ "$VDM_REPO_PATH" = "$physical_sandbox/new repo" ]
  [ "$VDM_PROJECT_PATH" = "$physical_sandbox/new projects" ]
  [ ! -e "$VDM_REPO_PATH" ]
  [ ! -e "$VDM_PROJECT_PATH" ]
  V4_REQUEST='{"repo_path":"/tmp/../etc"}'
  run v4Init
  assert_status 2
}

@test "v4 site loader checks metadata identity and root ownership" {
  v4_cli_fixture
  v4LoadSite alpha.test
  [ "$V4_DB_SERVICE" = mariadbalpha ]
  [ "$V4_WEB_SERVICE" = joomlaalpha ]
  [ "$V4_DOCROOT" = "$VDM_PROJECT_PATH/alpha/joomla" ]
  jq '.host="other.test"' "$V4_DIR/project.json" > "$V4_DIR/replacement"
  mv "$V4_DIR/replacement" "$V4_DIR/project.json"
  run v4LoadSite alpha.test
  assert_status 2
}

@test "v4 metadata rejects parent docroots and invalid database engines" {
  v4_cli_fixture
  local metadata
  metadata=$(cat "$V4_DIR/project.json")
  run v4ValidateMetadata "$(jq '.docroot="../outside"' <<< "$metadata")"
  assert_failure
  run v4ValidateMetadata "$(jq '.database.engine="sqlite"' <<< "$metadata")"
  assert_failure
  run v4ValidateMetadata "$(jq '.docroot="public/site"' <<< "$metadata")"
  assert_success
}

@test "v4 Compose includes project overrides and preserves literal arguments" {
  v4_cli_fixture
  v4LoadSite alpha.test
  printf '%s\n' 'services: {}' > "$V4_DIR/docker-compose.override.yml"
  v4Compose exec -T joomlaalpha printf '%s' 'a b'
  assert_command "--env-file $(v4DockerHostPath "$V4_ENV_FILE") --file $(v4DockerHostPath "$V4_COMPOSE") --file $(v4DockerHostPath "$V4_DIR/docker-compose.override.yml") exec -T joomlaalpha printf %s a b"
}

@test "v4 Compose normalizes native service-name records for ps and config" {
  v4_cli_fixture
  v4LoadSite alpha.test
  function docker() { printf 'joomlaalpha\r\nmariadbalpha\r\n'; }
  run v4Compose ps --status running --services
  assert_success
  [ "$output" = $'joomlaalpha\nmariadbalpha' ]
  run v4Compose config --services
  assert_success
  [ "$output" = $'joomlaalpha\nmariadbalpha' ]
}

@test "v4 Compose service-name normalization preserves failure and stderr" {
  v4_cli_fixture
  v4LoadSite alpha.test
  local result=0
  function docker() { printf 'joomlaalpha\r\n'; printf 'Docker failed\r\n' >&2; return 7; }
  v4Compose ps --services > "$SANDBOX/service-names" 2> "$SANDBOX/service-error" || result=$?
  [ "$result" -eq 7 ]
  printf 'joomlaalpha\n' > "$SANDBOX/expected-names"
  printf 'Docker failed\r\n' > "$SANDBOX/expected-error"
  cmp "$SANDBOX/expected-names" "$SANDBOX/service-names"
  cmp "$SANDBOX/expected-error" "$SANDBOX/service-error"
}

@test "v4 Compose preserves raw command log and non-service configuration bytes" {
  v4_cli_fixture
  v4LoadSite alpha.test
  function docker() { printf '\r\nembedded\rreturn\000data\r\n'; }
  printf '\r\nembedded\rreturn\000data\r\n' > "$SANDBOX/expected-stream"
  v4Exec joomlaalpha printf --services > "$SANDBOX/actual-stream"
  cmp "$SANDBOX/expected-stream" "$SANDBOX/actual-stream"
  v4Compose logs joomlaalpha > "$SANDBOX/actual-stream"
  cmp "$SANDBOX/expected-stream" "$SANDBOX/actual-stream"
  v4Compose ps --format json > "$SANDBOX/actual-stream"
  cmp "$SANDBOX/expected-stream" "$SANDBOX/actual-stream"
  v4Compose config > "$SANDBOX/actual-stream"
  cmp "$SANDBOX/expected-stream" "$SANDBOX/actual-stream"
  v4Compose config -- --services > "$SANDBOX/actual-stream"
  cmp "$SANDBOX/expected-stream" "$SANDBOX/actual-stream"
}

@test "v4 environment creation never enters the legacy create-file dialog" {
  local file="$SANDBOX/scoped/.env" value
  v4SetEnv "$file" 'VDM_ALPHA_DB_PASS="a $literal # value"'
  migrationReadEnvValue "$file" VDM_ALPHA_DB_PASS value
  [ "$value" = 'a $literal # value' ]
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "v4 live operation lock cannot be stolen or released by another process" {
  v4Lock "$SANDBOX/operation.lock"
  run v4Lock "$SANDBOX/operation.lock"
  assert_status 4
  run v4Unlock "$SANDBOX/operation.lock"
  assert_failure
  v4Unlock "$SANDBOX/operation.lock"
  [ ! -e "$SANDBOX/operation.lock" ]
}

@test "v4 stale same-host lock recovers while foreign and unknown owners remain" {
  local path="$SANDBOX/operation.lock"
  mkdir "$path"
  printf '%s\t%s\t%s\n' 2147483647 "$(hostname)" "$(id -u)" > "$path/owner"
  v4Lock "$path"
  v4Unlock "$path"
  mkdir "$path"
  printf '%s\t%s\t%s\n' 2147483647 other-host "$(id -u)" > "$path/owner"
  run v4Lock "$path"
  assert_status 4
  [ -f "$path/owner" ]
}

@test "v4 schema accepts verified source packages and string array flags" {
  v4Parse site create --source-sha256 0123456789abcdef --tables '["one","two"]'
  [ "$(v4Get source_sha256)" = 0123456789abcdef ]
  [ "$(v4Get tables)" = '["one","two"]' ]
  run v4Parse database export --tables '["one",2]'
  assert_status 2
}

@test "v4 JSON mode respects explicit false and literal tool arguments" {
  function v4SiteExec() { v4Result '{"stdout":"plain output","stderr":""}'; }
  run v4Main site exec --json --json=false -- printf --json
  assert_success
  [ "$output" = 'plain output' ]
  run v4Main site exec --json false -- printf --json
  assert_success
  [ "$output" = 'plain output' ]
  run v4ShouldHandle --type joomla --task setup -- --json
  assert_failure
}

@test "v4 rejects nested command arguments and multiple metadata documents" {
  V4_REQUEST='{"commands":[["php",["nested"]]]}'
  run v4ValidateRequest
  assert_status 2
  v4_cli_fixture
  local metadata
  metadata=$(cat "$V4_DIR/project.json")
  run v4ValidateMetadata "$metadata $metadata"
  assert_failure
  unset V4_REQUEST
  [ "$(v4Get site fallback)" = fallback ]
}

@test "v4 legacy loader preserves existing database identity and explicit image versions" {
  v4_cli_fixture
  rm "$V4_DIR/project.json"
  cat > "$V4_DIR/docker-compose.yml" <<'YAML'
services:
  mariadbalpha:
    image: mariadb:11.4.5
    container_name: mariadbalpha
    environment:
      - MARIADB_DATABASE=${VDM_ALPHA_DB}
    volumes:
      - ${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql
  joomlaalpha:
    image: "joomla:6.0.3-php8.3-apache"
    container_name: joomlaalpha
YAML
  printf '%s\n' 'VDM_ALPHA_DB_USER="legacyuser"' >> "$V4_DIR/.env"
  v4LoadSite alpha.test
  [ "$V4_LEGACY" = true ]
  [ "$(jq -r .database.user <<< "$V4_META")" = legacyuser ]
  [ "$(jq -r .database.version <<< "$V4_META")" = 11.4.5 ]
  [ "$(jq -r .joomla_version <<< "$V4_META")" = 6.0.3 ]
  [ "$(jq -r .php_version <<< "$V4_META")" = 8.3 ]
  [ ! -e "$V4_DIR/project.json" ]
}

@test "v4 SQL command uses JSON envelope while interactive console rejects JSON" {
  function v4DbConsole() { v4Result '{"stdout":"1\n","exit_code":0}'; }
  run v4Main database console --site alpha.test --command 'SELECT 1' --json
  assert_success
  [ "$(jq -r .data.stdout <<< "$output")" = 1 ]
  run v4Main database console --site alpha.test --json
  assert_status 2
}

@test "v4 rejects supported option names that do not belong to the action" {
  function v4SiteInfo() { printf 'HANDLER SHOULD NOT RUN\n'; }
  v4Main site info --site alpha.test --php-version 8.3 --json > "$SANDBOX/result" 2> "$SANDBOX/errors" && return 1
  [ "$(jq -r .error.code "$SANDBOX/result")" -eq 2 ]
  [[ "$(jq -r .error.message "$SANDBOX/result")" == *php_version* ]]
  [[ "$(cat "$SANDBOX/result")" != *'HANDLER SHOULD NOT RUN'* ]]
  [ ! -s "$STUB_DIR/commands.log" ]
}

@test "v4 action guard accepts normalized aliases and common flags" {
  function v4SiteCreate() { v4Result "$(jq -c '{database_engine,activate}' <<< "$V4_REQUEST")"; }
  run v4Main --type joomla --task setup --db-engine mysql --start=false --no-interaction --yes --json
  assert_success
  [ "$(jq -r .data.database_engine <<< "$output")" = mysql ]
  [ "$(jq -r .data.activate <<< "$output")" = false ]
}

@test "v4 publishes desktop form descriptors from the TUI contract" {
  v4_cli_limit_native_arguments
  run v4Main site schema --json
  assert_success
  [ "$(jq -r '.data.form_schemas["site.path"].fields[] | select(.name=="target") | .enum | join(",")' <<< "$output")" = project,docroot ]
  [ "$(jq -r '.data.form_schemas["site.create"].fields[] | select(.name=="admin_password") | .secret' <<< "$output")" = true ]
  [ "$(jq -r '.data.action_schemas["site.create"].conditions[0].required[0]' <<< "$output")" = admin_email ]
}

@test "v4 large requests aliases and results stay off native argument lists" {
  v4_cli_limit_native_arguments
  local large
  large=$(jq -rn '"value with spaces $() " * 3000')
  printf '%s' "$large" | jq -Rs '{schema_version:1,db_name:.,json:true}' > "$SANDBOX/large-request.json"
  function v4SiteCreate() { v4Result "$V4_REQUEST"; }
  run v4Main site create --config "$SANDBOX/large-request.json"
  assert_success
  [ "$(jq -r .data.database_name <<< "$output")" = "$large" ]
  [ "$(jq -r '.data|has("db_name")' <<< "$output")" = false ]
  v4Parse site create --site-name "$large" --php-settings '{"extra":true}'
  [ "$(v4Get site_name)" = "$large" ]
  [ "$(v4Get php_settings)" = '{"extra":true}' ]
  large=$(printf '%s' "$large" | jq -Rsc '{extra:.}')
  v4Parse site create --php-settings "$large"
  [ "$(v4Get php_settings)" = "$large" ]
}

@test "v4 validates explicit and persisted hook maps with the shared validator" {
  V4_REQUEST='{"hooks":{"post-start":[["php","-v"]]},"trust_hooks":false}'
  v4ValidateRequest
  V4_REQUEST='{"hooks":{"unknown-event":[["php","-v"]]}}'
  run v4ValidateRequest
  assert_status 2
  v4_cli_fixture
  local metadata
  metadata=$(jq '.hooks={"post-start":[["php",{}]]}' "$V4_DIR/project.json")
  run v4ValidateMetadata "$metadata"
  assert_failure
}

@test "v4 roots resolve existing aliases without creating missing suffixes" {
  local physical_target
  mkdir -p "$SANDBOX/physical"
  physical_target=$(cd "$SANDBOX/physical" && pwd -P)
  ln -s "$SANDBOX/physical" "$SANDBOX/alias"
  [ -L "$SANDBOX/alias" ]
  V4_REQUEST=$(jq -cn --arg repo "$SANDBOX/alias/new repo" --arg project "$SANDBOX/alias/new projects" --arg backup "$SANDBOX/alias/new backups" '{repo_path:$repo,project_path:$project,backup_path:$backup}')
  v4Init
  [ "$VDM_REPO_PATH" = "$physical_target/new repo" ]
  [ "$VDM_PROJECT_PATH" = "$physical_target/new projects" ]
  [ "$VDM_BACKUP_PATH" = "$physical_target/new backups" ]
  [ ! -e "$VDM_REPO_PATH" ]
  # Native Windows links require an existing target when they are created.
  mkdir "$SANDBOX/missing-target"
  ln -s "$SANDBOX/missing-target" "$SANDBOX/dangling"
  [ -L "$SANDBOX/dangling" ]
  rmdir "$SANDBOX/missing-target"
  run v4CanonicalRoot "$SANDBOX/dangling/new"
  assert_status 2
}

@test "v4 rejects ambiguous batch targets and ignores empty selections" {
  function v4DbExport() { v4Result "$V4_REQUEST"; }
  run v4Main database export --site alpha.test --all --json
  assert_status 2
  run v4Main database export --all --sites '["alpha.test"]' --json
  assert_status 2
  run v4Main database export --site alpha.test --sites '["beta.test"]' --json
  assert_status 2
  run v4Main database export --site alpha.test --sites '[]' --json
  assert_success
  [ "$(jq -r .data.site <<< "$output")" = alpha.test ]
  [ "$(jq -r '.data | has("sites")' <<< "$output")" = false ]
  run v4Main database export --all --site '' --sites '[]' --json
  assert_success
  [ "$(jq -r '.data | has("site") or has("sites")' <<< "$output")" = false ]
}

@test "v4 native Windows jq keeps JSON paths literal and translates only files" {
  local native="$SANDBOX/native" argument
  local -a arguments=()
  mkdir "$native"
  cat > "$native/jq" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$SANDBOX/jq-arguments"
printf '%s\n' "$MSYS_NO_PATHCONV" "$MSYS2_ARG_CONV_EXCL" > "$SANDBOX/jq-environment"
SH
  chmod +x "$native/jq"
  function cygpath() { printf 'C:/translated%s\n' "${@: -1}"; }
  PATH="$native:$PATH" OSTYPE=msys jq -n --arg project '/c/Users/Dev/Projects' --rawfile body /tmp/request --slurpfile metadata /tmp/meta '. + {project:$project}' /tmp/input
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done < "$SANDBOX/jq-arguments"
  [ "${arguments[0]}" = -b ]
  [ "${arguments[4]}" = /c/Users/Dev/Projects ]
  [ "${arguments[7]}" = C:/translated/tmp/request ]
  [ "${arguments[10]}" = C:/translated/tmp/meta ]
  [ "${arguments[11]}" = '. + {project:$project}' ]
  [ "${arguments[12]}" = C:/translated/tmp/input ]
  [ "$(cat "$SANDBOX/jq-environment")" = $'1\n*' ]
}

@test "v4 initializes platform before legacy privilege helpers run" {
  local original_ostype="$OSTYPE"
  # This isolates platform initialization from jq's actual host-native boundary.
  # Spoofing macOS on Windows must not turn off jq.exe's MSYS handling.
  function v4Get() { printf '%s' "${2:-}"; }
  OSTYPE=msys v4Init
  [ "$OS_NUMBER" -eq 3 ]
  OSTYPE=darwin v4Init
  [ "$OS_NUMBER" -eq 2 ]
  OSTYPE=linux-gnu v4Init
  [ "$OS_NUMBER" -eq 1 ]
  OSTYPE="$original_ostype"
}

@test "v4 native Docker boundary preserves container paths and code literally" {
  local argument
  local -a arguments=()
  function docker() {
    printf '%s\0' "$@" > "$SANDBOX/docker-arguments"
    printf '%s\n' "$MSYS_NO_PATHCONV" "$MSYS2_ARG_CONV_EXCL" > "$SANDBOX/docker-environment"
  }
  OSTYPE=msys v4Docker exec --workdir /var/www/html joomlaalpha php -r 'echo "/var/www/html";'
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done < "$SANDBOX/docker-arguments"
  [ "${arguments[2]}" = /var/www/html ]
  [ "${arguments[6]}" = 'echo "/var/www/html";' ]
  [ "$(cat "$SANDBOX/docker-environment")" = $'1\n*' ]
}

@test "v4 Windows Compose translates selected root without leaking caller settings" {
  v4_cli_fixture
  v4LoadSite alpha.test
  local selected_root="$VDM_PROJECT_PATH" argument
  local -a arguments=()
  function cygpath() { printf 'C:/translated%s\n' "${@: -1}"; }
  function docker() {
    printf '%s\0' "$@" > "$SANDBOX/scoped-compose-arguments"
    printf '%s\n' "$VDM_PROJECT_PATH" "${VDM_ALPHA_DB:-unset}" > "$SANDBOX/scoped-compose-environment"
  }
  export VDM_ALPHA_DB=stale_database
  OSTYPE=msys v4Compose exec -T joomlaalpha php -v
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done < "$SANDBOX/scoped-compose-arguments"
  [ "${arguments[2]}" = "C:/translated$V4_ENV_FILE" ]
  [ "${arguments[4]}" = "C:/translated$V4_COMPOSE" ]
  [ "$(cat "$SANDBOX/scoped-compose-environment")" = "C:/translated$selected_root"$'\nunset' ]
  [ "$VDM_PROJECT_PATH" = "$selected_root" ]
  [ "$VDM_ALPHA_DB" = stale_database ]
}
