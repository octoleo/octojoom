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
  joomlaPlaygroundPlanReplacement() {
    local work="$3"
    cp "$SANDBOX/model.json" "$work/original-model.json" && cp "$SANDBOX/model.json" "$work/rendered.json" || return 1
    printf '%s\n' '{"project":"shop","app":"app","db":"db","web":"127.0.0.1","root":"/var/www/html","engine":"mariadb","image":"joomla:6"}' > "$work/services.json"
    cp "$SANDBOX/original.yml" "$work/candidate.yml" && echo '# candidate compose' >> "$work/candidate.yml" || return 1
    echo 'VDM_SHOP_DB="candidate"' > "$work/candidate.env"
    echo 'candidate ini' > "$work/candidate.ini"
    printf '%s\n' "$TX_PROJECT/php.ini" > "$work/ini-destination"
  }
  joomlaPlaygroundStageReplacement() {
    local role candidate
    joomlaDatabaseCopyConfiguration "$2" "$3/target-configuration.php" || return 1
    for role in web db; do
      candidate=$(joomlaSiteJSON -er --arg role "$role" '.[$role].candidate' < "$3/storage.json") || return 1
      printf 'candidate %s' "$role" > "$candidate/content" || return 1
    done
    echo staged >> "$TX_EVENTS"
  }
  migrationRunCompose() { cat "$SANDBOX/model.json"; }
  joomlaSiteCompose() {
    [ "$1" = "$TX_SITE" ] || return 1
    shift
    printf '%s\n' "$*" >> "$TX_EVENTS"
    case "$*" in
      'config --format json') cat "$SANDBOX/model.json";;
      'ps --status running --services') printf '%s\n' "$TX_RUNNING";;
      'ps --all --services') printf 'app\ndb\nhelper\n';;
      'stop'|'stop '*|'start '*|'up --no-start '*|'up -d --force-recreate '*|'down') return 0;;
      *) return 92;;
    esac
  }
  docker() { case "$*" in 'ps -aq'|'ps --quiet') return 0;; *) return 92;; esac; }
  joomlaBackupCreateAction() {
    [ "$1" = "$TX_SITE" ] && [ "$3" = full ] && [ "$6" = true ] || return 1
    touch "$2" || return 1
    echo backup-created >> "$TX_EVENTS"
  }
  joomlaBackupVerifyAction() {
    [ -f "$1" ] || return 1
    echo backup-verified >> "$TX_EVENTS"
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
  assert_file_contains "$TX_EVENTS" 'start app'
  assert_file_contains "$TX_EVENTS" 'start db'
  refute_file_contains "$TX_EVENTS" 'up -d'
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
  assert_file_contains "$TX_EVENTS" 'start app'
  assert_file_contains "$TX_EVENTS" 'start db'
  refute_file_contains "$TX_EVENTS" 'start helper'
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
