# Contributing symbols

Contributions must be original artwork expressed in the canonical primitive TOML grammar. Do not trace proprietary libraries, import vendor artwork, or submit SVG as canonical source.

Each symbol requires a stable domain ID, exact bounds and coordinates, semantic ports, snap and label anchors, supported rotations, accessible text, styles, deterministic state/LOD variants, `AIMORA original` provenance, and `PolyForm-Noncommercial-1.0.0` licensing. Add both source and canonical-content SHA-256 values to `metadata/library.toml` and include the ID in the profile.

Tests must prove parsing, bounds, fallback behavior, all compile targets, target geometry equivalence, deterministic hashing, malformed-input rejection, and rights metadata.
