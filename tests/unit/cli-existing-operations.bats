#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  octojoom_config
  VDM_CONTAINER_TYPE=joomla
  OCTOJOOM_NON_INTERACTIVE=true
}

@test "headless clone rejects incomplete destination before creating its lock" {
  make_joomla_container source SOURCE source
  VDM_TASK=clone VDM_CONTAINER=source.vdm.dev
  run cloneJoomlaContainer
  assert_status 17
  refute_file_exists "$VDM_REPO_PATH/joomla/.clone.lock"
}

@test "headless clone preserves a missing source error instead of reporting success" {
  VDM_TASK=clone VDM_CONTAINER=missing.example.test VDM_KEY=target VDM_DOMAIN=example.test
  mkdir -p "$VDM_REPO_PATH/joomla"
  run cloneJoomlaContainer
  assert_failure
  refute_file_exists "$VDM_PROJECT_PATH/target"
}

@test "headless reset removes only the explicitly selected stopped data directory" {
  make_joomla_container source SOURCE source
  mkdir -p "$VDM_PROJECT_PATH/source/joomla" "$VDM_PROJECT_PATH/source/db"
  printf keep > "$VDM_PROJECT_PATH/source/db/marker"
  VDM_TASK=reset VDM_PROJECT=source VDM_VOLUME=web
  run joomla__TRuST__reset
  assert_success
  refute_file_exists "$VDM_PROJECT_PATH/source/joomla"
  assert_file_contains "$VDM_PROJECT_PATH/source/db/marker" keep
  [ ! -s "$STUB_DIR/dialogs.log" ]
}

@test "headless reset requires the precise data target even when yes is supplied" {
  mkdir -p "$VDM_PROJECT_PATH/source/joomla"
  VDM_TASK=reset VDM_PROJECT=source VDM_FORCE=true
  run joomla__TRuST__reset
  assert_status 17
  assert_file_exists "$VDM_PROJECT_PATH/source/joomla"
}

@test "headless project guard detects custom named containers using its bind directory" {
  mkdir -p "$VDM_PROJECT_PATH/source/joomla"
  docker() {
    case "$1" in
      ps) printf 'custom-container-id\n';;
      inspect) printf '%s\n' "$VDM_PROJECT_PATH/source/joomla";;
      *) return 1;;
    esac
  }
  run ensureProjectStopped source
  assert_failure
  assert_file_exists "$VDM_PROJECT_PATH/source/joomla"
}

@test "cold data operations reject a nested root without touching the source" {
  make_joomla_container source SOURCE source
  printf 'VDM_SOURCE_DOCROOT="site"\n' >> "$VDM_REPO_PATH/joomla/.env"
  run requireOriginalJoomlaDataLayout source.vdm.dev Clone
  assert_failure
  assert_output_contains 'nested document root'
  assert_file_exists "$VDM_REPO_PATH/joomla/available/source.vdm.dev/docker-compose.yml"
}

@test "headless SSH worker retains literal arguments and disables password prompts" {
  VDM_REMOTE=deploy@host.example.test
  ssh() { printf '%s\n' "$@"; }
  run remoteMigrationWorker "$VDM_REMOTE" true digest '/tmp/with spaces'
  assert_success
  assert_output_contains 'BatchMode=yes'
  refute_output_contains $'\n-t\n'
  assert_output_contains "'/tmp/with spaces'"
}
