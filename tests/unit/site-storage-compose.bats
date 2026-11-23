#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  site=alpha.example.test
  directory="$VDM_REPO_PATH/joomla/available/$site"
  compose="$directory/docker-compose.yml"
  mkdir -p "$directory" "$VDM_PROJECT_PATH/alpha/joomla"
  cat > "$compose" <<'YAML'
services:
  web:
    image: busybox:latest
    volumes:
      - "${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"
YAML
  local host
  host=$(joomlaWebHostPath "$VDM_PROJECT_PATH")
  printf 'VDM_PROJECT_PATH="%s"\n' "$host" > "$directory/.env"
  cp "$directory/.env" "$VDM_REPO_PATH/joomla/.env"
}

storage_render_fixture() {
  joomlaSiteJSON -nc --arg source "$VDM_PROJECT_PATH/alpha/joomla" '{services:{web:{
    environment:{PRIVATE_VALUE:"fixture-secret"},
    volumes:[{type:"bind",source:$source,target:"/var/www/html"}]}}}' > "$SANDBOX/model.json"
  joomlaSiteJSON '.services.web.volumes[0].source="${VDM_PROJECT_PATH}/alpha/joomla"' \
    < "$SANDBOX/model.json" > "$SANDBOX/unexpanded.json"
  : > "$SANDBOX/diagnostic"
  echo 0 > "$SANDBOX/render-status"
  runComposeProgress() {
    shift
    if [[ " $* " == *' config --no-interpolate --format json '* ]]; then
      cat "$SANDBOX/unexpanded.json"
      return 0
    fi
    if [[ " $* " == *' config --format json '* ]]; then
      cat "$SANDBOX/diagnostic" >&2
      cat "$SANDBOX/model.json"
      return "$(cat "$SANDBOX/render-status")"
    fi
    docker "$@"
  }
}

storage_real_compose() {
  if [ -z "$REAL_DOCKER" ] || ! "$REAL_DOCKER" compose version >/dev/null 2>&1; then
    skip 'Docker Compose is unavailable'
  fi
}

storage_original_snapshot() {
  original_work="$SANDBOX/original-check"
  mkdir "$original_work"
  cp "$compose" "$original_work/initial-compose"
  original_digest=$(migrationArchiveDigest "$directory/.env")
  joomlaStorageComposeModel "$site" "$directory/.env" "$compose" > "$original_work/rendered.json"
  # Project ownership needs a daemon; the configuration and original-state
  # checks remain real and must finish before this ownership check is reached.
  joomlaPlaygroundReplacementProject() { return 0; }
}

@test "storage rejects unset interpolation from successful Compose without exposing native diagnostics" {
  storage_render_fixture
  local diagnostic
  for diagnostic in \
    'WARN[0000] The "VDM_PROJECT_PATH" variable is not set. Defaulting to a blank string.' \
    'time="now" level=warning msg="The \"VDM_PROJECT_PATH\" variable is not set. Defaulting to a blank string."'; do
    printf '%s\n%s\n%s\n' "$diagnostic" "$diagnostic" 'native diagnostic: fixture-secret' > "$SANDBOX/diagnostic"
    run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
    assert_failure
    assert_output_contains "Cannot verify storage for $site using $directory/.env"
    assert_output_contains 'Compose storage variables are unset (VDM_PROJECT_PATH).'
    refute_output_contains 'fixture-secret'
    refute_output_contains 'Defaulting to a blank string'
    refute_output_contains 'services'
  done
}

@test "storage rejects native Compose failure without printing configuration or secrets" {
  storage_render_fixture
  echo 42 > "$SANDBOX/render-status"
  printf 'invalid field with fixture-secret\n' > "$SANDBOX/diagnostic"
  run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
  assert_failure
  assert_output_contains "Cannot verify storage for $site using $directory/.env"
  assert_output_contains 'Compose configuration could not be rendered.'
  refute_output_contains 'fixture-secret'
}

@test "storage returns valid facts without replaying unrelated obsolete version warnings" {
  storage_render_fixture
  printf 'WARN[0000] %s: the attribute `version` is obsolete, it will be ignored\n' "$compose" > "$SANDBOX/diagnostic"
  run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
  assert_success
  assert_equal "$output" "$(cat "$SANDBOX/model.json")"
  refute_output_contains 'obsolete'
}

@test "replacement accepts unchanged native JSON without a final newline and rejects changed rendered storage" {
  storage_render_fixture
  local native
  native=$(cat "$SANDBOX/model.json")
  printf '%s' "$native" > "$SANDBOX/model.json"
  storage_original_snapshot
  # Native Compose can omit this newline; the saved validated model adds one.
  assert_equal "$(tail -c 1 "$SANDBOX/model.json")" '}'
  run cmp -s "$SANDBOX/model.json" "$original_work/rendered.json"
  assert_failure
  run joomlaPlaygroundCheckOriginalSite "$site" "$original_work" "$compose" "$directory/.env" "$original_digest" disabled '' alpha
  assert_success
  assert_equal "$output" ''
  cmp "$original_work/rendered.json" "$original_work/current-model.json"

  joomlaSiteJSON '.services.web.volumes[0].source += "/changed"' < "$SANDBOX/model.json" > "$SANDBOX/changed.json"
  mv "$SANDBOX/changed.json" "$SANDBOX/model.json"
  run joomlaPlaygroundCheckOriginalSite "$site" "$original_work" "$compose" "$directory/.env" "$original_digest" disabled '' alpha
  assert_failure
  assert_output_contains 'The original Compose settings or site registration changed during deployment.'
}

@test "storage rejects malformed JSON and unresolved mount identities" {
  storage_render_fixture
  local model
  for model in \
    'invalid fixture-secret JSON' \
    '{"services":null}' \
    '{"services":{"web":{"volumes":[{"type":"bind","source":"","target":"/data"}]}}}' \
    '{"services":{"web":{"volumes":[{"type":"volume","source":"missing","target":"/data"}]}}}' \
    '{"services":{"web":{"volumes":[{"type":"volume","source":"data","target":"/data"}]}},"volumes":{"data":{"name":""}}}'; do
    printf '%s\n' "$model" > "$SANDBOX/model.json"
    run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
    assert_failure
    assert_output_contains "Cannot verify storage for $site using $directory/.env"
    assert_output_contains 'Compose returned incomplete storage information.'
    refute_output_contains 'fixture-secret'
  done
}

@test "storage ignores missing variables unrelated to project or storage identity" {
  storage_render_fixture
  printf 'WARN The "OPTIONAL_UNRELATED_SETTING" variable is not set. Defaulting to a blank string.\n' > "$SANDBOX/diagnostic"
  joomlaSiteJSON '.services.web.environment.OPTIONAL="${OPTIONAL_UNRELATED_SETTING}"' \
    < "$SANDBOX/unexpanded.json" > "$SANDBOX/next.json"
  mv "$SANDBOX/next.json" "$SANDBOX/unexpanded.json"
  run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
  assert_success
  assert_equal "$output" "$(cat "$SANDBOX/model.json")"
  refute_output_contains 'variable is not set'
}

@test "anonymous configured volumes do not prevent checking concrete storage ownership" {
  storage_render_fixture
  joomlaSiteJSON '.services.web.volumes += [{type:"volume",target:"/cache"}]' \
    < "$SANDBOX/model.json" > "$SANDBOX/anonymous.json"
  mv "$SANDBOX/anonymous.json" "$SANDBOX/model.json"
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_success
  assert_equal "$output" ''
  assert_command '^docker ps -aq$'
}

@test "persistence conversion refuses a configured same-project mount at another target" {
  storage_render_fixture
  joomlaSiteJSON '.services.worker={image:"busybox:latest",volumes:[
    .services.web.volumes[0] | .target="/srv/application"]}' \
    < "$SANDBOX/model.json" > "$SANDBOX/aliases.json"
  mv "$SANDBOX/aliases.json" "$SANDBOX/model.json"

  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains 'Storage is shared or overlaps another mount'
}

@test "persistence conversion refuses an actual same-project mount at another target" {
  storage_render_fixture
  joomlaSiteJSON -nc --arg source "$VDM_PROJECT_PATH/alpha/joomla" '[
    {Id:"own-web",Mounts:[{Type:"bind",Source:$source,Destination:"/var/www/html"}]},
    {Id:"own-worker",Mounts:[{Type:"bind",Source:$source,Destination:"/srv/application"}]}
  ]' > "$SANDBOX/containers.json"
  docker() {
    case "$1 $2" in
      'ps -aq') printf 'own-web\nown-worker\n';;
      'inspect own-web') cat "$SANDBOX/containers.json";;
      *) return 99;;
    esac
  }
  joomlaSiteCompose() { printf 'own-web\nown-worker\n'; }

  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains 'Another container shares this storage.'
}

@test "persistence conversion refuses an exact store declared by a different project" {
  storage_render_fixture
  local other="$VDM_REPO_PATH/joomla/available/neighbor.example.test"
  mkdir "$other"
  cp "$compose" "$other/docker-compose.yml"
  cp "$directory/.env" "$other/.env"
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains 'Storage is shared or overlaps another mount (neighbor.example.test)'
}

@test "storage inventory and inspect failures still prevent a change" {
  storage_render_fixture
  fail_command docker-ps 19
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  rm "$STUB_DIR/fail/docker-ps"
  running_containers foreign-container
  fail_command docker-inspect 23
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_command '^docker inspect foreign-container$'
}

@test "actual foreign container mounts remain part of the ownership check" {
  storage_render_fixture
  joomlaSiteJSON -nc --arg source "$VDM_PROJECT_PATH/alpha/joomla" \
    '[{Id:"foreign-container",Mounts:[{Type:"bind",Source:$source,Destination:"/foreign"}]}]' > "$SANDBOX/containers.json"
  docker() {
    case "$1 $2" in
      'ps -aq') printf 'foreign-container\n';;
      'inspect foreign-container') cat "$SANDBOX/containers.json";;
      'compose --env-file') return 0;;
      *) return 99;;
    esac
  }
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains 'Another container shares this storage.'
}

@test "real Compose original-state checks accept an unchanged model and reject a changed external service environment" {
  storage_real_compose
  cat > "$compose" <<'YAML'
services:
  web:
    image: busybox:latest
    env_file: service.env
    volumes:
      - "${VDM_PROJECT_PATH}/alpha/joomla:/var/www/html"
YAML
  printf 'DEPLOYMENT_MARKER=original\n' > "$directory/service.env"
  storage_original_snapshot
  run joomlaPlaygroundCheckOriginalSite "$site" "$original_work" "$compose" "$directory/.env" "$original_digest" disabled '' alpha
  assert_success
  assert_equal "$output" ''
  cmp "$original_work/rendered.json" "$original_work/current-model.json"

  # A dependency changes while the checked Compose and interpolation files
  # remain identical. Only comparing the rendered model catches this edit.
  printf 'DEPLOYMENT_MARKER=changed\n' > "$directory/service.env"
  cmp "$original_work/initial-compose" "$compose"
  assert_equal "$(migrationArchiveDigest "$directory/.env")" "$original_digest"
  run joomlaPlaygroundCheckOriginalSite "$site" "$original_work" "$compose" "$directory/.env" "$original_digest" disabled '' alpha
  assert_failure
  assert_output_contains 'The original Compose settings or site registration changed during deployment.'
  assert_equal "$(joomlaSiteJSON -r '.services.web.environment.DEPLOYMENT_MARKER' < "$original_work/current-model.json")" changed
}

@test "persistence conversion refuses an incomplete stopped neighbor environment with real Compose" {
  storage_real_compose
  local other=neighbor.example.test neighbor="$VDM_REPO_PATH/joomla/available/neighbor.example.test"
  mkdir "$neighbor"
  cp "$compose" "$neighbor/docker-compose.yml"
  printf 'VDM_UNUSED=kept\n' > "$neighbor/.env"
  cp "$neighbor/.env" "$SANDBOX/neighbor.env"
  cp "$neighbor/docker-compose.yml" "$SANDBOX/neighbor.yml"
  # The shared file and exported host variable are populated; only the
  # neighboring site's overriding file is incomplete. No containers exist.
  [ ! -e "$VDM_REPO_PATH/joomla/enabled/$other" ]
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains "Cannot verify storage for $other using $neighbor/.env"
  assert_output_contains 'Compose storage variables are unset (VDM_PROJECT_PATH).'
  refute_output_contains 'Defaulting to a blank string'
  refute_command '^docker ps '
  cmp "$neighbor/.env" "$SANDBOX/neighbor.env"
  cmp "$neighbor/docker-compose.yml" "$SANDBOX/neighbor.yml"
}

@test "real Compose refuses an explicitly empty required project base" {
  storage_real_compose
  printf 'VDM_PROJECT_PATH=\n' > "$directory/.env"
  run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
  assert_failure
  assert_output_contains 'VDM_PROJECT_PATH is empty but is required by a storage path.'
  assert_output_contains "$directory/.env"
}

@test "real Compose accepts explicit path defaults and escaped dollar literals" {
  storage_real_compose
  printf 'VDM_PROJECT_PATH=\n' > "$directory/.env"
  local host source expected
  host=$(joomlaWebHostPath "$VDM_PROJECT_PATH")
  for source in "$host/"'${VDM_PROJECT_PATH:-fallback}/files' "$host/"'$${VDM_PROJECT_PATH}/files'; do
    joomlaSiteJSON -n --arg source "$source" '{services:{web:{image:"busybox:latest",
      volumes:[{type:"bind",source:$source,target:"/data"}]}}}' > "$compose"
    run joomlaStorageComposeModel "$site" "$directory/.env" "$compose"
    assert_success
    if [[ "$source" == *':-fallback}'* ]]; then expected="$host/fallback/files"
    else expected="$host/"'${VDM_PROJECT_PATH}/files'; fi
    assert_equal "$(joomlaSiteJSON -r '.services.web.volumes[0].source | gsub("\\$\\$";"$")' <<< "$output")" "$expected"
  done
}

@test "configured stopped sites are checked again when their mounts change" {
  storage_real_compose
  local neighbor="$VDM_REPO_PATH/joomla/available/neighbor.example.test" host
  mkdir "$neighbor"
  cp "$directory/.env" "$neighbor/.env"
  host=$(joomlaWebHostPath "$VDM_PROJECT_PATH/neighbor/joomla")
  joomlaSiteJSON -n --arg source "$host" '{version:"3.8",services:{web:{image:"busybox:latest",
    volumes:[{type:"bind",source:$source,target:"/var/www/html"},{type:"volume",target:"/cache"}]}}}' > "$neighbor/docker-compose.yml"
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_success
  assert_equal "$output" ''
  cp "$compose" "$neighbor/docker-compose.yml"
  run joomlaPersistenceCheckShared "$site" bind "$VDM_PROJECT_PATH/alpha/joomla" /var/www/html
  assert_failure
  assert_output_contains 'Storage is shared or overlaps another mount (neighbor.example.test)'
}
