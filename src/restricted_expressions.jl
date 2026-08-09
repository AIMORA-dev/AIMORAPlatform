@enum RestrictedExpressionUnaryOperator::UInt8 begin
    ExpressionPositive = 0x01
    ExpressionNegative = 0x02
    ExpressionLogicalNot = 0x03
end

@enum RestrictedExpressionBinaryOperator::UInt8 begin
    ExpressionPower = 0x01
    ExpressionMultiply = 0x02
    ExpressionDivide = 0x03
    ExpressionRemainder = 0x04
    ExpressionAdd = 0x05
    ExpressionSubtract = 0x06
    ExpressionLess = 0x07
    ExpressionLessEqual = 0x08
    ExpressionGreater = 0x09
    ExpressionGreaterEqual = 0x0a
    ExpressionEqual = 0x0b
    ExpressionNotEqual = 0x0c
    ExpressionLogicalAnd = 0x0d
    ExpressionLogicalOr = 0x0e
end

const _EXPRESSION_UNARY_OPERATORS = Dict(
    "+" => ExpressionPositive,
    "-" => ExpressionNegative,
    "!" => ExpressionLogicalNot,
)
const _EXPRESSION_BINARY_OPERATORS = Dict(
    "^" => ExpressionPower,
    "*" => ExpressionMultiply,
    "/" => ExpressionDivide,
    "%" => ExpressionRemainder,
    "+" => ExpressionAdd,
    "-" => ExpressionSubtract,
    "<" => ExpressionLess,
    "<=" => ExpressionLessEqual,
    ">" => ExpressionGreater,
    ">=" => ExpressionGreaterEqual,
    "==" => ExpressionEqual,
    "!=" => ExpressionNotEqual,
    "&&" => ExpressionLogicalAnd,
    "||" => ExpressionLogicalOr,
)
const _EXPRESSION_FUNCTION_ARITIES = Dict(
    "abs" => (1, 1),
    "acos" => (1, 1),
    "asin" => (1, 1),
    "atan" => (1, 2),
    "ceil" => (1, 1),
    "clamp" => (3, 3),
    "cos" => (1, 1),
    "exp" => (1, 1),
    "floor" => (1, 1),
    "ifelse" => (3, 3),
    "log" => (1, 2),
    "log10" => (1, 1),
    "max" => (2, 16),
    "min" => (2, 16),
    "round" => (1, 1),
    "sin" => (1, 1),
    "sqrt" => (1, 1),
    "tan" => (1, 1),
)
const _EXPRESSION_CONTROL_IDENTIFIERS = Set([
    "baremodule",
    "begin",
    "break",
    "catch",
    "const",
    "continue",
    "do",
    "else",
    "elseif",
    "end",
    "export",
    "finally",
    "for",
    "function",
    "global",
    "if",
    "import",
    "let",
    "local",
    "macro",
    "module",
    "mutable",
    "primitive",
    "quote",
    "return",
    "struct",
    "try",
    "using",
    "while",
    "where",
])
const _EXPRESSION_HOST_VALUE_IDENTIFIERS = Set([
    "Inf",
    "Infinity",
    "NaN",
    "missing",
    "nothing",
])
const _EXPRESSION_PROHIBITED_IDENTIFIERS = Set([
    "ARGS",
    "Base",
    "Cmd",
    "Core",
    "Downloads",
    "ENV",
    "HTTP",
    "Libdl",
    "Main",
    "Sockets",
    "applicable",
    "ccall",
    "download",
    "eval",
    "fieldnames",
    "getfield",
    "getproperty",
    "include",
    "invokelatest",
    "invoke",
    "methods",
    "names",
    "open",
    "parentmodule",
    "pipeline",
    "propertynames",
    "read",
    "redirect_stderr",
    "redirect_stdin",
    "redirect_stdout",
    "run",
    "which",
    "write",
])

"""Closed inert syntax-tree family for the restricted expression language."""
abstract type RestrictedExpressionNode end

"""An exact number or Boolean expression literal."""
struct RestrictedExpressionLiteral <: RestrictedExpressionNode
    value::Union{FormatBoolean,FormatInteger,FormatDecimal}
    span::SourceSpan
end

Base.:(==)(left::RestrictedExpressionLiteral, right::RestrictedExpressionLiteral) =
    left.value == right.value && left.span == right.span

"""A portable variable identity; qualified names are lexical and never reflected."""
struct RestrictedExpressionVariable <: RestrictedExpressionNode
    name::String
    span::SourceSpan
end

Base.:(==)(left::RestrictedExpressionVariable, right::RestrictedExpressionVariable) =
    left.name == right.name && left.span == right.span

"""One admitted unary operation without an evaluator."""
struct RestrictedExpressionUnary <: RestrictedExpressionNode
    operation::RestrictedExpressionUnaryOperator
    operand::RestrictedExpressionNode
    span::SourceSpan
end

Base.:(==)(left::RestrictedExpressionUnary, right::RestrictedExpressionUnary) =
    left.operation == right.operation &&
    left.operand == right.operand &&
    left.span == right.span

"""One admitted binary operation without an evaluator."""
struct RestrictedExpressionBinary <: RestrictedExpressionNode
    operation::RestrictedExpressionBinaryOperator
    left::RestrictedExpressionNode
    right::RestrictedExpressionNode
    span::SourceSpan
end

Base.:(==)(left::RestrictedExpressionBinary, right::RestrictedExpressionBinary) =
    left.operation == right.operation &&
    left.left == right.left &&
    left.right == right.right &&
    left.span == right.span

"""A call to one closed, deterministic function name; parsing never invokes it."""
struct RestrictedExpressionCall <: RestrictedExpressionNode
    function_name::String
    arguments::FormatItemList{RestrictedExpressionNode}
    span::SourceSpan

    function RestrictedExpressionCall(
        function_name::String,
        arguments::AbstractVector{<:RestrictedExpressionNode},
        span::SourceSpan,
        ::Val{:parsed_restricted_expression_call},
    )
        return new(
            function_name,
            FormatItemList{RestrictedExpressionNode}(collect(arguments)),
            span,
        )
    end
end

Base.:(==)(left::RestrictedExpressionCall, right::RestrictedExpressionCall) =
    left.function_name == right.function_name &&
    left.arguments == right.arguments &&
    left.span == right.span

"""A parsed restricted expression and its deterministic fully parenthesized text."""
struct RestrictedExpression
    source::SourceDocument
    root::RestrictedExpressionNode
    canonical_text::String
    tree_depth::Int
    node_count::Int

    function RestrictedExpression(
        source::SourceDocument,
        root::RestrictedExpressionNode,
        canonical_text::String,
        tree_depth::Int,
        node_count::Int,
        ::Val{:parsed_restricted_expression},
    )
        return new(source, root, canonical_text, tree_depth, node_count)
    end
end


Base.:(==)(left::RestrictedExpression, right::RestrictedExpression) =
    left.source == right.source &&
    left.root == right.root &&
    left.canonical_text == right.canonical_text &&
    left.tree_depth == right.tree_depth &&
    left.node_count == right.node_count

const RestrictedExpressionParseResult = FormatResult{RestrictedExpression}

"""A strict `{"\$expr": ...}` envelope containing only an inert syntax tree."""
struct ExpressionEnvelope
    expression::RestrictedExpression
    span::SourceSpan
end

Base.:(==)(left::ExpressionEnvelope, right::ExpressionEnvelope) =
    left.expression == right.expression && left.span == right.span

struct _RestrictedExpressionFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _expression_fail(code::Symbol, message::AbstractString, span::SourceSpan)
    throw(_RestrictedExpressionFailure(
        FormatDiagnostic(DiagnosticError, code, String(message), span),
    ))
end

struct _RestrictedExpressionToken
    kind::Symbol
    text::String
    span::SourceSpan
end

function _expression_character_span(source::SourceDocument, index::Int)
    return source_span(source, index, nextind(source.text, index))
end

function _expression_push_token!(
    tokens::Vector{_RestrictedExpressionToken},
    token::_RestrictedExpressionToken,
    policy::FormatInputPolicy,
)
    length(tokens) < policy.max_collection_items || _expression_fail(
        :expression_token_limit,
        "restricted expression exceeds the configured token limit",
        token.span,
    )
    push!(tokens, token)
    return nothing
end

function _expression_lex(source::SourceDocument, policy::FormatInputPolicy)
    text = source.text
    tokens = _RestrictedExpressionToken[]
    index = firstindex(text)
    while index <= lastindex(text)
        character = text[index]
        if character == ' ' || character == '\t'
            index = nextind(text, index)
            continue
        elseif character == '\n' || character == '\r'
            _expression_fail(
                :expression_newline_prohibited,
                "restricted expressions must remain on one physical line",
                _expression_character_span(source, index),
            )
        end
        start = index
        if isascii(character) && (isletter(character) || character == '_')
            index = nextind(text, index)
            while index <= lastindex(text)
                candidate = text[index]
                if isascii(candidate) &&
                   (isletter(candidate) || isdigit(candidate) || candidate == '_' || candidate == '.')
                    index = nextind(text, index)
                else
                    break
                end
            end
            value = String(SubString(text, start, prevind(text, index)))
            token = _RestrictedExpressionToken(
                :identifier,
                value,
                source_span(source, start, index),
            )
            _expression_push_token!(tokens, token, policy)
            continue
        elseif isascii(character) && isdigit(character)
            suffix = SubString(text, index)
            matched = match(
                r"^(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?",
                suffix,
            )
            isnothing(matched) && _expression_fail(
                :invalid_expression_number,
                "restricted expression contains an invalid number",
                _expression_character_span(source, index),
            )
            value = String(matched.match)
            index += ncodeunits(value)
            token = _RestrictedExpressionToken(
                :number,
                value,
                source_span(source, start, index),
            )
            _expression_push_token!(tokens, token, policy)
            continue
        end
        remainder = SubString(text, index)
        matched_operator = nothing
        for operator in ("&&", "||", "<=", ">=", "==", "!=")
            if startswith(remainder, operator)
                matched_operator = operator
                break
            end
        end
        if !isnothing(matched_operator)
            index += ncodeunits(matched_operator)
            token = _RestrictedExpressionToken(
                :operator,
                matched_operator,
                source_span(source, start, index),
            )
            _expression_push_token!(tokens, token, policy)
            continue
        elseif character in ('+', '-', '*', '/', '%', '^', '!', '<', '>')
            index = nextind(text, index)
            token = _RestrictedExpressionToken(
                :operator,
                string(character),
                source_span(source, start, index),
            )
            _expression_push_token!(tokens, token, policy)
            continue
        elseif character == '('
            kind = :left_parenthesis
        elseif character == ')'
            kind = :right_parenthesis
        elseif character == ','
            kind = :comma
        elseif character == '='
            _expression_fail(
                :expression_assignment_prohibited,
                "assignment and mutation are prohibited in restricted expressions",
                _expression_character_span(source, index),
            )
        elseif character == '"' || character == '\''
            _expression_fail(
                :expression_string_prohibited,
                "string and command literals are prohibited in restricted expressions",
                _expression_character_span(source, index),
            )
        elseif character in ('[', ']', '{', '}', ';', ':', '?', '@', '\$', '`')
            _expression_fail(
                :expression_syntax_prohibited,
                "indexing, blocks, interpolation, macros, and control syntax are prohibited",
                _expression_character_span(source, index),
            )
        else
            _expression_fail(
                :unknown_expression_character,
                "restricted expression contains an unknown character",
                _expression_character_span(source, index),
            )
        end
        index = nextind(text, index)
        token = _RestrictedExpressionToken(
            kind,
            string(character),
            source_span(source, start, index),
        )
        _expression_push_token!(tokens, token, policy)
    end
    eof_span = source_span(source, ncodeunits(text) + 1, ncodeunits(text) + 1)
    push!(tokens, _RestrictedExpressionToken(:end_of_expression, "", eof_span))
    return tokens
end

mutable struct _RestrictedExpressionParser
    source::SourceDocument
    tokens::Vector{_RestrictedExpressionToken}
    index::Int
    policy::FormatInputPolicy
    node_count::Int
    recursion_depth::Int
end

struct _RestrictedExpressionBranch
    node::RestrictedExpressionNode
    depth::Int
end

_expression_current(parser::_RestrictedExpressionParser) = parser.tokens[parser.index]

function _expression_nested(
    parse_nested::Function,
    parser::_RestrictedExpressionParser,
    span::SourceSpan,
)
    parser.recursion_depth < parser.policy.max_nesting_depth || _expression_fail(
        :expression_nesting_too_deep,
        "restricted expression exceeds the configured syntax depth",
        span,
    )
    parser.recursion_depth += 1
    try
        return parse_nested()
    finally
        parser.recursion_depth -= 1
    end
end

function _expression_take!(parser::_RestrictedExpressionParser)
    token = _expression_current(parser)
    parser.index < length(parser.tokens) && (parser.index += 1)
    return token
end

function _expression_accept!(
    parser::_RestrictedExpressionParser,
    kind::Symbol,
    text::Union{Nothing,String} = nothing,
)
    token = _expression_current(parser)
    token.kind == kind || return nothing
    isnothing(text) || token.text == text || return nothing
    parser.index += 1
    return token
end

function _expression_expect!(
    parser::_RestrictedExpressionParser,
    kind::Symbol,
    label::String,
)
    token = _expression_accept!(parser, kind)
    isnothing(token) && _expression_fail(
        :expression_expected_token,
        "restricted expression expected $(label)",
        _expression_current(parser).span,
    )
    return token
end

function _expression_span(first::SourceSpan, last::SourceSpan)
    first.source_name == last.source_name || error("expression spans belong to different sources")
    return SourceSpan(first.source_name, first.start, last.stop)
end

function _expression_branch!(
    parser::_RestrictedExpressionParser,
    node::RestrictedExpressionNode,
    depth::Int,
)
    parser.node_count < parser.policy.max_collection_items || _expression_fail(
        :expression_node_limit,
        "restricted expression exceeds the configured syntax-node limit",
        getfield(node, :span),
    )
    depth <= parser.policy.max_nesting_depth || _expression_fail(
        :expression_nesting_too_deep,
        "restricted expression exceeds the configured syntax depth",
        getfield(node, :span),
    )
    parser.node_count += 1
    return _RestrictedExpressionBranch(node, depth)
end

function _expression_identifier_allowed(name::String, span::SourceSpan)
    occursin(_PORTABLE_SYMBOL_PATTERN, name) || _expression_fail(
        :invalid_expression_identifier,
        "restricted expression identifier is not portable",
        span,
    )
    segments = split(name, '.')
    any(segment -> segment in _EXPRESSION_CONTROL_IDENTIFIERS, segments) &&
        _expression_fail(
            :expression_control_prohibited,
            "control-flow and declaration identifiers are prohibited",
            span,
        )
    any(segment -> segment in _EXPRESSION_HOST_VALUE_IDENTIFIERS, segments) &&
        _expression_fail(
            :expression_host_value_prohibited,
            "nonfinite and Julia-host sentinel values are prohibited",
            span,
        )
    any(segment -> segment in _EXPRESSION_PROHIBITED_IDENTIFIERS, segments) &&
        _expression_fail(
            :expression_capability_prohibited,
            "reflection, process, filesystem, network, and runtime capabilities are prohibited",
            span,
        )
    return name
end

function _expression_number_value(token::_RestrictedExpressionToken)
    parsed = parse_json(token.text; source_name = token.span.source_name)
    format_succeeded(parsed) || _expression_fail(
        :invalid_expression_number,
        "restricted expression contains an invalid exact number",
        token.span,
    )
    value = parsed.value.root.value
    (value isa FormatInteger || value isa FormatDecimal) || error("numeric token parsed as nonnumber")
    return value
end

function _expression_primary(parser::_RestrictedExpressionParser)
    token = _expression_current(parser)
    if token.kind == :number
        _expression_take!(parser)
        node = RestrictedExpressionLiteral(_expression_number_value(token), token.span)
        return _expression_branch!(parser, node, 1)
    elseif token.kind == :identifier
        _expression_take!(parser)
        if token.text == "true" || token.text == "false"
            node = RestrictedExpressionLiteral(FormatBoolean(token.text == "true"), token.span)
            return _expression_branch!(parser, node, 1)
        elseif token.text == "null"
            _expression_fail(
                :expression_null_prohibited,
                "null is not an admitted expression literal",
                token.span,
            )
        end
        name = _expression_identifier_allowed(token.text, token.span)
        if isnothing(_expression_accept!(parser, :left_parenthesis))
            node = RestrictedExpressionVariable(name, token.span)
            return _expression_branch!(parser, node, 1)
        end
        haskey(_EXPRESSION_FUNCTION_ARITIES, name) || _expression_fail(
            :unknown_expression_function,
            "restricted expression function $(name) is not admitted",
            token.span,
        )
        arguments = RestrictedExpressionNode[]
        argument_depth = 0
        if isnothing(_expression_accept!(parser, :right_parenthesis))
            while true
                argument = _expression_nested(parser, token.span) do
                    _expression_or(parser)
                end
                push!(arguments, argument.node)
                argument_depth = max(argument_depth, argument.depth)
                isnothing(_expression_accept!(parser, :comma)) && break
            end
            close = _expression_expect!(parser, :right_parenthesis, "a closing parenthesis")
        else
            close = parser.tokens[parser.index - 1]
        end
        minimum, maximum = _EXPRESSION_FUNCTION_ARITIES[name]
        minimum <= length(arguments) <= maximum || _expression_fail(
            :invalid_expression_function_arity,
            "function $(name) requires $(minimum) to $(maximum) arguments",
            _expression_span(token.span, close.span),
        )
        span = _expression_span(token.span, close.span)
        node = RestrictedExpressionCall(
            name,
            arguments,
            span,
            Val(:parsed_restricted_expression_call),
        )
        return _expression_branch!(parser, node, argument_depth + 1)
    end
    open_parenthesis = _expression_accept!(parser, :left_parenthesis)
    if !isnothing(open_parenthesis)
        branch = _expression_nested(parser, open_parenthesis.span) do
            _expression_or(parser)
        end
        _expression_expect!(parser, :right_parenthesis, "a closing parenthesis")
        return branch
    end
    _expression_fail(
        :expression_expected_operand,
        "restricted expression expected a literal, variable, call, or parenthesized expression",
        token.span,
    )
end

function _expression_power(parser::_RestrictedExpressionParser)
    left = _expression_primary(parser)
    operator = _expression_accept!(parser, :operator, "^")
    isnothing(operator) && return left
    right = _expression_nested(parser, operator.span) do
        _expression_unary(parser)
    end
    node = RestrictedExpressionBinary(
        ExpressionPower,
        left.node,
        right.node,
        _expression_span(getfield(left.node, :span), getfield(right.node, :span)),
    )
    return _expression_branch!(parser, node, max(left.depth, right.depth) + 1)
end

function _expression_unary(parser::_RestrictedExpressionParser)
    token = _expression_current(parser)
    if token.kind == :operator && haskey(_EXPRESSION_UNARY_OPERATORS, token.text)
        _expression_take!(parser)
        operand = _expression_nested(parser, token.span) do
            _expression_unary(parser)
        end
        node = RestrictedExpressionUnary(
            _EXPRESSION_UNARY_OPERATORS[token.text],
            operand.node,
            _expression_span(token.span, getfield(operand.node, :span)),
        )
        return _expression_branch!(parser, node, operand.depth + 1)
    end
    return _expression_power(parser)
end

function _expression_binary_chain(
    parser::_RestrictedExpressionParser,
    operand_parser::Function,
    admitted::Set{String},
)
    left = operand_parser(parser)
    while true
        token = _expression_current(parser)
        token.kind == :operator && token.text in admitted || break
        _expression_take!(parser)
        right = operand_parser(parser)
        node = RestrictedExpressionBinary(
            _EXPRESSION_BINARY_OPERATORS[token.text],
            left.node,
            right.node,
            _expression_span(getfield(left.node, :span), getfield(right.node, :span)),
        )
        left = _expression_branch!(parser, node, max(left.depth, right.depth) + 1)
    end
    return left
end

_expression_multiplicative(parser::_RestrictedExpressionParser) =
    _expression_binary_chain(parser, _expression_unary, Set(["*", "/", "%"]))

_expression_additive(parser::_RestrictedExpressionParser) =
    _expression_binary_chain(parser, _expression_multiplicative, Set(["+", "-"]))

function _expression_comparison(parser::_RestrictedExpressionParser)
    left = _expression_additive(parser)
    comparisons = Set(["<", "<=", ">", ">=", "==", "!="])
    token = _expression_current(parser)
    token.kind == :operator && token.text in comparisons || return left
    _expression_take!(parser)
    right = _expression_additive(parser)
    next_token = _expression_current(parser)
    next_token.kind == :operator && next_token.text in comparisons && _expression_fail(
        :expression_comparison_chain_prohibited,
        "comparison chaining is ambiguous and prohibited",
        next_token.span,
    )
    node = RestrictedExpressionBinary(
        _EXPRESSION_BINARY_OPERATORS[token.text],
        left.node,
        right.node,
        _expression_span(getfield(left.node, :span), getfield(right.node, :span)),
    )
    return _expression_branch!(parser, node, max(left.depth, right.depth) + 1)
end

_expression_and(parser::_RestrictedExpressionParser) =
    _expression_binary_chain(parser, _expression_comparison, Set(["&&"]))

_expression_or(parser::_RestrictedExpressionParser) =
    _expression_binary_chain(parser, _expression_and, Set(["||"]))

function _expression_operator_text(operation::RestrictedExpressionUnaryOperator)
    operation == ExpressionPositive && return "+"
    operation == ExpressionNegative && return "-"
    operation == ExpressionLogicalNot && return "!"
    error("unsupported expression unary operator")
end

function _expression_operator_text(operation::RestrictedExpressionBinaryOperator)
    for (text, candidate) in _EXPRESSION_BINARY_OPERATORS
        candidate == operation && return text
    end
    error("unsupported expression binary operator")
end

function _expression_emit_literal(io::IO, value)
    if value isa FormatBoolean
        print(io, value.value ? "true" : "false")
    elseif value isa FormatInteger
        print(io, value.value)
    elseif iszero(value.coefficient)
        print(io, value.negative_zero ? "-0e0" : "0e0")
    else
        print(io, value.coefficient, 'e', value.exponent)
    end
end

function _expression_emit(io::IO, node::RestrictedExpressionNode)
    if node isa RestrictedExpressionLiteral
        _expression_emit_literal(io, node.value)
    elseif node isa RestrictedExpressionVariable
        print(io, node.name)
    elseif node isa RestrictedExpressionUnary
        print(io, '(', _expression_operator_text(node.operation))
        _expression_emit(io, node.operand)
        print(io, ')')
    elseif node isa RestrictedExpressionBinary
        print(io, '(')
        _expression_emit(io, node.left)
        print(io, ' ', _expression_operator_text(node.operation), ' ')
        _expression_emit(io, node.right)
        print(io, ')')
    elseif node isa RestrictedExpressionCall
        print(io, node.function_name, '(')
        for (index, argument) in enumerate(node.arguments)
            index > 1 && print(io, ',')
            _expression_emit(io, argument)
        end
        print(io, ')')
    else
        error("unsupported restricted expression node")
    end
    return nothing
end

function _expression_canonical_text(root::RestrictedExpressionNode)
    output = IOBuffer()
    _expression_emit(output, root)
    return String(take!(output))
end

"""Parse a bounded deterministic expression into an inert syntax tree."""
function parse_restricted_expression(
    source::SourceDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_scalar_bytes || begin
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :expression_too_large,
            "restricted expression exceeds the configured scalar limit",
            source_span(source, 1, 1),
        )
        return RestrictedExpressionParseResult(nothing, [diagnostic])
    end
    try
        tokens = _expression_lex(source, policy)
        parser = _RestrictedExpressionParser(source, tokens, 1, policy, 0, 0)
        root = _expression_or(parser)
        current = _expression_current(parser)
        current.kind == :end_of_expression || _expression_fail(
            :expression_trailing_syntax,
            "restricted expression contains trailing or unsupported syntax",
            current.span,
        )
        canonical = _expression_canonical_text(root.node)
        ncodeunits(canonical) <= policy.max_document_bytes || _expression_fail(
            :expression_too_large,
            "canonical restricted expression exceeds the configured document limit",
            getfield(root.node, :span),
        )
        return RestrictedExpressionParseResult(RestrictedExpression(
            source,
            root.node,
            canonical,
            root.depth,
            parser.node_count,
            Val(:parsed_restricted_expression),
        ))
    catch error
        error isa _RestrictedExpressionFailure || rethrow()
        return RestrictedExpressionParseResult(nothing, [error.diagnostic])
    end
end

function parse_restricted_expression(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<expression>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return RestrictedExpressionParseResult(nothing, collect(admitted.diagnostics))
    return parse_restricted_expression(admitted.value; policy)
end

parse_restricted_expression(
    text::AbstractString;
    source_name::AbstractString = "<expression>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_restricted_expression(
    Vector{UInt8}(codeunits(text));
    source_name,
    policy,
)

"""Write the deterministic fully parenthesized restricted expression text."""
function serialize_restricted_expression(
    expression::RestrictedExpression;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    bytes = Vector{UInt8}(codeunits(expression.canonical_text))
    if length(bytes) > policy.max_document_bytes || length(bytes) > policy.max_scalar_bytes
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :expression_too_large,
            "restricted expression exceeds the configured output limit",
            getfield(expression.root, :span),
        )
        return FormatSerializationResult(nothing, [diagnostic])
    end
    return FormatSerializationResult(SerializedFormatDocument(
        bytes,
        "text/x-aimora-expression",
    ))
end

"""Parse a strict expression envelope without evaluating its expression."""
function parse_expression_envelope(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) || return FormatResult{ExpressionEnvelope}(nothing, diagnostics)
    try
        entries = _inert_mapping_entries(node, "expression envelope", Set(["\$expr"]))
        value_entry = _inert_required_entry(entries, "\$expr", node, "expression envelope")
        value_entry.value.value isa FormatString || _inert_fail(
            :inert_envelope_field_kind_mismatch,
            "expression envelope \$expr must be a string",
            value_entry.value.span,
        )
        expression = parse_restricted_expression(
            value_entry.value.value.value;
            source_name = string(value_entry.value.span.source_name, "#/\$expr"),
            policy,
        )
        format_succeeded(expression) ||
            return FormatResult{ExpressionEnvelope}(nothing, collect(expression.diagnostics))
        return FormatResult(ExpressionEnvelope(expression.value, node.span))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(ExpressionEnvelope, error)
    end
end

parse_expression_envelope(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_expression_envelope(document.root; policy)

"""Write an expression envelope as deterministic canonical JSON without evaluation."""
function serialize_expression_envelope(
    envelope::ExpressionEnvelope;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    root = _inert_generated_mapping([
        "\$expr" => _inert_generated_string(envelope.expression.canonical_text),
    ])
    return serialize_canonical_json(root; policy)
end
