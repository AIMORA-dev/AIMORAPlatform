"""Restricted text grammars, deterministic serialization, migration, diagnostics, and import adapters for AIMORA projects."""
module AIMORAFormats

using SHA
using TOML
using UUIDs

export DiagnosticError,
    DiagnosticInformation,
    DiagnosticSeverity,
    DiagnosticWarning,
    DocumentProvenance,
    FormatBoolean,
    FormatDecimal,
    FormatDiagnostic,
    FormatInputPolicy,
    FormatInteger,
    FormatItemList,
    FormatMapping,
    FormatMappingEntry,
    FormatNode,
    FormatNull,
    FormatParseResult,
    FormatResult,
    FormatSequence,
    FormatSerializationResult,
    FormatString,
    FormatValue,
    JuliaEnvironmentDependency,
    JuliaEnvironmentFingerprint,
    LockAutomation,
    LockCatalog,
    LockDataOnly,
    LockFamily,
    LockFilesystemNone,
    LockFilesystemProjectOnly,
    LockFilesystemReadOnly,
    LockFilesystemScope,
    LockImport,
    LockIsolatedUntrustedScript,
    LockParseResult,
    LockPlugin,
    LockResourcePolicy,
    LockSchema,
    LockSignedOrganizationExtension,
    LockTrustClass,
    LockTrustedPlugin,
    LockTrustedProjectScript,
    ParsedFormatLock,
    ParsedFormatDocument,
    FormatLockDocument,
    FormatLockEntry,
    SerializedFormatDocument,
    SourceDocument,
    SourcePosition,
    SourceSpan,
    canonical_json_sha256,
    format_succeeded,
    inspect_julia_environment,
    parse_format_lock,
    parse_json,
    parse_restricted_yaml,
    serialize_canonical_json,
    serialize_format_lock,
    serialize_restricted_yaml,
    source_bytes,
    source_document,
    source_position,
    source_slice,
    source_span,
    sorted_diagnostics,
    validate_format_tree

include("source_documents.jl")
include("format_values.jl")
include("restricted_yaml.jl")
include("canonical_json.jl")
include("lock_documents.jl")

end
