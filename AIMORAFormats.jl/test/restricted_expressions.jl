function restricted_expression_failure(text::String, code::Symbol; column::Union{Nothing,Int} = nothing)
    result = parse_restricted_expression(text; source_name = "bad.expr")
    @test !format_succeeded(result)
    diagnostic = only(result.diagnostics)
    @test diagnostic.code == code
    @test diagnostic.span.source_name == "bad.expr"
    isnothing(column) || @test diagnostic.span.start.column == column
    return diagnostic
end

@testset "restricted expression precedence and deterministic writing" begin
    text = "-2^2 + 3*4 <= max(limit, 10) && !false || true"
    result = parse_restricted_expression(text; source_name = "control.expr")
    @test format_succeeded(result)
    expression = result.value
    @test expression.canonical_text ==
          "(((((-(2 ^ 2)) + (3 * 4)) <= max(limit,10)) && (!false)) || true)"
    @test expression.root isa RestrictedExpressionBinary
    @test expression.root.operation == ExpressionLogicalOr
    @test expression.root.left.operation == ExpressionLogicalAnd
    @test expression.root.left.left.operation == ExpressionLessEqual
    @test expression.root.span.start == SourcePosition(1, 1, 1)
    @test expression.root.span.stop == SourcePosition(47, 1, 47)
    @test expression.node_count == 17
    @test expression.tree_depth == 7

    serialized = serialize_restricted_expression(expression)
    @test serialized_inert_text(serialized) == expression.canonical_text
    repeated = parse_restricted_expression(
        serialized_inert_text(serialized);
        source_name = "canonical.expr",
    )
    @test format_succeeded(repeated)
    @test repeated.value.canonical_text == expression.canonical_text
    @test repeated.value.node_count == expression.node_count
    @test repeated.value.tree_depth == expression.tree_depth

    powers = parse_restricted_expression("2^-3^2")
    @test powers.value.canonical_text == "(2 ^ (-(3 ^ 2)))"
    decimals = parse_restricted_expression("clamp(signal.value,0.0,1e2)")
    @test decimals.value.canonical_text == "clamp(signal.value,0e0,1e2)"

    envelope_document = parse_restricted_yaml(
        "{\$expr: 'ifelse(enabled, min(a, b), max(a, b))'}";
        source_name = "expression-envelope.yaml",
    )
    envelope = parse_expression_envelope(envelope_document.value)
    @test format_succeeded(envelope)
    @test envelope.value.expression.root isa RestrictedExpressionCall
    envelope_json = serialized_inert_text(serialize_expression_envelope(envelope.value))
    @test envelope_json ==
          "{\"\$expr\":\"ifelse(enabled,min(a,b),max(a,b))\"}"
end

@testset "restricted expression closed literal, operator, and function families" begin
    expressions = [
        "+a - -b",
        "a/b % c",
        "a < b",
        "a <= b",
        "a > b",
        "a >= b",
        "a == b",
        "a != b",
        "a && b || !c",
        "abs(x)",
        "acos(x)",
        "asin(x)",
        "atan(x)",
        "atan(y,x)",
        "ceil(x)",
        "clamp(x,lower,upper)",
        "cos(x)",
        "exp(x)",
        "floor(x)",
        "ifelse(condition,a,b)",
        "log(x)",
        "log(x,base)",
        "log10(x)",
        "max(a,b,c,d)",
        "min(a,b)",
        "round(x)",
        "sin(x)",
        "sqrt(x)",
        "tan(x)",
        "true",
        "false",
        "-0.0",
        "123456789012345678901234567890",
    ]
    for text in expressions
        result = parse_restricted_expression(text)
        @test format_succeeded(result)
        @test format_succeeded(parse_restricted_expression(result.value.canonical_text))
    end

    @test parse_restricted_expression("a-b-c").value.canonical_text == "((a - b) - c)"
    @test parse_restricted_expression("a^b^c").value.canonical_text == "(a ^ (b ^ c))"
end

@testset "restricted expressions reject executable and ambiguous syntax" begin
    restricted_expression_failure("unknown(x)", :unknown_expression_function, column = 1)
    restricted_expression_failure("open(x)", :expression_capability_prohibited, column = 1)
    restricted_expression_failure("Base.open(x)", :expression_capability_prohibited, column = 1)
    restricted_expression_failure("run(command)", :expression_capability_prohibited, column = 1)
    restricted_expression_failure("eval(payload)", :expression_capability_prohibited, column = 1)
    restricted_expression_failure("NaN", :expression_host_value_prohibited, column = 1)
    restricted_expression_failure("Inf", :expression_host_value_prohibited, column = 1)
    restricted_expression_failure("nothing", :expression_host_value_prohibited, column = 1)
    restricted_expression_failure("missing", :expression_host_value_prohibited, column = 1)
    restricted_expression_failure("for", :expression_control_prohibited, column = 1)
    restricted_expression_failure("x = 1", :expression_assignment_prohibited, column = 3)
    restricted_expression_failure("x[1]", :expression_syntax_prohibited, column = 2)
    restricted_expression_failure("\"text\"", :expression_string_prohibited, column = 1)
    restricted_expression_failure("`command`", :expression_syntax_prohibited, column = 1)
    restricted_expression_failure("1 & 2", :unknown_expression_character, column = 3)
    restricted_expression_failure("1 < 2 < 3", :expression_comparison_chain_prohibited, column = 7)
    restricted_expression_failure("null", :expression_null_prohibited, column = 1)
    restricted_expression_failure("1 +", :expression_expected_operand, column = 4)
    restricted_expression_failure("sin()", :invalid_expression_function_arity, column = 1)
    restricted_expression_failure("clamp(x,0)", :invalid_expression_function_arity, column = 1)
    restricted_expression_failure("true()", :expression_trailing_syntax, column = 5)
    restricted_expression_failure("a\nb", :expression_newline_prohibited, column = 2)

    valid = parse_restricted_expression("a+b").value
    @test_throws MethodError RestrictedExpression(
        valid.source,
        valid.root,
        "run(command)",
        1,
        1,
    )
end

@testset "restricted expression resource limits are enforced before exhaustion" begin
    scalar_limited = parse_restricted_expression(
        "12345";
        policy = FormatInputPolicy(max_scalar_bytes = 4),
    )
    @test !format_succeeded(scalar_limited)
    @test only(scalar_limited.diagnostics).code == :expression_too_large

    token_limited = parse_restricted_expression(
        "1+2";
        policy = FormatInputPolicy(max_collection_items = 2),
    )
    @test !format_succeeded(token_limited)
    @test only(token_limited.diagnostics).code == :expression_token_limit

    deep_cases = [
        repeat("(", 500) * "1" * repeat(")", 500),
        repeat("-", 500) * "1",
        join(fill("1", 500), "^"),
        foldl((nested, _) -> "sin($(nested))", 1:500; init = "x"),
    ]
    depth_policy = FormatInputPolicy(
        max_nesting_depth = 16,
        max_collection_items = 10_000,
    )
    for text in deep_cases
        result = parse_restricted_expression(text; policy = depth_policy)
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == :expression_nesting_too_deep
    end

    expression = parse_restricted_expression("a+b").value
    output_limited = serialize_restricted_expression(
        expression;
        policy = FormatInputPolicy(max_document_bytes = 4, max_scalar_bytes = 4),
    )
    @test !format_succeeded(output_limited)
    @test only(output_limited.diagnostics).code == :expression_too_large
end

@testset "restricted expression parsing never evaluates capabilities" begin
    working_directory = pwd()
    loaded_modules = copy(Base.loaded_modules)
    for text in (
        "open(secret)",
        "Downloads.download(uri)",
        "run(command)",
        "ccall(target)",
        "getfield(object,field)",
    )
        @test !format_succeeded(parse_restricted_expression(text))
    end
    @test pwd() == working_directory
    @test Base.loaded_modules == loaded_modules
end

record_format_conformance!(:restricted_expressions)
