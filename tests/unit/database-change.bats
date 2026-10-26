#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  make_joomla_container alpha ALPHA alpha
  db_test_dir="$VDM_REPO_PATH/joomla/available/alpha.vdm.dev"
  db_test_compose="$db_test_dir/docker-compose.yml"
  work="$SANDBOX/database-change"
  mkdir -p "$work"
  cat > "$work/configuration.php" <<'PHP'
<?php
class JConfig {
    public $host = 'mariadbalpha:3306';
    public $dbtype = 'mysqli';
    public $db = 'alpha_db';
    public $user = 'alpha_user';
    public $password = 'secret';
    public $dbprefix = 'alpha_';
    public $sitename = 'Keep custom website settings';
}
PHP
  cp "$work/configuration.php" "$work/original.php"
  cp "$db_test_compose" "$work/original.yml"
}

stage_doubles() {
  readJoomlaSiteFacts() {
    VDM_SITE_DIR="$db_test_dir" VDM_SITE_COMPOSE="$db_test_compose" VDM_SITE_ENV="$VDM_REPO_PATH/joomla/.env"
    [ ! -f "$db_test_dir/.env" ] || VDM_SITE_ENV="$db_test_dir/.env"
    VDM_SITE_ENV_KEY=ALPHA VDM_SITE_KEY=alpha VDM_SITE_SERVICE=joomlaalpha VDM_SITE_IMAGE=joomla:5
  }
  joomlaDatabaseContext() {
    readJoomlaSiteFacts "$1"
    VDM_DB_SERVICE=mariadbalpha VDM_DB_ENGINE=mariadb VDM_DB_IMAGE=mariadb:10.11
    VDM_DB_NAME=alpha_db VDM_DB_USER=alpha_user VDM_DB_PASSWORD=secret VDM_DB_PREFIX=alpha_
    if [ -f "$db_test_dir/.env" ]; then migrationReadEnvValue "$db_test_dir/.env" VDM_ALPHA_DB_ENGINE VDM_DB_ENGINE || :; fi
  }
  joomlaDatabaseImageFacts() {
    VDM_DATABASE_IMAGE_VERSION=10.11.8 VDM_DATABASE_VOLUME_TARGET=/var/lib/mysql
    [ "$2" != postgres ] || { VDM_DATABASE_IMAGE_VERSION=18.0; VDM_DATABASE_VOLUME_TARGET=/var/lib/postgresql; }
  }
  joomlaDatabaseJoomlaCapability() {
    VDM_DATABASE_JOOMLA_DRIVER=mysqli VDM_DATABASE_INIT_SIMPLE_PG=false
    [ "$2" != postgres ] || VDM_DATABASE_JOOMLA_DRIVER=pgsql
    printf '%s\n' "$VDM_DATABASE_JOOMLA_DRIVER"
  }
  joomlaDatabaseInstalledCapability() { return 0; }
  migrationRunCompose() {
    if [[ "$*" == *'config --format json' ]]; then
      jq -n --arg source "${test_db_source:-$VDM_PROJECT_PATH/alpha/db}" --arg type "${test_db_type:-bind}" \
        '{services:{mariadbalpha:{volumes:[{type:$type,source:$source,target:"/var/lib/mysql"},{type:"bind",source:"/custom/tls",target:"/tls",read_only:true}]},joomlaalpha:{}}}'
    fi
  }
  joomlaSiteCompose() {
    [ "$2" != config ] || migrationRunCompose '' '' config --format json
  }
  siteValidateCompose() { [ -s "$1" ] && [ -s "$2" ]; }
}

transaction_doubles() {
  stage_doubles
  joomlaDatabaseRequirePrivateConfiguration() { return 0; }
  printf 'mariadbalpha\njoomlaalpha\nphpmyadminalpha\n' > "$work/running"
  : > "$work/events"
  joomlaDatabaseCopyConfiguration() { cp "$work/configuration.php" "$2"; }
  joomlaDatabaseWriteConfiguration() { cp "$2" "$work/configuration.php"; }
  joomlaSiteCompose() {
    local site="$1" action="$2" service
    shift 2
    printf '%s %s\n' "$action" "$*" >> "$work/events"
    case "$action" in
      config) migrationRunCompose '' '' config --format json;;
      ps) cat "$work/running";;
      stop)
        if [ "$#" -eq 0 ]; then : > "$work/running"; fi
        for service in "$@"; do
          grep -vxF "$service" "$work/running" > "$work/running.next" || :
          mv "$work/running.next" "$work/running"
        done;;
      up)
        [[ " $* " != *' --no-start '* ]] || return 0
        for service in "$@"; do
          case "$service" in mariadbalpha|joomlaalpha|phpmyadminalpha)
            grep -qxF "$service" "$work/running" || printf '%s\n' "$service" >> "$work/running";;
          esac
        done;;
    esac
  }
  joomlaDatabaseExport() {
    printf 'export\n' >> "$work/events"
    ! grep -qxF joomlaalpha "$work/running" || return 1
    [ ! -f "$work/export-fails" ] || return 1
    printf 'CREATE TABLE kept (id int);\n' > "$2"
  }
  joomlaDatabaseClient() {
    if [ "$1" = import ]; then
      printf 'import\n' >> "$work/events"
      [ ! -f "$work/import-fails" ] || return 1
      if [ "$VDM_DATABASE_STAGE_STORAGE_TYPE" = bind ]; then printf imported > "$VDM_DATABASE_STAGE_STORAGE/imported-data"; fi
    else cat >/dev/null; fi
  }
  joomlaDatabaseTablesResolved() { printf 'alpha_extensions\nkept\n'; }
  joomlaDatabaseRowCountsResolved() { printf '0\t10\n1\t4\n'; }
  joomlaDatabaseVerifyConnection() {
    printf 'verify\n' >> "$work/events"
    [ ! -f "$work/verify-fails" ]
  }
}

@test "configuration patch preserves custom settings and literal password characters" {
  password="literal'\\\$\`value"
  joomlaDatabasePatchConfiguration "$work/configuration.php" "$work/changed.php" mariadbalpha:5432 pgsql alpha_db alpha_user "$password" alpha_
  assert_file_contains "$work/changed.php" "public \$dbtype = 'pgsql';"
  assert_file_contains "$work/changed.php" "public \$password = 'literal\\'\\\\\$\`value';"
  assert_file_contains "$work/changed.php" "public \$sitename = 'Keep custom website settings';"
  cmp "$work/configuration.php" "$work/original.php"
}

@test "configuration patch refuses ambiguous or computed connection properties" {
  sed "s/public \$dbtype = 'mysqli';/public \$dbtype = getenv('DRIVER');/" "$work/configuration.php" > "$work/computed.php"
  run joomlaDatabasePatchConfiguration "$work/computed.php" "$work/changed.php" db mysqli name user secret prefix_
  assert_failure
  printf "    public \$host = 'second';\n" >> "$work/configuration.php"
  run joomlaDatabasePatchConfiguration "$work/configuration.php" "$work/changed.php" db mysqli name user secret prefix_
  assert_failure
}

@test "fresh storage stage preserves unrelated YAML and never reuses source datadir" {
  stage_doubles
  printf '    labels:\n      - "custom.database=keep"\n' > "$work/labels"
  joomlaSetServiceProperty "$db_test_compose" "$work/custom.yml" mariadbalpha labels "$work/labels"
  cp "$work/custom.yml" "$db_test_compose"
  joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:8.4 "$work/stage"
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'custom.database=keep'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" '"source":"/custom/tls","target":"/tls","read_only":true'
  refute_file_contains "$VDM_DATABASE_STAGE_COMPOSE" "\"source\":\"$VDM_PROJECT_PATH/alpha/db\""
  assert_equal "$VDM_DATABASE_STAGE_STORAGE_TYPE" bind
  assert_equal "$VDM_DATABASE_STAGE_STORAGE_ORIGINAL" "$VDM_PROJECT_PATH/alpha/db"
  assert_file_contains "$work/stage/final-volumes" '${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql'
  [[ "$VDM_DATABASE_STAGE_STORAGE" == "$VDM_PROJECT_PATH/"* ]]
  [[ "$VDM_DATABASE_STAGE_STORAGE" != "$VDM_PROJECT_PATH/alpha/"* ]]
  [ -d "$VDM_DATABASE_STAGE_STORAGE" ]
  refute_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'type":"volume'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'MYSQL_PASSWORD=${VDM_ALPHA_DB_PASS}'
  assert_file_contains "$VDM_DATABASE_STAGE_ENV" 'VDM_ALPHA_DB_ENGINE=mysql'
  assert_equal "$(joomlaServiceBlock "$db_test_compose" phpmyadminalpha)" "$(joomlaServiceBlock "$VDM_DATABASE_STAGE_COMPOSE" phpmyadminalpha)"
  refute_file_contains "$STUB_DIR/commands.log" 'volume create'
}

@test "PostgreSQL stage uses measured data target and parks mysql-only viewer" {
  stage_doubles
  joomlaDatabaseStageStorage alpha.vdm.dev postgres postgres:18 "$work/stage"
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" '"target":"/var/lib/postgresql"'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'POSTGRES_PASSWORD=${VDM_ALPHA_DB_PASS}'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'JOOMLA_DB_HOST=mariadbalpha:5432'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'JOOMLA_DB_TYPE=pgsql'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'pg_isready -U \"$$POSTGRES_USER\" -d \"$$POSTGRES_DB\"'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" 'octojoom-mysql-viewer-disabled'
  assert_file_contains "$VDM_DATABASE_STAGE_ENV" 'VDM_ALPHA_DB_ROOT="rootsecret"'
}

@test "cross-family conversion is refused before source mutation" {
  transaction_doubles
  run joomlaDatabaseChange alpha.vdm.dev postgres postgres:18 preserve
  assert_failure
  assert_output_contains 'conversion is unsupported'
  [ ! -s "$work/events" ]
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
}

@test "failed logical export restores prior running services without publishing" {
  transaction_doubles
  touch "$work/export-fails"
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_failure
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
  [ ! -e "$db_test_dir/.env" ]
  assert_file_contains "$work/running" joomlaalpha
  assert_file_contains "$work/running" mariadbalpha
  refute_file_contains "$work/events" import
  [ ! -d "$db_test_dir/.octojoom-change.lock" ]
}

@test "failed target import restores original Compose credentials config and running state" {
  transaction_doubles
  touch "$work/import-fails"
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_failure
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
  [ ! -e "$db_test_dir/.env" ]
  assert_file_contains "$work/running" joomlaalpha
  assert_file_contains "$work/running" mariadbalpha
  assert_file_contains "$work/events" import
  refute_file_contains "$STUB_DIR/commands.log" 'volume rm'
}

@test "preserve performs consistent export imports verifies and retains old storage" {
  transaction_doubles
  printf retained > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_success
  assert_output_contains 'alpha.vdm.dev'
  assert_file_contains "$db_test_dir/.env" 'VDM_ALPHA_DB_ENGINE=mysql'
  assert_file_contains "$work/events" import
  assert_file_contains "$work/events" verify
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/imported-data")" imported
  [ ! -e "$VDM_PROJECT_PATH/alpha/db/sentinel" ]
  recovery=$(find "$VDM_PROJECT_PATH" -path '*/original/sentinel' -print)
  [ -n "$recovery" ]
  assert_equal "$(cat "$recovery")" retained
  assert_file_contains "$db_test_compose" '${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql'
  refute_file_contains "$db_test_compose" 'type":"volume'
  assert_file_contains "$work/running" joomlaalpha
  assert_file_contains "$work/running" phpmyadminalpha
}

@test "successful stopped-site change restores stopped state" {
  transaction_doubles
  : > "$work/running"
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_success
  [ ! -s "$work/running" ]
}

@test "fresh target does not import content and explicitly keeps website stopped" {
  transaction_doubles
  run joomlaDatabaseChange alpha.vdm.dev postgres postgres:18 fresh
  assert_success
  assert_output_contains 'target database is empty'
  refute_file_contains "$work/events" export
  refute_file_contains "$work/events" import
  refute_file_contains "$work/running" joomlaalpha
  refute_file_contains "$work/running" phpmyadminalpha
  assert_file_contains "$work/configuration.php" "public \$dbtype = 'pgsql';"
}

@test "missing explicit outcome and confirmation fail before source inspection" {
  VDM_CONTAINER=alpha.vdm.dev VDM_DB_ENGINE=mysql VDM_DB_IMAGE=mysql:8.4 OCTOJOOM_NON_INTERACTIVE=true
  run joomlaDatabaseChangeAction
  assert_failure
  assert_output_contains '--data-mode'
  refute_file_contains "$STUB_DIR/commands.log" 'docker'
}

@test "clone destination collision fails before backup or mutation" {
  VDM_CONTAINER=source.vdm.dev VDM_DB_ENGINE=mysql VDM_DB_IMAGE=mysql:8.4 VDM_DATA_MODE=clone VDM_CONFIRM=true
  VDM_KEY=alpha VDM_SUBDOMAIN=alpha VDM_DOMAIN=vdm.dev OCTOJOOM_NON_INTERACTIVE=true
  run joomlaDatabaseChangeAction
  assert_failure
  assert_output_contains 'destination already exists'
  refute_file_contains "$STUB_DIR/commands.log" 'docker'
}

@test "Joomla verification failure returns to the original database storage" {
  transaction_doubles
  touch "$work/verify-fails"
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_failure
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
  [ ! -e "$db_test_dir/.env" ]
  assert_file_contains "$work/events" verify
  assert_file_contains "$work/running" joomlaalpha
}

@test "database changes refuse custom engine command before source mutation" {
  stage_doubles
  printf '    command: ["mysqld", "--custom-native-option"]\n' > "$work/command"
  joomlaSetServiceProperty "$db_test_compose" "$work/custom.yml" mariadbalpha command "$work/command"
  cp "$work/custom.yml" "$db_test_compose"
  run joomlaDatabaseStageStorage alpha.vdm.dev postgres postgres:18 "$work/stage"
  assert_failure
  assert_output_contains 'custom database command'
  [ ! -e "$work/stage" ]
}

@test "engine change honors complete-backup request under the existing lock" {
  transaction_doubles
  joomlaBackupCreate() {
    [ "$6" = true ] && [ -d "$db_test_dir/.octojoom-change.lock" ] || return 1
    printf 'backup\n' >> "$work/events"
  }
  VDM_PRE_BACKUP=true
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_success
  backup_line=$(grep -n '^backup$' "$work/events" | cut -d: -f1)
  stop_line=$(grep -n '^stop ' "$work/events" | head -n1 | cut -d: -f1)
  [ "$backup_line" -lt "$stop_line" ]
}

@test "independent clone passes explicit identity to logical restore and changes only clone" {
  stage_doubles
  clone_events="$work/clone-events"
  joomlaBackupCreate() { printf 'backup:%s\n' "$1" > "$clone_events"; }
  joomlaBackupRestoreNew() { printf 'restore:%s:%s\n' "$2" "$3" >> "$clone_events"; }
  joomlaDatabaseChange() { printf 'change:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" >> "$clone_events"; }
  VDM_CONTAINER=alpha.vdm.dev VDM_DB_ENGINE=mysql VDM_DB_IMAGE=mysql:8.4 VDM_DATA_MODE=clone VDM_CONFIRM=true
  VDM_KEY=preview VDM_SUBDOMAIN=preview VDM_DOMAIN=example.test OCTOJOOM_NON_INTERACTIVE=true
  run joomlaDatabaseChangeAction
  assert_success
  assert_file_contains "$work/clone-events" 'backup:alpha.vdm.dev'
  assert_file_contains "$work/clone-events" 'restore:preview.example.test:preview'
  assert_file_contains "$work/clone-events" 'change:preview.example.test:mysql:mysql:8.4:preserve'
  cmp "$db_test_compose" "$work/original.yml"
}

@test "row count mismatch rolls back even when native import succeeded" {
  transaction_doubles
  joomlaDatabaseRowCountsResolved() {
    if grep -q import "$work/events"; then printf '0\t10\n1\t3\n'; else printf '0\t10\n1\t4\n'; fi
  }
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:8.4 preserve
  assert_failure
  assert_output_contains 'row counts differ'
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
  assert_file_contains "$work/running" joomlaalpha
}

@test "shared website configuration refuses database repointing for the selected site" {
  make_joomla_container beta BETA beta
  readJoomlaSiteFacts() {
    VDM_SITE_MOUNT_TYPE=bind VDM_SITE_MOUNT_SOURCE="$work"
    VDM_SITE_MOUNT_TARGET=/var/www/html VDM_SITE_DOCROOT=/var/www/html VDM_SITE_HOST_PATH="$work"
  }
  run joomlaDatabaseRequirePrivateConfiguration alpha.vdm.dev
  assert_failure
  assert_output_contains 'shares configuration.php with beta.vdm.dev'
  cmp "$work/configuration.php" "$work/original.php"
}

@test "explicit named database storage stays named without moving project folders" {
  stage_doubles
  test_db_type=volume test_db_source=alpha_db
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  assert_equal "$VDM_DATABASE_STAGE_STORAGE_TYPE" volume
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" '"type":"volume"'
  assert_file_contains "$VDM_DATABASE_STAGE_COMPOSE" "name: $VDM_DATABASE_STAGE_STORAGE"
  cp "$VDM_DATABASE_STAGE_COMPOSE" "$work/named.yml"
  joomlaDatabasePublishStorage "$work/stage" "$work/named.yml"
  joomlaDatabaseRollbackStorage "$work/stage"
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/sentinel")" original
  cmp "$VDM_DATABASE_STAGE_COMPOSE" "$work/named.yml"
}

@test "post-publication verification failure restores original directory and retains candidate data" {
  transaction_doubles
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaDatabaseVerifyConnection() {
    # Before publication the candidate path exists; after the directory swap
    # this failure exercises rollback of real filesystem state, not just YAML.
    [ -d "$VDM_DATABASE_STAGE_STORAGE" ]
  }
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:target preserve
  assert_failure
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/sentinel")" original
  [ ! -e "$VDM_PROJECT_PATH/alpha/db/imported-data" ]
  retained=$(find "$VDM_PROJECT_PATH" -path '*/candidate/imported-data' -print)
  [ -n "$retained" ]
  assert_equal "$(cat "$retained")" imported
  cmp "$db_test_compose" "$work/original.yml"
  cmp "$work/configuration.php" "$work/original.php"
  assert_file_contains "$work/running" joomlaalpha
}

@test "interruption between directory moves is recoverable without deleting either dataset" {
  stage_doubles
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  printf candidate > "$VDM_DATABASE_STAGE_STORAGE/sentinel"
  # This is the actual state after the first publication rename, before the
  # second. Recovery must not depend on a later marker having been written.
  mv "$VDM_DATABASE_STAGE_STORAGE_ORIGINAL" "$VDM_DATABASE_STAGE_STORAGE_RECOVERY"
  joomlaDatabaseRollbackStorage "$work/stage"
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/sentinel")" original
  assert_equal "$(cat "$VDM_DATABASE_STAGE_STORAGE/sentinel")" candidate
  [ ! -e "$VDM_DATABASE_STAGE_STORAGE_RECOVERY" ]
}

@test "live database mounts prevent publication before any directory moves" {
  stage_doubles
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  printf candidate > "$VDM_DATABASE_STAGE_STORAGE/sentinel"
  docker() {
    case "$1" in
      ps) printf 'running-database\n';;
      inspect) jq -n --arg source "$VDM_DATABASE_STAGE_STORAGE" '[{Mounts:[{Type:"bind",Source:$source}]}]';;
      *) return 1;;
    esac
  }
  run joomlaDatabasePublishStorage "$work/stage" "$db_test_compose"
  assert_failure
  assert_output_contains 'still mounted by a running container'
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/sentinel")" original
  assert_equal "$(cat "$VDM_DATABASE_STAGE_STORAGE/sentinel")" candidate
  [ ! -e "$VDM_DATABASE_STAGE_STORAGE_RECOVERY" ]
}

@test "failed storage rollback does not restart an uncertain deployment" {
  transaction_doubles
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaDatabaseVerifyConnection() { [ -d "$VDM_DATABASE_STAGE_STORAGE" ]; }
  joomlaDatabaseRollbackStorage() { return 1; }
  run joomlaDatabaseChange alpha.vdm.dev mysql mysql:target preserve
  assert_failure
  assert_output_contains 'Automatic recovery is incomplete'
  [ ! -s "$work/running" ]
  retained=$(find "$VDM_PROJECT_PATH" -path '*/original/sentinel' -print)
  [ -n "$retained" ]
  assert_equal "$(cat "$retained")" original
}

@test "a stopped configured website sharing the database folder prevents staging" {
  stage_doubles
  make_joomla_container beta BETA beta
  printf original > "$VDM_PROJECT_PATH/alpha/db/sentinel"
  joomlaSiteCompose() {
    [ "$2" = config ] || return 1
    jq -n --arg source "$VDM_PROJECT_PATH/alpha/db" \
      '{services:{db:{volumes:[{type:"bind",source:$source,target:"/var/lib/mysql"}]}}}'
  }
  run joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  assert_failure
  assert_output_contains 'shared or overlaps'
  [ ! -e "$work/stage" ]
  assert_equal "$(cat "$VDM_PROJECT_PATH/alpha/db/sentinel")" original
  cmp "$db_test_compose" "$work/original.yml"
}

@test "a stopped configured parent mount prevents database directory replacement" {
  stage_doubles
  make_joomla_container beta BETA beta
  joomlaSiteCompose() {
    [ "$2" = config ] || return 1
    local source="$VDM_PROJECT_PATH/alpha/db"
    [ "$1" != beta.vdm.dev ] || source="$VDM_PROJECT_PATH/alpha"
    jq -n --arg source "$source" \
      '{services:{db:{volumes:[{type:"bind",source:$source,target:"/var/lib/mysql"}]}}}'
  }
  run joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  assert_failure
  assert_output_contains 'shared or overlaps'
  [ ! -e "$work/stage" ]
}

@test "a stopped configured symlink alias prevents database directory replacement" {
  stage_doubles
  make_joomla_container beta BETA beta
  ln -s "$VDM_PROJECT_PATH/alpha" "$work/alias"
  joomlaSiteCompose() {
    [ "$2" = config ] || return 1
    local source="$VDM_PROJECT_PATH/alpha/db"
    [ "$1" != beta.vdm.dev ] || source="$work/alias/db"
    jq -n --arg source "$source" \
      '{services:{db:{volumes:[{type:"bind",source:$source,target:"/var/lib/mysql"}]}}}'
  }
  run joomlaDatabaseStageStorage alpha.vdm.dev mysql mysql:target "$work/stage"
  assert_failure
  assert_output_contains 'shared or overlaps'
  [ ! -e "$work/stage" ]
}
