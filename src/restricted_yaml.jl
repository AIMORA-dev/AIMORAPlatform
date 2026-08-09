const _YAML_MEDIA_TYPE = "application/yaml"
const _YAML_AMBIGUOUS_NUMBER_PATTERN = Regex(
    raw"^[+-]?(?:[0-9][0-9_]*(?:\.[0-9_]*)?(?:[eE][+-]?[0-9_]*)?|" *
    raw"\.[0-9_]+(?:[eE][+-]?[0-9_]*)?)$",
)

struct _RestrictedYamlFailure <: Exception
    diagnostic::FormatDiagnostic
end

function Base.showerror(io::IO, failure::_RestrictedYamlFailure)
    show(io, failure.diagnostic)
end

struct _RestrictedYamlLine
    start_byte::Int
    stop_byte::Int
    next_byte::Int
    indent::Int
    content_byte::Int
end

mutable struct _RestrictedYamlState
    source::SourceDocument
    lines::Vector{_RestrictedYamlLine}
    policy::FormatInputPolicy
    collection_items::Int
end

mutable struct _RestrictedYamlInline
    state::_RestrictedYamlState
    byte::Int
    stop_byte::Int
    depth::Int
end

_yaml_byte(text::String, byte::Int) = codeunit(text, byte)

function _yaml_text(text::String, first_byte::Int, stop_byte::Int)
    first_byte >= stop_byte && return ""
    return String(SubString(text, first_byte, prevind(text, stop_byte)))
end

function _yaml_span(state::_RestrictedYamlState, first_byte::Int, stop_byte::Int = first_byte)
    return source_span(state.source, first_byte, stop_byte)
end

function _yaml_fail(
    state::_RestrictedYamlState,
    code::Symbol,
    message::String,
    first_byte::Int,
    stop_byte::Int = first_byte,
)
    throw(_RestrictedYamlFailure(
        FormatDiagnostic(
            DiagnosticError,
            code,
            message,
            _yaml_span(state, first_byte, stop_byte),
        ),
    ))
end

function _yaml_character_stop(state::_RestrictedYamlState, byte::Int)
    byte > ncodeunits(state.source.text) && return byte
    return nextind(state.source.text, byte)
end

function _yaml_fail_character(
    state::_RestrictedYamlState,
    code::Symbol,
    message::String,
    byte::Int,
)
    _yaml_fail(state, code, message, byte, _yaml_character_stop(state, byte))
end

function _yaml_check_depth(state::_RestrictedYamlState, depth::Int, byte::Int)
    depth <= state.policy.max_nesting_depth ||
        _yaml_fail_character(
            state,
            :nesting_too_deep,
            "restricted YAML exceeds the configured nesting depth",
            byte,
        )
end

function _yaml_count_item!(state::_RestrictedYamlState, byte::Int)
    state.collection_items += 1
    state.collection_items <= state.policy.max_collection_items ||
        _yaml_fail_character(
            state,
            :collection_too_large,
            "restricted YAML exceeds the configured collection item limit",
            byte,
        )
end

function _yaml_check_scalar_size(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
)
    stop_byte - first_byte <= state.policy.max_scalar_bytes ||
        _yaml_fail(
            state,
            :scalar_too_large,
            "restricted YAML scalar exceeds the configured byte limit",
            first_byte,
            stop_byte,
        )
end

function _yaml_lines(state_source::SourceDocument, policy::FormatInputPolicy)
    text = state_source.text
    byte_count = ncodeunits(text)
    lines = _RestrictedYamlLine[]
    line_start = 1

    while line_start <= byte_count
        line_stop = line_start
        while line_stop <= byte_count
            byte = _yaml_byte(text, line_stop)
            (byte == 0x0a || byte == 0x0d) && break
            line_stop += 1
        end
        next_byte = line_stop
        if next_byte <= byte_count && _yaml_byte(text, next_byte) == 0x0d
            next_byte += 1
            if next_byte <= byte_count && _yaml_byte(text, next_byte) == 0x0a
                next_byte += 1
            end
        elseif next_byte <= byte_count
            next_byte += 1
        end

        content_byte = line_start
        while content_byte < line_stop && _yaml_byte(text, content_byte) == 0x20
            content_byte += 1
        end
        if content_byte < line_stop && _yaml_byte(text, content_byte) == 0x09
            state = _RestrictedYamlState(state_source, lines, policy, 0)
            _yaml_fail_character(
                state,
                :tab_indentation,
                "restricted YAML indentation must contain spaces, not tabs",
                content_byte,
            )
        end
        push!(
            lines,
            _RestrictedYamlLine(
                line_start,
                line_stop,
                next_byte,
                content_byte - line_start,
                content_byte,
            ),
        )
        line_start = next_byte
    end

    return lines
end

function _yaml_trim_right(text::String, first_byte::Int, stop_byte::Int)
    result = stop_byte
    while result > first_byte
        previous = prevind(text, result)
        byte = _yaml_byte(text, previous)
        (byte == 0x20 || byte == 0x09) || break
        result = previous
    end
    return result
end

function _yaml_line_content_stop(state::_RestrictedYamlState, line::_RestrictedYamlLine)
    text = state.source.text
    byte = line.content_byte
    single_quoted = false
    double_quoted = false
    escaped = false

    while byte < line.stop_byte
        value = _yaml_byte(text, byte)
        if double_quoted
            if escaped
                escaped = false
            elseif value == 0x5c
                escaped = true
            elseif value == 0x22
                double_quoted = false
            end
        elseif single_quoted
            if value == 0x27
                next_byte = byte + 1
                if next_byte < line.stop_byte && _yaml_byte(text, next_byte) == 0x27
                    byte = next_byte
                else
                    single_quoted = false
                end
            end
        elseif value == 0x22
            double_quoted = true
        elseif value == 0x27
            single_quoted = true
        elseif value == 0x23
            previous_is_space = byte == line.content_byte ||
                _yaml_byte(text, prevind(text, byte)) in (0x20, 0x09)
            previous_is_space && return _yaml_trim_right(text, line.content_byte, byte)
        end
        byte += 1
    end
    return _yaml_trim_right(text, line.content_byte, line.stop_byte)
end

function _yaml_significant_line(state::_RestrictedYamlState, line_index::Int)
    index = line_index
    while index <= length(state.lines)
        line = state.lines[index]
        stop_byte = _yaml_line_content_stop(state, line)
        line.content_byte < stop_byte && return index
        index += 1
    end
    return index
end

function _yaml_starts_with(text::String, first_byte::Int, stop_byte::Int, token::String)
    stop_byte - first_byte >= ncodeunits(token) || return false
    for (offset, token_byte) in enumerate(codeunits(token))
        _yaml_byte(text, first_byte + offset - 1) == token_byte || return false
    end
    return true
end

function _yaml_is_sequence_marker(text::String, first_byte::Int, stop_byte::Int)
    first_byte < stop_byte && _yaml_byte(text, first_byte) == 0x2d || return false
    first_byte + 1 == stop_byte && return true
    return _yaml_byte(text, first_byte + 1) in (0x20, 0x09)
end

function _yaml_skip_spaces(text::String, byte::Int, stop_byte::Int)
    result = byte
    while result < stop_byte && _yaml_byte(text, result) == 0x20
        result += 1
    end
    return result
end

function _yaml_find_mapping_colon(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
)
    text = state.source.text
    byte = first_byte
    single_quoted = false
    double_quoted = false
    escaped = false
    square_depth = 0
    curly_depth = 0

    while byte < stop_byte
        value = _yaml_byte(text, byte)
        if double_quoted
            if escaped
                escaped = false
            elseif value == 0x5c
                escaped = true
            elseif value == 0x22
                double_quoted = false
            end
        elseif single_quoted
            if value == 0x27
                next_byte = byte + 1
                if next_byte < stop_byte && _yaml_byte(text, next_byte) == 0x27
                    byte = next_byte
                else
                    single_quoted = false
                end
            end
        elseif value == 0x22
            double_quoted = true
        elseif value == 0x27
            single_quoted = true
        elseif value == 0x5b
            square_depth += 1
        elseif value == 0x5d
            square_depth -= 1
        elseif value == 0x7b
            curly_depth += 1
        elseif value == 0x7d
            curly_depth -= 1
        elseif value == 0x3a && square_depth == 0 && curly_depth == 0
            after = byte + 1
            if after == stop_byte || _yaml_byte(text, after) in (0x20, 0x09)
                return byte
            end
        end
        byte += 1
    end
    return 0
end

function _yaml_reject_document_marker!(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
)
    text = state.source.text
    token = _yaml_text(text, first_byte, stop_byte)
    if startswith(token, "%")
        _yaml_fail_character(
            state,
            :yaml_directive_prohibited,
            "YAML directives are not admitted by the restricted profile",
            first_byte,
        )
    elseif token == "---" || startswith(token, "--- ")
        _yaml_fail(
            state,
            :multiple_documents_prohibited,
            "YAML document markers and multiple documents are not admitted",
            first_byte,
            min(first_byte + 3, stop_byte),
        )
    elseif token == "..." || startswith(token, "... ")
        _yaml_fail(
            state,
            :multiple_documents_prohibited,
            "YAML document markers and multiple documents are not admitted",
            first_byte,
            min(first_byte + 3, stop_byte),
        )
    end
end

function _yaml_parse_unicode_escape!(cursor::_RestrictedYamlInline, digits::Int)
    state = cursor.state
    text = state.source.text
    first_byte = cursor.byte
    cursor.byte + digits <= cursor.stop_byte ||
        _yaml_fail(
            state,
            :invalid_string_escape,
            "quoted string contains an incomplete Unicode escape",
            first_byte,
            cursor.stop_byte,
        )
    codepoint = 0
    for _ in 1:digits
        byte = _yaml_byte(text, cursor.byte)
        digit = if 0x30 <= byte <= 0x39
            Int(byte - 0x30)
        elseif 0x41 <= byte <= 0x46
            Int(byte - 0x41 + 10)
        elseif 0x61 <= byte <= 0x66
            Int(byte - 0x61 + 10)
        else
            _yaml_fail_character(
                state,
                :invalid_string_escape,
                "Unicode escape contains a non-hexadecimal digit",
                cursor.byte,
            )
        end
        codepoint = 16 * codepoint + digit
        cursor.byte += 1
    end
    return codepoint
end

function _yaml_parse_double_quoted!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    start_byte = cursor.byte
    cursor.byte += 1
    output = IOBuffer()

    while cursor.byte < cursor.stop_byte
        byte = _yaml_byte(text, cursor.byte)
        if byte == 0x22
            cursor.byte += 1
            _yaml_check_scalar_size(state, start_byte, cursor.byte)
            return FormatNode(
                FormatString(String(take!(output))),
                _yaml_span(state, start_byte, cursor.byte),
            )
        elseif byte == 0x5c
            escape_start = cursor.byte
            cursor.byte += 1
            cursor.byte < cursor.stop_byte ||
                _yaml_fail(
                    state,
                    :invalid_string_escape,
                    "quoted string ends inside an escape",
                    escape_start,
                    cursor.stop_byte,
                )
            escape = _yaml_byte(text, cursor.byte)
            cursor.byte += 1
            if escape == 0x22
                print(output, '"')
            elseif escape == 0x2f
                print(output, '/')
            elseif escape == 0x5c
                print(output, '\\')
            elseif escape == 0x30
                print(output, '\0')
            elseif escape == 0x61
                print(output, '\a')
            elseif escape == 0x62
                print(output, '\b')
            elseif escape == 0x74
                print(output, '\t')
            elseif escape == 0x6e
                print(output, '\n')
            elseif escape == 0x76
                print(output, '\v')
            elseif escape == 0x66
                print(output, '\f')
            elseif escape == 0x72
                print(output, '\r')
            elseif escape == 0x65
                print(output, Char(0x1b))
            elseif escape == 0x20
                print(output, ' ')
            elseif escape == 0x4e
                print(output, Char(0x85))
            elseif escape == 0x5f
                print(output, Char(0xa0))
            elseif escape == 0x4c
                print(output, Char(0x2028))
            elseif escape == 0x50
                print(output, Char(0x2029))
            elseif escape == 0x78
                codepoint = _yaml_parse_unicode_escape!(cursor, 2)
                print(output, Char(codepoint))
            elseif escape == 0x75 || escape == 0x55
                digits = escape == 0x75 ? 4 : 8
                codepoint = _yaml_parse_unicode_escape!(cursor, digits)
                if 0xd800 <= codepoint <= 0xdbff && escape == 0x75
                    pair_start = cursor.byte
                    if pair_start + 2 <= cursor.stop_byte &&
                       _yaml_byte(text, pair_start) == 0x5c &&
                       _yaml_byte(text, pair_start + 1) == 0x75
                        cursor.byte += 2
                        low = _yaml_parse_unicode_escape!(cursor, 4)
                        if 0xdc00 <= low <= 0xdfff
                            codepoint = 0x10000 + (codepoint - 0xd800) * 0x400 + (low - 0xdc00)
                        else
                            _yaml_fail(
                                state,
                                :invalid_unicode_escape,
                                "high surrogate is not followed by a low surrogate",
                                escape_start,
                                cursor.byte,
                            )
                        end
                    else
                        _yaml_fail(
                            state,
                            :invalid_unicode_escape,
                            "high surrogate is not followed by a low surrogate",
                            escape_start,
                            cursor.byte,
                        )
                    end
                elseif 0xdc00 <= codepoint <= 0xdfff || codepoint > 0x10ffff
                    _yaml_fail(
                        state,
                        :invalid_unicode_escape,
                        "Unicode escape is not a scalar value",
                        escape_start,
                        cursor.byte,
                    )
                end
                print(output, Char(codepoint))
            else
                _yaml_fail(
                    state,
                    :invalid_string_escape,
                    "quoted string contains an unsupported escape",
                    escape_start,
                    cursor.byte,
                )
            end
        elseif byte < 0x20
            _yaml_fail_character(
                state,
                :invalid_control_character,
                "quoted string contains an unescaped control character",
                cursor.byte,
            )
        else
            character = text[cursor.byte]
            print(output, character)
            cursor.byte = nextind(text, cursor.byte)
        end
    end

    _yaml_fail(
        state,
        :unterminated_string,
        "double-quoted string is not terminated on its physical line",
        start_byte,
        cursor.stop_byte,
    )
end

function _yaml_parse_single_quoted!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    start_byte = cursor.byte
    cursor.byte += 1
    output = IOBuffer()

    while cursor.byte < cursor.stop_byte
        byte = _yaml_byte(text, cursor.byte)
        if byte == 0x27
            following = cursor.byte + 1
            if following < cursor.stop_byte && _yaml_byte(text, following) == 0x27
                print(output, '\'')
                cursor.byte += 2
            else
                cursor.byte += 1
                _yaml_check_scalar_size(state, start_byte, cursor.byte)
                return FormatNode(
                    FormatString(String(take!(output))),
                    _yaml_span(state, start_byte, cursor.byte),
                )
            end
        elseif byte < 0x20
            _yaml_fail_character(
                state,
                :invalid_control_character,
                "quoted string contains an unescaped control character",
                cursor.byte,
            )
        else
            character = text[cursor.byte]
            print(output, character)
            cursor.byte = nextind(text, cursor.byte)
        end
    end

    _yaml_fail(
        state,
        :unterminated_string,
        "single-quoted string is not terminated on its physical line",
        start_byte,
        cursor.stop_byte,
    )
end

function _yaml_parse_decimal(
    state::_RestrictedYamlState,
    token::String,
    first_byte::Int,
    stop_byte::Int,
)
    matched = match(
        r"^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$",
        token,
    )
    isnothing(matched) && return nothing
    fraction = matched.captures[3]
    exponent_text = matched.captures[4]
    isnothing(fraction) && isnothing(exponent_text) && return nothing

    integer_digits = matched.captures[2]
    fraction_digits = isnothing(fraction) ? "" : fraction
    coefficient_digits = integer_digits * fraction_digits
    coefficient = parse(BigInt, coefficient_digits)
    matched.captures[1] == "-" && (coefficient = -coefficient)
    explicit_exponent = isnothing(exponent_text) ? BigInt(0) : parse(BigInt, exponent_text)
    total_exponent = explicit_exponent - ncodeunits(fraction_digits)
    if total_exponent < typemin(Int) || total_exponent > typemax(Int)
        _yaml_fail(
            state,
            :numeric_exponent_out_of_range,
            "decimal exponent is outside the supported exact range",
            first_byte,
            stop_byte,
        )
    end
    negative_zero = iszero(coefficient) && matched.captures[1] == "-"
    return FormatDecimal(
        coefficient,
        Int(total_exponent);
        negative_zero,
    )
end

function _yaml_plain_value(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
)
    text = state.source.text
    trimmed_stop = _yaml_trim_right(text, first_byte, stop_byte)
    first_byte < trimmed_stop ||
        _yaml_fail(state, :missing_value, "restricted YAML value is missing", first_byte)
    _yaml_check_scalar_size(state, first_byte, trimmed_stop)
    token = _yaml_text(text, first_byte, trimmed_stop)
    lower = lowercase(token)

    token == "null" && return FormatNull()
    token == "true" && return FormatBoolean(true)
    token == "false" && return FormatBoolean(false)

    if token == "-0"
        return FormatDecimal(0, 0; negative_zero = true)
    elseif occursin(r"^-?(0|[1-9][0-9]*)$", token)
        return FormatInteger(parse(BigInt, token))
    end

    decimal = _yaml_parse_decimal(state, token, first_byte, trimmed_stop)
    !isnothing(decimal) && return decimal

    if lower in ("yes", "no", "on", "off", "~") ||
       (lower in ("true", "false", "null") && token != lower)
        _yaml_fail(
            state,
            :implicit_scalar_prohibited,
            "non-JSON implicit boolean or null spelling must be quoted",
            first_byte,
            trimmed_stop,
        )
    elseif lower in (".nan", ".inf", "+.inf", "-.inf", "nan", "inf", "infinity")
        _yaml_fail(
            state,
            :nonfinite_number_prohibited,
            "nonfinite numbers are not admitted",
            first_byte,
            trimmed_stop,
        )
    elseif occursin(r"^[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:[Tt ].*)?$", token)
        _yaml_fail(
            state,
            :implicit_date_prohibited,
            "date-like plain scalars must be quoted",
            first_byte,
            trimmed_stop,
        )
    elseif occursin(
        r"^[+-]?(?:0[xX][0-9A-Fa-f_]+|0[oO][0-7_]+|0[bB][01_]+)$",
        token,
    ) || occursin(_YAML_AMBIGUOUS_NUMBER_PATTERN, token)
        _yaml_fail(
            state,
            :ambiguous_number_prohibited,
            "numeric-looking scalar is not an admitted exact JSON number and must be quoted",
            first_byte,
            trimmed_stop,
        )
    end

    first = _yaml_byte(text, first_byte)
    if first == 0x21
        _yaml_fail_character(
            state,
            :yaml_tag_prohibited,
            "YAML tags and executable constructors are prohibited",
            first_byte,
        )
    elseif first == 0x26
        _yaml_fail_character(
            state,
            :yaml_anchor_prohibited,
            "YAML anchors are prohibited",
            first_byte,
        )
    elseif first == 0x2a
        _yaml_fail_character(
            state,
            :yaml_alias_prohibited,
            "YAML aliases are prohibited",
            first_byte,
        )
    elseif first in (0x7c, 0x3e)
        _yaml_fail_character(
            state,
            :block_scalar_prohibited,
            "multiline block scalars are not admitted by the restricted profile",
            first_byte,
        )
    elseif first in (0x40, 0x60)
        _yaml_fail_character(
            state,
            :reserved_indicator_prohibited,
            "reserved YAML indicator must be quoted",
            first_byte,
        )
    end

    for byte in first_byte:(trimmed_stop - 1)
        value = _yaml_byte(text, byte)
        if value < 0x20
            _yaml_fail_character(
                state,
                :invalid_control_character,
                "plain scalar contains a control character",
                byte,
            )
        elseif value == 0x3a && byte + 1 < trimmed_stop &&
               _yaml_byte(text, byte + 1) in (0x20, 0x09)
            _yaml_fail_character(
                state,
                :ambiguous_mapping_separator,
                "plain scalar contains an ambiguous mapping separator",
                byte,
            )
        end
    end
    return FormatString(token)
end

function _yaml_inline_skip_spaces!(cursor::_RestrictedYamlInline)
    text = cursor.state.source.text
    while cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) == 0x20
        cursor.byte += 1
    end
end

function _yaml_flow_plain_stop(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    byte = cursor.byte
    while byte < cursor.stop_byte
        value = _yaml_byte(text, byte)
        value in (0x2c, 0x5d, 0x7d) && break
        if value == 0x23 &&
           (byte == cursor.byte || _yaml_byte(text, prevind(text, byte)) in (0x20, 0x09))
            break
        end
        byte += 1
    end
    return _yaml_trim_right(text, cursor.byte, byte)
end

function _yaml_parse_flow_key!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    _yaml_inline_skip_spaces!(cursor)
    start_byte = cursor.byte
    cursor.byte < cursor.stop_byte ||
        _yaml_fail(state, :missing_mapping_key, "flow mapping key is missing", cursor.byte)

    if _yaml_byte(text, cursor.byte) == 0x22
        key = _yaml_parse_double_quoted!(cursor)
    elseif _yaml_byte(text, cursor.byte) == 0x27
        key = _yaml_parse_single_quoted!(cursor)
    else
        while cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) != 0x3a
            value = _yaml_byte(text, cursor.byte)
            value in (0x2c, 0x5b, 0x5d, 0x7b, 0x7d) &&
                _yaml_fail_character(
                    state,
                    :invalid_mapping_key,
                    "flow mapping keys must be plain or quoted strings",
                    cursor.byte,
                )
            cursor.byte += 1
        end
        key_stop = _yaml_trim_right(text, start_byte, cursor.byte)
        start_byte < key_stop ||
            _yaml_fail(state, :missing_mapping_key, "flow mapping key is missing", start_byte)
        value = _yaml_plain_key(state, start_byte, key_stop)
        key = FormatNode(value, _yaml_span(state, start_byte, key_stop))
    end
    key.value isa FormatString ||
        _yaml_fail(
            state,
            :invalid_mapping_key,
            "flow mapping key must decode to a string",
            key.span.start.byte,
            key.span.stop.byte,
        )
    _yaml_inline_skip_spaces!(cursor)
    cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) == 0x3a ||
        _yaml_fail(
            state,
            :missing_mapping_separator,
            "flow mapping key must be followed by ':'",
            cursor.byte,
        )
    cursor.byte += 1
    return key
end

function _yaml_parse_flow_sequence!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    start_byte = cursor.byte
    _yaml_check_depth(state, cursor.depth, start_byte)
    cursor.byte += 1
    elements = FormatNode[]
    _yaml_inline_skip_spaces!(cursor)
    if cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) == 0x5d
        cursor.byte += 1
        return FormatNode(FormatSequence(elements), _yaml_span(state, start_byte, cursor.byte))
    end

    while true
        _yaml_count_item!(state, cursor.byte)
        child_cursor = _RestrictedYamlInline(
            state,
            cursor.byte,
            cursor.stop_byte,
            cursor.depth + 1,
        )
        child = _yaml_parse_inline_value!(child_cursor)
        cursor.byte = child_cursor.byte
        push!(elements, child)
        _yaml_inline_skip_spaces!(cursor)
        cursor.byte < cursor.stop_byte ||
            _yaml_fail(
                state,
                :unterminated_flow_sequence,
                "flow sequence is missing its closing ']'",
                start_byte,
                cursor.stop_byte,
            )
        delimiter = _yaml_byte(text, cursor.byte)
        if delimiter == 0x5d
            cursor.byte += 1
            break
        elseif delimiter == 0x2c
            cursor.byte += 1
            _yaml_inline_skip_spaces!(cursor)
            cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) != 0x5d ||
                _yaml_fail(
                    state,
                    :trailing_flow_separator,
                    "flow sequence must not contain a trailing comma",
                    cursor.byte,
                )
        else
            _yaml_fail_character(
                state,
                :missing_flow_separator,
                "flow sequence elements must be separated by ','",
                cursor.byte,
            )
        end
    end
    return FormatNode(FormatSequence(elements), _yaml_span(state, start_byte, cursor.byte))
end

function _yaml_parse_flow_mapping!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    start_byte = cursor.byte
    _yaml_check_depth(state, cursor.depth, start_byte)
    cursor.byte += 1
    entries = FormatMappingEntry[]
    keys = Set{String}()
    _yaml_inline_skip_spaces!(cursor)
    if cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) == 0x7d
        cursor.byte += 1
        return FormatNode(FormatMapping(entries), _yaml_span(state, start_byte, cursor.byte))
    end

    while true
        key = _yaml_parse_flow_key!(cursor)
        key_text = key.value.value
        key_text == "<<" &&
            _yaml_fail(
                state,
                :yaml_merge_key_prohibited,
                "YAML merge keys are prohibited",
                key.span.start.byte,
                key.span.stop.byte,
            )
        key_text in keys &&
            _yaml_fail(
                state,
                :duplicate_mapping_key,
                "mapping contains duplicate key '$(key_text)'",
                key.span.start.byte,
                key.span.stop.byte,
            )
        push!(keys, key_text)
        _yaml_inline_skip_spaces!(cursor)
        cursor.byte < cursor.stop_byte ||
            _yaml_fail(
                state,
                :missing_value,
                "flow mapping value is missing",
                cursor.byte,
            )
        _yaml_count_item!(state, key.span.start.byte)
        value_cursor = _RestrictedYamlInline(
            state,
            cursor.byte,
            cursor.stop_byte,
            cursor.depth + 1,
        )
        value = _yaml_parse_inline_value!(value_cursor)
        cursor.byte = value_cursor.byte
        push!(entries, FormatMappingEntry(key, value))
        _yaml_inline_skip_spaces!(cursor)
        cursor.byte < cursor.stop_byte ||
            _yaml_fail(
                state,
                :unterminated_flow_mapping,
                "flow mapping is missing its closing '}'",
                start_byte,
                cursor.stop_byte,
            )
        delimiter = _yaml_byte(text, cursor.byte)
        if delimiter == 0x7d
            cursor.byte += 1
            break
        elseif delimiter == 0x2c
            cursor.byte += 1
            _yaml_inline_skip_spaces!(cursor)
            cursor.byte < cursor.stop_byte && _yaml_byte(text, cursor.byte) != 0x7d ||
                _yaml_fail(
                    state,
                    :trailing_flow_separator,
                    "flow mapping must not contain a trailing comma",
                    cursor.byte,
                )
        else
            _yaml_fail_character(
                state,
                :missing_flow_separator,
                "flow mapping entries must be separated by ','",
                cursor.byte,
            )
        end
    end
    return FormatNode(FormatMapping(entries), _yaml_span(state, start_byte, cursor.byte))
end

function _yaml_parse_inline_value!(cursor::_RestrictedYamlInline)
    state = cursor.state
    text = state.source.text
    _yaml_check_depth(state, cursor.depth, cursor.byte)
    _yaml_inline_skip_spaces!(cursor)
    cursor.byte < cursor.stop_byte ||
        _yaml_fail(state, :missing_value, "restricted YAML value is missing", cursor.byte)
    first_byte = cursor.byte
    first = _yaml_byte(text, first_byte)
    if first == 0x22
        return _yaml_parse_double_quoted!(cursor)
    elseif first == 0x27
        return _yaml_parse_single_quoted!(cursor)
    elseif first == 0x5b
        return _yaml_parse_flow_sequence!(cursor)
    elseif first == 0x7b
        return _yaml_parse_flow_mapping!(cursor)
    end

    scalar_stop = _yaml_flow_plain_stop(cursor)
    value = _yaml_plain_value(state, first_byte, scalar_stop)
    cursor.byte = scalar_stop
    return FormatNode(value, _yaml_span(state, first_byte, scalar_stop))
end

function _yaml_parse_inline(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
    depth::Int,
)
    cursor = _RestrictedYamlInline(state, first_byte, stop_byte, depth)
    node = _yaml_parse_inline_value!(cursor)
    _yaml_inline_skip_spaces!(cursor)
    cursor.byte == stop_byte ||
        _yaml_fail_character(
            state,
            :trailing_content,
            "unexpected content follows the restricted YAML value",
            cursor.byte,
        )
    return node
end

function _yaml_plain_key(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
)
    text = state.source.text
    first_byte < stop_byte ||
        _yaml_fail(state, :missing_mapping_key, "mapping key is missing", first_byte)
    _yaml_check_scalar_size(state, first_byte, stop_byte)
    token = _yaml_text(text, first_byte, stop_byte)
    token == "<<" &&
        _yaml_fail(
            state,
            :yaml_merge_key_prohibited,
            "YAML merge keys are prohibited",
            first_byte,
            stop_byte,
        )
    first = _yaml_byte(text, first_byte)
    if first == 0x21
        _yaml_fail_character(state, :yaml_tag_prohibited, "YAML tags are prohibited", first_byte)
    elseif first == 0x26
        _yaml_fail_character(
            state,
            :yaml_anchor_prohibited,
            "YAML anchors are prohibited",
            first_byte,
        )
    elseif first == 0x2a
        _yaml_fail_character(
            state,
            :yaml_alias_prohibited,
            "YAML aliases are prohibited",
            first_byte,
        )
    elseif first in (0x5b, 0x7b, 0x3f)
        _yaml_fail_character(
            state,
            :complex_mapping_key_prohibited,
            "complex YAML mapping keys are not admitted",
            first_byte,
        )
    end
    return FormatString(token)
end

function _yaml_parse_key(
    state::_RestrictedYamlState,
    first_byte::Int,
    stop_byte::Int,
    depth::Int,
)
    text = state.source.text
    key_stop = _yaml_trim_right(text, first_byte, stop_byte)
    key_stop > first_byte ||
        _yaml_fail(state, :missing_mapping_key, "mapping key is missing", first_byte)
    first = _yaml_byte(text, first_byte)
    if first in (0x22, 0x27)
        cursor = _RestrictedYamlInline(state, first_byte, key_stop, depth)
        key = first == 0x22 ? _yaml_parse_double_quoted!(cursor) :
            _yaml_parse_single_quoted!(cursor)
        _yaml_inline_skip_spaces!(cursor)
        cursor.byte == key_stop ||
            _yaml_fail_character(
                state,
                :invalid_mapping_key,
                "quoted mapping key contains trailing content",
                cursor.byte,
            )
        return key
    end
    value = _yaml_plain_key(state, first_byte, key_stop)
    return FormatNode(value, _yaml_span(state, first_byte, key_stop))
end

function _yaml_null_node(state::_RestrictedYamlState, byte::Int)
    return FormatNode(FormatNull(), _yaml_span(state, byte, byte))
end

function _yaml_parse_mapping_entry(
    state::_RestrictedYamlState,
    line_index::Int,
    content_byte::Int,
    mapping_indent::Int,
    depth::Int,
)
    line = state.lines[line_index]
    stop_byte = _yaml_line_content_stop(state, line)
    colon = _yaml_find_mapping_colon(state, content_byte, stop_byte)
    colon != 0 ||
        _yaml_fail(
            state,
            :missing_mapping_separator,
            "block mapping entry must contain a ':' followed by whitespace or line end",
            content_byte,
            stop_byte,
        )
    key = _yaml_parse_key(state, content_byte, colon, depth + 1)
    _yaml_count_item!(state, key.span.start.byte)
    value_start = _yaml_skip_spaces(state.source.text, colon + 1, stop_byte)

    if value_start < stop_byte
        value = _yaml_parse_inline(state, value_start, stop_byte, depth + 1)
        return (FormatMappingEntry(key, value), line_index + 1)
    end

    next_index = _yaml_significant_line(state, line_index + 1)
    if next_index <= length(state.lines) && state.lines[next_index].indent > mapping_indent
        child_indent = state.lines[next_index].indent
        value, following = _yaml_parse_block(state, next_index, child_indent, depth + 1)
        return (FormatMappingEntry(key, value), following)
    end
    return (FormatMappingEntry(key, _yaml_null_node(state, colon + 1)), line_index + 1)
end

function _yaml_parse_block_mapping(
    state::_RestrictedYamlState,
    line_index::Int,
    mapping_indent::Int,
    depth::Int;
    first_content_byte::Union{Nothing,Int} = nothing,
)
    _yaml_check_depth(state, depth, state.lines[line_index].content_byte)
    entries = FormatMappingEntry[]
    keys = Set{String}()
    index = line_index
    initial = true
    mapping_start = if isnothing(first_content_byte)
        state.lines[line_index].content_byte
    else
        first_content_byte
    end

    while index <= length(state.lines)
        index = _yaml_significant_line(state, index)
        index > length(state.lines) && break
        line = state.lines[index]
        content_byte = if initial && !isnothing(first_content_byte)
            first_content_byte
        else
            line.indent < mapping_indent && break
            line.indent > mapping_indent &&
                _yaml_fail_character(
                    state,
                    :unexpected_indentation,
                    "block mapping contains unexpected indentation",
                    line.content_byte,
                )
            line.indent == mapping_indent || break
            line.content_byte
        end
        stop_byte = _yaml_line_content_stop(state, line)
        _yaml_reject_document_marker!(state, content_byte, stop_byte)
        _yaml_is_sequence_marker(state.source.text, content_byte, stop_byte) &&
            _yaml_fail_character(
                state,
                :mixed_block_collection,
                "block mapping cannot contain a sequence item at the same indentation",
                content_byte,
            )
        entry, following = _yaml_parse_mapping_entry(
            state,
            index,
            content_byte,
            mapping_indent,
            depth,
        )
        key_text = entry.key.value.value
        key_text in keys &&
            _yaml_fail(
                state,
                :duplicate_mapping_key,
                "mapping contains duplicate key '$(key_text)'",
                entry.key.span.start.byte,
                entry.key.span.stop.byte,
            )
        push!(keys, key_text)
        push!(entries, entry)
        index = following
        initial = false
    end

    mapping_stop = isempty(entries) ? mapping_start : entries[end].value.span.stop.byte
    return (
        FormatNode(FormatMapping(entries), _yaml_span(state, mapping_start, mapping_stop)),
        index,
    )
end

function _yaml_parse_block_sequence(
    state::_RestrictedYamlState,
    line_index::Int,
    sequence_indent::Int,
    depth::Int,
)
    _yaml_check_depth(state, depth, state.lines[line_index].content_byte)
    elements = FormatNode[]
    index = line_index
    sequence_start = state.lines[line_index].content_byte
    sequence_stop = sequence_start

    while index <= length(state.lines)
        index = _yaml_significant_line(state, index)
        index > length(state.lines) && break
        line = state.lines[index]
        line.indent < sequence_indent && break
        line.indent > sequence_indent &&
            _yaml_fail_character(
                state,
                :unexpected_indentation,
                "block sequence contains unexpected indentation",
                line.content_byte,
            )
        stop_byte = _yaml_line_content_stop(state, line)
        _yaml_reject_document_marker!(state, line.content_byte, stop_byte)
        _yaml_is_sequence_marker(state.source.text, line.content_byte, stop_byte) ||
            _yaml_fail_character(
                state,
                :mixed_block_collection,
                "block sequence cannot contain a mapping entry at the same indentation",
                line.content_byte,
            )
        _yaml_count_item!(state, line.content_byte)
        item_start = _yaml_skip_spaces(state.source.text, line.content_byte + 1, stop_byte)

        if item_start == stop_byte
            next_index = _yaml_significant_line(state, index + 1)
            if next_index <= length(state.lines) &&
               state.lines[next_index].indent > sequence_indent
                child_indent = state.lines[next_index].indent
                child, following = _yaml_parse_block(
                    state,
                    next_index,
                    child_indent,
                    depth + 1,
                )
                push!(elements, child)
                sequence_stop = child.span.stop.byte
                index = following
            else
                null = _yaml_null_node(state, line.content_byte + 1)
                push!(elements, null)
                sequence_stop = null.span.stop.byte
                index += 1
            end
            continue
        end

        colon = _yaml_find_mapping_colon(state, item_start, stop_byte)
        if colon != 0
            mapping_indent = item_start - line.start_byte
            child, following = _yaml_parse_block_mapping(
                state,
                index,
                mapping_indent,
                depth + 1;
                first_content_byte = item_start,
            )
            push!(elements, child)
            sequence_stop = child.span.stop.byte
            index = following
        else
            child = _yaml_parse_inline(state, item_start, stop_byte, depth + 1)
            push!(elements, child)
            sequence_stop = child.span.stop.byte
            index += 1
            next_index = _yaml_significant_line(state, index)
            if next_index <= length(state.lines) &&
               state.lines[next_index].indent > sequence_indent
                _yaml_fail_character(
                    state,
                    :unexpected_indentation,
                    "scalar sequence item cannot own an indented block",
                    state.lines[next_index].content_byte,
                )
            end
        end
    end

    return (
        FormatNode(
            FormatSequence(elements),
            _yaml_span(state, sequence_start, sequence_stop),
        ),
        index,
    )
end

function _yaml_parse_block(
    state::_RestrictedYamlState,
    line_index::Int,
    indent::Int,
    depth::Int,
)
    index = _yaml_significant_line(state, line_index)
    index <= length(state.lines) ||
        _yaml_fail(
            state,
            :missing_value,
            "restricted YAML block is empty",
            ncodeunits(state.source.text) + 1,
        )
    line = state.lines[index]
    line.indent == indent ||
        _yaml_fail_character(
            state,
            :unexpected_indentation,
            "restricted YAML block begins at an unexpected indentation",
            line.content_byte,
        )
    stop_byte = _yaml_line_content_stop(state, line)
    _yaml_reject_document_marker!(state, line.content_byte, stop_byte)
    if _yaml_is_sequence_marker(state.source.text, line.content_byte, stop_byte)
        return _yaml_parse_block_sequence(state, index, indent, depth)
    end
    colon = _yaml_find_mapping_colon(state, line.content_byte, stop_byte)
    if colon != 0
        return _yaml_parse_block_mapping(state, index, indent, depth)
    end
    return (_yaml_parse_inline(state, line.content_byte, stop_byte, depth), index + 1)
end

function _parse_restricted_yaml(source::SourceDocument, policy::FormatInputPolicy)
    try
        byte_count = ncodeunits(source.text)
        if byte_count >= 3 &&
           _yaml_byte(source.text, 1) == 0xef &&
           _yaml_byte(source.text, 2) == 0xbb &&
           _yaml_byte(source.text, 3) == 0xbf
            state = _RestrictedYamlState(source, _RestrictedYamlLine[], policy, 0)
            _yaml_fail(
                state,
                :byte_order_mark_prohibited,
                "UTF-8 byte-order marks are not admitted",
                1,
                4,
            )
        end
        lines = _yaml_lines(source, policy)
        state = _RestrictedYamlState(source, lines, policy, 0)
        first_line = _yaml_significant_line(state, 1)
        if first_line > length(lines)
            root = FormatNode(FormatNull(), _yaml_span(state, 1, 1))
            return FormatParseResult(ParsedFormatDocument(source, root))
        end
        lines[first_line].indent == 0 ||
            _yaml_fail_character(
                state,
                :top_level_indentation,
                "top-level restricted YAML content must begin in column one",
                lines[first_line].content_byte,
            )
        root, following = _yaml_parse_block(state, first_line, 0, 1)
        trailing = _yaml_significant_line(state, following)
        trailing > length(lines) ||
            _yaml_fail_character(
                state,
                :trailing_content,
                "unexpected top-level content follows the document root",
                lines[trailing].content_byte,
            )
        diagnostics = validate_format_tree(root, policy)
        isempty(diagnostics) || return FormatParseResult(nothing, diagnostics)
        return FormatParseResult(ParsedFormatDocument(source, root))
    catch error
        error isa _RestrictedYamlFailure || rethrow()
        return FormatParseResult(nothing, [error.diagnostic])
    end
end

"""Parse the inert restricted YAML 1.2 profile from a validated source document."""
function parse_restricted_yaml(
    source::SourceDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_document_bytes || begin
        span = source_span(source, 1, 1)
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "source document exceeds the configured byte limit",
            span,
        )
        return FormatParseResult(nothing, [diagnostic])
    end
    return _parse_restricted_yaml(source, policy)
end

"""Validate UTF-8 and parse the inert restricted YAML 1.2 profile."""
function parse_restricted_yaml(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return FormatParseResult(nothing, collect(admitted.diagnostics))
    return parse_restricted_yaml(admitted.value; policy)
end

parse_restricted_yaml(
    text::AbstractString;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_restricted_yaml(
    Vector{UInt8}(codeunits(text));
    source_name,
    policy,
)

function _yaml_emit_string(io::IO, value::String)
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

function _yaml_emit_decimal(io::IO, value::FormatDecimal)
    if iszero(value.coefficient)
        print(io, value.negative_zero ? "-0.0" : "0.0")
        return
    end
    print(io, value.coefficient, 'e')
    value.exponent >= 0 && print(io, '+')
    print(io, value.exponent)
end

function _yaml_emit_node(io::IO, node::FormatNode, depth::Int, policy::FormatInputPolicy)
    depth <= policy.max_nesting_depth ||
        throw(_RestrictedYamlFailure(FormatDiagnostic(
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
        _yaml_emit_decimal(io, value)
    elseif value isa FormatString
        _yaml_emit_string(io, value.value)
    elseif value isa FormatSequence
        print(io, '[')
        for (index, child) in enumerate(value.elements)
            index > 1 && print(io, ',')
            _yaml_emit_node(io, child, depth + 1, policy)
        end
        print(io, ']')
    elseif value isa FormatMapping
        print(io, '{')
        for (index, entry) in enumerate(value.entries)
            index > 1 && print(io, ',')
            _yaml_emit_string(io, entry.key.value.value)
            print(io, ':')
            _yaml_emit_node(io, entry.value, depth + 1, policy)
        end
        print(io, '}')
    else
        throw(_RestrictedYamlFailure(FormatDiagnostic(
            DiagnosticError,
            :unsupported_format_value,
            "value does not belong to the admitted restricted YAML domain",
            node.span,
        )))
    end
end

"""Serialize a located format value as deterministic single-line restricted YAML."""
function serialize_restricted_yaml(
    root::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(root, policy)
    isempty(diagnostics) || return FormatSerializationResult(nothing, diagnostics)
    output = IOBuffer()
    try
        _yaml_emit_node(output, root, 1, policy)
        print(output, '\n')
        bytes = take!(output)
        length(bytes) <= policy.max_document_bytes || begin
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :document_too_large,
                "serialized restricted YAML exceeds the configured byte limit",
                root.span,
            )
            return FormatSerializationResult(nothing, [diagnostic])
        end
        return FormatSerializationResult(SerializedFormatDocument(bytes, _YAML_MEDIA_TYPE))
    catch error
        error isa _RestrictedYamlFailure || rethrow()
        return FormatSerializationResult(nothing, [error.diagnostic])
    end
end

"""Serialize a parsed format document as deterministic single-line restricted YAML."""
serialize_restricted_yaml(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = serialize_restricted_yaml(document.root; policy)
