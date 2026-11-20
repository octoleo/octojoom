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
    joomlaSiteJSON --arg ini "$ini_source" --arg web "$TX_WEB" '
      .services.helper={image:"helper"} |
      if $web=="nginx" then .services.nginx={image:"nginx",volumes:[.services.app.volumes[] | select(.target=="/var/www/html") | .read_only=true]} else . end |
      .services.app.volumes |= (map(select(.target!="/usr/local/etc/php/conf.d/zz-octojoom.ini")) +
        [{type:"bind",source:$ini,target:"/usr/local/etc/php/conf.d/zz-octojoom.ini",read_only:true}])' \
      < "$SANDBOX/model.json" > "$work/original-model.json" || return 1
    cp "$work/original-model.json" "$SANDBOX/model.json" && cp "$work/original-model.json" "$work/rendered.json" &&
      cp "$work/original-model.json" "$work/proposed.json" || return 1
    joomlaSiteJSON -nc --arg web "$TX_WEB" '{project:"shop",app:"app",db:"db",web:$web,
      root:"/var/www/html",ini:"/usr/local/etc/php/conf.d/zz-octojoom.ini",engine:"mariadb",image:"joomla:6"}' > "$work/services.json"
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
    VDM_DB_HOST=db joomlaPlaygroundReplacementModel "$3" "$(cat "$3/token")" app db "$TX_WEB" "$(cat "$3/services.json")" || return 1
    case "$TX_FAULT" in
      compose) echo 'name: other-project' >> "$TX_DIR/docker-compose.yml";;
      registration) link_enabled joomla "$TX_SITE";;
    esac
    echo staged >> "$TX_EVENTS"
  }
  migrationRunCompose() {
    case "$2" in
      */candidate.yml) cat "$SANDBOX/model.json"; return;;
      verify.json)
        [ "$3" = config ] && [ "$4" = --quiet ] &&
          joomlaSiteJSON -e --arg project "$COMPOSE_PROJECT_NAME" --arg web "$TX_WEB" '
            .name==$project and .networks.default.internal and
            (.services|keys)==(if $web=="nginx" then ["app","db","nginx"] else ["app","db"] end)' < "$2"
        return;;
      */verify.json) ;;
      *) return 92;;
    esac
    local work="${2%/*}"
    [ -z "$1" ] && [ "$COMPOSE_PROJECT_NAME" = "octojoom-verify-$(cat "$work/token")" ] &&
      [ -f "$work/verifying" ] && [ ! -e "$work/committed" ] &&
      assert_registration_gated && assert_candidate_storage || return 1
    shift 2
    case "$*" in
      'up -d'*) [ -f "$SANDBOX/public-removed" ] && echo 'gate up' >> "$TX_EVENTS" && touch "$SANDBOX/gate-live";;
      'down --remove-orphans')
        echo 'gate down' >> "$TX_EVENTS"
        if [ "$TX_FAULT" != gate-held ]; then rm -f "$SANDBOX/gate-live"; fi;;
      *) return 92;;
    esac
  }
  joomlaPlaygroundOriginalCompose() {
    [ -s "$1/rendered.json" ] && [ "$2" = "$TX_DIR" ] && [ "$3" = shop ] || return 1
    shift 3
    TX_PINNED=true joomlaSiteCompose "$TX_SITE" "$@"
  }
  joomlaSiteCompose() {
    [ "$1" = "$TX_SITE" ] || return 1
    shift
    if [ "$1" = up ]; then
      local work scope
      IFS= read -r work < "$TX_DIR/.octojoom-change.lock/recovery.path" || return 1
      if grep -qF '# candidate compose' "$TX_DIR/docker-compose.yml"; then
        scope=candidate
        [ -f "$work/committed" ] && [ ! -e "$SANDBOX/gate-live" ] && assert_candidate_storage || return 1
      else
        scope=original
        cmp -s "$TX_DIR/docker-compose.yml" "$SANDBOX/original.yml" &&
          [ ! -e "$SANDBOX/gate-live" ] && [ "$(cat "$TX_PROJECT/db/content")" = 'original db' ] &&
          [ "$(cat "$TX_PROJECT/joomla/content")" = 'original web' ] || return 1
      fi
      printf '%s %s\n' "$scope" "$*" >> "$TX_EVENTS"
      if [ "$scope" = candidate ] && [ "$2" = -d ] && [ "$TX_FAULT" = public-start ]; then
        printf 'customer order' > "$TX_PROJECT/db/accepted-order"
        return 1
      fi
      return 0
    fi
    printf '%s\n' "$*" >> "$TX_EVENTS"
    if [ "$*" = stop ] && [ "$TX_FAULT" = ini-cutover ]; then
      printf 'late operator edit' > "$TX_INI_DESTINATION"
    fi
    case "$*" in
      'config --format json') cat "$SANDBOX/model.json";;
      'ps --status running --services') printf '%s\n' "$TX_RUNNING";;
      'ps --all --services') printf 'app\ndb\nhelper\n'; [ "$TX_WEB" = 127.0.0.1 ] || printf '%s\n' "$TX_WEB";;
      'rm --force --stop '*)
        [ "${TX_PINNED:-}" = true ] && assert_registration_gated &&
          [ "$(cat "$TX_PROJECT/db/content")" = 'original db' ] && touch "$SANDBOX/public-removed";;
      'stop'|'stop '*) return 0;;
      *) return 92;;
    esac
  }
  docker() {
    case "$*" in
      'ps -aq'|'ps --quiet'|'ps -aq --filter label=com.docker.compose.project=shop') return 0;;
      'ps -aq --filter label=com.docker.compose.project=octojoom-verify-'*)
        [ ! -f "$SANDBOX/gate-live" ] || echo verify-container;;
      'network ls -q --filter name=^octojoom-verify-'*) return 0;;
      *) return 92;;
    esac
  }
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
    if [[ "$2" == */verify.json ]]; then
      [ -z "$1" ] && [ -f "$SANDBOX/gate-live" ] && assert_registration_gated && assert_candidate_storage || return 1
      [ "$3" = app ] && [ "$4" = "$TX_SITE" ] && [ "$5" = /var/www/html ] && [ "$6" = "$TX_WEB" ] || return 1
      echo 'gate ready' >> "$TX_EVENTS"
      [ "$TX_FAULT" != ready ]
    elif [ "$1" = "$VDM_REPO_PATH/joomla/.env" ]; then
      assert_original_site || return 1
      echo 'original ready' >> "$TX_EVENTS"
    else
      [ "$2" = "$TX_DIR/docker-compose.yml" ] && assert_candidate_storage || return 1
      echo 'public ready' >> "$TX_EVENTS"
    fi
  }
  VDM_DEFAULT_BACKUP_PATH="$SANDBOX/backups"
  mkdir -p "$VDM_DEFAULT_BACKUP_PATH"
  OCTOJOOM_NON_INTERACTIVE=true
}

assert_registration_gated() {
  local file
  [ -f "$TX_DIR/docker-compose.yml" ] || return 1
  for file in "$TX_DIR/docker-compose.yml" "$VDM_REPO_PATH/joomla/enabled/$TX_SITE/docker-compose.yml"; do
    [ -d "${file%/*}" ] || continue
    [ -f "$file" ] || return 1
    joomlaSiteJSON -e '.name=="shop" and .services=={}' < "$file" >/dev/null || return 1
  done
}

assert_candidate_storage() {
  assert_equal "$(cat "$TX_PROJECT/joomla/content")" 'candidate web' &&
    assert_equal "$(cat "$TX_PROJECT/db/content")" 'candidate db' &&
    assert_file_contains "$TX_DIR/.env" candidate && assert_file_contains "$TX_PROJECT/php.ini" 'candidate ini'
}

assert_public_lifecycle() {
  local expected actual
  expected=$(printf '%s\n' "$@")
  actual=$(awk '/^rm / {removed=1} removed && /^(rm |gate |original (up|ready)|candidate up|public ready|stop|down)/' "$TX_EVENTS")
  assert_equal "$actual" "$expected"
}

assert_offline_originals() {
  local recovery="$1" role sibling
  for role in web db; do
    sibling=$(joomlaSiteJSON -er --arg role "$role" '.[$role].candidate' < "$recovery/storage.json") || return 1
    assert_equal "$(cat "${sibling%/*}/original/content")" "original $role" || return 1
  done
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
  assert_file_contains "$TX_EVENTS" 'original up -d --no-recreate --no-deps app db'
  refute_file_contains "$TX_EVENTS" 'candidate up'
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
  assert_file_contains "$TX_EVENTS" 'original up -d --no-recreate --no-deps app db'
  refute_file_contains "$TX_EVENTS" 'candidate up'
  joomlaSiteJSON -e '.status=="failed" and .outcome=="not_committed" and .committed==false and .stage=="backup" and .recovery==null and .backup==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "failed gated readiness removes the verifier before restoring the original storage, definition and running set" {
  TX_FAULT=ready
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_public_lifecycle 'rm --force --stop app db helper' \
    'gate up' 'gate ready' 'gate down' \
    'original up --no-start --no-deps app db helper' \
    'original up -d --no-recreate --no-deps app db' \
    'original ready'
  refute_file_contains "$TX_EVENTS" backup-created
  joomlaSiteJSON -e '.status=="failed" and .outcome=="not_committed" and .committed==false and
    .stage=="verify" and .recovery==null and .running==true' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "a verifier still holding published storage keeps the registration gated and the recovery lock held" {
  TX_FAULT=gate-held
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  local report="$TX_PACKAGE/result.json" recovery
  joomlaSiteJSON -e '.status=="failed" and .outcome=="recovery_incomplete" and .committed==false and
    .stage=="verify" and .running==null and (.reason|length)>0' < "$report"
  recovery=$(joomlaSiteJSON -er .recovery < "$report")
  assert_equal "$(cat "$TX_DIR/.octojoom-change.lock/recovery.path")" "$recovery"
  assert_file_exists "$recovery/verifying"
  refute_file_exists "$recovery/committed"
  assert_file_contains "$TX_EVENTS" 'gate down'
  refute_file_contains "$TX_EVENTS" 'original up'
  refute_file_contains "$TX_EVENTS" 'candidate up'
  assert_registration_gated
  assert_candidate_storage
  assert_offline_originals "$recovery"
}

@test "a successful default replacement reopens only after commit and keeps verified recovery data" {
  link_enabled joomla "$TX_SITE"
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_success
  local report="$TX_PACKAGE/result.json" backup recovery
  joomlaSiteJSON -e '.status=="deployed" and .outcome=="committed" and .committed==true and
    .enabled=="enabled" and .running==true' < "$report"
  backup=$(joomlaSiteJSON -er .backup < "$report")
  recovery=$(joomlaSiteJSON -er .recovery < "$report")
  assert_file_exists "$backup"
  assert_file_exists "$recovery/committed"
  assert_offline_originals "$recovery"
  assert_file_contains "$TX_EVENTS" backup-verified
  assert_public_lifecycle 'rm --force --stop app db helper' \
    'gate up' 'gate ready' 'gate down' \
    'candidate up --no-start --no-deps --pull never app db helper' \
    'candidate up -d --no-recreate --no-deps --pull never app db' 'public ready'
  assert_equal "$(getJoomlaSiteEnabledState "$TX_SITE")" enabled
  [ ! -e "$TX_DIR/.octojoom-change.lock" ]
}

@test "a stopped site's private verifier starts and stops without ever starting public services" {
  TX_RUNNING=''
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  joomlaSiteJSON -e '.status=="deployed" and .outcome=="committed" and .committed==true and
    .running==false and .backup==null and .recovery==null' < "$TX_PACKAGE/result.json"
  assert_public_lifecycle 'rm --force --stop app db helper' \
    'gate up' 'gate ready' 'gate down' \
    'candidate up --no-start --no-deps --pull never app db helper'
  assert_candidate_storage
  assert_equal "$(cat "$TX_PROJECT/adjacent-file")" untouched
  cmp "$VDM_REPO_PATH/joomla/.env" "$SANDBOX/shared.env"
  assert_transaction_cleaned
}

@test "a partially running FPM site keeps its public Nginx stopped and its companion running" {
  TX_WEB=nginx
  TX_RUNNING=$'app\ndb\nhelper'
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_success
  assert_public_lifecycle 'rm --force --stop app db helper nginx' \
    'gate up' 'gate ready' 'gate down' \
    'candidate up --no-start --no-deps --pull never app db helper nginx' \
    'candidate up -d --no-recreate --no-deps --pull never app db helper'
  joomlaSiteJSON -e '.status=="deployed" and .committed==true and .running==false' < "$TX_PACKAGE/result.json"
  assert_transaction_cleaned
}

@test "rollback restores a running Nginx with stopped FPM without waiting for an unavailable site" {
  TX_WEB=nginx
  TX_RUNNING=$'db\nnginx'
  TX_FAULT=ready
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_public_lifecycle 'rm --force --stop app db helper nginx' \
    'gate up' 'gate ready' 'gate down' \
    'original up --no-start --no-deps app db helper nginx' \
    'original up -d --no-recreate --no-deps db nginx'
  joomlaSiteJSON -e '.outcome=="not_committed" and .stage=="verify" and .running==false and .recovery==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "the commit receipt exists before the first public definition can reopen" {
  joomlaPlaygroundOpenIngress() {
    local work="${1%/*}"
    if [ -f "$work/committed" ] && [ -f "$TX_PACKAGE/committed" ] && assert_registration_gated &&
      [ ! -e "$work/verifying" ] && [ ! -e "$SANDBOX/gate-live" ]; then
      touch "$SANDBOX/committed-before-open"
    fi
    return 1
  }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  assert_file_exists "$SANDBOX/committed-before-open"
  joomlaSiteJSON -e '.outcome=="committed_with_followup" and .committed==true and .stage=="ingress"' < "$TX_PACKAGE/result.json"
  refute_file_contains "$TX_EVENTS" 'candidate up'
  assert_registration_gated
  assert_candidate_storage
}

@test "partial public activation after commit keeps acknowledged writes, recovery data and the copied registration" {
  local mirror="$VDM_REPO_PATH/joomla/enabled/$TX_SITE" report="$TX_PACKAGE/result.json" recovery
  mkdir -p "$mirror"
  cp "$TX_DIR/docker-compose.yml" "$mirror/docker-compose.yml"
  getJoomlaSiteEnabledState() { printf 'enabled\n'; }
  TX_FAULT=public-start
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" true
  assert_failure
  joomlaSiteJSON -e '.status=="committed_with_followup" and .outcome=="committed_with_followup" and
    .committed==true and .stage=="ingress" and .running==null and (.reason|length)>0' < "$report"
  recovery=$(joomlaSiteJSON -er .recovery < "$report")
  assert_file_exists "$recovery/committed"
  assert_equal "$(cat "$TX_DIR/.octojoom-change.lock/recovery.path")" "$recovery"
  assert_file_exists "$(joomlaSiteJSON -er .backup < "$report")"
  assert_file_exists "$recovery/candidate.yml"
  assert_equal "$(cat "$recovery/running-services")" "$TX_RUNNING"
  assert_equal "$(cat "$recovery/existing-services")" $'app\ndb\nhelper'
  joomlaSiteJSON -e '.reason | contains("candidate.yml") and contains("service")' < "$report"
  assert_offline_originals "$recovery"
  assert_file_contains "$TX_EVENTS" 'candidate up -d --no-recreate --no-deps --pull never app db'
  refute_file_contains "$TX_EVENTS" 'original up'
  assert_equal "$(cat "$TX_PROJECT/db/accepted-order")" 'customer order'
  assert_candidate_storage
  assert_file_contains "$TX_DIR/docker-compose.yml" '# candidate compose'
  cmp "$TX_DIR/docker-compose.yml" "$mirror/docker-compose.yml"
  cmp "$TX_DIR/.env" "$mirror/.env"
}

@test "failed retirement of offline storage keeps the committed site and the original storage receipt" {
  local report="$TX_PACKAGE/result.json" recovery
  joomlaDatabaseStorageStopped() {
    if [[ "$1" == */original ]]; then
      echo 'cleanup original' >> "$TX_EVENTS"
      return 1
    fi
    return 0
  }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  joomlaSiteJSON -e '.status=="committed_with_followup" and .outcome=="committed_with_followup" and
    .committed==true and .stage=="cleanup" and .running==true and .backup==null and (.reason|length)>0' < "$report"
  recovery=$(joomlaSiteJSON -er .recovery < "$report")
  assert_file_exists "$recovery/committed"
  assert_equal "$(cat "$TX_DIR/.octojoom-change.lock/recovery.path")" "$recovery"
  joomlaSiteJSON -e '.reason | contains("original storage") and contains("cleanup")' < "$report"
  assert_offline_originals "$recovery"
  assert_file_contains "$TX_EVENTS" 'candidate up -d --no-recreate --no-deps --pull never app db'
  assert_file_contains "$TX_EVENTS" 'cleanup original'
  refute_file_contains "$TX_EVENTS" 'original up'
  assert_candidate_storage
  assert_file_contains "$TX_DIR/docker-compose.yml" '# candidate compose'
}

@test "a failure before the running services were inspected reports an unknown running state" {
  joomlaPlaygroundPlanReplacement() { return 1; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  joomlaSiteJSON -e '.stage=="preflight" and .committed==false and .outcome=="not_committed" and has("running") and .running==null' < "$TX_PACKAGE/result.json"
  assert_original_site
  assert_transaction_cleaned
}

@test "failed verification of the restored original reports an unknown running state" {
  joomlaPlaygroundWaitFresh() { return 1; }
  run joomlaPlaygroundReplaceSite "$TX_PACKAGE" "$TX_SITE" false
  assert_failure
  joomlaSiteJSON -e '.stage=="verify" and .committed==false and .outcome=="recovery_incomplete" and has("running") and .running==null and .recovery!=null' < "$TX_PACKAGE/result.json"
  [ -s "$TX_DIR/.octojoom-change.lock/recovery.path" ]
}
