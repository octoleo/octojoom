#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2034,SC2317
load ../helpers/common

setup() {
  octojoom_setup
  REAL_DOCKER=''
  export REAL_DOCKER
  LAYOUT_ROWS=43 LAYOUT_COLUMNS=190
  LAYOUT_ACTIONS=(back 'Return to website list')
  local index
  for index in {1..29}; do
    LAYOUT_ACTIONS+=("action${index}" "Website action ${index}")
  done
}

tput() {
  case "$1" in
    lines) printf '%s\n' "$LAYOUT_ROWS" ;;
    cols) printf '%s\n' "$LAYOUT_COLUMNS" ;;
    *) return 1 ;;
  esac
}

whiptail() {
  printf '%s\0' "$@" > "$SANDBOX/website-menu.args"
  command whiptail "$@"
}

# Preserve argument boundaries, including multiline text and paths with spaces.
read_website_menu() {
  local argument index
  local -a arguments=()
  while IFS= read -r -d '' argument; do arguments+=("$argument"); done < "$SANDBOX/website-menu.args"
  MENU_DETAILS='' MENU_HEIGHT='' MENU_WIDTH='' MENU_ROWS='' MENU_SCROLL=false MENU_HINT=''
  for ((index=0; index<${#arguments[@]}; index++)); do
    case "${arguments[index]}" in
      --menu)
        MENU_DETAILS="${arguments[index+1]}"
        MENU_HEIGHT="${arguments[index+2]}"
        MENU_WIDTH="${arguments[index+3]}"
        MENU_ROWS="${arguments[index+4]}"
        ;;
      --scrolltext) MENU_SCROLL=true ;;
      --backtitle) MENU_HINT="${arguments[index+1]}" ;;
    esac
  done
}

@test "website menu reserves visible actions and bounded information at large and small terminal sizes" {
  local dimensions information_rows
  for dimensions in '43 190' '37 168' '24 112' '24 80'; do
    read -r LAYOUT_ROWS LAYOUT_COLUMNS <<< "$dimensions"
    answers back
    run showJoomlaWebsiteMenu first.vdm.dev 'Website: first.vdm.dev' "${LAYOUT_ACTIONS[@]}"
    assert_success
    assert_equal "$output" back
    assert_answers_used
    read_website_menu
    [ "$MENU_HEIGHT" -gt 0 ] && [ "$MENU_HEIGHT" -le "$((LAYOUT_ROWS - 2))" ]
    [ "$MENU_WIDTH" -gt 0 ] && [ "$MENU_WIDTH" -le "$((LAYOUT_COLUMNS - 2))" ]
    [ "$MENU_WIDTH" -le 112 ]
    [ "$MENU_ROWS" -ge 8 ]
    information_rows=$((MENU_HEIGHT - MENU_ROWS - 7))
    [ "$information_rows" -ge 1 ] && [ "$information_rows" -le 10 ]
    assert_equal "$MENU_SCROLL" true
    [[ "$MENU_HINT" == *Tab* && "$MENU_HINT" == *Up/Down* ]]
  done
}

@test "long website reports and unbroken paths retain every character without reducing action space" {
  LAYOUT_ROWS=24 LAYOUT_COLUMNS=80
  local details short_height short_rows index
  details=$'Website: first.vdm.dev\nEnabled: enabled\nServices: running\n'
  details+="Compose: /a path with spaces/$(printf '%0300d' 0)/docker-compose.yml"
  details+=$'\nLiteral: $value; $(nothing); \\n; "quotes"\n'
  for index in {1..100}; do details+="Service ${index}: running"$'\n'; done
  details+='Last service: healthy'
  answers back back
  run showJoomlaWebsiteMenu first.vdm.dev 'Short report' "${LAYOUT_ACTIONS[@]}"
  assert_success
  read_website_menu
  short_height="$MENU_HEIGHT" short_rows="$MENU_ROWS"
  run showJoomlaWebsiteMenu first.vdm.dev "$details" "${LAYOUT_ACTIONS[@]}"
  assert_success
  read_website_menu
  assert_equal "$MENU_DETAILS" "$details"
  assert_equal "$MENU_HEIGHT" "$short_height"
  assert_equal "$MENU_ROWS" "$short_rows"
  assert_answers_used
}

@test "website menu uses safe positive dimensions when terminal sizing is unavailable or invalid" {
  local sizing
  for sizing in unavailable invalid; do
    if [ "$sizing" = unavailable ]; then
      tput() { return 1; }
    else
      tput() { printf 'not-a-size\n'; }
    fi
    answers back
    run showJoomlaWebsiteMenu first.vdm.dev 'Website: first.vdm.dev' "${LAYOUT_ACTIONS[@]}"
    assert_success
    read_website_menu
    [ "$MENU_HEIGHT" -gt 0 ] && [ "$MENU_HEIGHT" -le 24 ]
    [ "$MENU_WIDTH" -gt 0 ] && [ "$MENU_WIDTH" -le 112 ]
    [ "$MENU_ROWS" -ge 8 ]
    assert_answers_used
  done
}

@test "website menu refuses an unusably small terminal before opening whiptail" {
  local dimensions
  for dimensions in '11 190' '43 39'; do
    read -r LAYOUT_ROWS LAYOUT_COLUMNS <<< "$dimensions"
    run showJoomlaWebsiteMenu first.vdm.dev 'Website: first.vdm.dev' "${LAYOUT_ACTIONS[@]}"
    assert_failure
    assert_output_contains 'Enlarge the terminal'
    [ ! -e "$SANDBOX/website-menu.args" ]
  done
}

@test "website menu preserves cancel and Escape statuses without returning a selected action" {
  answers '<cancel>' '<esc>'
  run showJoomlaWebsiteMenu first.vdm.dev 'Website: first.vdm.dev' "${LAYOUT_ACTIONS[@]}"
  assert_status 1
  assert_equal "$output" ''
  run showJoomlaWebsiteMenu first.vdm.dev 'Website: first.vdm.dev' "${LAYOUT_ACTIONS[@]}"
  assert_status 255
  assert_equal "$output" ''
  assert_answers_used
}

@test "cancelling website details returns to the caller without dispatching an action" {
  make_joomla_container alpha ALPHA first
  runJoomlaSiteAction() { printf '%s\n' "$*" >> "$SANDBOX/unexpected-action"; }
  local answer
  for answer in '<cancel>' '<esc>'; do
    answers "$answer"
    run showJoomlaWebsiteInformation first.vdm.dev true
    assert_success
    assert_answers_used
    [ ! -e "$SANDBOX/unexpected-action" ]
    read_website_menu
    assert_equal "$MENU_SCROLL" true
    [[ "$MENU_DETAILS" == *'Website: first.vdm.dev'* ]]
  done
}
