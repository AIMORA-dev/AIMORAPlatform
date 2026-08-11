"""Severity of a format diagnostic, ordered from information through error."""
@enum DiagnosticSeverity::UInt8 begin
    DiagnosticInformation = 0x01
    DiagnosticWarning = 0x02
    DiagnosticError = 0x03
end

"""An insertion-ordered, read-only public collection of format-domain items."""
struct FormatItemList{T} <: AbstractVector{T}
    storage::Vector{T}

    FormatItemList{T}(items::AbstractVector{T} = T[]) where {T} = new{T}(collect(items))
end

FormatItemList(items::AbstractVector{T}) where {T} = FormatItemList{T}(items)

Base.IndexStyle(::Type{<:FormatItemList}) = IndexLinear()
Base.size(items::FormatItemList) = size(getfield(items, :storage))
Base.getindex(items::FormatItemList, index::Int) = getfield(items, :storage)[index]
Base.copy(items::FormatItemList{T}) where {T} = FormatItemList{T}(getfield(items, :storage))
Base.propertynames(::FormatItemList, private::Bool = false) = private ? (:storage,) : ()
Base.setindex!(::FormatItemList, value, index...) =
    throw(ArgumentError("format item lists are read-only"))
Base.push!(::FormatItemList, values...) =
    throw(ArgumentError("format item lists are read-only"))

function Base.getproperty(::FormatItemList, name::Symbol)
    name === :storage && throw(ArgumentError("format item storage is read-only"))
    throw(ArgumentError("format item list has no property named $(name)"))
end

"""A one-based UTF-8 byte position and one-based Unicode scalar line and column."""
struct SourcePosition
    byte::Int
    line::Int
    column::Int

    function SourcePosition(byte::Integer, line::Integer, column::Integer)
        byte > 0 || throw(ArgumentError("source byte must be positive"))
        line > 0 || throw(ArgumentError("source line must be positive"))
        column > 0 || throw(ArgumentError("source column must be positive"))
        return new(Int(byte), Int(line), Int(column))
    end
end

Base.:(==)(left::SourcePosition, right::SourcePosition) =
    left.byte == right.byte && left.line == right.line && left.column == right.column

function Base.show(io::IO, position::SourcePosition)
    print(io, position.line, ':', position.column, "@", position.byte)
end

"""A half-open source range whose `stop` position is immediately after its content."""
struct SourceSpan
    source_name::String
    start::SourcePosition
    stop::SourcePosition

    function SourceSpan(
        source_name::AbstractString,
        start::SourcePosition,
        stop::SourcePosition,
    )
        name = String(source_name)
        isempty(name) && throw(ArgumentError("source name must not be empty"))
        occursin('\0', name) && throw(ArgumentError("source name must not contain NUL"))
        start.byte <= stop.byte || throw(ArgumentError("source span stop precedes start"))
        start.line <= stop.line || throw(ArgumentError("source span line order is inconsistent"))
        if start.line == stop.line
            start.column <= stop.column ||
                throw(ArgumentError("source span column order is inconsistent"))
        end
        if start.byte == stop.byte
            start.line == stop.line && start.column == stop.column ||
                throw(ArgumentError("an empty source span must have one position"))
        end
        return new(name, start, stop)
    end
end

Base.:(==)(left::SourceSpan, right::SourceSpan) =
    left.source_name == right.source_name && left.start == right.start && left.stop == right.stop

function Base.show(io::IO, span::SourceSpan)
    print(io, span.source_name, ':', span.start.line, ':', span.start.column)
    if span.stop != span.start
        print(io, '-', span.stop.line, ':', span.stop.column)
    end
end

"""Stable provenance for the original bytes of one source document."""
struct DocumentProvenance
    source_name::String
    content_sha256::String
    byte_count::Int

    function DocumentProvenance(
        source_name::AbstractString,
        content_sha256::AbstractString,
        byte_count::Integer,
    )
        name = String(source_name)
        digest = String(content_sha256)
        isempty(name) && throw(ArgumentError("source name must not be empty"))
        occursin('\0', name) && throw(ArgumentError("source name must not contain NUL"))
        occursin(r"^[0-9a-f]{64}$", digest) ||
            throw(ArgumentError("content SHA-256 must contain 64 lowercase hexadecimal digits"))
        byte_count >= 0 || throw(ArgumentError("document byte count must not be negative"))
        return new(name, digest, Int(byte_count))
    end
end

Base.:(==)(left::DocumentProvenance, right::DocumentProvenance) =
    left.source_name == right.source_name &&
    left.content_sha256 == right.content_sha256 &&
    left.byte_count == right.byte_count

"""Limits applied before an untrusted format document is admitted."""
struct FormatInputPolicy
    max_document_bytes::Int
    max_nesting_depth::Int
    max_collection_items::Int
    max_scalar_bytes::Int
    max_diagnostics::Int

    function FormatInputPolicy(;
        max_document_bytes::Integer = 64 * 1024 * 1024,
        max_nesting_depth::Integer = 128,
        max_collection_items::Integer = 1_000_000,
        max_scalar_bytes::Integer = 8 * 1024 * 1024,
        max_diagnostics::Integer = 1_000,
    )
        limits = (
            max_document_bytes,
            max_nesting_depth,
            max_collection_items,
            max_scalar_bytes,
            max_diagnostics,
        )
        all(limit -> limit > 0, limits) ||
            throw(ArgumentError("every format input limit must be positive"))
        return new(Int.(limits)...)
    end
end

"""A stable, source-located problem or warning emitted by a format operation."""
struct FormatDiagnostic
    severity::DiagnosticSeverity
    code::Symbol
    message::String
    span::Union{Nothing,SourceSpan}

    function FormatDiagnostic(
        severity::DiagnosticSeverity,
        code::Symbol,
        message::AbstractString,
        span::Union{Nothing,SourceSpan} = nothing,
    )
        code_text = String(code)
        occursin(r"^[a-z][a-z0-9_]*$", code_text) ||
            throw(ArgumentError("diagnostic code must use lowercase domain words"))
        text = String(message)
        isempty(text) && throw(ArgumentError("diagnostic message must not be empty"))
        return new(severity, code, text, span)
    end
end

Base.:(==)(left::FormatDiagnostic, right::FormatDiagnostic) =
    left.severity == right.severity &&
    left.code == right.code &&
    left.message == right.message &&
    left.span == right.span

function Base.show(io::IO, diagnostic::FormatDiagnostic)
    severity = diagnostic.severity == DiagnosticInformation ? "information" :
        diagnostic.severity == DiagnosticWarning ? "warning" : "error"
    print(io, severity, '[', diagnostic.code, ']')
    if !isnothing(diagnostic.span)
        print(io, ' ', diagnostic.span)
    end
    print(io, ": ", diagnostic.message)
end

function _diagnostic_sort_key(diagnostic::FormatDiagnostic)
    span = diagnostic.span
    source_name = isnothing(span) ? "" : span.source_name
    start_byte = isnothing(span) ? 0 : span.start.byte
    stop_byte = isnothing(span) ? 0 : span.stop.byte
    return (
        source_name,
        start_byte,
        stop_byte,
        UInt8(diagnostic.severity),
        String(diagnostic.code),
        diagnostic.message,
    )
end

"""Return a stable copy ordered by source range, severity, code, and message."""
sorted_diagnostics(diagnostics::AbstractVector{FormatDiagnostic}) =
    sort!(collect(diagnostics); by = _diagnostic_sort_key)

"""The result contract shared by parsing, validation, migration, and serialization."""
struct FormatResult{T}
    value::Union{Nothing,T}
    diagnostics::FormatItemList{FormatDiagnostic}

    function FormatResult{T}(
        value::Union{Nothing,T},
        diagnostics::AbstractVector{FormatDiagnostic} = FormatDiagnostic[],
    ) where {T}
        copied_diagnostics = collect(diagnostics)
        if isnothing(value) && !any(d -> d.severity == DiagnosticError, copied_diagnostics)
            throw(ArgumentError("a result without a value must contain an error diagnostic"))
        end
        return new{T}(value, FormatItemList(sorted_diagnostics(copied_diagnostics)))
    end
end

FormatResult(value::T, diagnostics::AbstractVector{FormatDiagnostic} = FormatDiagnostic[]) where {T} =
    FormatResult{T}(value, diagnostics)

Base.:(==)(left::FormatResult, right::FormatResult) =
    left.value == right.value && left.diagnostics == right.diagnostics

"""Return true when a format operation produced a value and no error diagnostics."""
format_succeeded(result::FormatResult) =
    !isnothing(result.value) && !any(diagnostic -> diagnostic.severity == DiagnosticError, result.diagnostics)

"""A UTF-8 source document with precomputed physical line starts."""
struct SourceDocument
    provenance::DocumentProvenance
    text::String
    line_starts::Tuple{Vararg{Int}}

    function SourceDocument(
        provenance::DocumentProvenance,
        text::String,
        line_starts::Tuple{Vararg{Int}},
        ::Val{:validated_source_document},
    )
        return new(provenance, text, line_starts)
    end
end

Base.:(==)(left::SourceDocument, right::SourceDocument) =
    left.provenance == right.provenance && left.text == right.text

function _utf8_sequence_status(bytes::AbstractVector{UInt8}, index::Int)
    byte = bytes[index]
    remaining = length(bytes) - index
    continuation(offset) = index + offset <= length(bytes) && 0x80 <= bytes[index + offset] <= 0xbf

    byte <= 0x7f && return (1, 0)
    if 0xc2 <= byte <= 0xdf
        remaining >= 1 || return (0, index)
        continuation(1) || return (0, index + 1)
        return (2, 0)
    elseif byte == 0xe0
        remaining >= 2 || return (0, index)
        0xa0 <= bytes[index + 1] <= 0xbf || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        return (3, 0)
    elseif 0xe1 <= byte <= 0xec || 0xee <= byte <= 0xef
        remaining >= 2 || return (0, index)
        continuation(1) || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        return (3, 0)
    elseif byte == 0xed
        remaining >= 2 || return (0, index)
        0x80 <= bytes[index + 1] <= 0x9f || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        return (3, 0)
    elseif byte == 0xf0
        remaining >= 3 || return (0, index)
        0x90 <= bytes[index + 1] <= 0xbf || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        continuation(3) || return (0, index + 3)
        return (4, 0)
    elseif 0xf1 <= byte <= 0xf3
        remaining >= 3 || return (0, index)
        continuation(1) || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        continuation(3) || return (0, index + 3)
        return (4, 0)
    elseif byte == 0xf4
        remaining >= 3 || return (0, index)
        0x80 <= bytes[index + 1] <= 0x8f || return (0, index + 1)
        continuation(2) || return (0, index + 2)
        continuation(3) || return (0, index + 3)
        return (4, 0)
    end
    return (0, index)
end

function _inspect_utf8(bytes::AbstractVector{UInt8})
    line_starts = Int[1]
    line = 1
    column = 1
    index = 1
    while index <= length(bytes)
        width, invalid_byte = _utf8_sequence_status(bytes, index)
        invalid_byte == 0 || return (invalid_byte, line, column, line_starts)
        if bytes[index] == 0x0d
            if index < length(bytes) && bytes[index + 1] == 0x0a
                index += 2
            else
                index += 1
            end
            line += 1
            column = 1
            push!(line_starts, index)
        elseif bytes[index] == 0x0a
            index += 1
            line += 1
            column = 1
            push!(line_starts, index)
        else
            index += width
            column += 1
        end
    end
    return (0, line, column, line_starts)
end

function _point_span(source_name::String, byte::Int, line::Int, column::Int)
    position = SourcePosition(byte, line, column)
    return SourceSpan(source_name, position, position)
end

"""Validate and retain source bytes without replacement or newline normalization."""
function source_document(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    name = String(source_name)
    isempty(name) && throw(ArgumentError("source name must not be empty"))
    occursin('\0', name) && throw(ArgumentError("source name must not contain NUL"))
    if length(bytes) > policy.max_document_bytes
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "source document exceeds the configured byte limit",
            _point_span(name, 1, 1, 1),
        )
        return FormatResult{SourceDocument}(nothing, [diagnostic])
    end

    invalid_byte, line, column, line_starts = _inspect_utf8(bytes)
    if invalid_byte != 0
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :invalid_utf8,
            "source document contains invalid UTF-8",
            _point_span(name, invalid_byte, line, column),
        )
        return FormatResult{SourceDocument}(nothing, [diagnostic])
    end

    copied_bytes = collect(bytes)
    provenance = DocumentProvenance(name, bytes2hex(sha256(copied_bytes)), length(copied_bytes))
    document = SourceDocument(
        provenance,
        String(copied_bytes),
        Tuple(line_starts),
        Val(:validated_source_document),
    )
    return FormatResult{SourceDocument}(document)
end

source_document(
    text::AbstractString;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = source_document(Vector{UInt8}(codeunits(text)); source_name, policy)

"""Return a copy of the exact source bytes."""
source_bytes(document::SourceDocument) = Vector{UInt8}(codeunits(document.text))

function _validate_source_byte(document::SourceDocument, byte::Integer)
    last_byte = ncodeunits(document.text) + 1
    1 <= byte <= last_byte || throw(BoundsError(document.text, byte))
    (byte == last_byte || isvalid(document.text, Int(byte))) ||
        throw(ArgumentError("source byte is not a UTF-8 character boundary"))
    return Int(byte)
end

function _source_line(line_starts::Tuple{Vararg{Int}}, target::Int)
    lower = 1
    upper = length(line_starts)
    while lower <= upper
        middle = lower + (upper - lower) ÷ 2
        if line_starts[middle] <= target
            lower = middle + 1
        else
            upper = middle - 1
        end
    end
    return upper
end

"""Resolve a one-based UTF-8 byte boundary to a physical source position."""
function source_position(document::SourceDocument, byte::Integer)
    target = _validate_source_byte(document, byte)
    line = _source_line(document.line_starts, target)
    line_start = document.line_starts[line]
    column = 1
    index = line_start
    while index < target
        index = nextind(document.text, index)
        column += 1
    end
    return SourcePosition(target, line, column)
end

"""Construct a validated half-open source span from UTF-8 byte boundaries."""
function source_span(document::SourceDocument, first_byte::Integer, stop_byte::Integer)
    first_position = source_position(document, first_byte)
    stop_position = source_position(document, stop_byte)
    first_position.byte <= stop_position.byte ||
        throw(ArgumentError("source span stop precedes start"))
    return SourceSpan(document.provenance.source_name, first_position, stop_position)
end

"""Return the exact text covered by a span from the same source document."""
function source_slice(document::SourceDocument, span::SourceSpan)
    span.source_name == document.provenance.source_name ||
        throw(ArgumentError("source span belongs to another document"))
    first_byte = _validate_source_byte(document, span.start.byte)
    stop_byte = _validate_source_byte(document, span.stop.byte)
    first_byte <= stop_byte || throw(ArgumentError("source span stop precedes start"))
    first_byte == stop_byte && return ""
    return String(SubString(document.text, first_byte, prevind(document.text, stop_byte)))
end
