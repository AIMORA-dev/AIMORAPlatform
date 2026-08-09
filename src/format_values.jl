"""The solver-independent value domain shared by admitted text grammars."""
abstract type FormatValue end

"""A format value paired with its exact source range."""
struct FormatNode
    value::FormatValue
    span::SourceSpan
end

Base.:(==)(left::FormatNode, right::FormatNode) =
    left.value == right.value && left.span == right.span

"""The explicit null value admitted by a text grammar."""
struct FormatNull <: FormatValue end

Base.:(==)(::FormatNull, ::FormatNull) = true

"""A JSON-compatible boolean value."""
struct FormatBoolean <: FormatValue
    value::Bool
end

Base.:(==)(left::FormatBoolean, right::FormatBoolean) = left.value == right.value

"""An arbitrary-precision integer value."""
struct FormatInteger <: FormatValue
    value::BigInt
end

FormatInteger(value::Integer) = FormatInteger(BigInt(value))
Base.:(==)(left::FormatInteger, right::FormatInteger) = left.value == right.value

"""An exact finite decimal represented as `coefficient * 10^exponent`."""
struct FormatDecimal <: FormatValue
    coefficient::BigInt
    exponent::Int
    negative_zero::Bool

    function FormatDecimal(
        coefficient::Integer,
        exponent::Integer;
        negative_zero::Bool = false,
    )
        normalized_coefficient = BigInt(coefficient)
        normalized_exponent = Int(exponent)
        if iszero(normalized_coefficient)
            return new(BigInt(0), 0, negative_zero)
        end
        negative_zero && throw(ArgumentError("only a zero decimal can retain a negative-zero sign"))
        while iszero(rem(normalized_coefficient, 10))
            normalized_coefficient = div(normalized_coefficient, 10)
            normalized_exponent == typemax(Int) &&
                throw(OverflowError("decimal exponent exceeds Int"))
            normalized_exponent += 1
        end
        return new(normalized_coefficient, normalized_exponent, false)
    end
end

Base.:(==)(left::FormatDecimal, right::FormatDecimal) =
    left.coefficient == right.coefficient &&
    left.exponent == right.exponent &&
    left.negative_zero == right.negative_zero

"""A Unicode string retained without implicit date, unit, or boolean conversion."""
struct FormatString <: FormatValue
    value::String
end

FormatString(value::AbstractString) = FormatString(String(value))
Base.:(==)(left::FormatString, right::FormatString) = left.value == right.value

"""An insertion-ordered, read-only sequence of located values."""
struct FormatSequence <: FormatValue
    elements::FormatItemList{FormatNode}

    FormatSequence(elements::AbstractVector{FormatNode} = FormatNode[]) =
        new(FormatItemList(elements))
end

Base.:(==)(left::FormatSequence, right::FormatSequence) = left.elements == right.elements

"""One string-keyed mapping entry with separate key and value locations."""
struct FormatMappingEntry
    key::FormatNode
    value::FormatNode

    function FormatMappingEntry(key::FormatNode, value::FormatNode)
        key.value isa FormatString || throw(ArgumentError("format mapping keys must be strings"))
        return new(key, value)
    end
end

Base.:(==)(left::FormatMappingEntry, right::FormatMappingEntry) =
    left.key == right.key && left.value == right.value

"""An insertion-ordered, duplicate-free mapping with string keys."""
struct FormatMapping <: FormatValue
    entries::FormatItemList{FormatMappingEntry}

    function FormatMapping(entries::AbstractVector{FormatMappingEntry} = FormatMappingEntry[])
        copied_entries = collect(entries)
        keys = String[entry.key.value.value for entry in copied_entries]
        length(keys) == length(unique(keys)) ||
            throw(ArgumentError("format mapping contains duplicate keys"))
        return new(FormatItemList(copied_entries))
    end
end

Base.:(==)(left::FormatMapping, right::FormatMapping) = left.entries == right.entries

"""A parsed source document and its located root value."""
struct ParsedFormatDocument
    source::SourceDocument
    root::FormatNode
end

Base.:(==)(left::ParsedFormatDocument, right::ParsedFormatDocument) =
    left.source == right.source && left.root == right.root

"""Serialized bytes and their registered media type."""
struct SerializedFormatDocument
    bytes::FormatItemList{UInt8}
    media_type::String

    function SerializedFormatDocument(bytes::AbstractVector{UInt8}, media_type::AbstractString)
        registered_media_type = String(media_type)
        isempty(registered_media_type) && throw(ArgumentError("media type must not be empty"))
        occursin('\0', registered_media_type) &&
            throw(ArgumentError("media type must not contain NUL"))
        return new(FormatItemList(collect(bytes)), registered_media_type)
    end
end

Base.:(==)(left::SerializedFormatDocument, right::SerializedFormatDocument) =
    left.bytes == right.bytes && left.media_type == right.media_type

"""Typed result returned by an admitted grammar parser."""
const FormatParseResult = FormatResult{ParsedFormatDocument}

"""Typed result returned by an admitted deterministic serializer."""
const FormatSerializationResult = FormatResult{SerializedFormatDocument}

function _tree_limit_diagnostic(code::Symbol, message::String, span::SourceSpan)
    return FormatDiagnostic(DiagnosticError, code, message, span)
end

function _format_scalar_size(value::FormatValue)
    value isa FormatString && return ncodeunits(value.value)
    value isa FormatInteger && return ncodeunits(string(value.value))
    value isa FormatDecimal &&
        return ncodeunits(string(value.coefficient)) +
               ncodeunits(string(value.exponent)) +
               (value.negative_zero ? 2 : 1)
    return 0
end

"""Validate depth, collection size, scalar size, and diagnostic bounds for a located value tree."""
function validate_format_tree(root::FormatNode, policy::FormatInputPolicy = FormatInputPolicy())
    diagnostics = FormatDiagnostic[]
    stack = Tuple{FormatNode,Int}[(root, 1)]
    collection_items = 0

    while !isempty(stack) && length(diagnostics) < policy.max_diagnostics
        node, depth = pop!(stack)
        if depth > policy.max_nesting_depth
            push!(
                diagnostics,
                _tree_limit_diagnostic(
                    :nesting_too_deep,
                    "format value exceeds the configured nesting depth",
                    node.span,
                ),
            )
            continue
        end

        scalar_size = _format_scalar_size(node.value)
        if scalar_size > policy.max_scalar_bytes
            push!(
                diagnostics,
                _tree_limit_diagnostic(
                    :scalar_too_large,
                    "format scalar exceeds the configured byte limit",
                    node.span,
                ),
            )
        end

        children = FormatNode[]
        if node.value isa FormatSequence
            append!(children, node.value.elements)
            collection_items += length(node.value.elements)
        elseif node.value isa FormatMapping
            for entry in node.value.entries
                push!(children, entry.key, entry.value)
            end
            collection_items += length(node.value.entries)
        end
        if collection_items > policy.max_collection_items
            push!(
                diagnostics,
                _tree_limit_diagnostic(
                    :collection_too_large,
                    "format value exceeds the configured collection item limit",
                    node.span,
                ),
            )
            break
        end
        for child in Iterators.reverse(children)
            push!(stack, (child, depth + 1))
        end
    end

    return sorted_diagnostics(diagnostics)
end
