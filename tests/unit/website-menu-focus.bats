#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
}

@test "focused website menu preserves native fallback selection and cancellation statuses" {
  answers enable '<cancel>' '<esc>'
  run joomlaWebsiteMenuFocused --menu 'Website information' 20 80 3 --scrolltext back Back enable Enable
  assert_success
  assert_equal "$output" enable
  run joomlaWebsiteMenuFocused --menu 'Website information' 20 80 3 --scrolltext back Back enable Enable
  assert_status 1
  assert_equal "$output" ''
  run joomlaWebsiteMenuFocused --menu 'Website information' 20 80 3 --scrolltext back Back enable Enable
  assert_status 255
  assert_equal "$output" ''
  assert_answers_used
}

@test "focus input waits for native initialization and prefixes exactly one Tab" {
  local work="$SANDBOX/focus" input_fd
  mkdir "$work"
  touch "$work/slave"
  printf '%s\n' "$work/slave" > "$work/tty"
  printf '\033[B\r\t' > "$work/keys"
  exec {input_fd}< "$work/keys"
  probe_focus_input() {
    # Keep mocks inside run's subprocess; do not replace Bats timeout cleanup.
    kill() { [ "$1" = -0 ]; }
    stty() {
      if [ -f "$work/initialized" ]; then printf '%s\n' '-icanon -echo'; else printf 'icanon -echo\n'; fi
    }
    sleep() { touch "$work/initialized"; }
    joomlaWebsiteMenuInput "$work" "$input_fd" 123
  }
  run probe_focus_input
  assert_success
  assert_equal "$output" $'\t\033[B\r\t'
  [ -f "$work/initialized" ]
  exec {input_fd}<&-
}

@test "a dialog which exits during initialization receives no injected key" {
  local work="$SANDBOX/focus"
  mkdir "$work"
  printf '255\n' > "$work/status"
  run joomlaWebsiteMenuInput "$work" 0 "$BASHPID"
  assert_success
  assert_equal "$output" ''
}

@test "website focus wrapper does not change the action list or default item" {
  joomlaWebsiteMenuFocused() { printf '%s\n' "$@" > "$SANDBOX/menu.args"; printf 'back\n'; }
  run showJoomlaWebsiteMenu first.example.test 'Complete website report' back Back enable Enable php-settings 'PHP settings'
  assert_success
  assert_equal "$output" back
  assert_file_contains "$SANDBOX/menu.args" '--scrolltext'
  assert_file_contains "$SANDBOX/menu.args" 'Complete website report'
  refute_file_contains "$SANDBOX/menu.args" '--default-item'
  assert_equal "$(tail -n 6 "$SANDBOX/menu.args")" $'back\nBack\nenable\nEnable\nphp-settings\nPHP settings'
}
