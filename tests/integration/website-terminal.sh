#!/usr/bin/env bash
# Exercise the actual whiptail widgets under a Linux pseudo-terminal.
# Site facts/actions and Docker are simulated; widgets, input and tty cleanup are real.
set -euo pipefail

if [[ "${OSTYPE:-}" != linux* ]]; then
  printf 'SKIP: native terminal acceptance requires Linux util-linux script.\n'
  exit 0
fi
for required in script timeout whiptail; do
  command -v "$required" >/dev/null || { printf 'Missing test dependency: %s\n' "$required" >&2; exit 1; }
done
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
cleanup() {
  if [ -n "${OCTOJOOM_TTY_ARTIFACT_DIR:-}" ]; then
    mkdir -p "$OCTOJOOM_TTY_ARTIFACT_DIR"
    cp "$WORK"/*.log "$WORK"/*.args "$WORK"/*.stderr "$OCTOJOOM_TTY_ARTIFACT_DIR/" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
export OCTOJOOM_TTY_TEST_WORK="$WORK" TERM=xterm-256color
REAL_WHIPTAIL=$(command -v whiptail)
export REAL_WHIPTAIL
mkdir "$WORK/bin"
cat > "$WORK/bin/whiptail" <<'WRAPPER'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$OCTOJOOM_TTY_TEST_WORK/$OCTOJOOM_TTY_TEST_CASE.args"
# A delayed launch must still accept normal input once its widget opens.
[ "$OCTOJOOM_TTY_TEST_CASE" != menu-delayed ] || sleep 1
printf 'ready\n' >> "$OCTOJOOM_TTY_TEST_WORK/ready"
exec "$REAL_WHIPTAIL" "$@"
WRAPPER
chmod +x "$WORK/bin/whiptail"
export PATH="$WORK/bin:$PATH"
awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' \
  "$ROOT/src/octojoom" > "$WORK/functions.sh"
cat > "$WORK/session.sh" <<'SESSION'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$OCTOJOOM_TTY_TEST_WORK/functions.sh"
BACK_TITLE=OctoJoom
stty rows 37 cols 120
before=$(stty -g)
case "$OCTOJOOM_TTY_TEST_CASE" in
  menu-*)
    [ "$OCTOJOOM_TTY_TEST_CASE" != menu-small ] || stty rows 24 cols 80
    [ "$OCTOJOOM_TTY_TEST_CASE" != menu-tiny ] || stty rows 12 cols 40
    details=$(printf 'Information line %s\n' {1..40})
    result=$(showJoomlaWebsiteMenu first.example.test "$details" back Back enable Enable information 'View full information' php-settings 'PHP settings')
    status=$?
    printf '\nRESULT=%s STATUS=%s\n' "$result" "$status"
    ;;
  report|report-tiny)
    [ "$OCTOJOOM_TTY_TEST_CASE" != report-tiny ] || stty rows 12 cols 40
    details=$(printf 'Information line %s\n' {1..80})
    showJoomlaWebsiteReport first.example.test "$details"
    printf '\nREPORT_STATUS=%s\n' "$?"
    ;;
  navigation)
    # Exercise the real website loop, including the report's return path. These
    # stand-ins keep navigation read-only and independent of local deployments.
    VDM_REPO_PATH="$OCTOJOOM_TTY_TEST_WORK/sites"
    mkdir -p "$VDM_REPO_PATH/joomla/available/first.example.test"
    touch "$VDM_REPO_PATH/joomla/available/first.example.test/docker-compose.yml"
    readJoomlaSiteFacts() {
      VDM_SITE_ENABLED=disabled
      VDM_SITE_URL='' VDM_SITE_VIEWER_URL='' VDM_SITE_MAIL_URL=''
      VDM_SITE_HOST_PATH='' VDM_SITE_SERVICE=''
    }
    showJoomlaSiteFacts() { printf 'Information line %s\n' {1..80}; }
    isExpert() { return 1; }
    runJoomlaSiteAction() {
      printf '%s\n' "$2" >> "$OCTOJOOM_TTY_TEST_WORK/navigation.actions"
    }
    showJoomlaWebsiteInformation first.example.test true
    printf '\nNAVIGATION_STATUS=%s\n' "$?"
    ;;
  progress-*)
    # Keep diagnostics separate for exact-once assertions while the real native
    # gauge still owns /dev/tty. No alternate renderer is substituted.
    composeProgressCanCapture() { return 0; }
    docker() {
      if [[ "$*" == *'config --services' ]]; then printf 'database\nwebsite\n'; return; fi
      printf 'Container database Started\n' >&2
      sleep 0.5
      printf 'Container database Waiting\nContainer database Waiting\n' >&2
      sleep 1
      printf 'Container database Healthy\nContainer website Started\n' >&2
      sleep 0.5
      return "${OCTOJOOM_TTY_TEST_CASE#progress-}"
    }
    runComposeProgress '/tmp/a site/docker-compose.yml' compose --file '/tmp/a site/docker-compose.yml' up -d \
      > "$OCTOJOOM_TTY_TEST_WORK/$OCTOJOOM_TTY_TEST_CASE.stdout" \
      2> "$OCTOJOOM_TTY_TEST_WORK/$OCTOJOOM_TTY_TEST_CASE.stderr"
    status=$?
    printf '\nPROGRESS_STATUS=%s\n' "$status"
    ;;
esac
[ "$before" = "$(stty -g)" ] || { printf 'TERMINAL_NOT_RESTORED\n'; exit 1; }
printf 'TERMINAL_RESTORED\n'
: > "$OCTOJOOM_TTY_TEST_WORK/done"
SESSION

feed_keys() {
  local keys="$1" deadline=$((SECONDS + 15))
  wait_for_dialog 1 "$deadline" || return 1
  printf '%b' "$keys"
  if [ "$OCTOJOOM_TTY_TEST_CASE" = navigation ]; then
    # Report -> actions -> harmless Logs action -> refreshed actions -> Back.
    wait_for_dialog 2 "$deadline" || return 1
    printf '\033[6~\033[6~\033[6~\033[6~\033'
    wait_for_dialog 3 "$deadline" || return 1
    printf '\033[B\033[B\033[B\r'
    wait_for_dialog 4 "$deadline" || return 1
    printf '\r'
  fi
  while [ ! -f "$WORK/done" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

wait_for_dialog() {
  local count="$1" deadline="$2"
  while [ ! -f "$WORK/ready" ] || [ "$(wc -l < "$WORK/ready")" -lt "$count" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
  # Wait for the native widget to finish tty initialization before sending input.
  sleep 0.5
}

run_case() {
  local name="$1" keys="$2" expected="$3" widget="$4"
  export OCTOJOOM_TTY_TEST_CASE="$name"
  rm -f "$WORK/ready" "$WORK/done"
  # shellcheck disable=SC2016
  if ! feed_keys "$keys" |
    timeout --signal=TERM --kill-after=2s 20s script --quiet --return \
      --command 'bash "$OCTOJOOM_TTY_TEST_WORK/session.sh"' /dev/null > "$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    return 1
  fi
  grep -qF "$expected" "$WORK/$name.log"
  grep -qF 'TERMINAL_RESTORED' "$WORK/$name.log"
  grep -qxF -- "$widget" "$WORK/$name.args"
  if grep -Eq 'Bad file descriptor|ambiguous redirect|TERMINAL_NOT_RESTORED|duration unknown|\^\[\[5~' "$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    return 1
  fi
  printf 'PASS: %s uses native %s and restores the terminal\n' "$name" "$widget"
}

# The first Down/Enter must act on the real native menu, without an initial Tab.
run_case menu-actions '\033[B\r' 'RESULT=enable STATUS=0' --menu
run_case menu-default '\r' 'RESULT=back STATUS=0' --menu
run_case menu-information '\033[B\033[B\r' 'RESULT=information STATUS=0' --menu
run_case menu-delayed '\033[B\r' 'RESULT=enable STATUS=0' --menu
run_case menu-small '\033[B\r' 'RESULT=enable STATUS=0' --menu
run_case menu-tiny '\033[B\r' 'RESULT=enable STATUS=0' --menu
run_case menu-cancel '\t\t\r' 'RESULT= STATUS=1' --menu
run_case menu-escape '\033' 'RESULT= STATUS=255' --menu
run_case report '\033[6~\033[6~\033[6~\033[6~\t\r' 'REPORT_STATUS=0' --textbox
grep -qF 'Information line 80' "$WORK/report.log"
run_case report-tiny '\033[6~\t\r' 'REPORT_STATUS=0' --textbox
run_case navigation '\033[B\033[B\r' 'NAVIGATION_STATUS=0' --menu
grep -qxF -- '--textbox' "$WORK/navigation.args"
[ "$(cat "$WORK/navigation.actions")" = logs ]
[ "$(grep -cxF -- '--menu' "$WORK/navigation.args")" = 3 ]
run_case progress-0 '\033[5~' 'PROGRESS_STATUS=0' --gauge
run_case progress-23 '' 'PROGRESS_STATUS=23' --gauge
[ ! -s "$WORK/progress-0.stderr" ]
[ "$(grep -cF 'Container database Waiting' "$WORK/progress-23.stderr")" = 2 ]
for result in 0 23; do
  grep -qF 'Waiting' "$WORK/progress-$result.log"
  [ ! -s "$WORK/progress-$result.stdout" ]
done
printf 'PASS: live native progress, no successful log replay, full failure diagnostics\n'
