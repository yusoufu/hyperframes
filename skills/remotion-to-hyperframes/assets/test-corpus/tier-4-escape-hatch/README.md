# Tier 4 — escape-hatch

## What it tests

T4 is the **lint-only** tier. There are no renders to diff — the skill is
graded on whether it correctly _refuses_ to translate each case (and
recommends the runtime interop pattern from PR #214 instead) or, where
appropriate, translates after dropping warning-level decorations.

Each `cases/*.tsx` file is a minimal Remotion composition that
demonstrates one specific pattern. The skill should:

1. Run `scripts/lint_source.py` over the source.
2. Compare the JSON output to `expected.json` for that case.
3. Take the documented `skill_action`:
   - `refuse_translation_recommend_interop` — print the rationale + link to
     the PR #214 interop guide; do not produce HF output.
   - `drop_lambda_code_translate_remainder_if_clean` — drop the
     `@remotion/lambda` code with a note; translate the rest only if no
     other blockers are present.
   - `translate_after_dropping_wrappers` — translate normally; drop
     `useCallback` / `useMemo` / `delayRender` wrappers.
   - `inline_hook_body_if_pure` — inline the custom hook's body if it's a
     pure derivation of `useCurrentFrame`; otherwise bow out.

## Cases

| #   | File                       | Expected blocker              | Notes                                       |
| --- | -------------------------- | ----------------------------- | ------------------------------------------- |
| 01  | `01-use-state.tsx`         | `r2hf/use-state`              | useState driving animation                  |
| 02  | `02-use-effect-deps.tsx`   | `r2hf/use-effect-deps`        | useEffect with non-empty deps + side effect |
| 03  | `03-async-metadata.tsx`    | `r2hf/async-metadata`         | calculateMetadata returns a Promise         |
| 04  | `04-third-party-react.tsx` | `r2hf/third-party-react-ui`   | imports `@mui/material`                     |
| 05  | `05-lambda-config.tsx`     | `r2hf/lambda-import`          | imports `@remotion/lambda`                  |
| 06  | `06-warnings-only.tsx`     | (warnings only)               | delayRender / useCallback / useMemo         |
| 07  | `07-custom-hook.tsx`       | (warnings only)               | locally-defined `useFadeIn`                 |
| 08  | `08-mixed.tsx`             | useState + useEffect + chakra | aggregate-findings test                     |

## Validation

```bash
./validate.sh
```

The script runs `lint_source.py` against each case and asserts:

- Each expected blocker rule fires with severity `blocker`.
- Each expected warning rule fires with severity `warning` (or stronger).
- `lint_source.py`'s exit code is 1 when blockers are expected, 0 otherwise.

T4 passes when every case matches its expected output. No renders involved.
