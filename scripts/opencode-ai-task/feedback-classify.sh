#!/usr/bin/env bash
#
# Classify an untrusted pull-request comment so authorised humans do not need
# to remember a specific command. The classifier is pure: it only sees the
# comment body and never talks to GitHub.
#
# Input:  GATE_COMMENT_BODY (or stdin when piped)
# Output: "class=<class>" and, for actionable classes, "feedback=<text>"
#
# Classes:
#   revise          explicit "/ai revise <feedback>" command
#   revise-empty    "/ai revise" without feedback (malformed, needs a reply)
#   unknown-command "/ai <anything-else>" (e.g. "/ai assist"; needs a reply)
#   feedback        ordinary actionable feedback; treated as a revision request
#   clarify         actionable-looking but too vague or a bare question
#   non-actionable  pleasantries, emoji reactions and automation markers
#
# Only "revise" and "feedback" start an agent run. "revise-empty",
# "unknown-command" and "clarify" get an acknowledgement reply. An authorised
# user must never be answered with silence for a recognised command.

set -euo pipefail

body="${GATE_COMMENT_BODY:-}"
if [ $# -ge 1 ]; then body="$1"; elif [ "${body}" = "" ] && ! [ -t 0 ]; then
  body="$(cat)"
fi

# Strip a single leading HTML comment so automation markers never look like
# feedback, then trim surrounding whitespace.
body="$(printf '%s' "${body}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

emit() { echo "class=$1"; [ $# -ge 2 ] && echo "feedback=$2" || true; exit 0; }

is_blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

is_blank "${body}" && emit non-actionable

# A comment consisting only of an HTML marker (automation status output) is
# never feedback.
if printf '%s' "${body}" | grep -q '^<!--.*-->$'; then
  emit non-actionable
fi

# Explicit commands: "/ai ..." is always acknowledged, never silently ignored.
case "${body}" in
  '/ai revise') emit revise-empty ;;
  '/ai revise'*)
    if [[ "${body}" =~ ^/ai[[:space:]]revise[[:space:]] ]]; then
      feedback="${body#'/ai revise'}"
      if is_blank "${feedback}"; then emit revise-empty; fi
      emit revise "$(printf '%s' "${feedback}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    else
      # e.g. "/ai revisex ..." — a recognised prefix, malformed command.
      emit revise-empty
    fi
    ;;
  '/ai'|'/ai '[[:space:]]*|'/ai '*|'/ai'$'\t'*)
    # Any other "/ai <token>" (e.g. "/ai assist"): acknowledged as unknown.
    emit unknown-command
    ;;
esac
# "/airport ..." does not start with the /ai command token; fall through.

lower="$(printf '%s' "${body}" | tr '[:upper:]' '[:lower:]')"

# Emoji-only, symbol-only or punctuation-only reactions are never feedback.
# Anything without ASCII alphanumerics (including other scripts) is treated as
# a reaction rather than a directive.
stripped="$(printf '%s' "${lower}" | tr -cd 'a-z0-9')"
if is_blank "${stripped}"; then emit non-actionable; fi

words() { printf '%s' "$1" | wc -w | tr -d ' '; }

# Whole-comment pleasantries and acknowledgements carry no actionable change.
case "${lower}" in
  thanks|thank|'thank you'|'thank you!'|'thanks!'|thx|ty|'thanks a lot'|'many thanks'|'cheers')
    emit non-actionable ;;
  lgtm|'looks good'|'looks good to me'|'looks great'|'seems good'|'seems fine'|sgtm|'sounds good'|'works for me')
    emit non-actionable ;;
  nice|'nice work'|'nice one'|great|'great work'|'great job'|awesome|perfect|excellent|cool|okay)
    emit non-actionable ;;
  approved|approve|'ship it'|'ship it!'|':+1:'|'+1'|'-1')
    emit non-actionable ;;
  merged|merging|ping|bump|'any update'|'any update?'|done|'well done'|congrats|congratulations)
    emit non-actionable ;;
esac
case "${lower}" in ok) emit non-actionable ;; esac

# A bare question is discussion: acknowledge it and ask for a directive rather
# than spending an agent run on an answer.
case "${lower}" in
  what*|why*|how*|when*|where*|who*|which*|is*|are*|does*|do*|can*|could*|would*|should*|did*|was*|were*|will*|has*|have*)
    case "${body}" in
      *\?) emit clarify ;;
    esac
    ;;
esac

if [ "$(words "${body}")" -lt 3 ]; then
  emit clarify
fi

emit feedback
