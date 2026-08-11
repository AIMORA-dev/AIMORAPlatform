# AIMORAPlatform

AIMORAPlatform is the consolidated public repository for AIMORA’s project model, formats, diagram layout, service protocol, visual semantics, reporting semantics, and symbol library. Each package retains its existing public identity, version, tests, API, and licence boundary while connected platform changes can be published as one coherent repository revision.

| Path | Package or library | Stable identity |
| --- | --- | --- |
| `packages/AIMORAProject.jl` | `AIMORAProject` | `6e87310f-3ba6-4e69-9b4a-8a1fcbcc0c12` |
| `packages/AIMORAFormats.jl` | `AIMORAFormats` | `55f26d86-12d8-41b3-b163-188390d0187e` |
| `packages/AIMORALayout.jl` | `AIMORALayout` | `6f047e7d-bf2a-40ac-a20c-c55cfda68ba0` |
| `packages/AIMORAService.jl` | `AIMORAService` | `54bbdfc6-6134-4d5a-90dd-4d1a26642ec2` |
| `packages/AIMORAVisuals.jl` | `AIMORAVisuals` | `60d64674-9081-4077-878f-44c1107ce075` |
| `packages/AIMORAReporting.jl` | `AIMORAReporting` | `79e9649d-112a-4870-83df-912117092548` |
| `packages/AIMORASymbols.jl` | `aimora-public-symbols` | content library `0.1.0`; no Julia package UUID |

Run `julia test/runtests.jl` for the repository contract. Run each Julia package’s normal `Pkg.test()` command for package-local behavior; the symbol library retains `julia packages/AIMORASymbols.jl/tests/runtests.jl`.

Platform integration commits retain each exact source revision as a parent, so original commits, authors, dates, and messages remain reachable without rewritten SHAs. `history-map.toml` records the current migration boundary.

See `licensing.toml` before redistributing any path. The repository root does not override a package or content licence.
