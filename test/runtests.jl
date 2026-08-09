using Test
using AIMORAFormats

@testset "open-text format package boundary" begin
    @test nameof(AIMORAFormats) === :AIMORAFormats
end

@testset "source documents and physical locations" begin
    text = "α\r\nβ\nγ\rδ"
    result = source_document(text; source_name = "model/assets.yaml")
    @test format_succeeded(result)
    document = only((result.value,))
    @test source_bytes(document) == Vector{UInt8}(codeunits(text))
    @test document.provenance.byte_count == ncodeunits(text)
    @test length(document.provenance.content_sha256) == 64
    @test source_position(document, 1) == SourcePosition(1, 1, 1)
    @test source_position(document, 3) == SourcePosition(3, 1, 2)
    @test source_position(document, 5) == SourcePosition(5, 2, 1)
    @test source_position(document, 8) == SourcePosition(8, 3, 1)
    @test source_position(document, 11) == SourcePosition(11, 4, 1)
    @test source_position(document, ncodeunits(text) + 1) == SourcePosition(13, 4, 2)
    alpha_span = source_span(document, 1, 3)
    @test source_slice(document, alpha_span) == "α"
    @test source_slice(document, source_span(document, 5, 5)) == ""
    @test_throws ArgumentError source_position(document, 2)
    @test_throws BoundsError source_position(document, 0)
    other = source_document("x"; source_name = "other.yaml").value
    @test_throws ArgumentError source_slice(other, alpha_span)

    repeated = source_document(source_bytes(document); source_name = "model/assets.yaml")
    @test repeated.value == document
    copy = source_bytes(document)
    copy[1] = 0x78
    @test source_bytes(document) != copy
end

@testset "untrusted source admission" begin
    invalid_cases = [
        (UInt8[0xc0], 1),
        (UInt8[0xe0, 0x80, 0x80], 2),
        (UInt8[0xed, 0xa0, 0x80], 2),
        (UInt8[0xf4, 0x90, 0x80, 0x80], 2),
        (UInt8[0xf0, 0x9f], 1),
        (UInt8[0x61, 0x0a, 0x80], 3),
    ]
    for (bytes, invalid_byte) in invalid_cases
        result = source_document(bytes; source_name = "bad.yaml")
        @test !format_succeeded(result)
        @test isnothing(result.value)
        diagnostic = only(result.diagnostics)
        @test diagnostic.code == :invalid_utf8
        @test diagnostic.span.start.byte == invalid_byte
    end

    policy = FormatInputPolicy(max_document_bytes = 2)
    oversized = source_document("abc"; source_name = "large.yaml", policy)
    @test !format_succeeded(oversized)
    @test only(oversized.diagnostics).code == :document_too_large
    @test_throws ArgumentError FormatInputPolicy(max_nesting_depth = 0)
    @test_throws ArgumentError source_document("x"; source_name = "")
    @test_throws ArgumentError source_document("x"; source_name = "bad\0name")
    @test_throws MethodError SourceDocument(
        DocumentProvenance("bad.yaml", repeat("0", 64), 1),
        "x",
        (1,),
    )
end

@testset "deterministic diagnostics and operation results" begin
    position = SourcePosition(1, 1, 1)
    first_span = SourceSpan("a.yaml", position, position)
    second_span = SourceSpan("b.yaml", position, position)
    diagnostics = [
        FormatDiagnostic(DiagnosticWarning, :later_warning, "later", second_span),
        FormatDiagnostic(DiagnosticError, :first_error, "first", first_span),
    ]
    ordered = sorted_diagnostics(diagnostics)
    @test getfield.(ordered, :code) == [:first_error, :later_warning]
    @test sprint(show, first_span) == "a.yaml:1:1"
    @test sprint(show, diagnostics[2]) == "error[first_error] a.yaml:1:1: first"
    successful = FormatResult{Int}(1, [diagnostics[1]])
    @test format_succeeded(successful)
    @test FormatResult(1, [diagnostics[1]]) == successful
    failed = FormatResult{Int}(nothing, [diagnostics[2]])
    @test !format_succeeded(failed)
    @test_throws ArgumentError FormatResult{Int}(nothing)
    @test_throws ArgumentError FormatDiagnostic(DiagnosticError, :BadCode, "bad", first_span)
    @test_throws ArgumentError FormatDiagnostic(DiagnosticError, :bad_code, "", first_span)
    @test_throws ArgumentError SourceSpan(
        "a.yaml",
        SourcePosition(1, 2, 1),
        SourcePosition(1, 1, 1),
    )
    @test_throws ArgumentError SourceSpan(
        "a.yaml",
        SourcePosition(1, 1, 2),
        SourcePosition(1, 1, 1),
    )
end

@testset "located format values" begin
    document = source_document("key: value"; source_name = "value.yaml").value
    key_node = FormatNode(FormatString("key"), source_span(document, 1, 4))
    value_node = FormatNode(FormatString("value"), source_span(document, 6, 11))
    entry = FormatMappingEntry(key_node, value_node)
    mapping = FormatMapping([entry])
    root = FormatNode(mapping, source_span(document, 1, 11))
    @test root == FormatNode(FormatMapping([entry]), source_span(document, 1, 11))
    @test FormatInteger(12) == FormatInteger(BigInt(12))
    @test FormatDecimal(1200, -2) == FormatDecimal(12, 0)
    @test FormatDecimal(0, 100) == FormatDecimal(0, 0)
    @test FormatBoolean(true) != FormatBoolean(false)
    @test FormatNull() == FormatNull()
    @test_throws ArgumentError FormatMappingEntry(
        FormatNode(FormatInteger(1), key_node.span),
        value_node,
    )
    @test_throws ArgumentError FormatMapping([entry, entry])
    entries = [entry]
    copied_mapping = FormatMapping(entries)
    empty!(entries)
    @test length(copied_mapping.entries) == 1
    @test_throws ArgumentError push!(copied_mapping.entries, entry)
    @test_throws ArgumentError setindex!(copied_mapping.entries, entry, 1)
    @test_throws ArgumentError copied_mapping.entries.storage
    @test copy(copied_mapping.entries) == copied_mapping.entries
    @test isempty(propertynames(copied_mapping.entries))

    parsed = ParsedFormatDocument(document, root)
    parse_result = FormatParseResult(parsed)
    @test format_succeeded(parse_result)
    serialized = SerializedFormatDocument(UInt8[0x7b, 0x7d], "application/json")
    serialization_result = FormatSerializationResult(serialized)
    @test format_succeeded(serialization_result)
    @test serialization_result.value.bytes == UInt8[0x7b, 0x7d]
    original_bytes = UInt8[0x7b, 0x7d]
    copied_bytes = SerializedFormatDocument(original_bytes, "application/json")
    original_bytes[1] = 0x5b
    @test copied_bytes.bytes == UInt8[0x7b, 0x7d]
    @test_throws ArgumentError setindex!(copied_bytes.bytes, 0x5b, 1)
    @test_throws ArgumentError SerializedFormatDocument(UInt8[], "")
end

@testset "format tree resource limits" begin
    document = source_document("abcdef"; source_name = "limits.yaml").value
    span = source_span(document, 1, 7)
    scalar = FormatNode(FormatString("abcdef"), span)
    nested = FormatNode(FormatSequence([FormatNode(FormatSequence([scalar]), span)]), span)
    diagnostics = validate_format_tree(
        nested,
        FormatInputPolicy(
            max_nesting_depth = 2,
            max_collection_items = 10,
            max_scalar_bytes = 4,
        ),
    )
    @test getfield.(diagnostics, :code) == [:nesting_too_deep]

    scalar_diagnostics = validate_format_tree(
        scalar,
        FormatInputPolicy(max_scalar_bytes = 4),
    )
    @test getfield.(scalar_diagnostics, :code) == [:scalar_too_large]

    sequence = FormatNode(FormatSequence(fill(scalar, 3)), span)
    collection_diagnostics = validate_format_tree(
        sequence,
        FormatInputPolicy(max_collection_items = 2),
    )
    @test getfield.(collection_diagnostics, :code) == [:collection_too_large]
    one_entry_mapping = FormatNode(FormatMapping([
        FormatMappingEntry(
            FormatNode(FormatString("key"), span),
            scalar,
        ),
    ]), span)
    @test isempty(validate_format_tree(
        one_entry_mapping,
        FormatInputPolicy(max_collection_items = 1),
    ))
    @test isempty(validate_format_tree(scalar))
end
