#!/usr/bin/env bats
# shellcheck disable=SC2034,SC2317,SC2016
load ../helpers/common

setup() {
  octojoom_setup
  TMPDIR="$SANDBOX/tmp"
  mkdir -p "$TMPDIR"
  export TMPDIR
}

render_progress() {
  actionProgressCanRender() { return 0; }
  actionProgressDialog() {
    printf 'opened\n' >>"$SANDBOX/renderer"
    cat >>"$SANDBOX/frames"
    printf 'closed\n' >>"$SANDBOX/renderer"
  }
}

@test "progress preserves stdout bytes, stderr, arguments, and failure status" {
  render_progress
  task() {
    printf '<%s>' "$@"
    printf 'The requested port is already in use.\n' >&2
    return 21
  }
  run runActionProgress 'Connection' 'Starting...' task 'two words' '' 'literal $HOME'
  assert_status 21
  [[ "$output" == *'<two words><><literal $HOME>'* ]]
  [[ "$output" == *'The requested port is already in use.'* ]]
  [[ "$output" != *'XXX'* ]]
  if [ -f "$SANDBOX/frames" ]; then refute_file_contains "$SANDBOX/frames" 'Completed.'; fi
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "progress keeps stdout separate from diagnostics and gauge frames" {
  render_progress
  task() { printf 'https://alpha.test'; printf 'Certificate generated.\n' >&2; sleep 0.3; }
  runActionProgress Connection Starting task >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
  assert_equal "$(cat "$SANDBOX/stdout")" 'https://alpha.test'
  assert_equal "$(cat "$SANDBOX/stderr")" 'Certificate generated.'
  assert_file_contains "$SANDBOX/frames" 'Completed.'
  assert_file_contains "$SANDBOX/frames" '100'
  [ "$(wc -c <"$SANDBOX/stdout" | tr -d ' ')" = 18 ]
}

@test "progress heartbeat holds the actual stage instead of inventing percentages" {
  render_progress
  task() { actionProgressStep 42 'Waiting for the HTTPS route'; sleep 1.3; }
  run runActionProgress Connection Starting task
  assert_success
  assert_file_contains "$SANDBOX/frames" 'Waiting for the HTTPS route'
  assert_file_contains "$SANDBOX/frames" 'Elapsed: 1s.'
  run awk '/^[0-9]+$/ && $0 != 0 && $0 != 42 && $0 != 100 { bad=1 } END { exit bad }' "$SANDBOX/frames"
  assert_success
}

@test "nested progress keeps a single renderer and outer stage" {
  render_progress
  inner() { sleep 0.3; printf 'done'; }
  task() { actionProgressStep 65 'Starting site containers'; runActionProgress Inner 'Wrong stage' inner; }
  run runActionProgress Outer Starting task
  assert_success
  assert_equal "$output" 'done'
  assert_equal "$(cat "$SANDBOX/renderer")" $'opened\nclosed'
  assert_file_contains "$SANDBOX/frames" 'Starting site containers'
  refute_file_contains "$SANDBOX/frames" 'Wrong stage'
}

@test "prompt pause releases the gauge before acknowledging and resumes afterward" {
  render_progress
  task() {
    sleep 0.3
    ( actionProgressPause )
    [ "$(tail -n 1 "$SANDBOX/renderer")" = closed ] || return 41
    local before
    before=$(wc -c <"$SANDBOX/frames")
    sleep 0.3
    [ "$(wc -c <"$SANDBOX/frames")" = "$before" ] || return 42
    actionProgressStep 75 'Installing certificates'
    ( actionProgressResume )
    sleep 0.3
  }
  run runActionProgress Connection Starting task
  assert_success
  assert_equal "$(cat "$SANDBOX/renderer")" $'opened\nclosed\nopened\nclosed'
  assert_file_contains "$SANDBOX/frames" 'Installing certificates'
}

@test "nested prompts do not resume the gauge until the outer prompt finishes" {
  render_progress
  task() {
    sleep 0.3
    actionProgressPause
    ( actionProgressPause; actionProgressResume )
    [ -f "$OCTOJOOM_PROGRESS_DIR/pause" ] || return 41
    sleep 0.3
    [ "$(tail -n 1 "$SANDBOX/renderer")" = closed ] || return 42
    actionProgressResume
    actionProgressStep 90 'Checking the finished route'
    sleep 0.3
  }
  run runActionProgress Connection Starting task
  assert_success
  assert_equal "$(cat "$SANDBOX/renderer")" $'opened\nclosed\nopened\nclosed'
  assert_file_contains "$SANDBOX/frames" 'Checking the finished route'
}

@test "temporary diagnostics are private and removed after failure" {
  skip_on_windows 'Windows does not expose POSIX file modes'
  render_progress
  task() {
    printf '%s %s\n' "$(file_mode "$OCTOJOOM_PROGRESS_DIR")" "$(file_mode "$OCTOJOOM_PROGRESS_DIR/diagnostics")" >"$SANDBOX/modes"
    return 7
  }
  run runActionProgress Connection Starting task
  assert_status 7
  assert_equal "$(cat "$SANDBOX/modes")" '700 600'
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "termination removes the renderer and private work directory" {
  render_progress
  task() {
    jobs -p >"$SANDBOX/children"
    sleep 0.3
    kill -TERM "$BASHPID"
  }
  run runActionProgress Connection Starting task
  assert_status 143
  local child
  while IFS= read -r child; do ! kill -0 "$child" 2>/dev/null; done <"$SANDBOX/children"
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
  refute_file_contains "$SANDBOX/frames" 'Completed.'
}

@test "renderer exit does not lose the foreground operation or hang a prompt" {
  render_progress
  actionProgressDialog() { return 0; }
  task() { sleep 0.4; actionProgressPause; actionProgressResume; printf 'operation finished'; }
  run runActionProgress Connection Starting task
  assert_success
  [[ "$output" == *'operation finished'* ]]
}

@test "no terminal and CLI output modes preserve command behavior without rendering" {
  task() { caller_value=changed; printf 'result'; return 9; }
  actionProgressRender() { touch "$SANDBOX/unexpected-renderer"; }
  local setting
  for setting in OCTOJOOM_NON_INTERACTIVE OCTOJOOM_NO_PROGRESS OCTOJOOM_QUIET; do
    printf -v "$setting" true
    run runActionProgress Connection Starting task
    assert_status 9
    assert_equal "$output" result
    unset "$setting"
  done
  OCTOJOOM_OUTPUT=json
  run runActionProgress Connection Starting task
  assert_status 9
  assert_equal "$output" result
  unset OCTOJOOM_OUTPUT
  local result=0
  runActionProgress Connection Starting task >/dev/null || result=$?
  assert_equal "$result" 9
  assert_equal "$caller_value" changed
  refute_file_exists "$SANDBOX/unexpected-renderer"
}

@test "termination preserves diagnostics before removing private logs" {
  render_progress
  task() {
    printf 'Recovery: original configuration restored.\n' >&2
    kill -TERM "$BASHPID"
  }
  run runActionProgress Connection Starting task
  assert_status 143
  [[ "$output" == *'Recovery: original configuration restored.'* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "cancellation cleanup does not depend on the renderer receiving a signal" {
  render_progress
  # A signal may arrive during renderer startup. Its stop marker must also
  # terminate the render loop, even when the signal itself has no effect.
  kill() { return 0; }
  task() {
    printf 'Recovery completed.\n' >&2
    builtin kill -TERM "$BASHPID"
  }
  run runActionProgress Connection Starting task
  assert_status 143
  [[ "$output" == *'Recovery completed.'* ]]
  [ -z "$(find "$TMPDIR" -mindepth 1 -print)" ]
}

@test "stage text is on stderr only and respects quiet JSON and no-progress" {
  actionProgressStep 08 'Checking the proxy' >"$SANDBOX/stdout" 2>"$SANDBOX/stderr"
  [ ! -s "$SANDBOX/stdout" ]
  assert_file_contains "$SANDBOX/stderr" 'Checking the proxy'
  OCTOJOOM_OUTPUT=json run actionProgressStep 12 hidden
  assert_success
  assert_equal "$output" ''
  OCTOJOOM_QUIET=true run actionProgressStep 12 hidden
  assert_success
  assert_equal "$output" ''
  OCTOJOOM_NO_PROGRESS=true run actionProgressStep 12 hidden
  assert_success
  assert_equal "$output" ''
}

@test "sudo uses cached authentication without pausing an active gauge" {
  OCTOJOOM_PROGRESS_DIR="$SANDBOX/active"
  mkdir "$OCTOJOOM_PROGRESS_DIR"
  sudo() { printf '%s\n' "$*" >>"$SANDBOX/sudo"; }
  actionProgressPause() { return 81; }
  run cliSudo cp 'two words' destination
  assert_success
  assert_equal "$(cat "$SANDBOX/sudo")" $'-n -v\n-n cp two words destination'
}

@test "legacy progress compatibility reports elapsed time without simulated percentages" {
  local checks=0
  inProgress() { checks=$((checks + 1)); [ "$checks" -lt 3 ]; }
  sleep() { :; }
  whiptail() { cat; }
  run showProgress 'Copying files' 'File copy'
  assert_success
  [[ "$output" == *'Elapsed:'* ]]
  [[ "$output" == *'Operation finished.'* ]]
  printf '%s\n' "$output" >"$SANDBOX/legacy-frames"
  run awk '/^[0-9]+$/ && $0 != 0 && $0 != 100 { bad=1 } END { exit bad }' "$SANDBOX/legacy-frames"
  assert_success
}
