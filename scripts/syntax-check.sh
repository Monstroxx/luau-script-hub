#!/usr/bin/env bash
# Syntax-check Luau files with the best checker actually installed on this machine.
#
# Checker preference, best first:
#   1. luau-analyze          real Luau parser + type checker
#   2. luau-lsp analyze      same parser, via the language server
#   3. luau --check          Luau CLI, parse only
#   4. luac -p               Lua 5.1 FALLBACK. Cannot parse Luau. Compound
#                            assignments are rewritten first so it becomes a
#                            usable brace/end check -- and nothing more.
#
# The fallback is weak evidence on purpose: `continue`, type annotations,
# backtick string interpolation, `//` and if-expressions are all valid Luau that
# Lua 5.1 rejects. A fallback failure may be a false alarm; a fallback pass only
# means the ends and parens balance. Prefer installing a real Luau parser.
#
# Overrides:  $LUAC points at a Lua 5.1 luac binary.
#
# Usage:
#   syntax-check.sh FILE...      check files
#   syntax-check.sh --selftest   prove the active checker can actually fail
#   syntax-check.sh --which      report which checker would be used

set -uo pipefail

CHECKER=""
CHECKER_KIND=""

detect() {
  if command -v luau-analyze >/dev/null 2>&1; then
    CHECKER="luau-analyze"; CHECKER_KIND="luau"
  elif command -v luau-lsp >/dev/null 2>&1; then
    CHECKER="luau-lsp analyze"; CHECKER_KIND="luau"
  elif command -v luau >/dev/null 2>&1 && luau --help 2>&1 | grep -q -- --check; then
    CHECKER="luau --check"; CHECKER_KIND="luau"
  elif [ -n "${LUAC:-}" ] && command -v "$LUAC" >/dev/null 2>&1; then
    CHECKER="$LUAC"; CHECKER_KIND="lua51"
  else
    for c in luac5.1 luac51 luac; do
      if command -v "$c" >/dev/null 2>&1; then
        CHECKER="$c"; CHECKER_KIND="lua51"; break
      fi
    done
  fi
}

# Rewrite Luau-only syntax that Lua 5.1 cannot parse. Only compound assignments
# are handled -- everything else Luau adds is left alone and WILL false-alarm.
rewrite() {
  sed -E 's/(\.\.|[-+*/%])=[[:space:]]/= /g' "$1" > "$2"
}

check_one() {
  local f="$1"
  [ -f "$f" ] || { echo "  MISSING  $f"; return 1; }

  if [ "$CHECKER_KIND" = "luau" ]; then
    local out
    out=$($CHECKER "$f" 2>&1)
    local rc=$?
    if [ $rc -eq 0 ]; then
      echo "  ok       $f"
      return 0
    fi
    echo "  FAIL     $f"
    echo "$out" | sed 's/^/           /'
    return 1
  fi

  # --- Lua 5.1 fallback ---
  local tmp; tmp=$(mktemp -t syntaxcheck.XXXXXX.lua)
  rewrite "$f" "$tmp"
  # Caution 1: a failed rewrite truncates the file and luac happily calls an
  # empty file valid. Refuse to report success on nothing.
  if [ ! -s "$tmp" ]; then
    echo "  ERROR    $f -- rewrite produced an empty file, refusing to report a pass"
    rm -f "$tmp"; return 1
  fi
  local out rc
  out=$("$CHECKER" -p "$tmp" 2>&1); rc=$?
  rm -f "$tmp"
  if [ $rc -eq 0 ]; then
    echo "  ok*      $f   (Lua 5.1 fallback: ends/parens balance only)"
    return 0
  fi
  echo "  FAIL*    $f"
  echo "$out" | sed "s|$tmp|$f|g; s/^/           /"
  echo "           * fallback checker -- if this uses continue, type annotations,"
  echo "             backtick strings, // or an if-expression, the failure is a"
  echo "             false alarm. Verify by eye or install a Luau parser."
  return 1
}

selftest() {
  # Caution 2: a checker that never fails is worse than no checker. Feed it a
  # file with a deliberately removed `end` and require a non-zero exit.
  local good bad
  good=$(mktemp -t selftest.XXXXXX.lua)
  bad=$(mktemp -t selftest.XXXXXX.lua)
  printf 'local function f(a)\n\tif a then\n\t\treturn 1\n\tend\nend\nreturn f\n' > "$good"
  printf 'local function f(a)\n\tif a then\n\t\treturn 1\n\tend\nreturn f\n' > "$bad"

  echo "selftest: checker = ${CHECKER:-<none>} (${CHECKER_KIND:-none})"
  local ok=0

  if check_one "$good" >/dev/null 2>&1; then
    echo "  PASS  valid file accepted"
  else
    echo "  FAIL  valid file was REJECTED -- checker is unusable"; ok=1
  fi
  if check_one "$bad" >/dev/null 2>&1; then
    echo "  FAIL  broken file (missing 'end') was ACCEPTED -- checker proves nothing"; ok=1
  else
    echo "  PASS  broken file rejected"
  fi
  rm -f "$good" "$bad"
  [ $ok -eq 0 ] && echo "selftest OK" || echo "selftest FAILED"
  return $ok
}

detect

if [ $# -eq 0 ]; then
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
fi

case "${1:-}" in
  --which)
    if [ -z "$CHECKER" ]; then
      echo "no Luau or Lua 5.1 syntax checker found on PATH."
      echo "install one of: luau-analyze (github.com/luau-lang/luau/releases),"
      echo "luau-lsp, or a Lua 5.1 luac (then set \$LUAC if it is not on PATH)."
      exit 1
    fi
    echo "$CHECKER  ($CHECKER_KIND)"
    [ "$CHECKER_KIND" = "lua51" ] && echo "warning: fallback checker -- see --help"
    exit 0 ;;
  --selftest)
    if [ -z "$CHECKER" ]; then echo "no checker found; nothing to self-test"; exit 1; fi
    selftest; exit $? ;;
esac

if [ -z "$CHECKER" ]; then
  echo "no Luau or Lua 5.1 syntax checker found on PATH -- cannot verify syntax."
  echo "Do NOT claim these files parse. Run --which for install hints."
  exit 1
fi

echo "checker: $CHECKER ($CHECKER_KIND)"
fail=0
for f in "$@"; do check_one "$f" || fail=1; done
exit $fail
