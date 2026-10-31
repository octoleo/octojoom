#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
}

render_compose() {
  actionProgressCanRender() { return 0; }
  composeProgressCanCapture() { return 0; }
  actionProgressDialog() {
    printf '%s\n' "${OCTOJOOM_PROGRESS_MODE:-stages}" >> "$SANDBOX/modes"
    cat >> "$SANDBOX/frames"
  }
}

@test "interactive Compose executes lifecycle once and advances the native gauge without log replay" {
  render_compose
  docker() {
    printf '%s\n' "$*" >> "$SANDBOX/docker-calls"
    if [[ "$*" == *'config --services' ]]; then printf 'database\nwebsite\n'; return; fi
    printf ' Container database Creating\n'
    sleep 0.4
    printf ' Container database Started\n Container database Waiting\n Container database Waiting\n'
    sleep 0.4
    printf ' Container database Healthy\n Container website Started\n'
    sleep 0.4
  }
  run runComposeProgress 'a path/compose.yml' compose --file 'a path/compose.yml' up -d
  assert_success
  assert_equal "$output" ''
  assert_equal "$(cat "$SANDBOX/modes")" compose
  assert_equal "$(grep -c ' up -d$' "$SANDBOX/docker-calls")" 1
  assert_equal "$(grep -c ' config --services$' "$SANDBOX/docker-calls")" 1
  assert_file_contains "$SANDBOX/frames" 'Creating'
  assert_file_contains "$SANDBOX/frames" 'Waiting'
  assert_file_contains "$SANDBOX/frames" 'Healthy'
  grep -qxF 50 "$SANDBOX/frames"
  grep -qxF 90 "$SANDBOX/frames"
  assert_file_contains "$SANDBOX/frames" 'Completed.'
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "failed Compose retains native exit status and prints diagnostics once" {
  render_compose
  docker() {
    if [[ "$*" == *'config --services' ]]; then printf 'website\n'; return; fi
    printf ' Container website Starting\n'
    sleep 0.3
    printf 'Error response: port is already allocated\n' >&2
    return 23
  }
  run runComposeProgress compose.yml compose --file compose.yml up -d
  assert_status 23
  assert_equal "$(printf '%s\n' "$output" | grep -c 'port is already allocated')" 1
  refute_file_contains "$SANDBOX/frames" 'Completed.'
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "successful Compose warnings survive without replaying routine status" {
  render_compose
  docker() {
    if [[ "$*" == *'config --services' ]]; then printf 'website\n'; return; fi
    printf ' Container website Started\n'
    printf 'WARN[0000] an optional setting was ignored\n' >&2
    printf 'WARN[0000] an optional setting was ignored\n' >&2
    sleep 0.3
  }
  run runComposeProgress compose.yml compose --file compose.yml up -d
  assert_success
  assert_equal "$output" 'WARN[0000] an optional setting was ignored'
}

@test "Compose output consumers retain separate stdout stderr and command arguments" {
  render_compose
  composeProgressCanCapture() { return 1; }
  docker() { printf 'stdout bytes'; printf 'stderr bytes' >&2; return 9; }
  local result=0
  runComposeProgress compose.yml compose --file compose.yml stop > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || result=$?
  assert_equal "$result" 9
  assert_equal "$(cat "$SANDBOX/stdout")" 'stdout bytes'
  assert_equal "$(cat "$SANDBOX/stderr")" 'stderr bytes'
}

@test "nested Compose preserves its enclosing measured stage and single renderer" {
  render_compose
  docker() {
    if [[ "$*" == *'config --services' ]]; then printf 'website\n'; return; fi
    printf ' Container website Started\n'; sleep 0.4
  }
  task() {
    actionProgressStep 65 'Starting site containers'
    runComposeProgress compose.yml compose --file compose.yml up -d
  }
  run runActionProgress Outer Preparing task
  assert_success
  assert_equal "$(cat "$SANDBOX/modes")" stages
  assert_file_contains "$SANDBOX/frames" '65'
  assert_file_contains "$SANDBOX/frames" 'Starting site containers'
  assert_file_contains "$SANDBOX/frames" 'Container website Started'
  run ! grep -qxF 90 "$SANDBOX/frames"
}

@test "native summaries show each resource latest state and strip terminal controls" {
  OCTOJOOM_PROGRESS_DIR="$SANDBOX/progress"
  mkdir "$OCTOJOOM_PROGRESS_DIR"
  printf ' Container db Waiting\n Container db Waiting\n Container db Healthy\n Container db Healthy\n Container web Starting\n Container web Started\n\033[31mbad control\033[0m\n' > "$OCTOJOOM_PROGRESS_DIR/compose-output"
  run actionProgressLogSummary
  assert_success
  assert_equal "$output" $'  Container db Healthy\n  Container web Started\n  bad control'
}

@test "interrupted Compose retains diagnostics and removes its private session" {
  render_compose
  docker() {
    if [[ "$*" == *'config --services' ]]; then printf 'database\n'; return; fi
    printf 'Container database Waiting\n' >&2
    kill -TERM "$BASHPID"
  }
  run runComposeProgress "$SANDBOX/docker-compose.yml" compose up -d
  assert_status 143
  assert_equal "$(printf '%s\n' "$output" | grep -c 'Container database Waiting')" 1
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "stop and down progress count unique completed containers not repeated messages" {
  OCTOJOOM_PROGRESS_DIR="$SANDBOX/progress"
  mkdir "$OCTOJOOM_PROGRESS_DIR"
  printf '2\n' > "$OCTOJOOM_PROGRESS_DIR/compose-count"
  printf 'Container db Stopped\nContainer db Stopped\nContainer web Stopping\n' > "$OCTOJOOM_PROGRESS_DIR/compose-output"
  OCTOJOOM_COMPOSE_OPERATION=stop
  run actionProgressComposePercent
  assert_success
  assert_equal "$output" 50
  OCTOJOOM_COMPOSE_OPERATION=down
  run actionProgressComposePercent
  assert_equal "$output" 10
  printf 'Container db Removed\nContainer web Removed\n' >> "$OCTOJOOM_PROGRESS_DIR/compose-output"
  run actionProgressComposePercent
  assert_equal "$output" 90
}

@test "failed configuration probe does not retry or suppress the requested operation" {
  render_compose
  docker() {
    printf '%s\n' "$*" >> "$SANDBOX/docker-calls"
    if [[ "$*" == *'config --services' ]]; then return 18; fi
    printf 'native lifecycle failure\n' >&2
    return 27
  }
  run runComposeProgress '/path with spaces/compose.yml' compose --env-file '/private env' --file '/path with spaces/compose.yml' up -d
  assert_status 27
  assert_equal "$output" 'native lifecycle failure'
  assert_equal "$(grep -c ' up -d$' "$SANDBOX/docker-calls")" 1
}
