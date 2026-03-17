#!/bin/bash
# Steer A/B Benchmark — tests a realistic browser automation flow
# Usage: ./bench/steer-bench.sh [label]
#
# Test flow (simulates a real agent task):
#   1. Screenshot Chrome (see)
#   2. OCR Chrome for text
#   3. Click on a safe spot
#   4. Type a short string
#   5. Hotkey (Escape to cancel)
#   6. Full agent loop: see → OCR → click (x3)
#   7. Scroll down + screenshot
#
# Each step is timed individually. Total wall-clock is also measured.

set -euo pipefail

STEER=/Users/kmm/mac-mini-agent/apps/steer/.build/release/steer
LABEL="${1:-$(git branch --show-current)}"
APP="Google Chrome"
RESULTS_DIR="/Users/kmm/mac-mini-agent/bench/results"
mkdir -p "$RESULTS_DIR"
OUTFILE="$RESULTS_DIR/bench-${LABEL}-$(date +%s).txt"

# Helper: time a command, return milliseconds
ms() {
  local start end
  start=$(python3 -c "import time; print(int(time.time()*1000))")
  eval "$@" > /dev/null 2>&1
  end=$(python3 -c "import time; print(int(time.time()*1000))")
  echo $(( end - start ))
}

echo "=== Steer Benchmark: $LABEL ===" | tee "$OUTFILE"
echo "Date: $(date)" | tee -a "$OUTFILE"
echo "Branch: $(git branch --show-current)" | tee -a "$OUTFILE"
echo "Steer version: $($STEER --version 2>&1)" | tee -a "$OUTFILE"
echo "" | tee -a "$OUTFILE"

TOTAL_START=$(python3 -c "import time; print(int(time.time()*1000))")

# --- Step 1: Screenshot ---
echo "Step 1: see (screenshot + AX tree)" | tee -a "$OUTFILE"
T=$(ms "$STEER see --app '$APP' --json")
echo "  ${T}ms" | tee -a "$OUTFILE"

# --- Step 1b: see --no-save (if supported) ---
if $STEER see --help 2>&1 | grep -q "no-save"; then
  echo "Step 1b: see --no-save" | tee -a "$OUTFILE"
  T=$(ms "$STEER see --app '$APP' --no-save --json")
  echo "  ${T}ms" | tee -a "$OUTFILE"
else
  echo "Step 1b: see --no-save — NOT AVAILABLE" | tee -a "$OUTFILE"
fi

# --- Step 2: OCR ---
echo "Step 2: ocr" | tee -a "$OUTFILE"
T=$(ms "$STEER ocr --app '$APP' --json")
echo "  ${T}ms" | tee -a "$OUTFILE"

# --- Step 2b: OCR accurate (if supported) ---
if $STEER ocr --help 2>&1 | grep -q "accurate"; then
  echo "Step 2b: ocr --accurate" | tee -a "$OUTFILE"
  T=$(ms "$STEER ocr --app '$APP' --accurate --json")
  echo "  ${T}ms" | tee -a "$OUTFILE"
fi

# --- Step 3: Click (off-screen, timing only) ---
echo "Step 3: click" | tee -a "$OUTFILE"
T=$(ms "$STEER click -x 9999 -y 9999 --json")
echo "  ${T}ms" | tee -a "$OUTFILE"

# --- Step 6: Agent loop (see → OCR → click) x3 ---
echo "Step 6: agent loop (see+ocr+click) x3" | tee -a "$OUTFILE"
LOOP_START=$(python3 -c "import time; print(int(time.time()*1000))")
for i in 1 2 3; do
  $STEER see --app "$APP" --json > /dev/null 2>&1
  $STEER ocr --app "$APP" --json > /dev/null 2>&1
done
LOOP_END=$(python3 -c "import time; print(int(time.time()*1000))")
echo "  $(( LOOP_END - LOOP_START ))ms total ($(( (LOOP_END - LOOP_START) / 3 ))ms avg/iteration)" | tee -a "$OUTFILE"

# --- Step 7: Scroll + screenshot ---
echo "Step 7: scroll + see" | tee -a "$OUTFILE"
T=$(ms "$STEER scroll down 3 --json && $STEER see --app '$APP' --json")
echo "  ${T}ms" | tee -a "$OUTFILE"

# --- Step 8: OCR quality check ---
echo "Step 8: OCR element count" | tee -a "$OUTFILE"
COUNT=$($STEER ocr --app "$APP" --json 2>&1 | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null || echo "0")
echo "  $COUNT elements found" | tee -a "$OUTFILE"

TOTAL_END=$(python3 -c "import time; print(int(time.time()*1000))")
echo "" | tee -a "$OUTFILE"
echo "TOTAL: $(( TOTAL_END - TOTAL_START ))ms" | tee -a "$OUTFILE"
echo "" | tee -a "$OUTFILE"
echo "Results saved to: $OUTFILE"
