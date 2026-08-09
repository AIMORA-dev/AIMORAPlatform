# AIMORAProject.jl

`AIMORAProject.jl` is the public owner for AIMORA's canonical semantic project model, typed revisions, transactions, commands, queries, provenance, and view metadata. It contains no solver, GUI toolkit, parser duplication, executable callback, or private runtime type; existing engine consumers remain canonical until an authorized migration moves them to this public boundary.

The current semantic layer provides immutable project/global IDs, namespaces, typed local/external references and JSON Pointer paths, exact decimal/rational quantities, controlled unit/base/orientation conversion, provenance, licences, uncertainty, checksummed artifact identities, and a versioned callback-free semantic schema registry. Canonical physical values require provenance, quantity schemas require explicit dimensions and orientations, per-unit values require typed base references, schema and namespace collisions reject deterministically, and no schema field stores an arbitrary Julia value or hidden physical default. Immutable projects and revisions add typed ordered commands, validated transactions, rollback, deterministic replay, undo where defined, exact changed-owner and dependency-invalidation signals, explicit unverified developer construction, and revision-pinned query snapshots.

Run `julia --project=. examples/canonical_primitives.jl` for primitive construction, `julia --project=. examples/transactional_project.jl` for revisions and transactions, or `julia --project=. examples/semantic_graphs.jl` for typed physical topology built through commands.

## Licence

This repository's AIMORA-authored content is distributed under the PolyForm Noncommercial License 1.0.0. Research, education, personal study, public-interest noncommercial use, and other purposes permitted by that licence are free; commercial use requires a separate written agreement with Ahmed Elkholy <ahmed_elkholy@f-eng.tanta.edu.eg>. There is no licence key, activation, telemetry, or technical feature restriction. Clearly identified third-party material retains its own terms, and copies received under an earlier licence retain those prior grants.
