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

@test "fresh preparation stages installed files and keeps database exports and metadata private" {
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
  refute_file_exists "$prepared/site/database.ndjson"
  refute_file_exists "$prepared/site/metadata.json"
  refute_file_exists "$prepared/export.json"
  assert_file_contains "$prepared/database.ndjson" 'CREATE TABLE demo_items'
  joomlaSiteJSON -e '.admin.username=="fixture-admin" and .admin.password=="private-fixture-password" and
    .databaseName=="joomla" and .databasePrefix=="demo_" and .phpSettings.memory_limit=="512M"' < "$prepared/metadata.json"
  if ! is_windows; then
    assert_equal "$(file_mode "$prepared")" 700
    assert_equal "$(file_mode "$prepared/metadata.json")" 600
    assert_equal "$(file_mode "$prepared/database.sql")" 600
    assert_equal "$(file_mode "$prepared/database.ndjson")" 600
  fi
  refute_command '^docker '
}

@test "MySQL and MariaDB restore inline UTF-8 while preserving chunked text in the source column encoding" {
  write_playground_fixture "$package" mysql-values
  local digest engine imported="$SANDBOX/import.sql"
  digest=$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)
  joomlaPlaygroundPreparePackage "$package" "$prepared" "$digest" >/dev/null
  cp "$prepared/database.sql" "$SANDBOX/input.sql"
  cp "$prepared/database.ndjson" "$SANDBOX/input.ndjson"
  sed '/^INSERT INTO /d' "$SANDBOX/input.sql" > "$SANDBOX/non-row-before"
  for engine in mysql mariadb; do
    joomlaPlaygroundNativeImportStream "$prepared/database.sql" "$engine" > "$imported"
    assert_file_contains "$imported" "X'00FF',X'80',CONVERT(UNHEX('436166C3A9') USING utf8mb4)"
    assert_file_contains "$imported" "NULL,X'30',X'00',CONVERT(UNHEX('') USING utf8mb4),NULL,ST_GeomFromWKB(X'010100000000000000000000000000000000000000',4326));"
    if [ "$engine" = mysql ]; then
      assert_file_contains "$imported" "VALUES (UNHEX('30'),UNHEX('2D322E3530'),"
      assert_file_contains "$imported" "CONVERT(UNHEX('7B7D') USING utf8mb4),NULL),(UNHEX('3130'),"
      assert_file_contains "$imported" "VALUES (@__joomengine_export_0,CONVERT(@__joomengine_export_1 USING utf8mb4));"
    else
      assert_file_contains "$imported" "VALUES (X'30',X'2D322E3530',"
      assert_file_contains "$imported" "X'7B7D',NULL),(X'3130',"
      assert_file_contains "$imported" "VALUES (@__joomengine_export_0,@__joomengine_export_1);"
    fi
    sed '/^INSERT INTO /d' "$imported" > "$SANDBOX/non-row-after"
    cmp "$SANDBOX/non-row-before" "$SANDBOX/non-row-after"
  done
  cmp "$SANDBOX/input.sql" "$prepared/database.sql"
  cmp "$SANDBOX/input.ndjson" "$prepared/database.ndjson"
  assert_equal "$(joomlaPlaygroundInspectPackage "$package" json | joomlaSiteJSON -er .archiveSha256)" "$digest"
  refute_command '^docker '
}

@test "native import refuses disagreements between the verified SQL and its statement stream on both engines" {
  write_playground_fixture "$package" mysql-values
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  cp "$prepared/database.ndjson" "$SANDBOX/native-statements"
  printf '%s\n' '"SELECT 123"' >> "$prepared/database.ndjson"
  run joomlaPlaygroundNativeImportStream "$prepared/database.sql" mysql
  assert_failure
  mv "$SANDBOX/native-statements" "$prepared/database.ndjson"
  printf '%s\n' 'SELECT 123;' >> "$prepared/database.sql"
  run joomlaPlaygroundNativeImportStream "$prepared/database.sql" mariadb
  assert_failure
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
  joomlaSiteJSON -e '.sourceUsername=="fixture-admin" and .explicitSource==false and .password=="private-fixture-password" and
    (.changed|all(.[]; .==false))' < "$prepared/account.json"
  parseCLI --non-interactive --site-name "Imported store" --admin-username owner --admin-user "Store owner" \
    --admin-email owner@example.test --admin-password 'a private edited password!' --db-name shopdata --memory-limit 768M
  run joomlaPlaygroundConfirmFreshSettings "$prepared"
  assert_success
  refute_output_contains private-fixture
  refute_output_contains 'a private edited password!'
  joomlaSiteJSON -e '.sourceUsername=="fixture-admin" and .sourceEmail=="private-fixture@example.test" and
    .email=="owner@example.test" and .username=="owner" and .changed.password and
    .changed.username and .changed.email and .changed.name' < "$prepared/account.json"
  if ! is_windows; then assert_equal "$(file_mode "$prepared/account.json")" 600; fi
}

@test "Playground deployments accept an explicit imported login independently of the final login" {
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  local -a deploy=(--non-interactive --type joomla --task playground --action deploy)
  parseCLI "${deploy[@]}" --target new --source-admin-username owner
  joomlaPlaygroundConfirmFreshSettings "$prepared"
  assert_equal "$VDM_J_USERNAME" owner
  joomlaSiteJSON -e '.sourceUsername=="owner" and .username=="owner" and .explicitSource and (.changed.username|not)' < "$prepared/account.json"

  local VDM_DB_NAME=shop VDM_DB_USER=shop VDM_DB_PASSWORD=private-old-db
  parseCLI "${deploy[@]}" --target current --source-admin-username owner --admin-username publisher
  joomlaPlaygroundConfirmReplaceSettings "$prepared"
  assert_equal "$VDM_J_USERNAME" publisher
  joomlaSiteJSON -e '.sourceUsername=="owner" and .username=="publisher" and .explicitSource and .changed.username' < "$prepared/account.json"
  run cliComplete '' --source-admin joomla playground
  assert_success
  assert_equal "$output" --source-admin-username
}

@test "source administrator selection requires a single-line login and a Playground deploy action" {
  local -a playground=(--non-interactive --type joomla --task playground)
  run parseCLI "${playground[@]}" --action inspect --source-admin-username owner
  assert_equal "$status" 17
  assert_output_contains 'Playground deployment'
  run parseCLI "${playground[@]}" --action deploy --source-admin-username $'owner\nsecond'
  assert_equal "$status" 17
  assert_output_contains 'single-line login'
  printf '%s\n' '{"type":"joomla","task":"playground","action":"deploy","options":{"source-admin-username":""}}' > "$SANDBOX/request.json"
  run parseCLI --input-json "$SANDBOX/request.json"
  assert_equal "$status" 17
  assert_output_contains 'single-line login'
  refute_command '^docker '
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
  run joomlaPlaygroundConfigureImport "$prepared" '' mariadbshop mysqli shopdb shopuser 'private-fixture-new-db' /var/www/html/store
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
    [ -f "$fixture_site_dir/docker-compose.yml" ] || return 32
    mkdir -p "$1/runtime"
    printf '%s\n' "$2" >> "$SANDBOX/provision"
    return "${fixture_provision_status:-0}"
  }
  enableContainer() {
    [ "$1" = joomla ] && [ -f "$fixture_site_dir/docker-compose.yml" ] || return 33
    printf '%s\n' "$VDM_CONTAINER" >> "$SANDBOX/started"
    mkdir -p "$VDM_REPO_PATH/joomla/enabled" && ln -s "$fixture_site_dir" "$VDM_REPO_PATH/joomla/enabled/$VDM_CONTAINER" || return 1
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
  run --separate-stderr fresh_command --enable false --source-admin-username owner
  assert_success
  joomlaSiteJSON -e '.success and .data.site=="shop.example.test" and .data.enabled==false and .data.target=="new"' <<< "$output"
  [[ "${stderr:-}$output" != *private-fixture* ]]
  cmp "$SANDBOX/prior.env" "$VDM_REPO_PATH/joomla/.env"
  local value
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_SITE_NAME value
  assert_equal "$value" "Fixture Shop"
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_ADMIN_PASSWORD value
  assert_equal "$value" private-fixture-password
  migrationReadEnvValue "$fixture_site_dir/.env" VDM_SHOP_JOOMLA_ADMIN_USERNAME value
  assert_equal "$value" owner
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
    --customize false --enable true --phpmyadmin false --mailcatcher false --php-settings false
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

@test "website seeding accepts stored Apache IDs, fresh numeric IDs and image defaults" {
  local work="$SANDBOX/import" token=1234567890abcdef1234567890abcdef
  mkdir -p "$work/website"
  # The seeding helper invokes this test-local Docker stub indirectly.
  # shellcheck disable=SC2317
  docker() {
    cat >/dev/null
    # The guest shell receives root, UID, GID, file bytes and import mode.
    printf '%s:%s\n' "${@: -4:1}" "${@: -3:1}"
  }
  local -a seed=(joomlaPlaygroundImportWebsite "$work/website" web image . 0 "$token" fresh)
  VDM_PUID='#1234' VDM_PGID='#5678' run "${seed[@]}"
  assert_success
  assert_equal "$output" '1234:5678'
  VDM_PUID=1234 VDM_PGID=5678 run "${seed[@]}"
  assert_success
  assert_equal "$output" '1234:5678'
  VDM_PUID='' VDM_PGID='' run "${seed[@]}"
  assert_success
  assert_equal "$output" ':'
}

@test "website replacement confines clearing, permissions and ownership to the selected nested root" {
  local mount="$SANDBOX/mount" incoming="$SANDBOX/incoming" token=1234567890abcdef1234567890abcdef
  mkdir -p "$mount/store/public" "$incoming"
  mount=$(cd "$mount" && pwd -P)
  printf 'previous' > "$mount/store/public/old-only"
  printf 'neighbour' > "$mount/store/private"
  printf 'new configuration' > "$incoming/configuration.php"
  if ! is_windows; then chmod 600 "$mount/store/private"; fi
  local VDM_PUID VDM_PGID
  VDM_PUID=$(id -u)
  VDM_PGID=$(id -g)
  docker() {
    # Execute the guest's real import commands against the disposable mount.
    while [ "$#" -gt 0 ] && [ "$1" != -ceu ]; do shift; done
    [ "$#" -ge 2 ] || return 1
    local script="$2"
    shift 2
    sh -ceu "${script/base=\/octojoom-joomla/base=\$OCTOJOOM_TEST_MOUNT}" "$@"
  }
  export OCTOJOOM_TEST_MOUNT="$mount"
  run joomlaPlaygroundImportWebsite "$incoming" web image store/public 0 "$token" replace
  assert_success
  refute_file_exists "$mount/store/public/old-only"
  assert_equal "$(cat "$mount/store/public/configuration.php")" 'new configuration'
  assert_equal "$(cat "$mount/store/private")" neighbour
  if ! is_windows; then
    assert_equal "$(file_mode "$mount/store/private")" 600
    ln -s store "$mount/alias"
    run joomlaPlaygroundImportWebsite "$incoming" web image alias/public 0 "$token" replace
    assert_failure
    assert_output_contains 'symbolic link'
    assert_equal "$(cat "$mount/store/public/configuration.php")" 'new configuration'
    assert_equal "$(cat "$mount/store/private")" neighbour
  fi
}

@test "fresh MySQL bootstrap provisions literal credentials without changing the final Compose model" {
  local work="$SANDBOX/import"
  mkdir "$work"
  cat > "$work/rendered.json" <<'JSON'
{"services":{"mysql":{"environment":{"MYSQL_DATABASE":"shop_data","MYSQL_USER":"shop","MYSQL_PASSWORD":"a'\\$$b","MYSQL_ROOT_PASSWORD":"root'credential","MYSQL_ROOT_HOST":"localhost"}}}}
JSON
  cp "$work/rendered.json" "$work/final.before"
  run joomlaPlaygroundDatabaseBootstrap "$work" mysql mysql
  assert_success
  [ -z "$output" ]
  cmp "$work/final.before" "$work/rendered.json"
  joomlaSiteJSON -e '.services.mysql | (.environment | keys)==["MYSQL_ROOT_HOST","MYSQL_ROOT_PASSWORD"] and
    (.environment.MYSQL_ROOT_PASSWORD | test("^[a-f0-9]{64}$")) and
    (.volumes | length==1) and .volumes[0].read_only' < "$work/bootstrap.json" >/dev/null
  local bootstrap_password
  IFS= read -r bootstrap_password < "$work/bootstrap-root"
  [[ "$bootstrap_password" =~ ^[a-f0-9]{64}$ ]]
  [ "$(joomlaSiteJSON -r .services.mysql.environment.MYSQL_ROOT_PASSWORD < "$work/bootstrap.json")" = "$bootstrap_password" ]
  assert_file_contains "$work/bootstrap-account.sql" "IDENTIFIED BY 'a''\\\$b'"
  assert_file_contains "$work/bootstrap-root.sql" "ALTER USER 'root'@'localhost'"
  refute_file_contains "$work/bootstrap-root.sql" "'root'@'%'"
}

@test "native database entrypoints retain their ordinary credential path" {
  local work="$SANDBOX/import"
  mkdir "$work"
  printf '%s\n' '{"services":{"db":{"environment":{"MYSQL_DATABASE":"shop","MYSQL_USER":"shop","MYSQL_PASSWORD":"simple"}}}}' > "$work/rendered.json"
  joomlaPlaygroundDatabaseBootstrap "$work" db mysql
  refute_file_exists "$work/bootstrap.json"
  joomlaSiteJSON '.services.db.environment.MYSQL_PASSWORD="a\u0027quote"' < "$work/rendered.json" > "$work/maria.json"
  mv "$work/maria.json" "$work/rendered.json"
  joomlaPlaygroundDatabaseBootstrap "$work" db mariadb
  refute_file_exists "$work/bootstrap.json"
}

# Exercise the shared step against each destination. Files and native clients
# are substituted here; the Docker fixture checks the resulting Joomla sites.
shared_import_standins() {
  joomlaPlaygroundPreparePackage "$package" "$prepared" >/dev/null
  parseCLI --non-interactive
  joomlaPlaygroundConfirmFreshSettings "$prepared"
  work="$prepared/runtime"
  mkdir "$work"
  printf '%s\n' 1234567890abcdef1234567890abcdef > "$work/token"
  VDM_DB_ENGINE=mariadb VDM_DB_HOST=db VDM_DB_DRIVER=mysqli VDM_DB_NAME=shop
  VDM_DB_USER=shop VDM_DB_PASSWORD=private-fixture-db
  if [ "${1:-fresh}" = replace ]; then
    cp "$prepared/site/configuration.php" "$work/existing.php"
    joomlaPlaygroundConfigureImport "$prepared" "$work/existing.php" "$VDM_DB_HOST" "$VDM_DB_DRIVER" \
      "$VDM_DB_NAME" "$VDM_DB_USER" "$VDM_DB_PASSWORD" /var/www/html
  fi
  joomlaDatabaseDiscoverClients() { :; }
  joomlaPlaygroundWaitDatabase() { :; }
  joomlaDatabaseTablesResolved() { printf '%s' "${fixture_tables:-}"; }
  joomlaPlaygroundImportWebsite() {
    assert_file_contains "$1/configuration.php" "public \$host = 'db';"
    printf 'files:%s\n' "$7" >> "$SANDBOX/import-order"
    return "${fixture_files_status:-0}"
  }
  joomlaDatabaseClient() {
    local sql
    sql=$(cat)
    if [ "$1" = query ]; then
      if [[ "$sql" == *information_schema.EVENTS* ]]; then
        printf '%s\n' "$sql" > "$SANDBOX/programs-query"
        # shellcheck disable=SC2016 # SQL identifier quoting.
        printf '%s\n' 'DROP EVENT IF EXISTS `old_job`;' 'DROP PROCEDURE IF EXISTS `old_task`;'
      else
        printf '%s\n' "$sql" > "$SANDBOX/reset-query"
        # shellcheck disable=SC2016 # SQL identifier quoting.
        printf '%s\n' 'DROP TABLE IF EXISTS `old_only`;'
      fi
    elif [[ "$sql" == *'SET FOREIGN_KEY_CHECKS=0;'* ]]; then
      printf 'clear\n' >> "$SANDBOX/import-order"
      printf '%s\n' "$sql" > "$SANDBOX/reset-statements"
      return "${fixture_clear_status:-0}"
    elif [[ "$sql" == *'DROP EVENT'* ]]; then
      printf 'programs\n' >> "$SANDBOX/import-order"
      printf '%s\n' "$sql" > "$SANDBOX/program-statements"
      return "${fixture_program_status:-0}"
    else
      printf 'sql\n' >> "$SANDBOX/import-order"
      return "${fixture_sql_status:-0}"
    fi
  }
  joomlaDatabaseCompose() {
    [[ "$*" == 'run --rm --no-deps -T --label traefik.enable=false --label com.octoleo.octojoom.playground=1234567890abcdef1234567890abcdef --entrypoint php '* ]] || return 91
    [ "$MSYS_NO_PATHCONV" = 1 ] && [ "$MSYS2_ARG_CONV_EXCL" = '*' ] || return 92
    printf '%s\n' "$@" > "$SANDBOX/account-args"
    printf '%s\n' "$VDM_DB_COMPOSE" "$VDM_DB_ENV" "$VDM_DB_PROJECT_DIR" > "$SANDBOX/account-context"
    cat >/dev/null
    printf 'account\n' >> "$SANDBOX/import-order"
  }
}

@test "both targets use the same files SQL and administrator import with only selected-database reset" {
  shared_import_standins
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount fresh
  assert_success
  assert_equal "$(cat "$SANDBOX/import-order")" $'files:fresh\nsql\naccount'
  refute_file_exists "$SANDBOX/reset-query"
  : > "$SANDBOX/import-order"
  joomlaPlaygroundConfigureImport() { return 93; }
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_success
  assert_equal "$(cat "$SANDBOX/import-order")" $'programs\nfiles:replace\nclear\nsql\naccount'
  assert_file_contains "$SANDBOX/programs-query" 'WHERE EVENT_SCHEMA=DATABASE()'
  assert_file_contains "$SANDBOX/programs-query" 'WHERE ROUTINE_SCHEMA=DATABASE()'
  assert_file_contains "$SANDBOX/reset-query" 'WHERE TABLE_SCHEMA=DATABASE()'
  assert_equal "$(cat "$SANDBOX/reset-statements")" $'SET SESSION sql_mode=\'NO_BACKSLASH_ESCAPES\';\nSET FOREIGN_KEY_CHECKS=0;\nDROP TABLE IF EXISTS `old_only`;\nSET FOREIGN_KEY_CHECKS=1;'
  assert_file_exists "$work/import-writing"
  assert_equal "$(cat "$work/import-stage")" administrator
  refute_command '^docker .* (up|create|start|restart|down)( |$)'
}

@test "replacement requires its prepared Joomla configuration before clearing data" {
  shared_import_standins replace
  rm "$prepared/site/configuration.php"
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_failure
  assert_output_contains 'prepared Joomla configuration'
  assert_equal "$(cat "$work/import-stage")" configuration
  refute_file_exists "$SANDBOX/import-order"
  refute_file_exists "$work/import-writing"
}

@test "shared fresh import refuses a populated database before changing its website files" {
  shared_import_standins
  fixture_tables=existing_table
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount fresh
  assert_failure
  assert_output_contains 'already contains tables'
  refute_file_exists "$SANDBOX/import-order"
  refute_file_exists "$work/import-writing"
}

@test "both targets run administrator updates as the website owner so Joomla caches remain writable" {
  shared_import_standins
  local mode owner VDM_PUID VDM_PGID
  for mode in fresh replace; do
    for owner in www-data:www-data 1234:5678 '#1234:#5678' 1234:www-data www-data:5678; do
      IFS=: read -r VDM_PUID VDM_PGID <<< "$owner"
      [ "$VDM_PUID" != www-data ] || VDM_PUID=''
      [ "$VDM_PGID" != www-data ] || VDM_PGID=''
      run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount "$mode"
      assert_success
      assert_equal "$(awk 'previous=="--user" {print; exit} {previous=$0}' "$SANDBOX/account-args")" "${owner//#/}"
    done
  done
}

@test "a failed selected-database reset or SQL import cannot reach administrator setup" {
  shared_import_standins replace
  fixture_clear_status=1
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_failure
  assert_equal "$(cat "$SANDBOX/import-order")" $'programs\nfiles:replace\nclear'
  assert_equal "$(cat "$work/import-stage")" database-clear
  : > "$SANDBOX/import-order"
  fixture_clear_status=0 fixture_sql_status=1
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_failure
  assert_output_contains 'database import failed'
  assert_equal "$(cat "$SANDBOX/import-order")" $'programs\nfiles:replace\nclear\nsql'
  assert_equal "$(cat "$work/import-stage")" database-import
}

@test "failed file copy cannot import SQL and removes only operation-owned helper containers" {
  shared_import_standins
  fixture_files_status=1
  docker() {
    case "$1 $2" in
      'ps -aq')
        [ "$3" = --filter ] && [ "$4" = label=com.octoleo.octojoom.playground=1234567890abcdef1234567890abcdef ] || return 94
        printf 'owned-helper\n';;
      'rm -f')
        [ "$3" = owned-helper ] || return 95
        printf '%s\n' "$3" >> "$SANDBOX/removed-helpers";;
      *) return 96;;
    esac
  }
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount fresh
  assert_failure
  assert_equal "$(cat "$SANDBOX/import-order")" files:fresh
  assert_equal "$(cat "$SANDBOX/removed-helpers")" owned-helper
  assert_equal "$(cat "$work/import-stage")" files
  assert_file_exists "$work/import-writing"
  refute_file_exists "$SANDBOX/account-args"
}

@test "a failed read-only schema inventory keeps replacement before its first write" {
  shared_import_standins replace
  joomlaDatabaseClient() {
    [ "$1" = query ] && cat > "$SANDBOX/inventory-query"
    return 1
  }
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_failure
  assert_file_contains "$SANDBOX/inventory-query" 'FROM information_schema.EVENTS'
  assert_equal "$(cat "$work/import-stage")" database-programs
  refute_file_exists "$work/import-writing"
  refute_file_exists "$SANDBOX/import-order"
}

@test "old schema program removal must succeed before website files are replaced" {
  shared_import_standins replace
  fixture_program_status=1
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_failure
  assert_equal "$(cat "$SANDBOX/import-order")" programs
  assert_equal "$(cat "$work/import-stage")" database-programs
  assert_file_exists "$work/import-writing"
  refute_file_exists "$SANDBOX/reset-query"
}

@test "replacement administrator uses the normal selected context and readable prepared PHP settings" {
  shared_import_standins replace
  joomlaPHPPatchIni '' "$work/candidate.ini" memory_limit 768M
  local VDM_PHP_INI_TARGET=/usr/local/etc/php/conf.d/zz-octojoom.ini
  local VDM_DB_COMPOSE="$work/candidate.yml" VDM_DB_ENV="$work/published.env" VDM_DB_PROJECT_DIR="$SANDBOX/selected-site"
  run joomlaPlaygroundImportPackage "$prepared" "$site" "$work" app /var/www/html image mount replace
  assert_success
  assert_file_contains "$SANDBOX/account-args" --volume
  assert_file_contains "$SANDBOX/account-args" "$(joomlaWebHostPath "$work/candidate.ini"):$VDM_PHP_INI_TARGET:ro"
  assert_file_contains "$work/candidate.ini" 'memory_limit = 768M'
  assert_equal "$(cat "$SANDBOX/account-context")" "$(joomlaWebHostPath "$VDM_DB_COMPOSE")"$'\n'"$(joomlaWebHostPath "$VDM_DB_ENV")"$'\n'"$(joomlaWebHostPath "$VDM_DB_PROJECT_DIR")"
  if ! is_windows; then assert_equal "$(file_mode "$work/candidate.ini")" 644; fi
}

@test "database reset retains literal identifier bytes and confines its SQL mode to the reset session" {
  local VDM_DB_ENGINE=mysql scope statements
  mkdir -p "$SANDBOX/reset"
  # Model the native client's --raw rows with names containing a backtick,
  # backslash and newline. The helper must not split, decode or shell-evaluate them.
  # shellcheck disable=SC2016 # SQL names are literal test data.
  printf 'DROP TABLE IF EXISTS `old``quote\\name\nnext`;\n' > "$SANDBOX/raw-identifiers"
  joomlaDatabaseClient() {
    if [ "$1" = query ]; then
      cat > "$SANDBOX/object-query"
      cat "$SANDBOX/raw-identifiers"
    else cat > "$SANDBOX/object-statements"; fi
  }
  for scope in programs tables; do
    run joomlaPlaygroundClearDatabase "$SANDBOX/reset" "$scope"
    assert_success
    statements=$(cat "$SANDBOX/object-statements")
    [[ "$statements" == "SET SESSION sql_mode='NO_BACKSLASH_ESCAPES';"$'\n'* ]]
    [[ "$statements" == *"$(cat "$SANDBOX/raw-identifiers")"* ]]
    assert_file_contains "$SANDBOX/object-query" 'DATABASE()'
    assert_file_contains "$SANDBOX/object-query" "REPLACE("
    refute_file_contains "$SANDBOX/object-statements" 'SET GLOBAL'
  done
}
