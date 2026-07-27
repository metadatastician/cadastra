<!--
SPDX-License-Identifier: CC-BY-SA-4.0
Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->
# Architecture

## Overview

Cadastra is the hyperpolymath estate's *observer*: a survey/reporting tool,
not a service. It scans repos, classifies them, and writes a triage report
that the owner (or downstream tooling) acts on. It does not mutate the
estate itself — the migration scripts it houses are executors that the
owner runs deliberately; running them is the owner's act, not Cadastra's
identity (see `.machine_readable/descriptiles/anchors/ANCHOR.a2ml`).

## Pipeline

```
estate repos (GitHub + local checkouts)
        │
        ▼
tools/estate-migration-toolkit/scripts/estate-scan.sh
        │  (gh CLI + jq + git; classifies CLEAN/MIGRATE/KILL/DONE/FORK,
        │   detects anti-patterns: banned languages, DENO_NOT_BUN,
        │   DIRECT_FFI_NO_HEXADECA, NIF_WITHOUT_SNIF, ...)
        ▼
docs/status/estate-triage-report.csv
        │
        ▼
owner triage: KILL / MIGRATE / CLEAN
        │  (optionally via the toolkit's other scripts:
        │   rollout-language-gate.sh, deprecate-poly-mcps.sh,
        │   find-nif-to-snif.sh, migrate-deno-to-bun.sh,
        │   check-proven-bindings.sh)
        ▼
downstream repos
```

## Directory structure

```
.
├── tools/estate-migration-toolkit/  # The scan + migration toolkit (the point of this repo)
│   ├── scripts/                     # estate-scan.sh + the migration executors
│   ├── ci/                          # Shared CI policy shipped to other repos
│   └── templates/                   # Per-repo policy templates
├── docs/status/estate-triage-report.csv  # Latest scan output (generated, committed)
├── src/interface/                   # RSR scaffold's reference ABI/FFI example
│   ├── Abi/                         # Idris2 type + layout proofs
│   └── ffi/                         # Zig FFI implementation
├── .machine_readable/               # Machine-readable identity, policy, AI configs
├── docs/                            # Onboarding, status, governance, practice, decisions
├── tests/, benches/                 # Test suites and benchmarks
├── LICENSE, LICENSES/                # MPL-2.0 (code) / CC-BY-SA-4.0 (docs)
└── README.adoc                      # Project documentation
```

## Design principles

- **Observe, don't decide.** Cadastra reports what state the estate is in;
  it does not encode policy about what the estate *ought* to be
  (that authority lives in `standards` / `metadatastician-governance`).
- **Ground truth over memory.** The triage report reflects what running
  `estate-scan.sh` actually found at scan time, not what a status doc claims.
- **Separation of survey vs. registry.** Cadastra records *observed state*
  (languages, anti-patterns, freshness); it is not the estate's identity
  registry (that is `gv-clade-index`) and does not decide what the estate
  ought to be.

## Security considerations

- The toolkit reads via the `gh` CLI using the invoking user's own
  credentials; it does not embed or persist tokens.
- `estate-triage-report.csv` reflects only what the scanning credential
  could read at scan time — absence from it is not evidence of absence.
- Secrets are never committed to the repository.

## Maintainability

- Code follows the estate's RSR conventions (SPDX headers, `.machine_readable/`
  metadata, `Justfile` task orchestration).
- Pull requests require CI checks (quality, security, RSR anti-pattern
  enforcement — see `.github/workflows/`).
- Progress and blockers are tracked in
  `.machine_readable/descriptiles/STATE.a2ml`, not in ad hoc TODO files.

---

*Last updated: 2026-07-27.*
