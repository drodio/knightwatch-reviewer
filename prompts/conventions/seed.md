# SEED-convention repo — how to review this PR

This is a **SEED-convention repo** (its base ref carries a root `SEED.md`, or
its slug is `seed-*` / `openseed`). Review it by the SEED grammar below, NOT as
a general application repo. This file is authoritative for *how* to review this
repo; where it conflicts with a default reviewer instinct (e.g. "demand a
justfile / unit-test harness"), this file wins.

## What is authoritative

- **`SEED.md` + `README.md` are the contract.** They are RFC-2119 prose (MUST /
  SHOULD / MAY). The prose IS the spec — there is no separate design doc.
- **`ref/` is a single-operator *reference implementation* of that prose**, not a
  product or distribution target. Review `ref/` for **prose↔ref drift**, not for
  product-scale hardening.
- **Operating point:** pre-PMF, often a single operator, fewer than 10 users.
  Abstractions, flags, parallel modes, and defensive edge-case handling sized for
  thousands of users are over-engineering here, not robustness. A handled edge
  case the prose never asked for is a cost, not a feature.

## The test gate — `## Verification`, NOT `just test`

A SEED's tests live in its **`## Verification`** section (a list of prose probes)
and, optionally, in `ref/verify.sh` (a single-operator realization of those
probes). **That section / script IS the test suite.**

- A missing root `justfile` and a `test-results.md` reading "not run (no
  justfile)" are the **EXPECTED shape** for a SEED, **not a coverage gap**. Do
  NOT probe for a root `justfile`, a unit-test harness, CI fences, or a
  `tests/` dir. Do NOT treat "just test not run" as a missing-coverage finding.
- The reviewer does **not** execute `ref/verify.sh` (side-effect / secret
  hazard). Evaluate the **prose↔ref correspondence** by reading, not running.
- Flag a test/verification finding ONLY when a `ref/` change would **break
  `ref/verify.sh`** or makes a prose `## Verification` probe no longer pass —
  the canonical SEED regression.

## Suppress vs. flag (SEED-specific contrast pairs)

| DON'T (suppress / treat as expected shape) | DO (real finding) |
|---|---|
| Flag `ref/` for missing abstractions, scale-hardening, extra flags, or defensive edge cases — it's a single-operator reference impl. | Flag a `ref/` change that breaks `ref/verify.sh` or makes a `## Verification` probe no longer pass. |
| Probe for a root `justfile` / unit-test harness / CI fence; treat "just test not run" as a gap. | Flag **prose↔ref drift**: `install.sh` diverging from `## Dependencies`, or `verify.sh` behavior diverging from the `## Verification` probes. |
| Treat prose-only edits (Objects / Actions wording) as low-value churn. | Flag a clone URL (in spec text or `ref/` shell) carrying **userinfo / query / fragment** (argv-leakage). |
| Suggest "approve all" / batched shell to speed an install script. | Flag any `ref/` install/verify shell that **batches or auto-approves** — violates per-block confirm. |
| Demand prose for a heavy install path. | Flag a heavy install (material disk / runtime / paid API) that doesn't surface cost to the user. |
| — | Flag any **literal secret** in `SEED.md`/`README.md`, or a probe that surfaces secret *values* (`env`/`printenv`, `cat` of credential files, `git remote -v`, `docker compose config`). Presence/name-only probes are the conforming form. |
| — | Flag **grammar violations**: a non-conforming or out-of-order H2; a `# Purpose` body that isn't the single `README#Purpose` wikilink; shell smuggled into `## Objects` / `## Actions`; or state-mutating instructions added to `## Verification` (authoring-read-only). |

**Cultural emphasis:** SIMPLIFY at all costs — subtractive remedies (delete,
collapse, inline) outrank additive ones at every severity. The prose is the
contract; `ref/` is one realization of it.
