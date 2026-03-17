# Steer Performance Plan

## Problem

When using steer in an AI agent loop (screenshot → OCR → click → repeat), each iteration is slow. In our GitHub signup automation test, ~30+ steer invocations took several minutes. The agent had to wait for each steer call to return before deciding the next action, creating a tight coupling between steer latency and total task time.

## Current Architecture

Each steer command (`see`, `ocr`, `click`, `type`, `hotkey`) is a **fresh process invocation**. Every call:

1. Spawns a new Swift process
2. Loads AppKit, Vision, ApplicationServices frameworks
3. Initializes VNRecognizeTextRequest with `.accurate` + language correction
4. Captures screenshot via `CGWindowListCreateImage` at full Retina resolution
5. Encodes and writes a PNG to `/tmp/steer/`
6. Walks the accessibility tree via per-attribute IPC calls
7. Returns JSON and exits (all warm caches are lost)

## Where Time Goes

| Step | Estimated Cost | Source |
|------|---------------|--------|
| Process startup + framework init | 50-150ms | Every invocation |
| Vision ML model load (cold) | 100-300ms | Lost on every exit |
| Screenshot capture (Retina 2x) | 50-100ms | `ScreenCapture.swift` |
| PNG encode + disk write | 50-200ms | `See.swift` / `ElementStore.swift` |
| OCR `.accurate` + language correction | 200-500ms | `OCR.swift` |
| AX tree walk (8 IPC calls/element) | 100-500ms | `AccessibilityTree.swift` |
| Mouse click sleeps | 70ms | `MouseControl.swift` |
| **Total per see+click cycle** | **~600-1800ms** | |

## Proposed Changes

### Phase 1: Quick Wins (no architecture change)

These are single-line or small changes in existing files.

#### 1.1 OCR: Switch to `.fast` recognition level
- **File:** `Sources/steer/OCR.swift:18`
- **Change:** `recognitionLevel = .fast` (currently `.accurate`)
- **Impact:** 3-5x faster OCR. `.fast` uses a lighter model that's sufficient for UI text (button labels, menu items). Add `--accurate` flag for when neural-net precision is needed.

#### 1.2 OCR: Disable language correction
- **File:** `Sources/steer/OCR.swift:20`
- **Change:** `usesLanguageCorrection = false` (currently `true`)
- **Impact:** 10-20% OCR speedup. UI text doesn't benefit from dictionary correction. Add `--language-correction` opt-in flag.

#### 1.3 OCR: Raise minimum text height
- **File:** `Sources/steer/OCR.swift`
- **Change:** `minimumTextHeight` from `0.01` to `0.03`
- **Impact:** Fewer false positives, less work for Vision. Tiny text below 3% of image height is rarely actionable UI.

#### 1.4 Screenshots: Make PNG save optional
- **File:** `Sources/steer/See.swift`
- **Change:** Add `--no-save` flag to skip PNG write. JSON element data is often all the agent needs.
- **Impact:** Saves 50-200ms per `see` call.

#### 1.5 Screenshots: JPEG option
- **File:** `Sources/steer/ScreenCapture.swift`
- **Change:** Add `--format jpeg` option. JPEG encoding is much faster than PNG (no dictionary compression).
- **Impact:** 2-4x faster image save when screenshot is needed.

#### 1.6 Reduce mouse click sleeps
- **File:** `Sources/steer/MouseControl.swift`
- **Change:** Reduce post-warp sleep from 20ms to 10ms, mouseDown-to-mouseUp from 50ms to 25ms.
- **Impact:** 35ms saved per click. Needs reliability testing.

### Phase 2: Daemon Mode (biggest architectural win)

#### 2.1 Persistent daemon process
- **New subcommand:** `steer daemon [--socket /tmp/steer.sock]`
- Accepts newline-delimited JSON commands on stdin or Unix domain socket
- Keeps Vision ML model warm in memory (saves 100-300ms cold-load per OCR)
- Keeps ElementStore cache populated (instant snapshot lookups)
- Amortizes framework initialization across all commands
- **Expected impact:** Eliminates 150-450ms overhead per call

#### 2.2 ScreenCaptureKit migration
- Replace `CGWindowListCreateImage` with `SCStream` for persistent async frame capture
- In daemon mode, maintain a running stream and grab latest frame buffer on demand
- **Expected impact:** ~20ms captures vs ~100ms current, after initial stream setup

### Phase 3: Smarter Internals

#### 3.1 Parallel screenshot + AX tree
- **File:** `Sources/steer/See.swift`
- Screenshot capture and accessibility tree walk are independent. Run with `async let` concurrently.
- **Impact:** Overlaps two 50-500ms operations.

#### 3.2 Batched AX attribute fetching
- **File:** `Sources/steer/AccessibilityTree.swift`
- Use `AXUIElementCopyMultipleAttributeValues` to fetch all attributes in one IPC call per element instead of 8 separate calls.
- **Impact:** 30-50% faster tree walks for complex apps.

#### 3.3 Combined commands
- Add `steer find-and-click --text "Submit" --app Safari` that does see + OCR + coordinate lookup + click in one process.
- Eliminates the most common multi-invocation pattern.

## AI Cost Considerations

### Current model: Claude Code (Opus) drives steer directly

Each steer call returns JSON that Claude Code processes to decide the next action. The slow steer loop means:
- Claude Code is **idle waiting** for steer between decisions
- But it's NOT consuming extra tokens while waiting — latency doesn't cost more tokens
- The token cost comes from the **number of tool calls** and the **size of the JSON responses** (element lists, OCR results)

### Question: Does faster steer = more AI cost?

**Probably not, if done right.** The number of steer calls in a task is determined by the complexity of the task, not steer's speed. A faster steer just completes the same sequence faster. However:

- If we make steer return **richer data** (e.g., full OCR + elements in one call), the agent might need **fewer round trips**, actually **reducing** token usage
- Combined commands (`find-and-click`) would eliminate tool calls entirely for simple patterns

### Alternative: Cheaper model for simple actions

If steer becomes fast enough, the bottleneck shifts to the LLM decision time. Options:

- **Haiku for routine actions:** For simple "click the button labeled X" or "type this text" patterns, a smaller/cheaper model could interpret steer output and issue the next command. Reserve Opus/Sonnet for complex reasoning.
- **Rule-based fallback:** For the most mechanical patterns (enter code character by character, click Continue), skip the LLM entirely and use a simple script that reads OCR output and acts.
- **Hybrid approach:** Claude Code (Opus) plans the high-level sequence, then delegates GUI execution to a Haiku-powered loop that runs steer commands rapidly.

### Recommendation

Start with Phase 1 quick wins — they're zero-cost in terms of AI usage and purely reduce wall-clock time. Measure the before/after. Then evaluate:

1. If Phase 1 alone makes the loop fast enough → done, no cost increase
2. If daemon mode (Phase 2) is needed → still no AI cost increase, just faster execution
3. If we want to optimize AI cost too → explore Haiku delegation for mechanical GUI actions

## Phase 1 Results

Benchmark run on macOS 26.2, Apple Silicon, targeting Google Chrome.

| Command | Baseline | Phase 1 | Speedup |
|---------|----------|---------|---------|
| `see` (with save) | 236ms | 212ms | 1.1x |
| `see --no-save` | n/a | 123ms | NEW — 1.9x vs save |
| `ocr` (fast, default) | 394ms | 86ms | **4.6x** |
| `ocr --accurate` | 394ms | 279ms | 1.4x (lang correction off) |
| `click` | 103ms | 65ms | **1.6x** |
| 3x `see+ocr` loop | 1,610ms | 701ms | **2.3x** |

### OCR Quality (fast vs accurate)

| Mode | Elements Found | Time |
|------|---------------|------|
| `.fast` | 34 | 86ms |
| `.accurate` | 43 | 279ms |

Fast mode finds ~80% of elements at 3.2x the speed. Misses smaller text but catches all major UI elements (buttons, links, headings). For agent automation loops, fast mode is sufficient. Use `--accurate` when precision matters.

### Phase 1 Changes Made

- `OCR.swift`: Default to `.fast` recognition, disabled language correction, added `--accurate` and `--language-correction` opt-in flags
- `OcrCommand.swift`: New `--accurate` and `--language-correction` flags
- `See.swift`: Added `--no-save` flag to skip PNG write to disk
- `MouseControl.swift`: Reduced click sleeps from 70ms to 35ms total

## Future Phases

### Phase 4: iOS Simulator Support (proposed)

Steer's screenshot and OCR approach should work with iOS Simulator out of the box since Simulator is a macOS window. However:

- `CGWindowListCreateImage` can capture Simulator windows (screenshot works)
- OCR would work on Simulator content (text recognition works)
- Clicks via `CGEvent` would land on Simulator windows (input works)
- **AX tree will NOT expose iOS UI elements** — Simulator doesn't bridge iOS accessibility to macOS AX
- Steer's OCR-based element detection (O1, O2, etc.) is the path for Simulator, same as Electron apps

**Implementation:** No steer changes needed for basic Simulator support. The existing `steer see --app Simulator` + `steer ocr --app Simulator --store` + `steer click --on O1` pattern should work. Needs testing and possibly a helper for Simulator-specific actions (Home button, rotation, etc.).

### Phase 5: Better Electron App Support (proposed)

Current limitation: Electron apps (VS Code, Slack, Discord) return empty AX trees. OCR is the workaround but has gaps:
- White text on colored buttons can be missed by OCR (we saw this with GitHub's green Continue button)
- Small icons without text are invisible to OCR

**Potential improvements:**
- Auto-fallback to OCR when AX tree is empty (currently requires `--ocr` flag on `see`)
- Image-based element detection for common UI patterns (checkboxes, icons)
- Template matching for known app UIs

## Phase 1.5: Burst Capture (Record Command)

Added `steer record` — a burst screenshot capture mode for observing temporal UI changes.

### Usage

```bash
# Capture 3 seconds at 10fps (30 frames)
steer record --duration 3 --fps 10 --app "Google Chrome"

# Quick burst — 1 second at 20fps
steer record --duration 1 --fps 20

# Timing benchmark only (no disk writes)
steer record --duration 2 --fps 15 --no-save

# Machine-readable output
steer record --duration 2 --fps 5 --json
```

### Design Decisions

- **JPEG only** — PNG encoding is too slow for burst mode. JPEG at 0.8 quality gives ~285KB per frame vs ~1MB+ for PNG, with 2-4x faster encoding.
- **No AX tree / OCR** — these add 100-400ms overhead per frame. Record is pure screenshot capture for maximum throughput.
- **Frames saved to temp directory** — `/tmp/steer/record-<session-id>/frame-001.jpg`, `frame-002.jpg`, etc.
- **FPS cap at 30** — above this, the capture + encode + save overhead exceeds the frame interval.

### Benchmark Results

| Requested FPS | Actual FPS | Frames (2s) | Notes |
|--------------|-----------|-------------|-------|
| 5 | 5.3 | 10 | ~285KB/frame |
| 10 | 10.1 | 10 (1s) | Solid |
| 20 | 19.2 | 20 (1s) | Near limit |

### Use Cases

- **Animation verification**: Click a button, immediately burst capture to see if a spring/tween/CSS transition actually animated
- **Loading state testing**: Navigate to a page, capture frames to see loading → loaded transition
- **Route transition debugging**: Capture frames during a page navigation to spot stale content or flicker
- **CI/visual regression**: Capture burst during interaction, compare frames against baseline

### Example: Testing a Spring Animation

```bash
# Click the "Bounce" button then immediately record
steer click --on B5 --snapshot abc123 && steer record --duration 2 --fps 10 --app "Google Chrome"
# Then read frames to verify the box moved
```

## Testing Plan

1. **Benchmark current steer:** Time each command type (`see`, `ocr`, `click`, `type`) in isolation and in a loop
2. **Apply Phase 1 changes** on this branch (`steer-perf-experiment`)
3. **Benchmark again** with same test suite
4. **Run a real task** (e.g., "open Safari, navigate to a URL, click a link") and compare total time
5. **Monitor token usage** via Claude Code's billing to confirm no cost increase

## Rollback

All work is on branch `steer-perf-experiment`. Main branch is untouched.

```bash
# To go back to the original:
git checkout main

# To compare:
git diff main..steer-perf-experiment -- apps/steer/
```
