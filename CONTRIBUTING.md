# Contributing to AIMORAPlatform

Keep changes within the canonical package or library owner named by `package-graph.toml`. Preserve package names, UUIDs, Julia modules, public APIs, versions, tests, notices, and path-specific licences unless a separately reviewed migration explicitly changes them.

Run the touched package’s local tests and `julia test/runtests.jl`. Connected changes may be published as one coherent Platform commit; commit size alone is not a reason to fragment an accepted change.

Contributions are accepted under the licence controlling the modified path in `licensing.toml`. Commercial use requires a separately negotiated agreement with the project owner.
