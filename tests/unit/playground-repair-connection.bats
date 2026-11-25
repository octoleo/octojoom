#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_PLAYGROUND_REPAIR=true
  readJoomlaSiteFacts() {
    VDM_SITE_SERVICE=app VDM_SITE_DIR="$SANDBOX/site" VDM_SITE_COMPOSE="$SANDBOX/site/docker-compose.yml"
    VDM_SITE_ENV="$SANDBOX/shared.env" VDM_SITE_DOCROOT=/var/www/html
  }
  joomlaDatabaseCompose() { cat "$SANDBOX/model"; }
  joomlaDatabaseReadConfiguration() { touch "$SANDBOX/old-php-read"; return 1; }
  joomlaDatabaseDiscoverClients() { [ "$VDM_DB_SERVICE" = store ]; }
  cat > "$SANDBOX/model" <<'JSON'
{"services":{"app":{"environment":{"JOOMLA_DB_HOST":"db-alias:3307","JOOMLA_DB_NAME":"inventory","JOOMLA_DB_USER":"storeapp","JOOMLA_DB_PREFIX":"store_"}},"store":{"image":"acme/storage","networks":{"internal":{"aliases":["db-alias"]}},"environment":{"MARIADB_USER":"storeapp","MARIADB_PASSWORD":"literal$$secret"}},"other":{"image":"mariadb","environment":{"MARIADB_PASSWORD":"wrong database"}}}}
JSON
}

@test "repair resolves this site's connection without needing the old Joomla PHP" {
  # Native Windows jq writes CRLF even when Bash captures the result.
  jq() {
    set -o pipefail
    command jq "$@" | sed $'s/\r$//;s/$/\r/'
  }
  joomlaDatabaseContext shop.example.test
  assert_equal "$VDM_DB_SERVICE" store
  assert_equal "$VDM_DB_NAME" inventory
  assert_equal "$VDM_DB_USER" storeapp
  assert_equal "$VDM_DB_PASSWORD" 'literal$secret'
  assert_equal "$VDM_DB_HOST" db-alias:3307
  # shellcheck disable=SC2153 # joomlaDatabaseContext sets the selected port.
  assert_equal "$VDM_DB_PORT" 3307
  assert_equal "$VDM_DB_PREFIX" store_
  refute_file_exists "$SANDBOX/old-php-read"
}

@test "repair can use the old connection when Compose omits application credentials" {
  jq 'del(.services.app.environment.JOOMLA_DB_USER,.services.store.environment)' "$SANDBOX/model" > "$SANDBOX/partial"
  mv "$SANDBOX/partial" "$SANDBOX/model"
  joomlaDatabaseReadConfiguration() {
    printf '%s\n' '{"installed":true,"host":"db-alias:3307","driver":"mysqli","name":"inventory","user":"original","password":"existing","prefix":"orig_"}'
  }
  joomlaDatabaseContext shop.example.test
  assert_equal "$VDM_DB_SERVICE" store
  assert_equal "$VDM_DB_PASSWORD" existing
  assert_equal "$VDM_DB_PREFIX" orig_
}

@test "repair never redirects an unresolved application database host to a different service" {
  jq '.services.app.environment.JOOMLA_DB_HOST="external.test"' "$SANDBOX/model" > "$SANDBOX/partial"
  mv "$SANDBOX/partial" "$SANDBOX/model"
  run joomlaDatabaseContext shop.example.test
  assert_failure
  refute_output_contains 'literal'
}

@test "repair uses the package configuration when the selected site's PHP is absent or damaged" {
  local package="$SANDBOX/site.zip" prepared="$SANDBOX/prepared" work="$SANDBOX/import"
  local VDM_DB_HOST=db VDM_DB_DRIVER=mysqli VDM_DB_NAME=inventory VDM_DB_USER=store VDM_DB_PASSWORD=docker-secret
  mkdir "$work"
  write_playground_fixture "$package" fresh
  for damage in missing malformed; do
    rm -rf -- "$prepared"
    joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
    parseCLI --non-interactive
    joomlaPlaygroundConfirmReplaceSettings "$prepared"
    joomlaDatabaseConfigurationFile() {
      [ "$damage" = malformed ] && printf '%s' '<?php class old {' > "$3"
    }
    joomlaPlaygroundConfigureReplacement "$prepared" shop.example.test "$work" /var/www/html
    assert_file_contains "$prepared/site/configuration.php" "public \$db = 'inventory';"
    assert_file_contains "$prepared/site/configuration.php" "public \$password = 'docker-secret';"
  done
}

@test "repair keeps target PHP settings even when the exported PHP differs" {
  local package="$SANDBOX/php.zip" prepared="$SANDBOX/prepared"
  write_playground_fixture "$package" fresh
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  jq '.phpSettings.memory_limit = "donor-only"' "$prepared/metadata.json" > "$prepared/modified"
  mv "$prepared/modified" "$prepared/metadata.json"
  parseCLI --non-interactive
  run joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_success
  [ -z "$output" ]
  parseCLI --non-interactive --memory-limit 512M
  run joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_success
  assert_output_contains "supplied runtime override is ignored"
}

@test "an existing deployment ignores unsupported donor PHP during ZIP extraction while fresh setup reports it" {
  local package="$SANDBOX/original.zip" changed="$SANDBOX/unsupported.zip"
  write_playground_fixture "$package" fresh
  python3 - "$package" "$changed" <<'PY'
import json
import sys
from zipfile import ZipFile

with ZipFile(sys.argv[1]) as source, ZipFile(sys.argv[2], "w") as output:
    for entry in source.infolist():
        data = source.read(entry)
        if entry.filename == "export.json":
            export = json.loads(data)
            export["playground"]["configuration"]["phpSettings"]["memory_limit"] = "unknown-donor-setting"
            data = json.dumps(export).encode()
        output.writestr(entry, data)
PY
  run joomlaPlaygroundPreparePackage "$changed" "$SANDBOX/current" '' current
  assert_success
  jq -e '.phpSettings == {}' "$SANDBOX/current/metadata.json"
  run joomlaPlaygroundPreparePackage "$changed" "$SANDBOX/fresh"
  assert_failure
  assert_output_contains 'Invalid exported PHP setting'
}

@test "current menu keeps SQL accounts missing plaintext details with one settings choice" {
  local package="$SANDBOX/keep.zip" prepared="$SANDBOX/prepared"
  write_playground_fixture "$package" fresh
  joomlaPlaygroundPreparePackage "$package" "$prepared" '' current >/dev/null
  jq '.admin={}' "$prepared/metadata.json" > "$prepared/brief"
  mv "$prepared/brief" "$prepared/metadata.json"
  OCTOJOOM_NON_INTERACTIVE=false
  answers keep
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_answers_used
  jq -e '.username=="" and .password=="" and (.changed|all(.[]; .==false))' "$prepared/account.json"
  [ "$(wc -l < "$STUB_DIR/dialogs.log")" -eq 1 ]
}

@test "current menu can edit site and account fields while a blank password keeps the imported hash" {
  local package="$SANDBOX/edit.zip" prepared="$SANDBOX/prepared"
  write_playground_fixture "$package" fresh
  joomlaPlaygroundPreparePackage "$package" "$prepared" '' current >/dev/null
  jq 'del(.admin.password)' "$prepared/metadata.json" > "$prepared/brief"
  mv "$prepared/brief" "$prepared/metadata.json"
  OCTOJOOM_NON_INTERACTIVE=false
  answers edit 'Changed store' fixture-admin 'New display' private-fixture@example.test ''
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_answers_used
  jq -e '.siteName=="Changed store" and .name=="New display" and .changed.name and (.changed.password|not)' "$prepared/account.json"
}
