#!/usr/bin/env bash
# Shared xcbeautify pipe helper. Sourced by swift-test-helpers.sh and mise tasks.
#
# Optional variables:
#   XCB_EXTRA_ARGS - Extra xcbeautify flags (e.g. "--renderer github-actions")
#   _XCB_BYPASS    - Set to "1" to force raw output (skips xcbeautify)

set -o pipefail

_xcb_pipe_cmd() {
  if [ "${_XCB_BYPASS:-0}" = "1" ]; then
    echo "cat"
  elif command -v xcbeautify >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    echo "xcbeautify"${XCB_EXTRA_ARGS:+ $XCB_EXTRA_ARGS}
  else
    echo "cat"
  fi
}
