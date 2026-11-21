#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  TX_SITE=shop.example.test
  TX_DIR="$VDM_REPO_PATH/joomla/available/$TX_SITE"
  TX_PROJECT="$VDM_PROJECT_PATH/shop"
  TX_PACKAGE="$SANDBOX/prepared"
  TX_EVENTS="$SANDBOX/events"
  TX_ENV="$VDM_REPO_PATH/joomla/.env"
  TX_FAULT=''
  export TMPDIR="$SANDBOX"
  TX_WEB=127.0.0.1
  mkdir "$TX_PACKAGE"
  make_joomla_container shop SHOP shop example.test
  VDM_SITE_ENV_KEY=SHOP
  printf 'original web' > "$TX_PROJECT/joomla/content"
  printf 'old-only file' > "$TX_PROJECT/joomla/old-only"
  printf 'original database' > "$TX_PROJECT/db/content"
  printf 'other database' > "$TX_PROJECT/db/other"
  printf 'original ini' > "$TX_PROJECT/php.ini"
  printf 'untouched' > "$TX_PROJECT/adjacent-file"
  printf 'app\ndb\n' > "$SANDBOX/running"
  cp "$TX_DIR/docker-compose.yml" "$SANDBOX/original.yml"
  cp "$TX_ENV" "$SANDBOX/shared.env"
  : > "$TX_EVENTS"

  local web_path="$TX_PROJECT/joomla" db_path="$TX_PROJECT/db"
  if is_windows; then web_path=$(cygpath -am "$web_path"); db_path=$(cygpath -am "$db_path"); fi
  joomlaSiteJSON -n --arg web "$web_path" --arg db "$db_path" '{
    name:"shop",services:{
      app:{image:"joomla:6",volumes:[{type:"bind",source:$web,target:"/var/www/html"}]},
      db:{image:"mariadb:lts",volumes:[{type:"bind",source:$db,target:"/var/lib/mysql"}]},
      helper:{image:"helper"}}}' > "$SANDBOX/model.json"

  joomlaDatabaseContext() {
    VDM_DB_SITE="$TX_SITE" VDM_DB_SERVICE=db VDM_DB_NAME=shop_db VDM_DB_USER=shop_user
    VDM_DB_PASSWORD=existing-password VDM_DB_ENGINE=mariadb VDM_DB_DRIVER=mysqli VDM_DB_INSTALLED=true
    VDM_SITE_SERVICE=app VDM_SITE_DOCROOT=/var/www/html VDM_SITE_ENV_KEY=SHOP VDM_SITE_KEY=shop
    VDM_SITE_IMAGE=joomla:6 VDM_SITE_WEBSERVER=apache VDM_DB_HOST=db
    return 0
  }
  joomlaStorageComposeModel() { cat "$SANDBOX/model.json"; }
  joomlaPlaygroundConfirmReplaceSettings() { return 0; }
  joomlaPlaygroundConfigureImport() { return 0; }
  joomlaDatabaseCopyConfiguration() { cp "$TX_PROJECT/joomla/content" "$2"; }
  joomlaPHPIniDestination() { printf '%s\n' "${TX_INI_DESTINATION:-$TX_PROJECT/php.ini}"; }
  joomlaPHPValidateIni() { return 0; }
  joomlaPHPReplaceMount() { return 0; }
  joomlaPlaygroundPlanReplacement() {
    local work="$3" ini_source
    [ "$TX_FAULT" != plan ] || return 1
    ini_source=$(joomlaWebHostPath "${TX_INI_SOURCE:-$TX_PROJECT/php.ini}") || return 1
    joomlaSiteJSON --arg ini "$ini_source" --arg web "$TX_WEB" '
      if $web=="nginx" then .services.nginx={image:"nginx",volumes:[.services.app.volumes[] | .read_only=true]} else . end |
      .services.app.volumes |= (map(select(.target!="/usr/local/etc/php/conf.d/zz-octojoom.ini")) +
        [{type:"bind",source:$ini,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini",read_only:true}])' \
      < "$SANDBOX/model.json" > "$work/original-model.json" || return 1
    cp "$work/original-model.json" "$SANDBOX/model.json" && cp "$work/original-model.json" "$work/rendered.json" &&
      cp "$work/original-model.json" "$work/proposed.json" || return 1
    joomlaSiteJSON -nc --arg web "$TX_WEB" '{project:"shop",app:"app",db:"db",web:$web,
      root:"/var/www/html",ini:"/usr/local/etc/php/conf.d/zz-octojoom.ini",engine:"mariadb",image:"joomla:6",driver:"mysqli"}' > "$work/services.json"
    cp "$SANDBOX/original.yml" "$work/candidate.yml" && echo '# imported runtime' >> "$work/candidate.yml" || return 1
    cp "$work/candidate.yml" "$work/with-env.yml" || return 1
    printf 'VDM_SHOP_JOOMLA_SITE_NAME="Imported shop"\n' > "$work/candidate.env"
    VDM_SITE_SERVICE=app VDM_PHP_INI_TARGET=/usr/local/etc/php/conf.d/zz-octojoom.ini \
      joomlaPlaygroundReplacementIni "$2" "$work" joomla:6 "${4:-}" || return 1
    printf '\n; imported PHP settings\n' >> "$work/candidate.ini"
  }
  joomlaPlaygroundImportPackage() {
    local work="$3"
    [ "$1" = "$TX_PACKAGE" ] && [ "$2" = "$TX_SITE" ] && [ "$4" = app ] &&
      [ "$5" = /var/www/html ] && [ "$6" = joomla:6 ] && [ "$8" = replace ] || return 91
    printf 'configuration\n' > "$work/import-stage"
    [ "$TX_FAULT" != before-write ] || return 1
    : > "$work/import-writing"
    printf 'import\n' >> "$TX_EVENTS"
    printf 'files\n' > "$work/import-stage"
    rm -f -- "$TX_PROJECT/joomla/old-only" || return 1
    printf 'imported web' > "$TX_PROJECT/joomla/content"
    printf 'database-import\n' > "$work/import-stage"
    printf 'imported database' > "$TX_PROJECT/db/content"
    if [ "$TX_FAULT" = helper-cleanup ]; then
      : > "$work/import-cleanup-failed"
      return 1
    fi
    [ "$TX_FAULT" != import ]
  }
  joomlaPlaygroundWaitDatabase() { printf 'database-ready\n' >> "$TX_EVENTS"; [ "$TX_FAULT" != database ]; }
  joomlaPlaygroundOriginalCompose() { shift 3; joomlaSiteCompose "$TX_SITE" "$@"; }
  joomlaSiteCompose() {
    [ "$1" = "$TX_SITE" ] || return 1
    shift
    printf 'compose %s\n' "$*" >> "$TX_EVENTS"
    case "$1" in
      ps)
        case "$*" in
          'ps -aq app'|'ps -aq db') return 0;;
          'ps --status running --services') cat "$SANDBOX/running";;
          'ps --all --services') printf 'app\ndb\nhelper\n'; [ "$TX_WEB" = 127.0.0.1 ] || printf '%s\n' "$TX_WEB";;
          *) return 92;;
        esac;;
      config) cat "$SANDBOX/model.json";;
      stop)
        shift
        if [ "$#" -eq 0 ]; then : > "$SANDBOX/running"
        else
          local service
          for service in "$@"; do
            awk -v service="$service" '$0!=service' "$SANDBOX/running" > "$SANDBOX/running.next"
            mv "$SANDBOX/running.next" "$SANDBOX/running"
          done
        fi;;
      up|start)
        local service
        for service in "$@"; do
          case "$service" in app|db|helper|nginx)
            grep -Fxq "$service" "$SANDBOX/running" || printf '%s\n' "$service" >> "$SANDBOX/running";;
          esac
        done
        if [ "$TX_FAULT" = resume ] && [[ " $* " == *' app '* ]]; then return 1; fi;;
      *) return 92;;
    esac
  }
  docker() {
    case "$*" in
      'ps -aq'|'ps --quiet'|'ps -aq --filter label=com.docker.compose.project=shop') return 0;;
      *) return 92;;
    esac
  }
  joomlaPersistenceCheckShared() { return 0; }
  joomlaBackupCreateAction() {
    [ "$1" = "$TX_SITE" ] && [ "$3" = full ] && [ "$6" = true ] || return 1
    [ "$(cat "$TX_PROJECT/joomla/content")" = 'original web' ] &&
      [ "$(cat "$TX_PROJECT/db/content")" = 'original database' ] || return 1
    printf 'verified full backup fixture\n' > "$2" || return 1
    printf 'backup-created\n' >> "$TX_EVENTS"
  }
  joomlaBackupVerifyAction() {
    [ -f "$1" ] || return 1
    printf 'backup-verified\n' >> "$TX_EVENTS"
    if [ "$TX_FAULT" = env-edit ]; then printf 'VDM_OTHER_NOTE="operator edit"\n' >> "$TX_ENV"; fi
    if [ "$TX_FAULT" = ini-edit ]; then printf 'operator ini edit' > "$TX_PROJECT/php.ini"; fi
    [ "$TX_FAULT" != backup ]
  }
  VDM_DEFAULT_BACKUP_PATH="$SANDBOX/backups"
  mkdir -p "$VDM_DEFAULT_BACKUP_PATH"
  OCTOJOOM_NON_INTERACTIVE=true
}

assert_import_cleaned() {
  [ ! -e "$TX_DIR/.octojoom-change.lock" ]
  [ ! -e "${TX_ENV}.octojoom-change.lock" ]
  assert_equal "$(find "$TX_DIR" -maxdepth 1 -name '.playground-*' -print)" ''
  assert_equal "$(find "$TX_PROJECT" -name '.octojoom-*' -print)" ''
}

assert_old_data() {
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'original web'
  assert_equal "$(cat "$TX_PROJECT/db/content")" 'original database'
  assert_file_exists "$TX_PROJECT/joomla/old-only"
  assert_equal "$(cat "$TX_PROJECT/db/other")" 'other database'
}

assert_imported_data() {
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'imported web'
  assert_equal "$(cat "$TX_PROJECT/db/content")" 'imported database'
  refute_file_exists "$TX_PROJECT/joomla/old-only"
  assert_equal "$(cat "$TX_PROJECT/db/other")" 'other database'
  assert_equal "$(cat "$TX_PROJECT/adjacent-file")" untouched
}

@test "replacement verifies the normal full backup before in-place writes and resumes existing services" {
  link_enabled joomla "$TX_SITE"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_success
  assert_equal "$(awk '/^(backup-created|backup-verified|import)$/' "$TX_EVENTS")" $'backup-created\nbackup-verified\nimport'
  local archive
  archive=$(joomlaSiteJSON -er '.backup' < "$TX_PACKAGE/result.json")
  assert_file_exists "$archive"
  joomlaSiteJSON -e '.status=="deployed" and .target=="current" and .destructive_started and
    .running==true and .enabled=="enabled"' < "$TX_PACKAGE/result.json"
  assert_imported_data
  assert_file_contains "$TX_ENV" 'Imported shop'
  refute_file_exists "$TX_DIR/.env"
  assert_import_cleaned
}

@test "replacement backup opt-out creates no archive or old data copy" {
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_imported_data
  assert_equal "$(find "$VDM_DEFAULT_BACKUP_PATH" -mindepth 1 -print)" ''
  refute_file_contains "$TX_EVENTS" backup-created
  joomlaSiteJSON -e '.status=="deployed" and .destructive_started and .backup==null' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "an unverified backup stops before writes and resumes the previous running services" {
  TX_FAULT=backup
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  refute_file_contains "$TX_EVENTS" import
  assert_old_data
  cmp "$TX_ENV" "$SANDBOX/shared.env"
  joomlaSiteJSON -e '.status=="failed" and .stage=="backup" and .destructive_started==false and
    .backup==null and .running==true' < "$TX_PACKAGE/result.json"
  assert_file_contains "$SANDBOX/running" app
  assert_import_cleaned
}

@test "a failed import leaves partial data and writers stopped with an explicit failed receipt" {
  TX_FAULT=import
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_imported_data
  refute_file_contains "$SANDBOX/running" app
  joomlaSiteJSON -e '.status=="failed" and .destructive_started and .stage=="database-import" and
    .running==false and .backup==null and (.reason|length)>0' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "unconfirmed import helper cleanup retains the site lock and blocks another writer" {
  TX_FAULT=helper-cleanup
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_imported_data
  refute_file_contains "$SANDBOX/running" app
  joomlaSiteJSON -e --arg lock "$TX_DIR/.octojoom-change.lock" '
    .status=="failed" and .destructive_started and .running==null and .backup==null and
    (.reason|contains("com.octoleo.octojoom.playground=")) and (.reason|contains($lock))' < "$TX_PACKAGE/result.json"
  [ -d "$TX_DIR/.octojoom-change.lock" ]
  [ ! -e "${TX_ENV}.octojoom-change.lock" ]
  assert_equal "$(find "$SANDBOX" -maxdepth 1 -name 'octojoom-import.*' -print)" ''
  : > "$TX_EVENTS"
  TX_FAULT=''
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_output_contains 'Another operation is changing this website.'
  [ ! -s "$TX_EVENTS" ]
  assert_imported_data
}

@test "a failed write reports the verified backup and does not invent automatic restoration" {
  TX_FAULT=import
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  assert_imported_data
  refute_file_contains "$SANDBOX/running" app
  local archive
  archive=$(joomlaSiteJSON -er '.backup' < "$TX_PACKAGE/result.json")
  assert_file_exists "$archive"
  joomlaSiteJSON -e '.status=="failed" and .destructive_started and .running==false' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "an importer failure before its first write resumes the original site" {
  TX_FAULT=before-write
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_old_data
  assert_file_contains "$SANDBOX/running" app
  joomlaSiteJSON -e '.status=="failed" and .destructive_started==false and .running==true' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "replacement starts only the import database for a stopped site and stops it again" {
  : > "$SANDBOX/running"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_imported_data
  [ ! -s "$SANDBOX/running" ]
  joomlaSiteJSON -e '.status=="deployed" and .running==false and .enabled=="disabled"' < "$TX_PACKAGE/result.json"
  refute_file_contains "$TX_EVENTS" 'up -d --no-deps app'
  assert_import_cleaned
}

@test "a partially running FPM site resumes only its original services" {
  TX_WEB=nginx
  printf 'app\ndb\nhelper\n' > "$SANDBOX/running"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_file_contains "$SANDBOX/running" app
  assert_file_contains "$SANDBOX/running" helper
  refute_file_contains "$SANDBOX/running" nginx
  joomlaSiteJSON -e '.status=="deployed" and .running==false' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "a startup failure after import stops writers and retains the imported data" {
  TX_FAULT=resume
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_imported_data
  refute_file_contains "$SANDBOX/running" app
  joomlaSiteJSON -e '.status=="failed" and .destructive_started and .running==false' < "$TX_PACKAGE/result.json"
  assert_import_cleaned
}

@test "shared environment publication preserves neighboring settings comments and file mode" {
  printf '# Neighbor comment\nVDM_OTHER_DB_PASS="neighbor-only"\n' >> "$TX_ENV"
  if ! is_windows; then chmod 640 "$TX_ENV"; fi
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  refute_file_exists "$TX_DIR/.env"
  assert_file_contains "$TX_ENV" '# Neighbor comment'
  assert_file_contains "$TX_ENV" 'VDM_OTHER_DB_PASS="neighbor-only"'
  assert_file_contains "$TX_ENV" 'Imported shop'
  if ! is_windows; then assert_equal "$(file_mode "$TX_ENV")" 640; fi
  assert_import_cleaned
}

@test "a private environment and copied enabled registration retain their own file modes" {
  TX_ENV="$TX_DIR/.env"
  cp "$SANDBOX/shared.env" "$TX_ENV"
  if ! is_windows; then chmod 640 "$TX_ENV"; fi
  local mirror="$VDM_REPO_PATH/joomla/enabled/$TX_SITE"
  mkdir -p "$mirror"
  cp "$TX_DIR/docker-compose.yml" "$mirror/docker-compose.yml"
  cp "$TX_ENV" "$mirror/.env"
  if ! is_windows; then chmod 600 "$mirror/.env"; fi
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_file_contains "$TX_ENV" 'Imported shop'
  assert_file_contains "$mirror/.env" 'Imported shop'
  cmp "$mirror/docker-compose.yml" "$TX_DIR/docker-compose.yml"
  cmp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/shared.env"
  if ! is_windows; then
    assert_equal "$(file_mode "$TX_ENV")" 640
    assert_equal "$(file_mode "$mirror/.env")" 600
  fi
  assert_import_cleaned
}

@test "an environment edit during backup is preserved and prevents writes" {
  TX_FAULT=env-edit
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  assert_old_data
  assert_file_contains "$TX_ENV" 'operator edit'
  refute_file_contains "$TX_EVENTS" import
  assert_file_contains "$SANDBOX/running" app
  assert_import_cleaned
}

@test "a PHP override edited during backup is preserved and prevents writes" {
  TX_FAULT=ini-edit
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  assert_old_data
  assert_equal "$(cat "$TX_PROJECT/php.ini")" 'operator ini edit'
  refute_file_contains "$TX_EVENTS" import
  assert_file_contains "$SANDBOX/running" app
  assert_import_cleaned
}

@test "a competing site operation retains its lock and prevents replacement" {
  mkdir "$TX_DIR/.octojoom-change.lock"
  printf owner > "$TX_DIR/.octojoom-change.lock/owner"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_equal "$(cat "$TX_DIR/.octojoom-change.lock/owner")" owner
  assert_old_data
  [ ! -s "$TX_EVENTS" ]
}

@test "a competing shared environment operation prevents quiescing and keeps its lock" {
  mkdir "${TX_ENV}.octojoom-change.lock"
  printf owner > "${TX_ENV}.octojoom-change.lock/owner"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_equal "$(cat "${TX_ENV}.octojoom-change.lock/owner")" owner
  assert_old_data
  refute_file_contains "$TX_EVENTS" 'compose stop'
  [ ! -e "$TX_DIR/.octojoom-change.lock" ]
}
