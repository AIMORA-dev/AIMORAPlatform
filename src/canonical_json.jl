const _JSON_MEDIA_TYPE = "application/json"

struct _JsonFailure <: Exception
    diagnostic::FormatDiagnostic
end

function Base.showerror(io::IO, failure::_JsonFailure)
    show(io, failure.diagnostic)
end

mutable struct _JsonCursor
    source::SourceDocument
    policy::FormatInputPolicy
    byte::Int
    stop_byte::Int
    collection_items::Int
end

_json_byte(cursor::_JsonCursor, byte::Int) = codeunit(cursor.source.text, byte)

function _json_span(cursor::_JsonCursor, first_byte::Int, stop_byte::Int = first_byte)
    return source_span(cursor.source, first_byte, stop_byte)
end

function _json_fail(
    cursor::_JsonCursor,
    code::Symbol,
    message::String,
    first_byte::Int,
    stop_byte::Int = first_byte,
)
    throw(_JsonFailure(FormatDiagnostic(
        DiagnosticError,
        code,
        message,
        _json_span(cursor, first_byte, stop_byte),
    )))
end

function _json_character_stop(cursor::_JsonCursor, byte::Int)
    byte >= cursor.stop_byte && return byte
    return nextind(cursor.source.text, byte)
end

function _json_fail_character(
    cursor::_JsonCursor,
    code::Symbol,
    message::String,
    byte::Int,
)
    _json_fail(cursor, code, message, byte, _json_character_stop(cursor, byte))
end

function _json_skip_whitespace!(cursor::_JsonCursor)
    while cursor.byte < cursor.stop_byte &&
          _json_byte(cursor, cursor.byte) in (0x20, 0x09, 0x0a, 0x0d)
        cursor.byte += 1
    end
end

function _json_check_depth(cursor::_JsonCursor, depth::Int)
    depth <= cursor.policy.max_nesting_depth ||
        _json_fail_character(
            cursor,
            :nesting_too_deep,
            "JSON exceeds the configured nesting depth",
            cursor.byte,
        )
end

function _json_count_item!(cursor::_JsonCursor, byte::Int)
    cursor.collection_items += 1
    cursor.collection_items <= cursor.policy.max_collection_items ||
        _json_fail_character(
            cursor,
            :collection_too_large,
            "JSON exceeds the configured collection item limit",
            byte,
        )
end

function _json_check_scalar_size(
    cursor::_JsonCursor,
    first_byte::Int,
    stop_byte::Int,
)
    stop_byte - first_byte <= cursor.policy.max_scalar_bytes ||
        _json_fail(
            cursor,
            :scalar_too_large,
            "JSON scalar exceeds the configured byte limit",
            first_byte,
            stop_byte,
        )
end

function _json_parse_hex_escape!(cursor::_JsonCursor)
    first_byte = cursor.byte
    cursor.byte + 4 <= cursor.stop_byte ||
        _json_fail(
            cursor,
            :invalid_json_escape,
            "JSON string contains an incomplete Unicode escape",
            first_byte,
            cursor.stop_byte,
        )
    codepoint = 0
    for _ in 1:4
        byte = _json_byte(cursor, cursor.byte)
        digit = if 0x30 <= byte <= 0x39
            Int(byte - 0x30)
        elseif 0x41 <= byte <= 0x46
            Int(byte - 0x41 + 10)
        elseif 0x61 <= byte <= 0x66
            Int(byte - 0x61 + 10)
        else
            _json_fail_character(
                cursor,
                :invalid_json_escape,
                "JSON Unicode escape contains a non-hexadecimal digit",
                cursor.byte,
            )
        end
        codepoint = 16 * codepoint + digit
        cursor.byte += 1
    end
    return codepoint
end

function _json_parse_string!(cursor::_JsonCursor)
    text = cursor.source.text
    start_byte = cursor.byte
    cursor.byte += 1
    output = IOBuffer()

    while cursor.byte < cursor.stop_byte
        byte = _json_byte(cursor, cursor.byte)
        if byte == 0x22
            cursor.byte += 1
            _json_check_scalar_size(cursor, start_byte, cursor.byte)
            return FormatNode(
                FormatString(String(take!(output))),
                _json_span(cursor, start_byte, cursor.byte),
            )
        elseif byte == 0x5c
            escape_start = cursor.byte
            cursor.byte += 1
            cursor.byte < cursor.stop_byte ||
                _json_fail(
                    cursor,
                    :invalid_json_escape,
                    "JSON string ends inside an escape",
                    escape_start,
                    cursor.stop_byte,
                )
            escape = _json_byte(cursor, cursor.byte)
            cursor.byte += 1
            if escape == 0x22
                print(output, '"')
            elseif escape == 0x2f
                print(output, '/')
            elseif escape == 0x5c
                print(output, '\\')
            elseif escape == 0x62
                print(output, '\b')
            elseif escape == 0x66
                print(output, '\f')
            elseif escape == 0x6e
                print(output, '\n')
            elseif escape == 0x72
                print(output, '\r')
            elseif escape == 0x74
                print(output, '\t')
            elseif escape == 0x75
                codepoint = _json_parse_hex_escape!(cursor)
                if 0xd800 <= codepoint <= 0xdbff
                    pair_start = cursor.byte
                    if pair_start + 2 <= cursor.stop_byte &&
                       _json_byte(cursor, pair_start) == 0x5c &&
                       _json_byte(cursor, pair_start + 1) == 0x75
                        cursor.byte += 2
                        low = _json_parse_hex_escape!(cursor)
                        if 0xdc00 <= low <= 0xdfff
                            codepoint = 0x10000 +
                                (codepoint - 0xd800) * 0x400 +
                                (low - 0xdc00)
                        else
                            _json_fail(
                                cursor,
                                :invalid_json_unicode,
                                "high surrogate is not followed by a low surrogate",
                                escape_start,
                                cursor.byte,
                            )
                        end
                    else
                        _json_fail(
                            cursor,
                            :invalid_json_unicode,
                            "high surrogate is not followed by a low surrogate",
                            escape_start,
                            cursor.byte,
                        )
                    end
                elseif 0xdc00 <= codepoint <= 0xdfff
                    _json_fail(
                        cursor,
                        :invalid_json_unicode,
                        "Unicode escape is not a scalar value",
                        escape_start,
                        cursor.byte,
                    )
                end
                print(output, Char(codepoint))
            else
                _json_fail(
                    cursor,
                    :invalid_json_escape,
                    "JSON string contains an unsupported escape",
                    escape_start,
                    cursor.byte,
                )
            end
        elseif byte < 0x20
            _json_fail_character(
                cursor,
                :invalid_json_control_character,
                "JSON string contains an unescaped control character",
                cursor.byte,
            )
        else
            character = text[cursor.byte]
            print(output, character)
            cursor.byte = nextind(text, cursor.byte)
        end
    end
    _json_fail(
        cursor,
        :unterminated_json_string,
        "JSON string is not terminated",
        start_byte,
        cursor.stop_byte,
    )
end

function _json_is_delimiter(cursor::_JsonCursor, byte::Int)
    byte == cursor.stop_byte && return true
    return _json_byte(cursor, byte) in (0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d)
end

function _json_exact_decimal(
    cursor::_JsonCursor,
    token::String,
    first_byte::Int,
    stop_byte::Int,
)
    matched = match(
        r"^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$",
        token,
    )
    isnothing(matched) &&
        _json_fail(
            cursor,
            :invalid_json_number,
            "JSON number does not use the admitted exact grammar",
            first_byte,
            stop_byte,
        )
    fraction = matched.captures[3]
    exponent_text = matched.captures[4]
    isnothing(fraction) && isnothing(exponent_text) &&
        _json_fail(
            cursor,
            :invalid_json_number,
            "internal decimal classification failed",
            first_byte,
            stop_byte,
        )
    integer_digits = matched.captures[2]
    fraction_digits = isnothing(fraction) ? "" : fraction
    coefficient = parse(BigInt, integer_digits * fraction_digits)
    matched.captures[1] == "-" && (coefficient = -coefficient)
    explicit_exponent = isnothing(exponent_text) ? BigInt(0) : parse(BigInt, exponent_text)
    total_exponent = explicit_exponent - ncodeunits(fraction_digits)
    if total_exponent < typemin(Int) || total_exponent > typemax(Int)
        _json_fail(
            cursor,
            :json_exponent_out_of_range,
            "JSON decimal exponent is outside the supported exact range",
            first_byte,
            stop_byte,
        )
    end
    negative_zero = iszero(coefficient) && matched.captures[1] == "-"
    return FormatDecimal(coefficient, Int(total_exponent); negative_zero)
end

function _json_parse_number!(cursor::_JsonCursor)
    start_byte = cursor.byte
    while cursor.byte < cursor.stop_byte &&
          !_json_is_delimiter(cursor, cursor.byte)
        cursor.byte += 1
    end
    _json_check_scalar_size(cursor, start_byte, cursor.byte)
    token = String(SubString(
        cursor.source.text,
        start_byte,
        prevind(cursor.source.text, cursor.byte),
    ))
    matched = match(
        r"^-?(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$",
        token,
    )
    isnothing(matched) &&
        _json_fail(
            cursor,
            :invalid_json_number,
            "JSON number does not use the admitted exact grammar",
            start_byte,
            cursor.byte,
        )
    if isnothing(matched.captures[2]) && isnothing(matched.captures[3])
        value = token == "-0" ? FormatDecimal(0, 0; negative_zero = true) :
            FormatInteger(parse(BigInt, token))
    else
        value = _json_exact_decimal(cursor, token, start_byte, cursor.byte)
    end
    return FormatNode(value, _json_span(cursor, start_byte, cursor.byte))
end

function _json_parse_literal!(
    cursor::_JsonCursor,
    token::String,
    value::FormatValue,
)
    start_byte = cursor.byte
    token_bytes = codeunits(token)
    cursor.byte + length(token_bytes) <= cursor.stop_byte ||
        _json_fail(
            cursor,
            :invalid_json_literal,
            "JSON literal is incomplete",
            start_byte,
            cursor.stop_byte,
        )
    for token_byte in token_bytes
        _json_byte(cursor, cursor.byte) == token_byte ||
            _json_fail_character(
                cursor,
                :invalid_json_literal,
                "JSON literal must be lowercase true, false, or null",
                cursor.byte,
            )
        cursor.byte += 1
    end
    _json_is_delimiter(cursor, cursor.byte) ||
        _json_fail_character(
            cursor,
            :invalid_json_literal,
            "unexpected character follows JSON literal",
            cursor.byte,
        )
    return FormatNode(value, _json_span(cursor, start_byte, cursor.byte))
end

function _json_parse_array!(cursor::_JsonCursor, depth::Int)
    start_byte = cursor.byte
    cursor.byte += 1
    elements = FormatNode[]
    _json_skip_whitespace!(cursor)
    if cursor.byte < cursor.stop_byte && _json_byte(cursor, cursor.byte) == 0x5d
        cursor.byte += 1
        return FormatNode(FormatSequence(elements), _json_span(cursor, start_byte, cursor.byte))
    end

    while true
        _json_count_item!(cursor, cursor.byte)
        push!(elements, _json_parse_value!(cursor, depth + 1))
        _json_skip_whitespace!(cursor)
        cursor.byte < cursor.stop_byte ||
            _json_fail(
                cursor,
                :unterminated_json_array,
                "JSON array is missing its closing ']'",
                start_byte,
                cursor.stop_byte,
            )
        delimiter = _json_byte(cursor, cursor.byte)
        if delimiter == 0x5d
            cursor.byte += 1
            break
        elseif delimiter == 0x2c
            cursor.byte += 1
            _json_skip_whitespace!(cursor)
            cursor.byte < cursor.stop_byte &&
                _json_byte(cursor, cursor.byte) != 0x5d ||
                _json_fail(
                    cursor,
                    :json_trailing_comma,
                    "JSON arrays must not contain a trailing comma",
                    cursor.byte,
                )
        else
            _json_fail_character(
                cursor,
                :missing_json_separator,
                "JSON array elements must be separated by ','",
                cursor.byte,
            )
        end
    end
    return FormatNode(FormatSequence(elements), _json_span(cursor, start_byte, cursor.byte))
end

function _json_parse_object!(cursor::_JsonCursor, depth::Int)
    start_byte = cursor.byte
    cursor.byte += 1
    entries = FormatMappingEntry[]
    keys = Set{String}()
    _json_skip_whitespace!(cursor)
    if cursor.byte < cursor.stop_byte && _json_byte(cursor, cursor.byte) == 0x7d
        cursor.byte += 1
        return FormatNode(FormatMapping(entries), _json_span(cursor, start_byte, cursor.byte))
    end

    while true
        cursor.byte < cursor.stop_byte && _json_byte(cursor, cursor.byte) == 0x22 ||
            _json_fail_character(
                cursor,
                :json_key_must_be_string,
                "JSON object keys must be double-quoted strings",
                cursor.byte,
            )
        key = _json_parse_string!(cursor)
        key_text = key.value.value
        key_text in keys &&
            _json_fail(
                cursor,
                :duplicate_json_key,
                "JSON object contains duplicate key '$(key_text)'",
                key.span.start.byte,
                key.span.stop.byte,
            )
        push!(keys, key_text)
        _json_skip_whitespace!(cursor)
        cursor.byte < cursor.stop_byte && _json_byte(cursor, cursor.byte) == 0x3a ||
            _json_fail_character(
                cursor,
                :missing_json_colon,
                "JSON object key must be followed by ':'",
                cursor.byte,
            )
        cursor.byte += 1
        _json_skip_whitespace!(cursor)
        _json_count_item!(cursor, key.span.start.byte)
        value = _json_parse_value!(cursor, depth + 1)
        push!(entries, FormatMappingEntry(key, value))
        _json_skip_whitespace!(cursor)
        cursor.byte < cursor.stop_byte ||
            _json_fail(
                cursor,
                :unterminated_json_object,
                "JSON object is missing its closing '}'",
                start_byte,
                cursor.stop_byte,
            )
        delimiter = _json_byte(cursor, cursor.byte)
        if delimiter == 0x7d
            cursor.byte += 1
            break
        elseif delimiter == 0x2c
            cursor.byte += 1
            _json_skip_whitespace!(cursor)
            cursor.byte < cursor.stop_byte &&
                _json_byte(cursor, cursor.byte) != 0x7d ||
                _json_fail(
                    cursor,
                    :json_trailing_comma,
                    "JSON objects must not contain a trailing comma",
                    cursor.byte,
                )
        else
            _json_fail_character(
                cursor,
                :missing_json_separator,
                "JSON object entries must be separated by ','",
                cursor.byte,
            )
        end
    end
    return FormatNode(FormatMapping(entries), _json_span(cursor, start_byte, cursor.byte))
end

function _json_parse_value!(cursor::_JsonCursor, depth::Int)
    _json_skip_whitespace!(cursor)
    _json_check_depth(cursor, depth)
    cursor.byte < cursor.stop_byte ||
        _json_fail(cursor, :missing_json_value, "JSON value is missing", cursor.byte)
    first = _json_byte(cursor, cursor.byte)
    if first == 0x7b
        return _json_parse_object!(cursor, depth)
    elseif first == 0x5b
        return _json_parse_array!(cursor, depth)
    elseif first == 0x22
        return _json_parse_string!(cursor)
    elseif first == 0x74
        return _json_parse_literal!(cursor, "true", FormatBoolean(true))
    elseif first == 0x66
        return _json_parse_literal!(cursor, "false", FormatBoolean(false))
    elseif first == 0x6e
        return _json_parse_literal!(cursor, "null", FormatNull())
    elseif first == 0x2d || 0x30 <= first <= 0x39
        return _json_parse_number!(cursor)
    elseif first == 0x2f
        _json_fail_character(
            cursor,
            :json_comment_prohibited,
            "JSON comments are prohibited",
            cursor.byte,
        )
    end
    _json_fail_character(
        cursor,
        :invalid_json_token,
        "unexpected token begins JSON value",
        cursor.byte,
    )
end

function _parse_json(source::SourceDocument, policy::FormatInputPolicy)
    cursor = _JsonCursor(
        source,
        policy,
        1,
        ncodeunits(source.text) + 1,
        0,
    )
    try
        if cursor.stop_byte >= 4 &&
           _json_byte(cursor, 1) == 0xef &&
           _json_byte(cursor, 2) == 0xbb &&
           _json_byte(cursor, 3) == 0xbf
            _json_fail(
                cursor,
                :json_byte_order_mark_prohibited,
                "UTF-8 byte-order marks are not admitted in canonical JSON input",
                1,
                4,
            )
        end
        root = _json_parse_value!(cursor, 1)
        _json_skip_whitespace!(cursor)
        cursor.byte == cursor.stop_byte ||
            _json_fail_character(
                cursor,
                :trailing_json_content,
                "unexpected content follows the JSON root value",
                cursor.byte,
            )
        diagnostics = validate_format_tree(root, policy)
        isempty(diagnostics) || return FormatParseResult(nothing, diagnostics)
        return FormatParseResult(ParsedFormatDocument(source, root))
    catch error
        error isa _JsonFailure || rethrow()
        return FormatParseResult(nothing, [error.diagnostic])
    end
end

"""Parse exact, source-located JSON without comments, duplicate keys, or implicit values."""
function parse_json(
    source::SourceDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_document_bytes || begin
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "source document exceeds the configured byte limit",
            source_span(source, 1, 1),
        )
        return FormatParseResult(nothing, [diagnostic])
    end
    return _parse_json(source, policy)
end

"""Validate UTF-8 and parse exact, source-located JSON."""
function parse_json(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return FormatParseResult(nothing, collect(admitted.diagnostics))
    return parse_json(admitted.value; policy)
end

parse_json(
    text::AbstractString;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_json(Vector{UInt8}(codeunits(text)); source_name, policy)

function _canonical_json_emit_string(io::IO, value::String, span::SourceSpan)
    isvalid(value) || throw(_JsonFailure(FormatDiagnostic(
        DiagnosticError,
        :invalid_unicode_value,
        "canonical JSON string contains invalid Unicode",
        span,
    )))
    print(io, '"')
    for character in value
        codepoint = Int(character)
        if character == '"'
            print(io, "\\\"")
        elseif character == '\\'
            print(io, "\\\\")
        elseif character == '\b'
            print(io, "\\b")
        elseif character == '\t'
            print(io, "\\t")
        elseif character == '\n'
            print(io, "\\n")
        elseif character == '\f'
            print(io, "\\f")
        elseif character == '\r'
            print(io, "\\r")
        elseif codepoint < 0x20
            print(io, "\\u", lpad(string(codepoint; base = 16), 4, '0'))
        else
            print(io, character)
        end
    end
    print(io, '"')
end

function _canonical_json_emit_node(
    io::IO,
    node::FormatNode,
    depth::Int,
    policy::FormatInputPolicy,
)
    depth <= policy.max_nesting_depth || throw(_JsonFailure(FormatDiagnostic(
        DiagnosticError,
        :nesting_too_deep,
        "format value exceeds the configured nesting depth",
        node.span,
    )))
    value = node.value
    if value isa FormatNull
        print(io, "null")
    elseif value isa FormatBoolean
        print(io, value.value ? "true" : "false")
    elseif value isa FormatInteger
        print(io, value.value)
    elseif value isa FormatDecimal
        if iszero(value.coefficient)
            print(io, value.negative_zero ? "-0e0" : "0e0")
        else
            print(io, value.coefficient, 'e', value.exponent)
        end
    elseif value isa FormatString
        _canonical_json_emit_string(io, value.value, node.span)
    elseif value isa FormatSequence
        print(io, '[')
        for (index, child) in enumerate(value.elements)
            index > 1 && print(io, ',')
            _canonical_json_emit_node(io, child, depth + 1, policy)
        end
        print(io, ']')
    elseif value isa FormatMapping
        print(io, '{')
        entries = sort!(
            collect(value.entries);
            by = entry -> entry.key.value.value,
        )
        for (index, entry) in enumerate(entries)
            index > 1 && print(io, ',')
            _canonical_json_emit_string(
                io,
                entry.key.value.value,
                entry.key.span,
            )
            print(io, ':')
            _canonical_json_emit_node(io, entry.value, depth + 1, policy)
        end
        print(io, '}')
    else
        throw(_JsonFailure(FormatDiagnostic(
            DiagnosticError,
            :unsupported_format_value,
            "value does not belong to the canonical JSON domain",
            node.span,
        )))
    end
end

"""Serialize a located format value using AIMORA's deterministic exact canonical JSON."""
function serialize_canonical_json(
    root::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(root, policy)
    isempty(diagnostics) || return FormatSerializationResult(nothing, diagnostics)
    output = IOBuffer()
    try
        _canonical_json_emit_node(output, root, 1, policy)
        bytes = take!(output)
        length(bytes) <= policy.max_document_bytes || begin
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :document_too_large,
                "canonical JSON exceeds the configured byte limit",
                root.span,
            )
            return FormatSerializationResult(nothing, [diagnostic])
        end
        return FormatSerializationResult(SerializedFormatDocument(bytes, _JSON_MEDIA_TYPE))
    catch error
        error isa _JsonFailure || rethrow()
        return FormatSerializationResult(nothing, [error.diagnostic])
    end
end

serialize_canonical_json(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = serialize_canonical_json(document.root; policy)

"""Return the lowercase SHA-256 identity of a value's canonical JSON bytes."""
function canonical_json_sha256(
    root::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    serialized = serialize_canonical_json(root; policy)
    format_succeeded(serialized) ||
        return FormatResult{String}(nothing, collect(serialized.diagnostics))
    digest = bytes2hex(sha256(collect(serialized.value.bytes)))
    return FormatResult(digest)
end

canonical_json_sha256(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = canonical_json_sha256(document.root; policy)
