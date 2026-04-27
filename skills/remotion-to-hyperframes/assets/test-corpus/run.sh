#!/usr/bin/env bash
# run.sh — corpus orchestrator. Runs every tier and prints a pass/fail summary.
#
# Tiers 1-3: render Remotion baseline + HF translation, run SSIM diff,
#            assert mean >= ssim_threshold from each fixture's expected.json.
# Tier 4:    runs cases/validate.sh which lints each case and asserts against
#            expected.json.
#
# Usage:
#   ./run.sh                    run all tiers
#   ./run.sh tier-1-title-card  run a single tier
#
# Requirements:
#   - ffmpeg, ffprobe, python3 on PATH
#   - node 22 (for the HF CLI)
#   - npm (for Remotion installs)
#   - HF CLI built at packages/cli/dist/cli.js (run `bun run --filter @hyperframes/core build`
#     in the repo root if missing)
#
# Output:
#   <fixture>/diff/summary.json   per-fixture SSIM summary
#   <fixture>/strip/strip.png     per-fixture comparison strip (only on fail)
#   ./run-report.json             aggregate report

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# THIS_DIR is .../skills/remotion-to-hyperframes/assets/test-corpus
SKILL_DIR="$(cd "$THIS_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"

LINT="$SKILL_DIR/scripts/lint_source.py"
DIFF="$SKILL_DIR/scripts/render_diff.sh"
STRIP="$SKILL_DIR/scripts/frame_strip.sh"
HF_CLI="$REPO_ROOT/packages/cli/dist/cli.js"

if [[ ! -f "$HF_CLI" ]]; then
  echo "error: HF CLI not built. Run 'bun run --filter @hyperframes/core build' in $REPO_ROOT" >&2
  exit 2
fi
if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not on PATH" >&2
  exit 2
fi

REPORT="$THIS_DIR/run-report.json"
declare -a RESULTS=()

# Run a single render-tier fixture (T1, T2, T3).
run_render_tier() {
  local fixture_dir="$1"
  local fixture_name
  fixture_name=$(basename "$fixture_dir")
  local expected="$fixture_dir/expected.json"

  if [[ ! -f "$expected" ]]; then
    echo "  ⚠ $fixture_name: missing expected.json, skipping"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"skipped\",\"reason\":\"missing expected.json\"}")
    return 0
  fi

  local threshold
  threshold=$(python3 -c "import json; print(json.load(open('$expected'))['ssim_threshold'])")
  local composition_id
  composition_id=$(python3 -c "
import json, re
exp = json.load(open('$expected'))
# Composition ID is the first id in the Root.tsx — read it from the file.
try:
    src = open('$fixture_dir/remotion-src/src/Root.tsx').read()
    m = re.search(r'id=\"([^\"]+)\"', src)
    print(m.group(1) if m else 'Composition')
except Exception:
    print('Composition')
")

  echo "  ▶ $fixture_name (threshold $threshold, composition $composition_id)"

  # Setup binary assets if needed.
  if [[ -x "$fixture_dir/setup.sh" ]]; then
    "$fixture_dir/setup.sh" >/dev/null
  fi

  # Lint Remotion source.
  if ! python3 "$LINT" "$fixture_dir/remotion-src/src/" >/dev/null; then
    echo "    ✗ lint failed (blockers in Remotion source)"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"fail\",\"stage\":\"lint\"}")
    return 0
  fi

  # Install Remotion deps if needed.
  if [[ ! -d "$fixture_dir/remotion-src/node_modules" ]]; then
    echo "    ⏳ npm install (first run)"
    (cd "$fixture_dir/remotion-src" && npm install --silent --no-progress >/dev/null 2>&1)
  fi

  # Render Remotion baseline.
  echo "    ⏳ render Remotion baseline"
  (cd "$fixture_dir/remotion-src" && \
    npx --no-install remotion render "$composition_id" out/baseline.mp4 >/dev/null 2>&1) || {
    echo "    ✗ Remotion render failed"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"fail\",\"stage\":\"remotion-render\"}")
    return 0
  }

  # Render HF translation.
  echo "    ⏳ render HF translation"
  (cd "$fixture_dir" && \
    node "$HF_CLI" render hf-src/ --output hf.mp4 --quiet >/dev/null 2>&1) || {
    echo "    ✗ HF render failed"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"fail\",\"stage\":\"hf-render\"}")
    return 0
  }

  # SSIM diff with the fixture-specific threshold.
  if R2HF_SSIM_THRESHOLD="$threshold" "$DIFF" \
      "$fixture_dir/remotion-src/out/baseline.mp4" \
      "$fixture_dir/hf.mp4" \
      "$fixture_dir/diff" >/dev/null; then
    local mean
    mean=$(python3 -c "import json; print(json.load(open('$fixture_dir/diff/summary.json'))['mean'])")
    echo "    ✓ pass (mean SSIM $mean, threshold $threshold)"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"pass\",\"mean_ssim\":$mean,\"threshold\":$threshold}")
  else
    local mean
    mean=$(python3 -c "import json; print(json.load(open('$fixture_dir/diff/summary.json'))['mean'])")
    echo "    ✗ fail (mean SSIM $mean, threshold $threshold)"
    # Generate a strip for visual inspection on failure.
    "$STRIP" \
      "$fixture_dir/remotion-src/out/baseline.mp4" \
      "$fixture_dir/hf.mp4" \
      "$fixture_dir/strip" 8 >/dev/null
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"fail\",\"stage\":\"ssim\",\"mean_ssim\":$mean,\"threshold\":$threshold}")
  fi
}

# Run the lint-only T4 tier.
run_lint_tier() {
  local fixture_dir="$1"
  local fixture_name
  fixture_name=$(basename "$fixture_dir")

  echo "  ▶ $fixture_name (lint-only)"
  if "$fixture_dir/validate.sh" >/dev/null 2>&1; then
    echo "    ✓ pass (8/8 cases)"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"pass\",\"mode\":\"lint\"}")
  else
    echo "    ✗ fail (some cases mismatched expected.json)"
    RESULTS+=("{\"fixture\":\"$fixture_name\",\"status\":\"fail\",\"mode\":\"lint\"}")
  fi
}

echo "remotion-to-hyperframes corpus run"
echo "=================================="

# Tier 1-3 (render + diff)
for tier in tier-1-title-card tier-2-multi-scene tier-3-data-driven; do
  if [[ -n "${1:-}" && "$1" != "$tier" ]]; then
    continue
  fi
  if [[ -d "$THIS_DIR/$tier" ]]; then
    run_render_tier "$THIS_DIR/$tier"
  fi
done

# Tier 4 (lint only)
if [[ -z "${1:-}" || "$1" == "tier-4-escape-hatch" ]]; then
  if [[ -d "$THIS_DIR/tier-4-escape-hatch" ]]; then
    run_lint_tier "$THIS_DIR/tier-4-escape-hatch"
  fi
fi

# Aggregate.
python3 - "$REPORT" <<PY
import json
import sys
results_json = """[$(IFS=,; echo "${RESULTS[*]}")]"""
results = json.loads(results_json)
total = len(results)
passed = sum(1 for r in results if r["status"] == "pass")
failed = sum(1 for r in results if r["status"] == "fail")
skipped = sum(1 for r in results if r["status"] == "skipped")
report = {
    "total": total,
    "passed": passed,
    "failed": failed,
    "skipped": skipped,
    "results": results,
}
with open(sys.argv[1], "w") as f:
    json.dump(report, f, indent=2)
print()
print("=" * 50)
print(f"  passed {passed}/{total}, failed {failed}, skipped {skipped}")
print(f"  report → {sys.argv[1]}")
print("=" * 50)
sys.exit(0 if failed == 0 else 1)
PY
