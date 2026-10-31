#!/usr/bin/env bash
# Linux pseudo-terminal acceptance for website menus and lifecycle activity.
# Uses the real terminal renderer with a fake Docker function; no daemon needed.
set -euo pipefail

if [[ "${OSTYPE:-}" != linux* ]] || ! command -v script >/dev/null 2>&1; then
  printf 'SKIP: website terminal acceptance needs Linux util-linux script.\n'
  exit 0
fi

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export OCTOJOOM_TTY_TEST_WORK="$WORK" TERM=xterm-256color
awk '/^(function )?[A-Za-z_][A-Za-z0-9_]*\(\) \{$/ {p=1} p {print} p && /^}$/ {p=0}' \
  "$ROOT/src/octojoom" > "$WORK/functions.sh"
cat > "$WORK/session.sh" <<'SESSION'
#!/usr/bin/env bash
# shellcheck disable=SC1091
source "$OCTOJOOM_TTY_TEST_WORK/functions.sh"
BACK_TITLE=OctoJoom
stty rows 24 cols 80
before=$(stty -g)
# Signal readiness at the first key read, after the menu owns the terminal.
# This clones a trusted function definition, not user-provided shell text.
eval "$(declare -f readJoomlaWebsiteKey | sed '1s/readJoomlaWebsiteKey/readJoomlaWebsiteKeyOriginal/')"
readJoomlaWebsiteKey() {
  : > "$OCTOJOOM_TTY_TEST_WORK/ready"
  readJoomlaWebsiteKeyOriginal "$@"
}
case "$OCTOJOOM_TTY_TEST_CASE" in
  menu-*)
    details=$(printf 'Information line %s\n' {1..40})
    result=$(showJoomlaWebsiteMenu first.example.test "$details" back Back start Start stop Stop)
    status=$?
    printf '\nRESULT=%s STATUS=%s\n' "$result" "$status"
    ;;
  progress-*)
    : > "$OCTOJOOM_TTY_TEST_WORK/ready"
    whiptail() { :; }
    docker() {
      printf 'Container database Starting\n' >&2
      sleep 0.4
      printf 'Container database Waiting\n' >&2
      sleep 0.4
      printf 'Container database Healthy\n' >&2
      sleep 0.4
      return "${OCTOJOOM_TTY_TEST_CASE#progress-}"
    }
    runComposeProgress '/tmp/a site/docker-compose.yml' compose --file '/tmp/a site/docker-compose.yml' up -d
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
  while [ ! -f "$WORK/ready" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
  printf '%b' "$keys"
  # Keep script's stdin open until the session exits. Early EOF injects an EOT
  # byte into the terminal and can consume a standalone Escape as a sequence.
  while [ ! -f "$WORK/done" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

run_case() {
  local name="$1" keys="$2" expected="$3"
  export OCTOJOOM_TTY_TEST_CASE="$name"
  rm -f "$WORK/ready" "$WORK/done"
  # The inner shell expands this path after script creates its terminal.
  # shellcheck disable=SC2016
  if ! feed_keys "$keys" |
    timeout --signal=TERM --kill-after=2s 20s script --quiet --return \
      --command 'bash "$OCTOJOOM_TTY_TEST_WORK/session.sh"' /dev/null > "$WORK/$name.log" 2>&1; then
    cat "$WORK/$name.log" >&2
    return 1
  fi
  grep -qF "$expected" "$WORK/$name.log"
  grep -qF 'TERMINAL_RESTORED' "$WORK/$name.log"
  grep -qF $'\033[?1049l' "$WORK/$name.log"
  if grep -Eq 'Bad file descriptor|ambiguous redirect|TERMINAL_NOT_RESTORED' "$WORK/$name.log"; then
    cat "$WORK/$name.log" >&2
    return 1
  fi
  printf 'PASS: %s\n' "$name"
}

run_case menu-actions '\033[B\n' 'RESULT=start STATUS=0'
run_case menu-tab '\t\033[B\033[6~\t\033[B\n' 'RESULT=start STATUS=0'
run_case menu-info-enter '\t\n\033[B\n' 'RESULT=start STATUS=0'
run_case menu-escape '\033' 'RESULT= STATUS=255'
run_case progress-0 '' 'PROGRESS_STATUS=0'
run_case progress-23 '' 'PROGRESS_STATUS=23'
for result in 0 23; do
  grep -qF 'Activity (duration unknown)' "$WORK/progress-$result.log"
  grep -qF 'Container database Waiting' "$WORK/progress-$result.log"
  # Everything after leaving the alternate screen is ordinary command output.
  awk -v end=$'\033[?1049l' 'index($0,end) {after=1; $0=substr($0,index($0,end)+length(end))} after {print}' \
    "$WORK/progress-$result.log" > "$WORK/after-$result.log"
done
if grep -qF 'Container database' "$WORK/after-0.log"; then exit 1; fi
[ "$(grep -cF 'Container database Waiting' "$WORK/after-23.log")" = 1 ]
printf 'PASS: successful output is not replayed; failures retain diagnostics once\n'
