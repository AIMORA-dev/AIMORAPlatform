"""Restricted text grammars, deterministic serialization, migration, diagnostics, and import adapters for AIMORA projects."""
module AIMORAFormats

using SHA

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
    ParsedFormatDocument,
    SerializedFormatDocument,
    SourceDocument,
    SourcePosition,
    SourceSpan,
    format_succeeded,
    source_bytes,
    source_document,
    source_position,
    source_slice,
    source_span,
    sorted_diagnostics,
    validate_format_tree

include("source_documents.jl")
include("format_values.jl")

end
