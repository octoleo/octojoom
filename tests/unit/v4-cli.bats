#!/usr/bin/env bats
# shellcheck shell=bash
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
  V4_REQUEST=$(jq -cn --arg repo "$SANDBOX/new repo" --arg project "$SANDBOX/new projects" '{repo_path:$repo,project_path:$project}')
  v4Init
  [ "$VDM_REPO_PATH" = "$SANDBOX/new repo" ]
  [ "$VDM_PROJECT_PATH" = "$SANDBOX/new projects" ]
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
  assert_command "--env-file $V4_ENV_FILE --file $V4_COMPOSE --file $V4_DIR/docker-compose.override.yml exec -T joomlaalpha printf %s a b"
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
