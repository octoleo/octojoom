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
  TX_RUNNING=$'app\ndb'
  TX_WEB=127.0.0.1
  TX_FAULT=''
  mkdir "$TX_PACKAGE"
  make_joomla_container shop SHOP shop example.test
  cp "$TX_DIR/docker-compose.yml" "$SANDBOX/original.yml"
  cp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/shared.env"
  printf 'original web' > "$TX_PROJECT/joomla/content"
  printf 'original db' > "$TX_PROJECT/db/content"
  printf 'original ini' > "$TX_PROJECT/php.ini"
  printf 'untouched' > "$TX_PROJECT/adjacent-file"
  : > "$TX_EVENTS"

  # Freeze Docker's rendered bind layout. The actual transaction reserves,
  # publishes, rolls back and cleans the files and directories in the sandbox.
  local web_path="$TX_PROJECT/joomla" db_path="$TX_PROJECT/db"
  if is_windows; then web_path=$(cygpath -am "$web_path"); db_path=$(cygpath -am "$db_path"); fi
  joomlaSiteJSON -n --arg web "$web_path" --arg db "$db_path" '{
    name:"shop",services:{
      app:{volumes:[{type:"bind",source:$web,target:"/var/www/html"}]},
      db:{volumes:[{type:"bind",source:$db,target:"/var/lib/mysql"}]}}}' > "$SANDBOX/model.json"

  joomlaDatabaseContext() { return 0; }
  joomlaPlaygroundConfirmReplaceSettings() { return 0; }
  joomlaDatabaseCopyConfiguration() { cp "$TX_PROJECT/joomla/content" "$2"; }
  joomlaPHPIniDestination() { printf '%s\n' "${TX_INI_DESTINATION:-$TX_PROJECT/php.ini}"; }
  joomlaPHPValidateIni() { return 0; }
  joomlaPHPReplaceMount() { return 0; }
  joomlaPlaygroundPlanReplacement() {
    local work="$3" ini_source
    ini_source=$(joomlaWebHostPath "${TX_INI_SOURCE:-$TX_PROJECT/php.ini}") || return 1
    joomlaSiteJSON --arg ini "$ini_source" '.services.app.volumes |=
      (map(select(.target!="/var/www/html/php.ini")) + [{type:"bind",source:$ini,target:"/var/www/html/php.ini"}])' \
      < "$SANDBOX/model.json" > "$work/original-model.json" || return 1
    cp "$work/original-model.json" "$SANDBOX/model.json" && cp "$work/original-model.json" "$work/rendered.json" || return 1
    joomlaSiteJSON -nc --arg web "$TX_WEB" '{project:"shop",app:"app",db:"db",web:$web,
      root:"/var/www/html",engine:"mariadb",image:"joomla:6"}' > "$work/services.json"
    cp "$SANDBOX/original.yml" "$work/candidate.yml" && echo '# candidate compose' >> "$work/candidate.yml" || return 1
    echo 'VDM_SHOP_DB="candidate"' > "$work/candidate.env"
    VDM_SITE_SERVICE=app VDM_PHP_INI_TARGET=/usr/local/etc/php/conf.d/zz-octojoom.ini \
      joomlaPlaygroundReplacementIni "$2" "$work" joomla:6 "$4" || return 1
    echo 'candidate ini' >> "$work/candidate.ini"
  }
  joomlaPlaygroundStageReplacement() {
    local role candidate
    joomlaDatabaseCopyConfiguration "$2" "$3/target-configuration.php" || return 1
    for role in web db; do
      candidate=$(joomlaSiteJSON -er --arg role "$role" '.[$role].candidate' < "$3/storage.json") || return 1
      printf 'candidate %s' "$role" > "$candidate/content" || return 1
    done
    case "$TX_FAULT" in
      compose) echo 'name: other-project' >> "$TX_DIR/docker-compose.yml";;
      registration) link_enabled joomla "$TX_SITE";;
    esac
    echo staged >> "$TX_EVENTS"
  }
  migrationRunCompose() { cat "$SANDBOX/model.json"; }
  joomlaPlaygroundOriginalCompose() {
    [ -s "$1/rendered.json" ] && [ "$2" = "$TX_DIR" ] && [ "$3" = shop ] || return 1
    shift 3
    joomlaSiteCompose "$TX_SITE" "$@"
  }
  joomlaSiteCompose() {
    [ "$1" = "$TX_SITE" ] || return 1
    shift
    printf '%s\n' "$*" >> "$TX_EVENTS"
    if [ "$*" = stop ] && [ "$TX_FAULT" = ini-cutover ]; then
      printf 'late operator edit' > "$TX_INI_DESTINATION"
    fi
    case "$*" in
      'config --format json') cat "$SANDBOX/model.json";;
      'ps --status running --services') printf '%s\n' "$TX_RUNNING";;
      'ps --all --services') printf 'app\ndb\nhelper\n'; [ "$TX_WEB" = 127.0.0.1 ] || printf '%s\n' "$TX_WEB";;
      'stop'|'stop '*|'up --no-start '*|'up -d --no-recreate '*|'up -d --force-recreate '*|'down') return 0;;
      *) return 92;;
    esac
  }
  docker() { case "$*" in 'ps -aq'|'ps --quiet'|'ps -aq --filter label=com.docker.compose.project=shop') return 0;; *) return 92;; esac; }
  joomlaBackupCreateAction() {
    [ "$1" = "$TX_SITE" ] && [ "$3" = full ] && [ "$6" = true ] || return 1
    touch "$2" || return 1
    echo backup-created >> "$TX_EVENTS"
  }
  joomlaBackupVerifyAction() {
    [ -f "$1" ] || return 1
    echo backup-verified >> "$TX_EVENTS"
    if [ "$TX_FAULT" = env ]; then echo 'COMPOSE_PROJECT_NAME=other-project' > "$TX_DIR/.env"; fi
    [ "$TX_FAULT" != backup ]
  }
  joomlaPlaygroundWaitFresh() {
    # Record a check only after the public configuration, web and DB form a
    # consistent candidate. A failing check exercises rollback after cutover.
    if [ "$1" = "$VDM_REPO_PATH/joomla/.env" ]; then
      assert_original_site || return 1
      echo 'original ready' >> "$TX_EVENTS"
      return 0
    fi
    [ "$(cat "$TX_PROJECT/joomla/content")" = 'candidate web' ] &&
      [ "$(cat "$TX_PROJECT/db/content")" = 'candidate db' ] &&
      grep -qF '# candidate compose' "$TX_DIR/docker-compose.yml" &&
      grep -qF 'candidate' "$TX_DIR/.env" &&
      grep -qF 'candidate ini' "$TX_PROJECT/php.ini" || return 1
    echo ready >> "$TX_EVENTS"
    [ "$TX_FAULT" != ready ]
  }
  VDM_DEFAULT_BACKUP_PATH="$SANDBOX/backups"
  mkdir -p "$VDM_DEFAULT_BACKUP_PATH"
  OCTOJOOM_NON_INTERACTIVE=true
}

assert_original_site() {
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'original web'
  assert_equal "$(cat "$TX_PROJECT/db/content")" 'original db'
  assert_equal "$(cat "$TX_PROJECT/php.ini")" 'original ini'
  assert_equal "$(cat "$TX_PROJECT/adjacent-file")" untouched
  cmp "$TX_DIR/docker-compose.yml" "$SANDBOX/original.yml"
  cmp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/shared.env"
  refute_file_exists "$TX_DIR/.env"
}

assert_transaction_cleaned() {
  [ ! -e "$TX_DIR/.octojoom-change.lock" ]
  assert_equal "$(find "$TX_PROJECT" -name '.octojoom-*' -print)" ''
  assert_equal "$(find "$TX_DIR" -name '.playground-replace.*' -print)" ''
}

@test "replacement preserves an edit to a separate mounted PHP override during backup" {
  TX_INI_SOURCE="$SANDBOX/shared.ini"
  printf 'original shared override' > "$TX_INI_SOURCE"
  joomlaBackupVerifyAction() { printf 'edited shared override' > "$TX_INI_SOURCE"; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  [[ "$output" == *'PHP override changed'* ]]
  assert_equal "$(cat "$TX_INI_SOURCE")" 'edited shared override'
  assert_original_site
  assert_transaction_cleaned
}

@test "replacement preserves a PHP publication destination created or edited during backup" {
  TX_INI_DESTINATION="$TX_PROJECT/separate.ini"
  joomlaBackupVerifyAction() { printf 'operator edit' > "$TX_INI_DESTINATION"; }
  local state
  for state in absent present; do
    if [ "$state" = present ]; then printf 'prior destination' > "$TX_INI_DESTINATION"; fi
    run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
    assert_failure
    [[ "$output" == *'PHP override changed'* ]]
    assert_equal "$(cat "$TX_INI_DESTINATION")" 'operator edit'
    assert_original_site
    assert_transaction_cleaned
  done
}

@test "replacement preserves a copied enabled registration's PHP override edited during backup" {
  local mirror="$VDM_REPO_PATH/joomla/enabled/$TX_SITE"
  mkdir -p "$mirror"
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  TX_INI_DESTINATION="$TX_DIR/private.ini"
  joomlaBackupVerifyAction() { printf 'edited mirror' > "$mirror/private.ini"; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  [[ "$output" == *'PHP override changed'* ]]
  assert_equal "$(cat "$mirror/private.ini")" 'edited mirror'
  refute_file_exists "$TX_INI_DESTINATION"
  assert_original_site
  assert_transaction_cleaned
}

@test "an INI edit after services stop survives rollback of the published storage" {
  TX_FAULT=ini-cutover
  TX_INI_DESTINATION="$TX_PROJECT/late.ini"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  [[ "$output" == *'PHP override changed'* ]]
  assert_equal "$(cat "$TX_INI_DESTINATION")" 'late operator edit'
  assert_original_site
  assert_transaction_cleaned
}

@test "a Compose or registration change during staging aborts before touching original services" {
  for TX_FAULT in compose registration; do
    run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
    assert_failure
    assert_output_contains 'site registration changed'
    refute_file_contains "$TX_EVENTS" 'ps --status running'
    refute_file_contains "$TX_EVENTS" stop
    refute_file_contains "$TX_EVENTS" start
    assert_transaction_cleaned
    cp "$SANDBOX/original.yml" "$TX_DIR/docker-compose.yml"
    : > "$TX_EVENTS"
  done
  assert_equal "$(getJoomlaSiteEnabledState "$TX_SITE")" enabled
}

@test "a new private environment during backup survives and the original project resumes" {
  TX_FAULT='env'
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  assert_output_contains 'site registration changed'
  assert_file_contains "$TX_EVENTS" backup-verified
  assert_file_contains "$TX_EVENTS" 'up -d --no-recreate --no-deps app db'
  refute_file_contains "$TX_EVENTS" 'up -d --force-recreate'
  assert_equal "$(cat "$TX_DIR/.env")" COMPOSE_PROJECT_NAME=other-project
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'original web'
  assert_equal "$(cat "$TX_PROJECT/db/content")" 'original db'
  assert_transaction_cleaned
}

@test "a competing site operation retains its lock and prevents a replacement from staging" {
  mkdir "$TX_DIR/.octojoom-change.lock"
  echo owner > "$TX_DIR/.octojoom-change.lock/owner"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_equal "$(cat "$TX_DIR/.octojoom-change.lock/owner")" owner
  [ ! -s "$TX_EVENTS" ]
  assert_original_site
}

@test "an unverified full backup aborts before public cutover and resumes original services" {
  TX_FAULT=backup
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  assert_file_contains "$TX_EVENTS" backup-created
  assert_file_contains "$TX_EVENTS" backup-verified
  assert_file_contains "$TX_EVENTS" 'up -d --no-recreate --no-deps app db'
  refute_file_contains "$TX_EVENTS" 'up -d --force-recreate'
  joomlaSiteJSON -e '.status=="failed" and .stage=="backup" and .recovery==null and .backup==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "failed public readiness restores the prior database, uploads, site configuration and running set" {
  TX_FAULT=ready
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_file_contains "$TX_EVENTS" ready
  refute_file_contains "$TX_EVENTS" backup-created
  assert_file_contains "$TX_EVENTS" 'up --no-start --no-deps app db helper'
  assert_file_contains "$TX_EVENTS" 'up -d --no-recreate --no-deps app db'
  assert_file_contains "$TX_EVENTS" 'original ready'
  joomlaSiteJSON -e '.status=="failed" and .stage=="activate" and .recovery==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "a successful default replacement keeps its verified backup and both offline originals for recovery" {
  link_enabled joomla "$TX_SITE"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_success
  local report="$TX_PACKAGE/result.json" backup recovery role sibling
  joomlaSiteJSON -e '.status=="deployed" and .enabled=="enabled" and .running==true' < "$report"
  backup=$(joomlaSiteJSON -er .backup < "$report")
  recovery=$(joomlaSiteJSON -er .recovery < "$report")
  assert_file_exists "$backup"
  assert_file_exists "$recovery/storage.json"
  for role in web db; do
    sibling=$(joomlaSiteJSON -er --arg role "$role" '.[$role].candidate' < "$recovery/storage.json")
    assert_equal "$(cat "${sibling%/*}/original/content")" "original $role"
  done
  assert_file_contains "$TX_EVENTS" backup-verified
  assert_file_contains "$TX_EVENTS" ready
  assert_equal "$(getJoomlaSiteEnabledState "$TX_SITE")" enabled
  [ ! -e "$TX_DIR/.octojoom-change.lock" ]
}

@test "a stopped site is restarted for readiness, then returned to its previous stopped state" {
  TX_RUNNING=''
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  joomlaSiteJSON -e '.status=="deployed" and .running==false and .backup==null and .recovery==null' < "$TX_PACKAGE/result.json"
  local lifecycle
  lifecycle=$(awk '/^(up|ready|stop)( |$)/' "$TX_EVENTS")
  assert_equal "$lifecycle" $'stop\nup --no-start --force-recreate --no-deps helper\nup -d --force-recreate --no-deps db app\nready\nstop db\nstop app'
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'candidate web'
  assert_equal "$(cat "$TX_PROJECT/db/content")" 'candidate db'
  assert_equal "$(cat "$TX_PROJECT/adjacent-file")" untouched
  cmp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/shared.env"
  assert_transaction_cleaned
}

@test "readiness temporarily starts Nginx while preserving a running FPM service and companion" {
  TX_WEB=nginx
  TX_RUNNING=$'app\ndb\nhelper'
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_file_contains "$TX_EVENTS" 'up -d --force-recreate --no-deps db app nginx helper'
  assert_equal "$(awk '/^ready$/{record=1; next} record && /^stop /' "$TX_EVENTS")" 'stop nginx'
  joomlaSiteJSON -e '.status=="deployed" and .running==false' < "$TX_PACKAGE/result.json"
  assert_transaction_cleaned
}

@test "rollback restores a running Nginx with stopped FPM without waiting for an unavailable site" {
  TX_WEB=nginx
  TX_RUNNING=$'db\nnginx'
  TX_FAULT=ready
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_file_contains "$TX_EVENTS" 'up -d --no-recreate --no-deps db nginx'
  refute_file_contains "$TX_EVENTS" 'original ready'
  joomlaSiteJSON -e '.stage=="activate" and .running==false and .recovery==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "a failure before the running services were inspected reports an unknown running state" {
  joomlaPlaygroundPlanReplacement() { return 1; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  joomlaSiteJSON -e '.stage=="preflight" and has("running") and .running==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "failed verification of the restored original reports an unknown running state" {
  joomlaPlaygroundWaitFresh() { return 1; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  joomlaSiteJSON -e '.stage=="activate" and has("running") and .running==null and .recovery!=null' < "$TX_PACKAGE/result.json"
  [ -s "$TX_DIR/.octojoom-change.lock/recovery.path" ]
}
