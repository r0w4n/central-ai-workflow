#!/usr/bin/env bash
# Safely select an approved model from an issue's machine-readable metadata.
# No issue content is sourced, evaluated, or interpolated into a shell command.

set -euo pipefail

SPEC_FILE="${SPEC_FILE:?SPEC_FILE is required}"
MODEL_CONFIG="${MODEL_CONFIG:?MODEL_CONFIG is required}"

fail() { echo "::error::$1" >&2; exit 1; }

[ -f "${SPEC_FILE}" ] || fail "issue specification is missing"
[ -f "${MODEL_CONFIG}" ] || fail "model configuration is missing"

default_complexity=""
simple_model=""
medium_model=""
complex_model=""
allowed_models=""

while IFS='=' read -r key value; do
  case "${key}" in
    ''|'#'*) continue ;;
    default_complexity) default_complexity="${value}" ;;
    simple) simple_model="${value}" ;;
    medium) medium_model="${value}" ;;
    complex) complex_model="${value}" ;;
    allowed_model) allowed_models="${allowed_models}${value}"$'\n' ;;
    *) fail "unknown model configuration key '${key}'" ;;
  esac
done <"${MODEL_CONFIG}"

case "${default_complexity}" in
  simple|medium|complex) ;;
  *) fail "default_complexity must be simple, medium, or complex" ;;
esac

for configured_model in "${simple_model}" "${medium_model}" "${complex_model}"; do
  [ -n "${configured_model}" ] || fail "every complexity must have a model mapping"
done

# Metadata format (at most one block per issue):
# <!-- ai-task-config
# complexity: medium
# model: opencode-go/glm-5.3-flash
# -->
block_count="$(grep -c '^<!--[[:space:]]*ai-task-config[[:space:]]*$' "${SPEC_FILE}" || true)"
[ "${block_count}" -le 1 ] || fail "issue contains multiple ai-task-config blocks"

complexity=""
explicit_model=""
if [ "${block_count}" -eq 1 ]; then
  block="$(awk '
    /^<!--[[:space:]]*ai-task-config[[:space:]]*$/ { inside=1; next }
    inside && /^[[:space:]]*-->[[:space:]]*$/ { closed=1; exit }
    inside { print }
    END { if (inside && !closed) exit 2 }
  ' "${SPEC_FILE}")" || fail "ai-task-config block is not closed"

  while IFS= read -r line; do
    [ -z "${line}" ] && continue
    case "${line}" in
      complexity:\ *)
        [ -z "${complexity}" ] || fail "complexity is specified more than once"
        complexity="${line#complexity: }"
        ;;
      model:\ *)
        [ -z "${explicit_model}" ] || fail "model is specified more than once"
        explicit_model="${line#model: }"
        ;;
      *) fail "invalid ai-task-config line '${line}'" ;;
    esac
  done <<<"${block}"
fi

[ -n "${complexity}" ] || complexity="${default_complexity}"
case "${complexity}" in
  simple) selected_model="${simple_model}" ;;
  medium) selected_model="${medium_model}" ;;
  complex) selected_model="${complex_model}" ;;
  *) fail "unsupported complexity '${complexity}'" ;;
esac

if [ -n "${explicit_model}" ]; then
  case "${explicit_model}" in
    *[!A-Za-z0-9._/-]*|'') fail "explicit model contains invalid characters" ;;
  esac
  if ! grep -Fxq -- "${explicit_model}" <<<"${allowed_models}"; then
    fail "explicit model '${explicit_model}' is not approved"
  fi
  selected_model="${explicit_model}"
fi

if ! grep -Fxq -- "${selected_model}" <<<"${allowed_models}"; then
  fail "mapped model '${selected_model}' is not in the approved allowlist"
fi

printf 'complexity=%s\nmodel=%s\n' "${complexity}" "${selected_model}"
