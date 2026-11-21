#!/usr/bin/env bats
# Each test sets up its own Compose model, host directories and Docker stub.
# shellcheck disable=SC2034,SC2030,SC2031,SC2016,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  site=store.example.test
  local available="$VDM_REPO_PATH/joomla/available/$site"
  mkdir -p "$available" "$SANDBOX/web" "$SANDBOX/data"
  : > "$available/docker-compose.yml"
  local web_path="$SANDBOX/web" db_path="$SANDBOX/data"
  if is_windows; then web_path=$(cygpath -am "$web_path"); db_path=$(cygpath -am "$db_path"); fi
  joomlaSiteJSON -n --arg web "$web_path" --arg db "$db_path" '{
    services:{app:{image:"vendor/runtime:old-apache",environment:{JOOMLA_DB_HOST:"data:3306",JOOMLA_ADMIN_PASSWORD:"private-marker"},
      volumes:[{type:"bind",source:$web,target:"/var/www/html"}]},
      data:{image:"mariadb:11",volumes:[{type:"bind",source:$db,target:"/var/lib/mysql"}]},
      other:{image:"postgres:16"}}}' > "$SANDBOX/model"
  summary='{"siteName":"Imported","joomlaVersion":"6.2.0","preferredPhpVersion":"8.4","fileBytes":1024,"databaseBytes":500}'
  unset DOCKER_CONTEXT DOCKER_HOST
  joomlaSiteCompose() {
    [ "$*" = "$site config --format json" ] || return 91
    cat "$SANDBOX/model"
  }
  docker() {
    printf '%s\n' "$*" >> "$SANDBOX/docker-calls"
    case "$1 $2" in
      'context inspect') echo 'unix:///var/run/docker.sock';;
      'volume inspect') echo '[{"Name":"existing","Driver":"local","Scope":"local","Options":{},"Mountpoint":"/inaccessible-docker-vm/octojoom"}]';;
      'image inspect') [ "$3" = vendor/runtime:6.2.0-php8.4-apache ];;
      *) return 91;;
    esac
  }
}

modify_model() {
  joomlaSiteJSON "$1" < "$SANDBOX/model" > "$SANDBOX/changed" && mv "$SANDBOX/changed" "$SANDBOX/model"
}

@test "Playground target preflight reads the connected engine, local space and an incoming runtime candidate" {
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_success
  joomlaSiteJSON -e '.targetPreflight | .databaseEngine=="mariadb" and .runtimeCandidate=="vendor/runtime:6.2.0-php8.4-apache" and .websiteStorage=="bind" and .websiteAvailableBytes >= 1024' <<< "$output"
  [[ "$output" != *private-marker* ]]
  assert_equal "$(awk '{print $1, $2}' "$SANDBOX/docker-calls")" $'context inspect\nimage inspect'
}

@test "Playground target preflight rejects external database services, PostgreSQL and unsupported mounts" {
  local change
  cp "$SANDBOX/model" "$SANDBOX/original"
  for change in '.services.app.environment.JOOMLA_DB_HOST="external"' '.services.data.image="postgres:16"' \
    '.services.data.volumes[0].read_only=true' '.services.data.volumes[0]|=(.type="volume"|.source="test") | .volumes.test={name:"existing",external:true}'; do
    cp "$SANDBOX/original" "$SANDBOX/model"
    modify_model "$change"
    run joomlaPlaygroundTargetPreflight "$site" "$summary"
    assert_failure
    assert_output_contains 'managed MariaDB or MySQL'
    [[ "$output" != *private-marker* ]]
  done
  refute_file_exists "$SANDBOX/docker-calls"
}

@test "Playground target preflight resolves local named volume metadata and identifies unknown capacity" {
  modify_model '.services.app.volumes[0]|=(.type="volume"|.source="web") | .volumes.web={name:"existing",driver:"local"}'
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_success
  joomlaSiteJSON -e '.targetPreflight | .websiteStorage=="volume" and .websiteAvailableBytes==null and (.spaceCheck|contains("unavailable"))' <<< "$output"
}

@test "Playground target preflight rejects a remote Docker endpoint and insufficient website capacity" {
  DOCKER_HOST='tcp://remote:2376'
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_failure
  assert_output_contains 'local Docker daemon'
  unset DOCKER_HOST
  joomlaPlaygroundFreeBytes() { echo 123; }
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_failure
  assert_output_contains 'insufficient space'
}

@test "Playground runtime metadata lookup isolates and removes its temporary tag cache" {
  docker() { return 1; }
  joomlaRuntimeTags() {
    [ "$VDM_SRC_PATH" != "$OCTOJOOM_HOME/.config/octojoom" ] || return 1
    printf '%s\n' "$VDM_SRC_PATH" > "$SANDBOX/cache-path"
    touch "$VDM_SRC_PATH/tags"
    printf '%s\n' '6.2.0-php8.4-apache' '6.2.1-php8.4-apache'
  }
  run joomlaPlaygroundRuntimeCandidate vendor/runtime:latest 6.2.0 8.4 apache
  assert_success
  assert_equal "$output" vendor/runtime:6.2.0-php8.4-apache
  [ ! -e "$(cat "$SANDBOX/cache-path")" ]
  run joomlaPlaygroundRuntimeCandidate vendor/runtime:latest 6.2.2 8.4 apache
  assert_failure
}

@test "Playground target preflight checks an exact nested document root and rejects overlapping storage" {
  getJoomlaComposeEnvKey() { echo SITE; }
  migrationReadEnvValue() {
    if [ "$2" = VDM_SITE_DOCROOT ]; then printf -v "$3" '%s' public; return 0; fi
    return 1
  }
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_failure
  assert_output_contains 'configured document root'
  mkdir -p "$SANDBOX/web/public"
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_success
  modify_model '.services.data.volumes[0].source=(.services.app.volumes[0].source+"/public")'
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_failure
  assert_output_contains 'overlap'
}

@test "Playground target preflight rejects a mount masking files inside the document root" {
  modify_model '.services.app.volumes += [{type:"volume",source:"extra",target:"/var/www/html/assets"}]'
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_failure
  assert_output_contains 'overlapping document-root mounts'
}

@test "Playground runtime chooses JoomEngine candidates by Joomla base label or qualified tag" {
  docker() { echo 'joomla:6.2.0-php8.4-apache'; }
  run joomlaPlaygroundRuntimeCandidate octoleo/joomengine:6.2.2-dev 6.2.0 8.4 apache
  assert_success
  assert_equal "$output" octoleo/joomengine:6.2.2-dev
  docker() { return 1; }
  joomlaRuntimeTags() { printf '%s\n' '6.2.0-php8.4-apache' '6.2.2-joomla6.2.0-php8.4-apache'; }
  run joomlaPlaygroundRuntimeCandidate octoleo/joomengine:latest 6.2.0 8.4 apache
  assert_success
  assert_equal "$output" octoleo/joomengine:6.2.2-joomla6.2.0-php8.4-apache
}

@test "Playground preflight reports unconfirmed runtime without mistaking archived PHP for Joomla's minimum" {
  summary=$(joomlaSiteJSON -c '.minimumPhpVersion="8.5.0"' <<< "$summary")
  run joomlaPlaygroundTargetPreflight "$site" "$summary"
  assert_success
  joomlaSiteJSON -e '.targetPreflight | .runtimeCandidate==null and (.runtimeCheck|contains("below"))' <<< "$output"
}
