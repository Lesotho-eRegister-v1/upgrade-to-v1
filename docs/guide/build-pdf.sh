#!/usr/bin/env bash
# =============================================================================
# docs/guide/build-pdf.sh — render the markdown chapters into one PDF.
#
# Requires: pandoc, plus a LaTeX install providing lualatex (preferred) or
# xelatex.
#   macOS:  brew install pandoc && brew install --cask basictex
#   Ubuntu: sudo apt install pandoc texlive-luatex texlive-xetex \
#                            texlive-fonts-recommended texlive-latex-extra
#
#   ./docs/guide/build-pdf.sh                  -> docs/guide/eregister-v1-upgrade-guide.pdf
#   ./docs/guide/build-pdf.sh /tmp/out.pdf     -> that path instead
#
# Chapter order is index.md, then every NN-name.md in numeric order. Adding a
# new numbered file picks it up automatically — no edit needed here.
#
# ABOUT THE GLYPHS
#   The report samples in this guide use the marks the scripts actually print
#   (✔ ⟳ ✘ ℹ ⚠), and most monospace fonts do not carry all of them. Inside a
#   code block LaTeX uses the mono font directly, so a per-character
#   substitution macro cannot help there — the font itself has to have them.
#
#   So: with lualatex, a real font fallback chain is installed and the marks
#   render as printed. With xelatex (no fallback support) the marks are swapped
#   for ASCII in a staged copy, because a missing glyph is a silent blank.
#   Either way the markdown files on disk are never modified.
#
#   The three emoji in the installer's startup banner are always substituted:
#   no TeX engine renders colour emoji usefully.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${HERE}/eregister-v1-upgrade-guide.pdf}"

command -v pandoc >/dev/null 2>&1 || {
  echo "pandoc is not installed. brew install pandoc / sudo apt install pandoc" >&2; exit 1; }

if command -v lualatex >/dev/null 2>&1; then ENGINE=lualatex
elif command -v xelatex >/dev/null 2>&1; then ENGINE=xelatex
else
  echo "Neither lualatex nor xelatex is installed." >&2
  echo "  macOS:  brew install --cask basictex" >&2
  echo "  Ubuntu: sudo apt install texlive-luatex texlive-fonts-recommended" >&2
  exit 1
fi

# --- font detection ----------------------------------------------------------
# The family list is captured ONCE, into a file. Re-running the pipeline per
# candidate and ending it in `grep -q` would trip `set -o pipefail`: grep exits
# on the first match, fc-list gets SIGPIPE, and the pipeline reports 141 — so a
# font that IS installed reads as missing, seemingly at random.
FONT_LIST="$(mktemp -t eregister-fonts.XXXXXX)"
if command -v fc-list >/dev/null 2>&1; then
  fc-list : family 2>/dev/null | tr ',' '\n' | sed 's/[[:space:]]*$//' | sort -u > "$FONT_LIST" || true
fi

have_font() { grep -qix -- "$1" "$FONT_LIST" 2>/dev/null; }
pick_font() {  # pick_font <fallback> <candidate>...
  local fallback="$1"; shift
  local c
  for c in "$@"; do have_font "$c" && { printf '%s' "$c"; return 0; }; done
  printf '%s' "$fallback"
}

MAINFONT="$(pick_font "Helvetica" "DejaVu Sans" "Noto Sans" "Liberation Sans" "Helvetica Neue" "Helvetica" "Arial")"
MONOFONT="$(pick_font "Menlo"     "DejaVu Sans Mono" "Noto Sans Mono" "Liberation Mono" "Menlo" "Courier New")"
# A font carrying the report marks, used only as a fallback behind the two above.
SYMFONT="$(pick_font ""           "DejaVu Sans" "Noto Sans Symbols 2" "Symbola" "Apple Symbols" "Arial Unicode MS")"

echo "Engine: ${ENGINE}"
echo "Fonts:  main=${MAINFONT}  mono=${MONOFONT}  symbols=${SYMFONT:-<none>}"

PREAMBLE="$(mktemp -t eregister-preamble.XXXXXX)"
STAGE="$(mktemp -d -t eregister-docs.XXXXXX)"
trap 'rm -rf "$STAGE" "$PREAMBLE" "$FONT_LIST"' EXIT

# --- preamble ----------------------------------------------------------------
# Decide up front whether the marks can be rendered; the staging pass below
# needs to know.
MARKS_OK=0
{
  if [ "$ENGINE" = "lualatex" ] && [ -n "$SYMFONT" ]; then
    MARKS_OK=1
    cat <<PRE
\\directlua{luaotfload.add_fallback("eregsymfb",
  {"${SYMFONT}:mode=node;", "${MONOFONT}:mode=node;"})}
\\setmainfont{${MAINFONT}}[RawFeature={fallback=eregsymfb}]
\\setmonofont{${MONOFONT}}[RawFeature={fallback=eregsymfb}]
PRE
  fi
  cat <<'PRE'
% Keep long command lines and wide report samples inside the margin. BOTH
% environments are needed: pandoc emits `Highlighting` for a fenced block with a
% language it knows, and plain `verbatim` for one without (```text, ```cron) —
% and the widest samples in this guide are exactly those.
\usepackage{fvextra}
\fvset{breaklines=true,breakanywhere=true,fontsize=\small}
\DefineVerbatimEnvironment{Highlighting}{Verbatim}{breaklines,breakanywhere,fontsize=\small,commandchars=\\\{\}}
\DefineVerbatimEnvironment{verbatim}{Verbatim}{breaklines,breakanywhere,fontsize=\small}
% The reference tables are text-heavy; let cells wrap rather than overflow.
\usepackage{ragged2e}
PRE
} > "$PREAMBLE"

# --- stage the chapters ------------------------------------------------------
stage_one() {  # stage_one <src> <dst>
  if [ "$MARKS_OK" = "1" ]; then
    sed -e 's/⏳/[..]/g' -e 's/🔍/[??]/g' -e 's/✨/[**]/g' "$1" > "$2"
  else
    sed -e 's/⏳/[..]/g' -e 's/🔍/[??]/g' -e 's/✨/[**]/g' \
        -e 's/✔/[ok]/g'  -e 's/⟳/[fix]/g' -e 's/✘/[gap]/g' \
        -e 's/ℹ/i/g'     -e 's/⚠/!/g' "$1" > "$2"
  fi
}

CHAPTERS=()
while IFS= read -r f; do
  b="$(basename "$f")"
  stage_one "$f" "${STAGE}/${b}"
  CHAPTERS+=("${STAGE}/${b}")
done < <(
  printf '%s\n' "${HERE}/index.md"
  find "$HERE" -maxdepth 1 -name '[0-9][0-9]-*.md' | sort
)

echo "Rendering ${#CHAPTERS[@]} file(s) -> ${OUT}"

PANDOC_ARGS=(
  --from=gfm
  --output="$OUT"
  --pdf-engine="$ENGINE"
  --include-in-header="$PREAMBLE"
  --toc --toc-depth=3
  --number-sections
  --top-level-division=chapter
  --metadata title="eRegister Lesotho — v1 Upgrade Toolkit"
  --metadata subtitle="Operations and reference guide"
  --metadata date="$(date '+%d %B %Y')"
  --variable documentclass=report
  --variable papersize=a4
  --variable geometry:margin=2.2cm
  --variable fontsize=10pt
  --variable colorlinks=true
  --variable linkcolor=RoyalBlue
  --variable urlcolor=RoyalBlue
  --variable toccolor=black
)
# With the lualatex fallback the fonts are already set in the preamble; setting
# them again through pandoc's variables would overwrite the RawFeature.
if [ "$MARKS_OK" != "1" ]; then
  PANDOC_ARGS+=( --variable mainfont="$MAINFONT" --variable monofont="$MONOFONT" )
fi

pandoc "${CHAPTERS[@]}" "${PANDOC_ARGS[@]}"

echo "Wrote ${OUT}  ($(du -h "$OUT" | awk '{print $1}'))"
