#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2154,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  MENU_TEST_ROWS=24 MENU_TEST_COLUMNS=80
  MENU_TEST_ACTIONS=(back 'Return to website list' start 'Start website services' stop 'Stop website services')
  : > "$SANDBOX/keys"
}

tput() {
  case "$1" in
    lines) printf '%s\n' "$MENU_TEST_ROWS" ;;
    cols) printf '%s\n' "$MENU_TEST_COLUMNS" ;;
    *) return 0 ;;
  esac
}

script_keys() {
  printf '%s\n' "$@" > "$SANDBOX/keys"
  readJoomlaWebsiteKey() {
    local answer
    IFS= read -r answer < "$SANDBOX/keys" || return 2
    tail -n +2 "$SANDBOX/keys" > "$SANDBOX/keys.next"
    mv "$SANDBOX/keys.next" "$SANDBOX/keys"
    printf '%s\n' "$answer"
  }
  joomlaWebsiteMenuFrame() {
    printf '%s|%s|%s\n' "$menu_focus" "$menu_selected" "$menu_info_top" >> "$SANDBOX/frames"
  }
}

@test "website actions have initial focus and Down Enter selects the next action" {
  script_keys down enter
  run joomlaWebsiteMenuLoop first.vdm.dev 'Website: first.vdm.dev' 1 "${MENU_TEST_ACTIONS[@]}"
  assert_success
  assert_equal "$output" start
  assert_equal "$(head -n 1 "$SANDBOX/frames")" 'actions|0|0'
  assert_equal "$(tail -n 1 "$SANDBOX/frames")" 'actions|1|0'
}

@test "Tab scrolls information independently and returns to the selected action" {
  local details
  details=$(printf 'Information line %s\n' {1..40})
  script_keys down tab down tab enter
  run joomlaWebsiteMenuLoop first.vdm.dev "$details" 1 "${MENU_TEST_ACTIONS[@]}"
  assert_success
  assert_equal "$output" start
  assert_file_contains "$SANDBOX/frames" 'information|1|1'
  assert_equal "$(tail -n 1 "$SANDBOX/frames")" 'actions|1|1'
}

@test "Enter in information returns focus without executing a website action" {
  script_keys down tab enter down enter
  run joomlaWebsiteMenuLoop first.vdm.dev 'Website information' 1 "${MENU_TEST_ACTIONS[@]}"
  assert_success
  assert_equal "$output" stop
  assert_file_contains "$SANDBOX/frames" 'information|1|0'
}

@test "Escape and end of input return without selecting an action" {
  script_keys escape
  run joomlaWebsiteMenuLoop first.vdm.dev 'Website information' 1 "${MENU_TEST_ACTIONS[@]}"
  assert_status 255
  assert_equal "$output" ''
  script_keys cancel
  run joomlaWebsiteMenuLoop first.vdm.dev 'Website information' 1 "${MENU_TEST_ACTIONS[@]}"
  assert_status 1
  assert_equal "$output" ''
}

@test "Home End and page keys stay within their focused pane" {
  local details
  details=$(printf 'Information line %s\n' {1..40})
  script_keys end pageup home tab end pagedown tab enter
  run joomlaWebsiteMenuLoop first.vdm.dev "$details" 1 "${MENU_TEST_ACTIONS[@]}"
  assert_success
  assert_equal "$output" back
  assert_file_contains "$SANDBOX/frames" 'actions|2|0'
  assert_file_contains "$SANDBOX/frames" 'information|0|34'
}

@test "terminal key decoding preserves the next key and supports Shift Tab" {
  local fd
  printf '\033[B\t\033[Z\n\033' > "$SANDBOX/key-bytes"
  exec {fd}< "$SANDBOX/key-bytes"
  run readJoomlaWebsiteKey "$fd"
  assert_success
  assert_equal "$output" down
  run readJoomlaWebsiteKey "$fd"
  assert_equal "$output" tab
  run readJoomlaWebsiteKey "$fd"
  assert_equal "$output" tab
  run readJoomlaWebsiteKey "$fd"
  assert_equal "$output" enter
  run readJoomlaWebsiteKey "$fd"
  assert_equal "$output" escape
  exec {fd}<&-
}

@test "terminal panel text preserves literal content and removes escape controls" {
  literal_panel_text() { printf '%b' 'literal $HOME; \033danger\tvalue\n' | terminalPanelText; }
  run literal_panel_text
  assert_success
  assert_equal "$output" 'literal $HOME; danger value'
}
