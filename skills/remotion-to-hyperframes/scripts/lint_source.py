#!/usr/bin/env python3
"""Lint a Remotion project for patterns that don't translate cleanly to HyperFrames.

The skill should run this *before* attempting a translation. If any blocker
findings come back, the recommendation is to use the runtime interop pattern
from PR #214 instead of producing broken HTML.

Usage:
    lint_source.py <path-to-remotion-src> [--json]

Output (default human-readable, --json for machine-readable):
    For each .ts/.tsx file, a list of findings with:
      - severity: blocker | warning | info
      - line, column
      - rule id
      - message
      - recommendation

Blockers (skill should refuse to translate):
  - r2hf/use-state            React state machine drives animation
  - r2hf/use-effect-deps      useEffect with non-empty deps (side effects)
  - r2hf/use-reducer          useReducer drives animation
  - r2hf/async-metadata       calculateMetadata returns a Promise
  - r2hf/lambda-import        @remotion/lambda configuration code
  - r2hf/third-party-react-ui Imports a React UI library (shadcn, mui, antd, mantine, chakra)

Warnings (translate but flag):
  - r2hf/delay-render         delayRender() — HF handles asset loading differently
  - r2hf/use-callback         useCallback — usually decorative, drop
  - r2hf/use-memo             useMemo — usually decorative, drop
  - r2hf/custom-hook          Custom hook (use*) defined locally; may need manual rewrite

Info (translate and document):
  - r2hf/static-file          staticFile("x") — convert to relative path
  - r2hf/interpolate-colors   interpolateColors — translate to GSAP color tween
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path

BLOCKER = "blocker"
WARNING = "warning"
INFO = "info"

THIRD_PARTY_UI_PACKAGES = {
    "@mui/material",
    "@mui/icons-material",
    "@chakra-ui/react",
    "@mantine/core",
    "antd",
    "@shadcn/ui",
    "@radix-ui",
    "@nextui-org/react",
}


@dataclass
class Finding:
    file: str
    line: int
    column: int
    severity: str
    rule: str
    message: str
    recommendation: str


# Each rule: (pattern, severity, rule_id, message, recommendation).
# Patterns are MULTILINE so ^/$ match line boundaries; we still report the
# line number by re-scanning the line offset.
RULES: list[tuple[re.Pattern[str], str, str, str, str]] = [
    (
        re.compile(r"\buseState\s*[(<]"),
        BLOCKER,
        "r2hf/use-state",
        "useState detected — Remotion compositions that drive animation via React state are not deterministic frame-capture targets in HyperFrames",
        "Use the runtime interop pattern from PR #214 instead of attempting a translation",
    ),
    (
        re.compile(r"\buseReducer\s*[(<]"),
        BLOCKER,
        "r2hf/use-reducer",
        "useReducer detected — same issue as useState",
        "Use the runtime interop pattern from PR #214",
    ),
    (
        # useEffect with deps array that isn't [] — i.e. side effects per dep change.
        # Multi-line bodies are common, so we use re.DOTALL and look for the
        # closing `} , [ <something> ]` signature instead of trying to parse
        # the body. The body itself can contain commas and nested closures.
        re.compile(r"useEffect\s*\([\s\S]*?\}\s*,\s*\[[^\]]+\]", re.DOTALL),
        BLOCKER,
        "r2hf/use-effect-deps",
        "useEffect with non-empty deps — side effects don't translate to HF's seek-driven model",
        "Move the side-effect work into a build step, or use the runtime interop pattern",
    ),
    (
        # `async` followed by `calculateMetadata` (with optional whitespace and `:` for type annotations).
        re.compile(r"calculateMetadata[^=]*=\s*async\b|async\s+calculateMetadata\b|calculateMetadata\s*:\s*async"),
        BLOCKER,
        "r2hf/async-metadata",
        "calculateMetadata returns a Promise — HF needs composition metadata up front",
        "Resolve metadata at build time and pass concrete values, or use runtime interop",
    ),
    (
        re.compile(r"from\s+['\"]@remotion/lambda['\"]"),
        BLOCKER,
        "r2hf/lambda-import",
        "@remotion/lambda is Remotion-specific distributed rendering — no HF equivalent today",
        "HF runs single-machine. Drop the Lambda config and document the gap",
    ),
    (
        re.compile(r"\bdelayRender\s*\("),
        WARNING,
        "r2hf/delay-render",
        "delayRender() — HF waits on asset readiness via the Frame Adapter pattern",
        "Drop the call; HF handles this transparently",
    ),
    (
        re.compile(r"\buseCallback\s*\("),
        WARNING,
        "r2hf/use-callback",
        "useCallback — typically decorative for render performance, no HF equivalent needed",
        "Drop the wrapper, inline the function",
    ),
    (
        re.compile(r"\buseMemo\s*\("),
        WARNING,
        "r2hf/use-memo",
        "useMemo — typically decorative, no HF equivalent needed",
        "Drop the wrapper, compute inline",
    ),
    (
        re.compile(r"\bstaticFile\s*\("),
        INFO,
        "r2hf/static-file",
        "staticFile() reference — convert to a relative path in the HF composition",
        "Replace `staticFile(\"x.png\")` with `\"x.png\"` and copy the asset alongside the HTML",
    ),
    (
        re.compile(r"\binterpolateColors\s*\("),
        INFO,
        "r2hf/interpolate-colors",
        "interpolateColors() — translate to a GSAP color tween",
        "See references/timing.md for the GSAP equivalent",
    ),
]


def lint_file(path: Path) -> list[Finding]:
    src = path.read_text()
    findings: list[Finding] = []

    # Line/column from a string offset.
    def loc(offset: int) -> tuple[int, int]:
        line = src.count("\n", 0, offset) + 1
        col = offset - (src.rfind("\n", 0, offset) + 1) + 1
        return line, col

    for pattern, severity, rule, message, rec in RULES:
        for m in pattern.finditer(src):
            line, col = loc(m.start())
            findings.append(Finding(str(path), line, col, severity, rule, message, rec))

    # Custom hook detection: any `function useXxx(` or `const useXxx = ` defined in this file.
    for m in re.finditer(r"^\s*(?:function|const|let)\s+(use[A-Z]\w+)\b", src, re.MULTILINE):
        name = m.group(1)
        # Skip Remotion's own hooks — they're imported, not defined.
        if name in {"useCurrentFrame", "useVideoConfig"}:
            continue
        line, col = loc(m.start())
        findings.append(
            Finding(
                str(path),
                line,
                col,
                WARNING,
                "r2hf/custom-hook",
                f"Custom hook `{name}` defined locally — may need manual rewrite",
                "Inline the hook body if pure; bow out to runtime interop if it uses useState/useEffect",
            )
        )

    # Third-party React UI library imports.
    for m in re.finditer(r"from\s+['\"]([^'\"]+)['\"]", src):
        pkg = m.group(1)
        if any(pkg.startswith(blocker) for blocker in THIRD_PARTY_UI_PACKAGES):
            line, col = loc(m.start())
            findings.append(
                Finding(
                    str(path),
                    line,
                    col,
                    BLOCKER,
                    "r2hf/third-party-react-ui",
                    f"Imports `{pkg}` — third-party React UI library has no HF equivalent",
                    "Use runtime interop, or rewrite the affected components as HTML+CSS",
                )
            )

    findings.sort(key=lambda f: (f.file, f.line, f.column))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", type=Path, help="Directory or file to lint")
    ap.add_argument("--json", action="store_true", help="Emit JSON instead of human-readable output")
    args = ap.parse_args()

    if not args.path.exists():
        print(f"error: {args.path} does not exist", file=sys.stderr)
        return 2

    files: list[Path]
    if args.path.is_file():
        files = [args.path]
    else:
        files = sorted(
            p
            for p in args.path.rglob("*")
            if p.is_file()
            and p.suffix in {".ts", ".tsx", ".jsx", ".js"}
            and "node_modules" not in p.parts
        )

    all_findings: list[Finding] = []
    for f in files:
        all_findings.extend(lint_file(f))

    blockers = sum(1 for f in all_findings if f.severity == BLOCKER)
    warnings = sum(1 for f in all_findings if f.severity == WARNING)
    infos = sum(1 for f in all_findings if f.severity == INFO)

    if args.json:
        json.dump(
            {
                "files_scanned": len(files),
                "blockers": blockers,
                "warnings": warnings,
                "infos": infos,
                "findings": [asdict(f) for f in all_findings],
            },
            sys.stdout,
            indent=2,
        )
        sys.stdout.write("\n")
    else:
        for f in all_findings:
            print(f"{f.file}:{f.line}:{f.column} [{f.severity}] {f.rule}: {f.message}")
            print(f"    -> {f.recommendation}")
        print()
        print(f"{len(files)} files scanned · {blockers} blocker · {warnings} warning · {infos} info")
        if blockers:
            print("RECOMMENDATION: do not attempt translation. Use the runtime interop pattern from PR #214.")

    return 1 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
