#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2154,SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  site=alpha.example.test
  directory="$VDM_REPO_PATH/joomla/available/$site"
  mkdir -p "$directory" "$VDM_PROJECT_PATH/alpha/joomla" "$VDM_PROJECT_PATH/alpha/db" "$SANDBOX/volumes" "$SANDBOX/work"
  compose="$directory/docker-compose.yml"
  cat > "$compose" <<'YAML'
services:
  joomlaalpha:
    image: joomla:published
    volumes:
      - "${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"
      - "./php.ini:/usr/local/etc/php/conf.d/site.ini:ro"
    labels:
      - "custom.owner=kept"
  mariadbalpha:
    image: mariadb:published
    volumes:
      - "${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql"
YAML
  printf 'VDM_PROJECT_PATH="%s"\n' "$VDM_PROJECT_PATH" > "$directory/.env"
  VDM_CONTAINER="$site" VDM_ACTION=set OCTOJOOM_NON_INTERACTIVE=true
  unset VDM_PERSISTENCE VDM_DB_PERSISTENCE
}

@test "persistence edits only the selected short mount and keeps ENV and custom properties" {
  joomlaPersistenceRewriteMount "$compose" "$SANDBOX/result.yml" joomlaalpha /var/www/html selected_web false "$SANDBOX/work"
  assert_file_contains "$SANDBOX/result.yml" '"selected_web:/var/www/html"'
  assert_file_contains "$SANDBOX/result.yml" '"${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql"'
  assert_file_contains "$SANDBOX/result.yml" '"./php.ini:/usr/local/etc/php/conf.d/site.ini:ro"'
  assert_file_contains "$SANDBOX/result.yml" 'custom.owner=kept'
}

@test "persistence accepts generated Nginx long mount and preserves read-only access" {
  cat >> "$compose" <<'YAML'
  nginxalpha:
    image: nginx:stable
    volumes:
      - type: bind
        source: /project/joomla
        target: /var/www/html
        read_only: true
      - "./nginx.conf:/etc/nginx/conf.d/default.conf:ro"
YAML
  joomlaPersistenceRewriteMount "$compose" "$SANDBOX/result.yml" nginxalpha /var/www/html selected_web true "$SANDBOX/work"
  assert_file_contains "$SANDBOX/result.yml" '"selected_web:/var/www/html:ro"'
  assert_file_contains "$SANDBOX/result.yml" '"./nginx.conf:/etc/nginx/conf.d/default.conf:ro"'
  refute_file_contains "$SANDBOX/result.yml" '/project/joomla'
}

@test "persistence supports JSON mount lists without resolving unrelated placeholders" {
  cat > "$SANDBOX/json.yml" <<'YAML'
services:
  db:
    image: mariadb:published
    volumes: [{"type":"bind","source":"${VDM_PROJECT_PATH}/alpha/db","target":"/var/lib/mysql"},{"type":"bind","source":"${VDM_CUSTOM_CONFIG}","target":"/etc/custom.cnf"}]
YAML
  joomlaPersistenceRewriteMount "$SANDBOX/json.yml" "$SANDBOX/result.yml" db /var/lib/mysql selected_db false "$SANDBOX/work"
  assert_file_contains "$SANDBOX/result.yml" '"source":"selected_db"'
  assert_file_contains "$SANDBOX/result.yml" '${VDM_CUSTOM_CONFIG}'
}

@test "retired volume declarations are removed without leaving an empty migration-blocking section" {
  joomlaPersistenceVolumeDeclaration "$compose" "$SANDBOX/first.yml" selected_web add
  joomlaPersistenceVolumeDeclaration "$SANDBOX/first.yml" "$SANDBOX/second.yml" unrelated add
  joomlaPersistenceVolumeDeclaration "$SANDBOX/second.yml" "$SANDBOX/third.yml" selected_web remove
  assert_file_contains "$SANDBOX/third.yml" 'unrelated:'
  refute_file_contains "$SANDBOX/third.yml" 'selected_web:'
  joomlaPersistenceVolumeDeclaration "$SANDBOX/third.yml" "$SANDBOX/result.yml" unrelated remove
  run grep -q '^volumes:' "$SANDBOX/result.yml"
  assert_failure
  # Services still have their original mount sections.
  assert_equal "$(grep -c '^    volumes:' "$SANDBOX/result.yml")" 2
}

persistence_fixture() {
  printf 'original website\n' > "$VDM_PROJECT_PATH/alpha/joomla/marker"
  printf 'original database\n' > "$VDM_PROJECT_PATH/alpha/db/marker"
  cp "$compose" "$SANDBOX/original.yml"
  : > "$SANDBOX/lifecycle"
  joomlaPersistenceInspect() {
    VDM_SITE_KEY=alpha VDM_SITE_DIR="$directory" VDM_SITE_COMPOSE="$compose" VDM_SITE_ENV="$directory/.env"
    VDM_PERSISTENCE_STORES=$(jq -nc --arg web "$VDM_PROJECT_PATH/alpha/joomla" --arg db "$VDM_PROJECT_PATH/alpha/db" \
      '{web:{type:"bind",source:$web,storage:$web,target:"/var/www/html",service:"joomlaalpha",image:"joomla:published"},database:{type:"bind",source:$db,storage:$db,target:"/var/lib/mysql",service:"mariadbalpha",image:"mariadb:published"}}')
    VDM_PERSISTENCE_MODEL=$(printf '%s' "$VDM_PERSISTENCE_STORES" | jq '{services:{joomlaalpha:{volumes:[.web]},mariadbalpha:{volumes:[.database]}}}')
  }
  getJoomlaComposeIdentity() { VDM_SRC_PROJECT_FOLDER=alpha; }
  joomlaPersistenceStatus() { printf 'current storage status\n'; }
  joomlaPersistenceCheckShared() { :; }
  siteValidateCompose() { :; }
  joomlaDatabaseVerifyConnection() { :; }
  joomlaSiteCompose() {
    shift
    printf '%s\n' "$*" >> "$SANDBOX/lifecycle"
    case "$*" in
      'ps --status running --services') printf 'joomlaalpha\nmariadbalpha\n';;
      'up --no-start --no-deps --force-recreate'* )
        if [ -f "$SANDBOX/fail-up" ]; then rm "$SANDBOX/fail-up"; return 29; fi;;
    esac
  }
  docker() {
    case "$1 $2" in
      'image inspect') return 0;;
      'volume inspect') [ -d "$SANDBOX/volumes/$3" ] || return 1; printf '[{"Driver":"local","Options":null}]\n';;
      'volume create') mkdir "$SANDBOX/volumes/$3";;
      *) return 1;;
    esac
  }
  joomlaPersistenceCopy() {
    local source="$3" target="$5"
    [ "$2" != volume ] || source="$SANDBOX/volumes/$3"
    [ "$4" != volume ] || target="$SANDBOX/volumes/$5"
    grep -q '^stop joomlaalpha mariadbalpha$' "$SANDBOX/lifecycle" || return 99
    [ ! -f "$SANDBOX/fail-copy" ] || return 28
    cp -a "$source/." "$target/"
  }
}

@test "website-only switch copies stopped data and leaves database mount/source unchanged" {
  persistence_fixture
  VDM_PERSISTENCE=false
  run joomla__TRuST__persistence
  assert_success
  assert_file_contains "$compose" '"${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql"'
  refute_file_contains "$compose" '"${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"'
  assert_file_contains "$VDM_PROJECT_PATH/alpha/joomla/marker" 'original website'
  assert_file_contains "$VDM_PROJECT_PATH/alpha/db/marker" 'original database'
  [ "$(find "$SANDBOX/volumes" -name marker | wc -l | tr -d ' ')" = 1 ]
  assert_file_contains "$SANDBOX/lifecycle" 'up --no-start --no-deps --force-recreate joomlaalpha'
  assert_file_contains "$SANDBOX/lifecycle" 'up -d --no-deps --wait --wait-timeout 120 joomlaalpha mariadbalpha'
}

@test "failed recreation restores exact Compose and previous running services without deleting source" {
  persistence_fixture
  VDM_DB_PERSISTENCE=false
  touch "$SANDBOX/fail-up"
  run joomla__TRuST__persistence
  assert_failure
  assert_output_contains 'previous configuration and running state restored'
  cmp "$compose" "$SANDBOX/original.yml"
  assert_file_contains "$VDM_PROJECT_PATH/alpha/db/marker" 'original database'
  assert_file_contains "$SANDBOX/lifecycle" 'up -d --no-deps --wait --wait-timeout 120 joomlaalpha mariadbalpha'
  [ ! -d "$directory/.octojoom-change.lock" ]
}

@test "copy failure restores service state before publishing any mount change" {
  persistence_fixture
  VDM_PERSISTENCE=false VDM_DB_PERSISTENCE=false
  touch "$SANDBOX/fail-copy"
  run joomla__TRuST__persistence
  assert_failure
  cmp "$compose" "$SANDBOX/original.yml"
  refute_file_contains "$SANDBOX/lifecycle" 'up --no-start'
  assert_file_contains "$SANDBOX/lifecycle" 'up -d --no-deps --wait --wait-timeout 120 joomlaalpha mariadbalpha'
}

volume_fixture() {
  persistence_fixture
  mkdir "$SANDBOX/volumes/active_web"
  printf 'current volume content\n' > "$SANDBOX/volumes/active_web/marker"
  joomlaPersistenceRewriteMount "$compose" "$SANDBOX/next.yml" joomlaalpha /var/www/html active_web false "$SANDBOX/work"
  joomlaPersistenceVolumeDeclaration "$SANDBOX/next.yml" "$compose" active_web add
  cp "$compose" "$SANDBOX/original.yml"
  joomlaPersistenceInspect() {
    VDM_SITE_KEY=alpha VDM_SITE_DIR="$directory" VDM_SITE_COMPOSE="$compose" VDM_SITE_ENV="$directory/.env"
    VDM_PERSISTENCE_STORES=$(jq -nc --arg db "$VDM_PROJECT_PATH/alpha/db" \
      '{web:{type:"volume",source:"active_web",storage:"active_web",target:"/var/www/html",service:"joomlaalpha",image:"joomla:published"},database:{type:"bind",source:$db,storage:$db,target:"/var/lib/mysql",service:"mariadbalpha",image:"mariadb:published"}}')
    VDM_PERSISTENCE_MODEL=$(printf '%s' "$VDM_PERSISTENCE_STORES" | jq --argjson extra "${PERSISTENCE_EXTRA_MODEL:-null}" '{services:{joomlaalpha:{volumes:[.web]},mariadbalpha:{volumes:[.database]}},volumes:{active_web:{name:"active_web"}}} | if $extra==null then . else . * $extra end')
  }
}

@test "volume to folder keeps current data and retains the previous folder outside the project" {
  volume_fixture
  VDM_PERSISTENCE=true
  run joomla__TRuST__persistence
  assert_success
  assert_file_contains "$VDM_PROJECT_PATH/alpha/joomla/marker" 'current volume content'
  assert_file_contains "$SANDBOX/volumes/active_web/marker" 'current volume content'
  assert_file_contains "$compose" '"${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"'
  run grep -q '^volumes:' "$compose"
  assert_failure
  previous=$(find "$VDM_PROJECT_PATH" -path '*/original/marker')
  [ -n "$previous" ]
  [[ "$previous" != "$VDM_PROJECT_PATH/alpha/"* ]]
  assert_file_contains "$previous" 'original website'
}

@test "failed volume to folder publication restores old target and active volume definition" {
  volume_fixture
  VDM_PERSISTENCE=true
  touch "$SANDBOX/fail-up"
  run joomla__TRuST__persistence
  assert_failure
  cmp "$compose" "$SANDBOX/original.yml"
  assert_file_contains "$VDM_PROJECT_PATH/alpha/joomla/marker" 'original website'
  assert_file_contains "$SANDBOX/volumes/active_web/marker" 'current volume content'
  candidate=$(find "$VDM_PROJECT_PATH" -path '*/candidate/marker')
  assert_file_contains "$candidate" 'current volume content'
}

@test "volume to folder supplies absent project path in the site's private ENV" {
  volume_fixture
  printf 'VDM_CUSTOM_VALUE="kept"\n' > "$directory/.env"
  VDM_PERSISTENCE=true
  siteValidateCompose() {
    local resolved
    migrationReadEnvValue "$2" VDM_PROJECT_PATH resolved || return 1
    [ "$resolved" = "$VDM_PROJECT_PATH" ]
  }
  run joomla__TRuST__persistence
  assert_success
  assert_file_contains "$directory/.env" 'VDM_CUSTOM_VALUE="kept"'
  migrationReadEnvValue "$directory/.env" VDM_PROJECT_PATH resolved
  assert_equal "$resolved" "$VDM_PROJECT_PATH"
  assert_file_contains "$VDM_PROJECT_PATH/alpha/joomla/marker" 'current volume content'
}

@test "failed volume to folder restores private ENV when project path was absent" {
  volume_fixture
  printf 'VDM_CUSTOM_VALUE="kept"\n' > "$directory/.env"
  cp "$directory/.env" "$SANDBOX/original.env"
  VDM_PERSISTENCE=true
  touch "$SANDBOX/fail-up"
  run joomla__TRuST__persistence
  assert_failure
  cmp "$directory/.env" "$SANDBOX/original.env"
  cmp "$compose" "$SANDBOX/original.yml"
  assert_file_contains "$VDM_PROJECT_PATH/alpha/joomla/marker" 'original website'
}

@test "switching to binds retires stale ordinary declarations while retaining custom and referenced volumes" {
  volume_fixture
  cat >> "$compose" <<'YAML'
  retired_db:
    name: retired_db
  custom_cache:
    external: true
  current_cache:
    name: current_cache
YAML
  PERSISTENCE_EXTRA_MODEL='{"volumes":{"retired_db":{"name":"retired_db"},"custom_cache":{"external":true},"current_cache":{"name":"current_cache"}},"services":{"cache":{"volumes":[{"type":"volume","source":"current_cache","target":"/cache"}]}}}'
  mkdir "$SANDBOX/volumes/retired_db"
  printf 'retired data\n' > "$SANDBOX/volumes/retired_db/marker"
  VDM_PERSISTENCE=true
  run joomla__TRuST__persistence
  assert_success
  refute_file_contains "$compose" 'retired_db:'
  refute_file_contains "$compose" 'active_web:'
  assert_file_contains "$compose" 'custom_cache:'
  assert_file_contains "$compose" 'current_cache:'
  assert_file_contains "$SANDBOX/volumes/retired_db/marker" 'retired data'
}

@test "persistence refuses a container whose actual mount differs from edited Compose" {
  persistence_fixture
  VDM_PERSISTENCE=false
  joomlaSiteCompose() {
    shift
    printf '%s\n' "$*" >> "$SANDBOX/lifecycle"
    case "$*" in 'ps -aq joomlaalpha') printf 'existing-app\n';; esac
  }
  docker() {
    case "$1 $2" in
      'image inspect') return 0;;
      'inspect --format') printf '[{"Type":"bind","Source":"/different/live-data","Destination":"/var/www/html"}]\n';;
      *) return 99;;
    esac
  }
  run joomla__TRuST__persistence
  assert_failure
  assert_output_contains 'existing container uses different storage'
  cmp "$compose" "$SANDBOX/original.yml"
  refute_file_contains "$SANDBOX/lifecycle" 'stop'
}

@test "physical alias comparison resolves another site's symlinked bind parent" {
  mkdir "$SANDBOX/physical"
  ln -s "$SANDBOX/physical" "$SANDBOX/alias" || skip 'symlink unsupported'
  [ -L "$SANDBOX/alias" ] || skip 'Symbolic links are unavailable'
  local physical
  physical=$(cd "$SANDBOX/physical" && pwd -P)
  assert_equal "$(joomlaPersistenceCanonicalPath "$SANDBOX/alias/missing-child")" "$physical/missing-child"
}

@test "physical alias comparison uses privileged resolution when directory traversal is denied" {
  mkdir "$SANDBOX/protected directory"
  local physical
  physical=$(cd "$SANDBOX/protected directory" && pwd -P)
  runPrivileged() { printf '<%s>\n' "$@" > "$SANDBOX/privileged-argv"; "$@"; }
  cd() { return 77; }
  run joomlaPersistenceCanonicalPath "$SANDBOX/protected directory/missing-child"
  unset -f cd
  assert_success
  assert_equal "$output" "$physical/missing-child"
  assert_file_contains "$SANDBOX/privileged-argv" "<$SANDBOX/protected directory>"
}

@test "single JSON data mount returns to original short bind form" {
  cat > "$SANDBOX/json.yml" <<'YAML'
services:
  db:
    image: mariadb:published
    volumes: [{"type":"volume","source":"local_db","target":"/var/lib/mysql"}]
YAML
  joomlaPersistenceRewriteMount "$SANDBOX/json.yml" "$SANDBOX/result.yml" db /var/lib/mysql '${VDM_PROJECT_PATH}/alpha/db' false "$SANDBOX/work"
  assert_file_contains "$SANDBOX/result.yml" '"${VDM_PROJECT_PATH}/alpha/db:/var/lib/mysql"'
  refute_file_contains "$SANDBOX/result.yml" 'volumes: ['
}
