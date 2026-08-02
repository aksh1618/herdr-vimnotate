#!/usr/bin/env bash
set -euo pipefail
pane="$(printf '%s' "${HERDR_PLUGIN_CONTEXT_JSON:-}" | jq -r '.focused_pane_id // empty')"
[ -n "$pane" ] || pane="${HERDR_ACTIVE_PANE_ID:-}"
[ -n "$pane" ] || exit 1
exec "${HERDR_BIN_PATH:-herdr}" plugin pane open --plugin "${HERDR_PLUGIN_ID:?}" --entrypoint annotate --env "ANNOTATE_TARGET_PANE=$pane" --focus
