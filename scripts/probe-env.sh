#!/usr/bin/env bash
# Report what this machine can actually do, so the agent adapts instead of assuming.
#
# Nothing here is required. The point is to know which capabilities are missing
# BEFORE claiming a change was verified. Run this first, every session.
#
# What this cannot see: MCP servers. Those are attached to the agent, not to the
# shell. The agent must check its own tool list -- see the note printed at the end.

set -uo pipefail

hdr() { printf '\n== %s ==\n' "$1"; }

# have <command> [version-args...]
have() {
  local name="$1"; shift
  if command -v "$name" >/dev/null 2>&1; then
    local v; v=$("$name" "$@" 2>&1 | head -1 | cut -c1-60)
    printf '  yes  %-14s %s\n' "$name" "$v"
    return 0
  fi
  printf '  --   %-14s\n' "$name"
  return 1
}

hdr "Luau / Lua toolchain"
luau_ok=1
have luau-analyze --version && luau_ok=0
have luau-lsp      --version && luau_ok=0
have luau          --version && luau_ok=0
have lune          --version
have stylua        --version
have selene        --version
have luac5.1       -v
have luac          -v
have lua5.1        -v
if [ $luau_ok -ne 0 ]; then
  echo "  NOTE: no real Luau parser. syntax-check.sh falls back to Lua 5.1, which"
  echo "        cannot parse continue / type annotations / backtick strings / // ."
  echo "        A fallback pass is weak evidence. Install luau-analyze if you can."
fi

hdr "Roblox project tooling"
have rojo    --version
have darklua --version
have wally   --version
have rokit   --version
have aftman  --version
have foreman --version

hdr "Scripting / network"
have python3 --version
have curl    --version
have git     --version

hdr "Image backend (icon-sheet.py)"
if python3 -c "import PIL" 2>/dev/null; then
  printf '  yes  %-14s %s\n' "Pillow" "$(python3 -c 'import PIL;print(PIL.__version__)' 2>/dev/null)"
elif command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then
  printf '  yes  %-14s (Pillow absent, using ImageMagick)\n' "ImageMagick"
else
  echo "  --   none         icon-sheet.py cannot composite."
  echo "       install:  pip install Pillow    (or an ImageMagick package)"
fi

hdr "Dev server port"
PORT="${1:-8080}"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    echo "  BUSY  :$PORT is already listening"
  else
    echo "  free  :$PORT"
  fi
else
  echo "  ?     cannot check :$PORT (no ss)"
fi

hdr "Repository"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "  branch : $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  echo "  remote : $(git remote get-url origin 2>/dev/null || echo '(none)')"
  echo "  status : $(git status --porcelain 2>/dev/null | wc -l) changed file(s)"
else
  echo "  not a git repository"
fi

hdr "Not visible from the shell"
cat <<'EOF'
  MCP servers are attached to the AGENT, not to this shell. Check your own tool
  list for a Roblox-capable MCP (names vary by machine: Madium, Potassium,
  roblox-mcp, ...). Never assume one is present.

  If no such MCP is attached, the "live, against a running client" verification
  layer is UNAVAILABLE. Say so plainly rather than implying a change was
  verified against a real game.
EOF
echo
