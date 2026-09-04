# AIMORALayout

`AIMORALayout` generates deterministic presentation geometry for canonical AIMORA drawings.

The engine reads connectivity only from explicit semantic view projections, ports, and physical connections. It provides initial, full, local, and incremental layout; stable integer-grid placement; repeated-bay alignment and boundaries; orthogonal routes; collision-reduced labels; deterministic page splitting; and preservation of locked, manual, or out-of-scope records.

`layout_project` returns a new canonical project and refuses the result unless its physics hash is identical to the input. Geometry is never interpreted as electrical topology.

## Licence

This repository's AIMORA-authored content is distributed under the PolyForm Noncommercial License 1.0.0. Research, education, personal study, public-interest noncommercial use, and other purposes permitted by that licence are free; commercial use requires a separate written agreement with Ahmed Elkholy <ahmed_elkholy@f-eng.tanta.edu.eg>. There is no licence key, activation, telemetry, or technical feature restriction. Clearly identified third-party material retains its own terms, and copies received under an earlier licence retain those prior grants.
