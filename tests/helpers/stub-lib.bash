# shellcheck shell=bash
#
# Shared by the command stand-ins in tests/helpers/bin.
#
# Every stand-in logs its call to ${STUB_DIR}/commands.log. A test can replace
# the behaviour of any stand-in by writing a bash script to
# ${STUB_DIR}/hooks/<command>; it is run with the same arguments and its exit
# status is returned.

# log one call
stub_log() {
  [ -n "${STUB_DIR:-}" ] || return 0
  printf '%s\n' "$*" >>"${STUB_DIR}/commands.log"
}

# run the test's hook for this command, if there is one (never returns when it ran)
stub_hook() {
  local name="$1"
  shift
  if [ -n "${STUB_DIR:-}" ] && [ -f "${STUB_DIR}/hooks/${name}" ]; then
    bash "${STUB_DIR}/hooks/${name}" "$@"
    exit $?
  fi
}

# the exit status a test asked for with ${STUB_DIR}/fail/<name>, else 0
stub_status() {
  local name="$1"
  if [ -n "${STUB_DIR:-}" ] && [ -f "${STUB_DIR}/fail/${name}" ]; then
    head -n 1 "${STUB_DIR}/fail/${name}" 2>/dev/null | grep -E '^[0-9]+$' || echo 1
  else
    echo 0
  fi
}
