#!/usr/bin/env bash
# validate.sh — assert lint_source.py output matches expected.json for every T4 case.
#
# T4 has no renders to diff. The skill is graded on whether it correctly
# refuses to translate each case (or drops only the lambda config in case 5,
# or warns appropriately in cases 6 and 7).
#
# Usage:
#   ./validate.sh
# Exit 0 on pass.

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINT="$THIS_DIR/../../../scripts/lint_source.py"
EXPECTED="$THIS_DIR/expected.json"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ ! -f "$LINT" ]]; then
  echo "error: lint_source.py not found at $LINT" >&2
  exit 2
fi
if [[ ! -f "$EXPECTED" ]]; then
  echo "error: expected.json not found at $EXPECTED" >&2
  exit 2
fi

FAIL=0
PASS=0

# Iterate every case file in expected.json and run lint_source against it.
python3 - "$EXPECTED" "$THIS_DIR" "$LINT" "$WORK" <<'PY'
import json
import subprocess
import sys
from collections import Counter
from pathlib import Path

expected_path = Path(sys.argv[1])
cases_dir = Path(sys.argv[2]) / "cases"
lint = Path(sys.argv[3])
work = Path(sys.argv[4])

expected = json.loads(expected_path.read_text())

fails: list[str] = []
passes: list[str] = []

for case in expected["cases"]:
    file_name = case["file"]
    fixture = cases_dir / file_name
    if not fixture.exists():
        fails.append(f"{file_name}: fixture missing at {fixture}")
        continue

    out_file = work / f"{file_name}.json"
    proc = subprocess.run(
        ["python3", str(lint), str(fixture), "--json"],
        capture_output=True,
        text=True,
    )
    out_file.write_text(proc.stdout)
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        fails.append(f"{file_name}: lint output not JSON ({e})")
        continue

    rule_counts: Counter[str] = Counter()
    severity_by_rule: dict[str, str] = {}
    for finding in result.get("findings", []):
        rule_counts[finding["rule"]] += 1
        severity_by_rule[finding["rule"]] = finding["severity"]

    case_failed = False

    for expected_blocker in case["expected"]["blockers"]:
        rule = expected_blocker["rule"]
        min_count = expected_blocker["min_count"]
        actual = rule_counts[rule]
        actual_severity = severity_by_rule.get(rule)
        if actual < min_count:
            fails.append(
                f"{file_name}: expected ≥{min_count} blocker findings of rule {rule}, got {actual}"
            )
            case_failed = True
        elif actual_severity != "blocker":
            fails.append(
                f"{file_name}: rule {rule} found but severity={actual_severity!r} (expected blocker)"
            )
            case_failed = True

    for expected_warning in case["expected"]["warnings"]:
        rule = expected_warning["rule"]
        min_count = expected_warning["min_count"]
        actual = rule_counts[rule]
        actual_severity = severity_by_rule.get(rule)
        if actual < min_count:
            fails.append(
                f"{file_name}: expected ≥{min_count} warning findings of rule {rule}, got {actual}"
            )
            case_failed = True
        elif actual_severity not in {"warning", "blocker"}:
            fails.append(
                f"{file_name}: rule {rule} found but severity={actual_severity!r} (expected warning or stronger)"
            )
            case_failed = True

    # If the case has no expected blockers, the lint exit code should be 0.
    expected_blockers_count = len(case["expected"]["blockers"])
    expected_rc = 1 if expected_blockers_count > 0 else 0
    if proc.returncode != expected_rc:
        fails.append(
            f"{file_name}: lint exit code {proc.returncode}, expected {expected_rc} "
            f"(blockers expected: {expected_blockers_count})"
        )
        case_failed = True

    if not case_failed:
        passes.append(file_name)

print(f"Passed: {len(passes)}")
for f in passes:
    print(f"  ✓ {f}")
if fails:
    print(f"Failed: {len(fails)}")
    for msg in fails:
        print(f"  ✗ {msg}")
    sys.exit(1)
sys.exit(0)
PY
