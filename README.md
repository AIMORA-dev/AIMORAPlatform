# AIMORAFormats.jl

`AIMORAFormats.jl` is the public Julia owner for restricted YAML, canonical JSON, TOML, CSV/JSONL, migrations, source maps, diagnostics, and admitted import adapters. It contains no solver construction.

The current public surface admits bounded UTF-8 source documents, exact byte/line/column spans, deterministic diagnostics, solver-independent located format values, typed operation results, and an inert restricted-YAML parser and deterministic emitter. `parse_restricted_yaml` accepts block and flow mappings and sequences, quoted and plain strings, exact finite JSON-style numbers, lowercase booleans and null, and comments. It rejects duplicate keys, implicit legacy booleans, implicit dates, ambiguous or nonfinite numbers, tags, anchors, aliases, merge keys, directives, document markers, block scalars, tab indentation, invalid Unicode escapes, and configured resource-limit violations with source-located diagnostics.

`serialize_restricted_yaml` writes deterministic single-line flow YAML while preserving mapping insertion order and sequence order. Reserved project envelopes such as `$ref`, `$artifact`, `extends`, patches, registered-function fields, and `$expr` remain ordinary inert mappings and strings: this package does not resolve references, open artifacts, evaluate expressions, execute Julia, load plugins, or access external resources. Canonical JSON, TOML/lock grammars, bulk formats, migrations, project-directory resolution, and import adapters remain unavailable until their executable packets pass; repository presence does not imply support for them.

## Licence

This repository's AIMORA-authored content is distributed under the PolyForm Noncommercial License 1.0.0. Research, education, personal study, public-interest noncommercial use, and other purposes permitted by that licence are free; commercial use requires a separate written agreement with Ahmed Elkholy <ahmed_elkholy@f-eng.tanta.edu.eg>. There is no licence key, activation, telemetry, or technical feature restriction. Clearly identified third-party material retains its own terms, and copies received under an earlier licence retain those prior grants.
