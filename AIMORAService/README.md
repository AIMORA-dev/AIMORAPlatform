# AIMORAService

`AIMORAService` is the public Julia owner of the authenticated, versioned local-process
boundary used by native AIMORAStudio. GUI040 provides the first executable service,
client protocol, and bounded study-worker lifecycle without moving engineering equations
or private solver internals into the service.

## Implemented GUI040 surface

The package now provides:

- a framed local socket or Windows named-pipe protocol with `AMR1` magic and bounded
  control and binary frames;
- one-use token-file authentication and exact protocol-version negotiation;
- typed, sanitized errors that do not return Julia stack traces, private types, or server
  filesystem paths;
- capability, ping, and clean-shutdown requests;
- confined read-only project references identified by stable SHA-256 revisions;
- confined artifact references and bounded binary result-window transfer;
- cancellation markers for request identifiers;
- a generic, bounded, out-of-process worker supervisor with start/status/stop operations;
- authenticated worker readiness records carried through private owner-only files rather
  than command-line secrets or inherited public output;
- exact worker-protocol negotiation, opaque manifest identities, bounded process
  termination, generation accounting, and fixed-ceiling crash recovery;
- a deterministic JSON protocol schema and generated C++ method/error bindings;
- a command-line service entrypoint and authenticated worker probe;
- framing, authentication, versioning, path-confinement, binary-window, cancellation,
  worker authentication/recovery, generator, and local transport tests.

The project-reference operation is intentionally opaque in GUI040. It hashes and describes
an allowed file but does not parse it into a second model. Canonical project loading,
transactions, schemas, and study orchestration are connected in later packets through their
existing Julia owners.

## Process boundary

```text
AIMORAStudio C++/Qt process
        |
        | QLocalSocket / named pipe, authenticated AMR1 frames
        v
AIMORAService.jl
        |
        | fixed command + private launch token/readiness file
        v
AIMORA study worker
```

The GUI does not embed `libjulia`. The service does not start until an engineering command
requires it, and a solver-heavy worker is not started until explicitly requested. Pointer
movement and numerical timesteps are never service messages.

## Start the service

```bash
julia --startup-file=no --project=. bin/aimora-service.jl \
  --endpoint /tmp/aimora-session.sock \
  --token-file /tmp/aimora-session.token \
  --allowed-root /path/to/projects \
  --worker-program julia \
  --worker-arg --startup-file=no \
  --worker-arg bin/aimora-worker-probe.jl
```

The token file must contain at least 64 text bytes and be readable/writable only by its
owner on Unix. The service consumes and removes the file before accepting clients. Tokens
are not accepted on the command line and are never printed.

On startup the service emits exactly one readiness line:

```text
AIMORA_SERVICE_READY<TAB>1.0<TAB><endpoint>
```

Each worker receives a fresh launch token and private readiness-file path through its
process environment. Before `worker.start` succeeds, the child must atomically publish:

```text
AIMORA_STUDY_WORKER_READY<TAB>1.0.0<TAB><manifest-sha256><TAB><token-sha256>
```

The service checks the record in constant time, removes the private launch directory, and
returns only the worker ID, protocol version, manifest hash, generation, and bounded
recovery counters. Neither the token nor a filesystem path crosses service IPC.

## Protocol generation

The canonical schema is:

```text
schema/service_protocol.json
```

Regenerate the committed C++ bindings with:

```bash
julia --startup-file=no --project=. tools/generate_cpp_bindings.jl \
  schema/service_protocol.json \
  generated/cpp/include/aimora/studio/protocol/generated/service_protocol.hpp \
  generated/cpp/src/service_protocol.cpp
```

Tests regenerate into a temporary directory and require byte-for-byte equality with the
committed files. AIMORAWorkspace integration also compares these files with the copies
compiled by AIMORAStudio.

## Security and limits

The protocol rejects invalid magic, reserved bytes, frame kinds, truncated data, oversized
frames, malformed JSON, unsupported versions, unauthenticated requests, invalid request
identifiers, paths outside configured roots, symlink escapes, oversized resources, invalid
windows, worker-limit violations, invalid worker readiness/authentication, and unknown
methods.

Only existing files whose resolved path remains below an allowed resolved directory are
admitted. Responses use display names and hashes and do not return canonical server paths.
Binary windows carry explicit dtype, shape, units, quantity, offset, length, byte order, and
source hash metadata.

The worker command is selected only by the trusted desktop package or administrator. Client
requests cannot supply an executable, arguments, environment variables, readiness path, or
launch token. Worker shutdown never performs an unbounded wait: termination and forced
termination are both bounded, and automatic recovery stops at a fixed ceiling.

## Scope boundary

GUI040 does not yet provide:

- canonical AIMORAProject loading or mutations;
- equipment inspector schemas;
- study preparation or numerical solver integration;
- remote/network service exposure;
- cloud scheduling;
- arbitrary plugin execution;
- full result-format interpretation.

## Licence

AIMORA-authored content is distributed under the PolyForm Noncommercial License 1.0.0.
Clearly identified third-party material retains its own terms. Commercial use outside the
licence requires a separate written agreement with Ahmed Elkholy.
