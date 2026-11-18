# Contributing to AIMORAService

AIMORAService owns transport and process orchestration only. Engineering models, equations,
project semantics, study readiness, result validity, and private solver kernels remain in
their canonical Julia repositories.

## Required checks

```bash
julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'
julia --startup-file=no --project=. tools/generate_cpp_bindings.jl \
  schema/service_protocol.json \
  generated/cpp/include/aimora/studio/protocol/generated/service_protocol.hpp \
  generated/cpp/src/service_protocol.cpp
```

The second command must leave the working tree unchanged.

## Protocol rules

- Preserve the `AMR1` frame header and explicit protocol-version handshake unless a
  separately versioned migration is authorized.
- Keep all limits finite and validated before allocation or file reads.
- Authenticate before any capability except the hello response.
- Never return stack traces, module/type names, absolute paths, environment variables,
  credentials, private solver identifiers, or unrestricted exception messages.
- Confine files by resolved paths, not lexical prefixes.
- Keep executable programs and worker arguments in trusted startup configuration; requests
  may start or stop registered workers but cannot choose commands.
- Keep full numerical data in Julia artifacts and return only bounded windows.
- Preserve deterministic generated bindings and the schema hash.

## Tests

New methods require positive, malformed, unauthorized, oversized, cancellation, and
leakage tests. Long-running behavior must define cancellation and clean process retirement.
Cross-platform local transport must be exercised on Windows, macOS, and Linux before a
release claim.
