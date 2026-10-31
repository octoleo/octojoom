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

@test "interactive Compose executes once with live output and no successful log replay" {
  render_compose
  docker() {
    printf '%s\n' "$*" >> "$SANDBOX/docker-calls"
    printf ' Container database Creating\n'
    sleep 0.4
    printf ' Container database Waiting\n Container database Waiting\n'
    sleep 0.4
    printf ' Container database Healthy\n Container website Started\n'
    sleep 0.4
  }
  run runComposeProgress 'a path/compose.yml' compose --file 'a path/compose.yml' up -d
  assert_success
  assert_equal "$output" ''
  assert_equal "$(cat "$SANDBOX/modes")" activity
  assert_equal "$(wc -l < "$SANDBOX/docker-calls" | tr -d ' ')" 1
  assert_file_contains "$SANDBOX/frames" 'Creating'
  assert_file_contains "$SANDBOX/frames" 'Waiting'
  assert_file_contains "$SANDBOX/frames" 'Healthy'
  assert_file_contains "$SANDBOX/frames" 'Completed.'
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "failed Compose retains its native exit status and prints diagnostics once" {
  render_compose
  docker() {
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

@test "successful Compose warnings are retained without replaying routine status" {
  render_compose
  docker() {
    printf ' Container website Started\n'
    printf 'WARN[0000] an optional setting was ignored\n' >&2
    printf 'WARN[0000] an optional setting was ignored\n' >&2
    sleep 0.3
  }
  run runComposeProgress compose.yml compose --file compose.yml up -d
  assert_success
  assert_equal "$output" 'WARN[0000] an optional setting was ignored'
}

@test "Compose output consumers retain separate stdout and stderr" {
  render_compose
  composeProgressCanCapture() { return 1; }
  docker() { printf 'stdout bytes'; printf 'stderr bytes' >&2; return 9; }
  local result=0
  runComposeProgress compose.yml compose --file compose.yml stop > "$SANDBOX/stdout" 2> "$SANDBOX/stderr" || result=$?
  assert_equal "$result" 9
  assert_equal "$(cat "$SANDBOX/stdout")" 'stdout bytes'
  assert_equal "$(cat "$SANDBOX/stderr")" 'stderr bytes'
}

@test "Compose activity preserves an enclosing operation's real stage and single renderer" {
  render_compose
  docker() { printf ' Container website Starting\n'; sleep 0.4; }
  task() {
    actionProgressStep 65 'Starting site containers'
    runComposeProgress compose.yml compose --file compose.yml up -d
  }
  run runActionProgress Outer Preparing task
  assert_success
  assert_equal "$(cat "$SANDBOX/modes")" stages
  assert_file_contains "$SANDBOX/frames" '65'
  assert_file_contains "$SANDBOX/frames" 'Starting site containers'
  assert_file_contains "$SANDBOX/frames" 'Container website Starting'
}

@test "activity summaries show each resource's latest state and remove control characters" {
  OCTOJOOM_PROGRESS_DIR="$SANDBOX/progress"
  mkdir "$OCTOJOOM_PROGRESS_DIR"
  printf ' Container db Waiting\n Container db Waiting\n Container db Healthy\n Container db Healthy\n Container web Starting\n Container web Started\n\033bad control\n' > "$OCTOJOOM_PROGRESS_DIR/compose-output"
  run actionProgressLogSummary
  assert_success
  assert_equal "$output" $'  Container db Healthy\n  Container web Started\n  bad control'
}

@test "interrupted Compose retains captured diagnostics and removes its private session" {
  render_compose
  docker() {
    printf 'Container database Waiting\n' >&2
    kill -TERM "$BASHPID"
  }
  run runComposeProgress "$SANDBOX/docker-compose.yml" compose up -d
  assert_status 143
  assert_equal "$(printf '%s\n' "$output" | grep -c 'Container database Waiting')" 1
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}
