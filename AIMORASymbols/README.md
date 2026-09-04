# AIMORASymbols

AIMORASymbols owns AIMORA's redistributable, independently authored electrical symbol sources.

The canonical format is strict open-text TOML using exact decimal coordinates and typed vector primitives. It is not SVG. One validated source compiles deterministically to retained-scene, reference-geometry, PDF-vector, and DXF-block command streams without backend-specific geometry.

The baseline `aimora` profile contains twenty searchable electrical symbols with stable IDs, semantic ports, snap and label anchors, quarter-turn metadata, styles, accessibility descriptions, state and level-of-detail variants, provenance, licence, source hashes, and canonical content hashes.

Run the contract with:

```text
julia AIMORASymbols/tests/runtests.jl
```
