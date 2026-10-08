#!/usr/bin/env bash
#
# Run the Octojoom test suite.
#
#   bash tests/run.sh                 all bats tests and the standalone scripts
#   bash tests/run.sh tests/unit/x.bats   only the given bats files
#
# Needs bash 4 or newer (as Octojoom itself), git (to fetch bats-core once) and
# the usual sed, grep and awk. Works on Linux, macOS (with a Homebrew bash) and
# Windows Git Bash. No docker daemon, whiptail or sudo is needed: the tests use
# the stand-ins in tests/helpers/bin and never change anything outside their
# own temporary folders.
#
# Environment:
#   BATS_JOBS          run bats files in parallel (needs GNU parallel), default 1
#   BATS_TEST_TIMEOUT  seconds before a single test is stopped, default 120

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${TEST_DIR}/.." && pwd)"
BATS_VERSION="v1.11.1"

if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "ERROR: the tests need bash 4 or newer (this is ${BASH_VERSION})." >&2
  echo "On macOS: brew install bash" >&2
  exit 2
fi

# use an installed bats, else fetch the pinned version once into tests/.cache
BATS="$(command -v bats 2>/dev/null || true)"
if [ -z "${BATS}" ]; then
  BATS_HOME="${TEST_DIR}/.cache/bats-core-${BATS_VERSION}"
  if [ ! -x "${BATS_HOME}/bin/bats" ]; then
    rm -rf "${BATS_HOME}.tmp"
    git clone --quiet --depth 1 --branch "${BATS_VERSION}" \
      https://github.com/bats-core/bats-core.git "${BATS_HOME}.tmp" || {
      echo "ERROR: could not fetch bats-core ${BATS_VERSION}." >&2
      exit 2
    }
    mv "${BATS_HOME}.tmp" "${BATS_HOME}"
  fi
  BATS="${BATS_HOME}/bin/bats"
fi

export BATS_TEST_TIMEOUT="${BATS_TEST_TIMEOUT:-120}"

failed=0
cd "${ROOT}" || exit 2

if [ $# -gt 0 ]; then
  "${BATS}" --print-output-on-failure "$@" || failed=1
  exit "${failed}"
fi

echo "# bats suites (bats ${BATS_VERSION})"
if [ "${BATS_JOBS:-1}" -gt 1 ]; then
  "${BATS}" --print-output-on-failure --jobs "${BATS_JOBS}" --recursive tests/unit || failed=1
else
  "${BATS}" --print-output-on-failure --recursive tests/unit || failed=1
fi

for script in tests/test-clone.sh tests/test-clone-flow.sh; do
  echo
  echo "# ${script}"
  bash "${script}" || failed=1
done

echo
if [ "${failed}" -ne 0 ]; then
  echo "SOME TESTS FAILED"
else
  echo "ALL TESTS PASSED"
fi
exit "${failed}"
