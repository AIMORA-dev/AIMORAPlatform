# AIMORAService

`AIMORAService` is the public Julia owner for the versioned process/API boundary used by the native AIMORAStudio client, notebooks, automation, and separately admitted future clients. It transports canonical commands, schemas, readiness, jobs, typed results, visual queries, report requests, and artifacts without duplicating engineering semantics or exposing private solver internals.

## Native desktop boundary

The accepted first-release process model is:

```text
AIMORAStudio C++/Qt process
        |
        | authenticated local socket or named pipe
        v
AIMORAService.jl
        |
        | bounded worker protocol
        v
AIMORA study worker using AIMORA.jl and AIMORASolvers.jl
```

The lightweight service starts lazily when a project or engineering command requires it. Solver-heavy workers start only for accepted requested studies or remain in a bounded pool. The first release does not embed `libjulia` into the GUI process.

The service owns:

- capability and protocol-version negotiation;
- project sessions, exact revisions, transactions, validation, and typed errors;
- schema-driven inspector queries and affected-object patches;
- study preparation, status, progress, cancellation, checkpoint, restore, and worker lifecycle;
- bounded binary and windowed result access;
- visual, drawing-publication, DXF, and report requests routed to canonical owners;
- restart, idempotency, ordering, authentication hooks, path confinement, and leakage prevention.

It does not own physical equations already assigned to `AIMORA.jl`, private numerical kernels, client rendering state, or a second project model.

No pointer event and no numerical timestep is a service message. The client commits one completed canonical edit at a time; a study returns bounded progress, significant events, selected live summaries, event-preserving display windows, and immutable artifact references.

## Licence

This repository's AIMORA-authored content is distributed under the PolyForm Noncommercial License 1.0.0. Research, education, personal study, public-interest noncommercial use, and other purposes permitted by that licence are free; commercial use requires a separate written agreement with Ahmed Elkholy <ahmed_elkholy@f-eng.tanta.edu.eg>. There is no licence key, activation, telemetry, or technical feature restriction. Clearly identified third-party material retains its own terms, and copies received under an earlier licence retain those prior grants.