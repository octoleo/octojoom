#!/usr/bin/env bats
# Each test runs with isolated Octojoom paths and Docker stand-ins. The Docker
# integration suite covers actual file loading, native SQL import and startup.
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  bats_require_minimum_version 1.5.0
  octojoom_setup
  octojoom_config
  package="$SANDBOX/Shop's \$5 export.zip"
  prepared="$SANDBOX/prepared"
  site=shop.example.test
  fixture_site_dir="$VDM_REPO_PATH/joomla/available/$site"
  enabled="$VDM_REPO_PATH/joomla/enabled/$site"
  write_playground_fixture "$package" fresh
}

@test "fresh preparation stages only installed files and SQL with private metadata" {
  local digest
  digest=$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)
  run joomlaPlaygroundPreparePackage "$package" "$prepared" "$digest"
  assert_success
  joomlaSiteJSON -e '.siteName=="Fixture Shop" and .payloadChecksum=="verified"' <<< "$output"
  refute_output_contains private-fixture
  assert_file_exists "$prepared/site/media/example/index.html"
  assert_file_contains "$prepared/database.sql" 'CREATE TABLE demo_items'
  assert_file_exists "$prepared/site/configuration.php"
  refute_file_exists "$prepared/site/database.sql"
  refute_file_exists "$prepared/site/metadata.json"
  refute_file_exists "$prepared/export.json"
  refute_file_exists "$prepared/database.ndjson"
  joomlaSiteJSON -e '.admin.username=="fixture-admin" and .admin.password=="private-fixture-password" and
    .databaseName=="joomla" and .databasePrefix=="demo_" and .phpSettings.memory_limit=="512M"' < "$prepared/metadata.json"
  if ! is_windows; then
    assert_equal "$(file_mode "$prepared")" 700
    assert_equal "$(file_mode "$prepared/metadata.json")" 600
    assert_equal "$(file_mode "$prepared/database.sql")" 600
  fi
  refute_command '^docker '
}

@test "fresh preparation checks the selected digest and preserves existing directories" {
  run joomlaPlaygroundPreparePackage "$package" "$prepared" "$(printf '%064d' 0)"
  assert_failure
  refute_output_contains private-fixture
  refute_file_exists "$prepared"
  mkdir -p "$prepared"
  printf '%s\n' original > "$prepared/owner"
  run joomlaPlaygroundPreparePackage "$package" "$prepared"
  assert_failure
  assert_file_contains "$prepared/owner" original
  refute_file_exists "$prepared/site"
  refute_command '^docker '
}

@test "fresh preparation discards ambiguous archive paths and partial payloads" {
  local variant
  for variant in path-alias bad-crc wrong-hash; do
    write_playground_fixture "$package" "$variant"
    run joomlaPlaygroundPreparePackage "$package" "$prepared"
    assert_failure
    refute_file_exists "$prepared"
    refute_output_contains private-fixture
  done
  refute_command '^docker '
}

@test "fresh settings keep package credentials and distinguish explicit account edits" {
  joomlaPlaygroundPreparePackage "$package" "$prepared" > /dev/null
  parseCLI --non-interactive
  joomlaPlaygroundConfirmFreshSettings "$prepared"
  assert_equal "$VDM_J_USERNAME" fixture-admin
  assert_equal "$VDM_J_DB_PREFIX" demo_
  assert_equal "${VDM_memory_limit:-}" 512M
  joomlaSiteJSON -e '.sourceUsername=="fixture-admin" and .password=="private-fixture-password" and
    (.changed|all(.[]; .==false))' < "$prepared/account.json"
  parseCLI --non-interactive --site-name "Imported store" --admin-username owner --admin-user "Store owner" \
    --admin-email owner@example.test --admin-password 'a private edited password!' --db-name shopdata --memory-limit 768M
  run joomlaPlaygroundConfirmFreshSettings "$prepared"
  assert_success
  refute_output_contains private-fixture
  refute_output_contains 'a private edited password!'
  joomlaSiteJSON -e '.sourceUsername=="fixture-admin" and .username=="owner" and .changed.password and
    .changed.username and .changed.email and .changed.name' < "$prepared/account.json"
  if ! is_windows; then assert_equal "$(file_mode "$prepared/account.json")" 600; fi
}

@test "interactive settings retain the imported password when the masked field is left blank" {
  joomlaPlaygroundPreparePackage "$package" "$prepared" > /dev/null
  answers "My new store" owner "Store owner" owner@example.test ''
  whiptail() {
    if [[ "$*" == *--passwordbox* ]]; then
      [[ "$*" != *private-fixture-password* ]] || return 17
    fi
    command whiptail "$@"
  }
  run joomlaPlaygroundConfirmFreshSettings "$prepared"
  assert_success
  assert_answers_used
  assert_dialog 'Enter a new administrator password'
  refute_output_contains private-fixture-password
  joomlaSiteJSON -e '.siteName=="My new store" and .username=="owner" and .changed.username and
    .password=="private-fixture-password" and .changed.password==false' < "$prepared/account.json"
}

@test "fresh configuration reconciles the real database, site name and paths on a private copy" {
  local digest config="$prepared/site/configuration.php"
  digest=$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)
  joomlaPlaygroundPreparePackage "$package" "$prepared" "$digest" > /dev/null
  parseCLI --non-interactive --site-name "Reader's store"
  joomlaPlaygroundConfirmFreshSettings "$prepared"
  run joomlaPlaygroundConfigureFresh "$prepared" mariadbshop mysqli shopdb shopuser 'private-fixture-new-db' /var/www/html/store
  assert_success
  refute_output_contains private-fixture
  assert_file_contains "$config" "public \$host = 'mariadbshop';"
  assert_file_contains "$config" "public \$db = 'shopdb';"
  assert_file_contains "$config" "public \$user = 'shopuser';"
  assert_file_contains "$config" "public \$password = 'private-fixture-new-db';"
  assert_file_contains "$config" "public \$secret = 'private-fixture-key';"
  assert_file_contains "$config" "public \$sitename = 'Reader\\'s store';"
  assert_file_contains "$config" "public \$tmp_path = '/var/www/html/store/tmp';"
  assert_file_contains "$config" "public \$live_site = '';"
  assert_equal "$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)" "$digest"
  refute_command '^docker '
}

@test "fresh CLI rejects an existing target, conflicting prefix and missing identity before deployment" {
  local fresh_home="$SANDBOX/uninitialized"
  local -a deploy=(--type joomla --task playground --action deploy --file "$package" --non-interactive --output json)
  run --separate-stderr env OCTOJOOM_HOME="$fresh_home" bash "$OCTOJOOM_SCRIPT" "${deploy[@]}" --target current
  assert_status 17
  joomlaSiteJSON -e '.success==false' <<< "$output"
  run --separate-stderr env OCTOJOOM_HOME="$fresh_home" bash "$OCTOJOOM_SCRIPT" "${deploy[@]}" --target new --container "$site"
  assert_status 17
  run --separate-stderr env OCTOJOOM_HOME="$fresh_home" bash "$OCTOJOOM_SCRIPT" "${deploy[@]}" --target new
  assert_status 17
  run --separate-stderr env OCTOJOOM_HOME="$fresh_home" bash "$OCTOJOOM_SCRIPT" "${deploy[@]}" \
    --target new --key shop --domain example.test --db-prefix other_
  assert_status 17
  [[ "${stderr:-}$output" != *private-fixture* ]]
  refute_file_exists "$fresh_home"
  refute_command '^docker '
}

# Exercise the normal command parser, package preparation, account selection and
# setup transaction. Substitute only the Docker runtime and its image discovery.
fresh_setup_standins() {
  joomlaPlaygroundSelectFreshRuntime() {
    VDM_J_REPO=joomla
    VDM_JV=6.2.0-php8.4-apache
    VDM_PHP_INI_TARGET=/usr/local/etc/php/conf.d/zz-octojoom.ini
  }
  joomlaRuntimeIniTarget() { printf '%s\n' /usr/local/etc/php/conf.d/zz-octojoom.ini; }
  joomlaPlaygroundProvisionFresh() {
    [ -s "$1/database.sql" ] && [ -s "$1/account.json" ] || return 31
    [ ! -e "$fixture_site_dir" ] || return 32
    printf '%s\n' "$2" >> "$SANDBOX/provision"
    return "${fixture_provision_status:-0}"
  }
  joomlaPlaygroundStartFresh() {
    [ -f "$fixture_site_dir/docker-compose.yml" ] || return 33
    printf '%s\n' "$2" >> "$SANDBOX/started"
    return "${fixture_start_status:-0}"
  }
  joomlaPlaygroundCleanupFresh() { printf '%s\n' "$2" >> "$SANDBOX/cleanup"; }
}

fresh_command() {
  cliStart --type joomla --task playground --action deploy --target new --file "$package" \
    --key shop --env-key SHOP --domain example.test --sub-domain shop \
    --db-name shopdata --db-user shopuser --non-interactive --output json "$@"
}

@test "fresh CLI publishes the site-specific environment and imported PHP preferences for a disabled site" {
  make_joomla_container bravo BRAVO bravo
  cp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/prior.env"
  fresh_setup_standins
  run --separate-stderr fresh_command --enable false
  assert_success
  joomlaSiteJSON -e '.success and .data.site=="shop.example.test" and .data.enabled==false and .data.target=="new"' <<< "$output"
  [[ "${stderr:-}$output" != *private-fixture* ]]
  cmp "$SANDBOX/prior.env" "$VDM_REPO_PATH/joomla/.env"
  local value
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_SITE_NAME value
  assert_equal "$value" "Fixture Shop"
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_ADMIN_PASSWORD value
  assert_equal "$value" private-fixture-password
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_DB_PREFIX value
  assert_equal "$value" demo_
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_DB value
  assert_equal "$value" shopdata
  refute_file_contains "$fixture_site_dir/.env" VDM_BRAVO_
  if ! is_windows; then assert_equal "$(file_mode "$fixture_site_dir/.env")" 600; fi
  refute_file_contains "$fixture_site_dir/docker-compose.yml" 'JOOMLA_ADMIN_PASSWORD='
  refute_file_contains "$fixture_site_dir/docker-compose.yml" 'JOOMLA_EXTENSIONS_URLS='
  assert_file_contains "$VDM_PROJECT_PATH/shop/php.ini" 'memory_limit = 512M'
  assert_file_contains "$SANDBOX/provision" "$site"
  refute_file_exists "$SANDBOX/started"
  refute_file_exists "$enabled"
}

@test "enabling a new Playground hostname starts the published site" {
  fresh_setup_standins
  run --separate-stderr fresh_command --enable true
  assert_success
  joomlaSiteJSON -e '.success and .data.enabled==true' <<< "$output"
  assert_file_contains "$SANDBOX/started" "$site"
  assert_file_exists "$enabled/docker-compose.yml"
}

@test "fresh setup preserves an occupied project key and never provisions over it" {
  fresh_setup_standins
  mkdir -p "$VDM_PROJECT_PATH/shop"
  printf '%s\n' original > "$VDM_PROJECT_PATH/shop/owner"
  run --separate-stderr fresh_command --enable true
  assert_failure
  assert_file_contains "$VDM_PROJECT_PATH/shop/owner" original
  refute_file_exists "$SANDBOX/provision"
  refute_file_exists "$fixture_site_dir"
}

@test "fresh setup preserves existing enabled or available identities for the same hostname" {
  fresh_setup_standins
  local registry
  for registry in "$enabled" "$fixture_site_dir"; do
    mkdir -p "$registry"
    printf '%s\n' original > "$registry/owner"
    run --separate-stderr fresh_command --enable true
    assert_failure
    assert_file_contains "$registry/owner" original
    refute_file_exists "$SANDBOX/provision"
    refute_file_exists "$VDM_PROJECT_PATH/shop"
    rm "$registry/owner"
    rmdir "$registry"
  done
}

@test "failed provisioning or activation rolls back only the fresh website" {
  fresh_setup_standins
  make_joomla_container bravo BRAVO bravo
  cp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/prior.env"
  local fixture_provision_status=51 fixture_start_status=0
  run --separate-stderr fresh_command --enable true
  assert_failure
  refute_file_exists "$fixture_site_dir"
  refute_file_exists "$enabled"
  refute_file_exists "$VDM_PROJECT_PATH/shop"
  local fixture_provision_status=0 fixture_start_status=52
  run --separate-stderr fresh_command --enable true
  assert_failure
  refute_file_exists "$fixture_site_dir"
  refute_file_exists "$enabled"
  refute_file_exists "$VDM_PROJECT_PATH/shop"
  assert_file_contains "$SANDBOX/cleanup" "$site"
  cmp "$SANDBOX/prior.env" "$VDM_REPO_PATH/joomla/.env"
  assert_file_exists "$VDM_REPO_PATH/joomla/available/bravo.vdm.dev/docker-compose.yml"
}

@test "verified package menu dispatches fresh setup with the previewed archive digest" {
  joomlaPlaygroundDeployFresh() {
    [ "$1" = "$package" ] && [[ "$2" =~ ^[a-f0-9]{64}$ ]] || return 17
    printf '%s\n' "$1" > "$SANDBOX/selected"
  }
  answers "$package" new
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_file_contains "$SANDBOX/selected" "$package"
}

@test "declining final deployment from the menu leaves site, host preferences and database untouched" {
  fresh_setup_standins
  make_joomla_container bravo BRAVO bravo
  cp "$VDM_SRC_PATH/.env" "$SANDBOX/host-before"
  cp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/sites-before"
  parseCLI --key shop --env-key SHOP --domain example.test --sub-domain shop --image-source joomla \
    --db-name shopdata --db-user shopuser --db-password fixture-db-password --db-root-password fixture-db-root \
    --customize false --enable true --phpmyadmin false --mailcatcher false
  answers "$package" new 'Reviewed store' 'fixture-admin' 'private-fixture-name' 'private-fixture@example.test' '' no
  run showJoomlaPlayground
  assert_success
  assert_answers_used
  assert_dialog "Import Fixture Shop (Joomla 6.2.0) into a new website?"
  assert_dialog "Website: shop.example.test"
  assert_dialog "Site name: Reviewed store"
  refute_dialog private-fixture-password
  refute_dialog fixture-db-root
  refute_file_exists "$SANDBOX/provision"
  refute_file_exists "$fixture_site_dir"
  refute_file_exists "$VDM_PROJECT_PATH/shop"
  cmp "$SANDBOX/host-before" "$VDM_SRC_PATH/.env"
  cmp "$SANDBOX/sites-before" "$VDM_REPO_PATH/joomla/.env"
  refute_command '^docker .* (up|create|stop|down|restart|rm)( |$)'
}

@test "fresh runtime verifies the image manifest, PHP extensions and package PHP preference" {
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  parseCLI --non-interactive
  local VDM_J_REPO=joomla VDM_JV=latest VDM_WEBSERVER=apache
  local fixture_probe='{"joomla":"6.2.0","php":"8.4.2","flavor":"apache","extensions":["json","session","dom","SimpleXML","xml","mbstring","mysqli"],"ini_dir":"/usr/local/etc/php/conf.d"}'
  joomlaRuntimeProbeImage() { printf '%s\n' "$fixture_probe"; }
  joomlaPlaygroundSelectFreshRuntime "$prepared"
  assert_equal "$VDM_JV" '6.2.0-php8.4-apache'
  assert_equal "${VDM_PHP_INI_TARGET:-}" '/usr/local/etc/php/conf.d/zz-octojoom.ini'
  parseCLI --non-interactive --image-tag custom
  fixture_probe=$(joomlaSiteJSON -c '.joomla="6.1.0"' <<< "$fixture_probe")
  run joomlaPlaygroundSelectFreshRuntime "$prepared"
  assert_failure
  fixture_probe=$(joomlaSiteJSON -c '.joomla="6.2.0" | .extensions-=["mysqli"]' <<< "$fixture_probe")
  run joomlaPlaygroundSelectFreshRuntime "$prepared"
  assert_failure
}

@test "cleanup removes only volumes owned by the interrupted Playground deployment" {
  local fixture_token=1234567890abcdef1234567890abcdef
  mkdir -p "$prepared/runtime"
  printf '%s\n' "$fixture_token" > "$prepared/runtime/token"
  printf '%s\t%s\n' db shop_database site preexisting_site > "$prepared/runtime/volumes"
  docker() {
    case "$1 $2" in
      'volume inspect')
        case "${!#}" in
          shop_database) printf '%s\n' "$fixture_token" ;;
          preexisting_site) printf '%s\n' 'unrelated' ;;
          *) return 1 ;;
        esac ;;
      'volume rm') printf '%s\n' "$3" >> "$SANDBOX/removed" ;;
      *) return 1 ;;
    esac
  }
  run joomlaPlaygroundCleanupFresh "$prepared" "$site"
  assert_success
  assert_equal "$(cat "$SANDBOX/removed")" shop_database
}
