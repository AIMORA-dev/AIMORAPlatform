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
    @test FormatDecimal(0, 0; negative_zero = true) != FormatDecimal(0, 0)
    @test_throws ArgumentError FormatDecimal(1, 0; negative_zero = true)
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

function semantic_format_value(node::FormatNode)
    value = node.value
    value isa FormatNull && return (:null,)
    value isa FormatBoolean && return (:boolean, value.value)
    value isa FormatInteger && return (:integer, value.value)
    value isa FormatDecimal &&
        return (:decimal, value.coefficient, value.exponent, value.negative_zero)
    value isa FormatString && return (:string, value.value)
    value isa FormatSequence &&
        return (:sequence, map(semantic_format_value, collect(value.elements)))
    value isa FormatMapping && return (
        :mapping,
        [
            (entry.key.value.value, semantic_format_value(entry.value))
            for entry in value.entries
        ],
    )
    error("unknown test format value")
end

function mapping_entry(node::FormatNode, key::String)
    node.value isa FormatMapping || error("test node is not a mapping")
    return only(entry for entry in node.value.entries if entry.key.value.value == key)
end

@testset "restricted YAML compact authoring grammar" begin
    text = """# inert compact AIMORA case
format:
  name: aimora-case
  version: 1.0e+0
project:
  id: source-load-demo
  title: 'Source #1''s load'
  note: "quoted # text"
nodes:
  - id: node.ac
    conductors: [A, B, C, N]
    nominal_voltage: {value: 230.0, unit: V}
  - id: node.earth
    conductors:
      - PE
      - N
enabled: true
optional: null
count: 12
negative_zero: -0.0
uri: asset:line.L1#/terminals/from # retained as inert text
unicode: Δίκτυο
"""
    parsed = parse_restricted_yaml(text; source_name = "source-load.aimora.yaml")
    @test format_succeeded(parsed)
    @test isempty(parsed.diagnostics)
    document = parsed.value
    @test document.source.provenance.source_name == "source-load.aimora.yaml"
    @test document.root.span.start == SourcePosition(29, 2, 1)

    format = mapping_entry(document.root, "format").value
    @test mapping_entry(format, "name").value.value == FormatString("aimora-case")
    @test mapping_entry(format, "version").value.value == FormatDecimal(1, 0)
    project = mapping_entry(document.root, "project").value
    @test mapping_entry(project, "title").value.value == FormatString("Source #1's load")
    @test mapping_entry(project, "note").value.value == FormatString("quoted # text")
    nodes = mapping_entry(document.root, "nodes").value
    @test nodes.value isa FormatSequence
    @test length(nodes.value.elements) == 2
    first_node = nodes.value.elements[1]
    @test mapping_entry(first_node, "conductors").value.value isa FormatSequence
    quantity = mapping_entry(first_node, "nominal_voltage").value
    @test mapping_entry(quantity, "value").value.value == FormatDecimal(23, 1)
    @test mapping_entry(document.root, "enabled").value.value == FormatBoolean(true)
    @test mapping_entry(document.root, "optional").value.value == FormatNull()
    @test mapping_entry(document.root, "count").value.value == FormatInteger(12)
    @test mapping_entry(document.root, "negative_zero").value.value ==
          FormatDecimal(0, 0; negative_zero = true)
    @test mapping_entry(document.root, "uri").value.value ==
          FormatString("asset:line.L1#/terminals/from")
    @test mapping_entry(document.root, "unicode").value.value == FormatString("Δίκτυο")

    bytes_parsed = parse_restricted_yaml(
        Vector{UInt8}(codeunits(text));
        source_name = "source-load.aimora.yaml",
    )
    @test bytes_parsed == parsed
    source = source_document(text; source_name = "source-load.aimora.yaml").value
    @test parse_restricted_yaml(source) == parsed
end

@testset "restricted YAML inert reserved mappings" begin
    text = """reference: {\$ref: asset:line.L1#/terminals/from}
artifact:
  \$artifact:
    path: data/profiles.parquet
    sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
extends: {catalog: generic.line, version: 2.0.0}
patches:
  - op: set
    target: asset:line.L1
    path: common.in_service
    value: false
expression: {\$expr: gain * error}
"""
    parsed = parse_restricted_yaml(text; source_name = "inert.aimora.yaml")
    @test format_succeeded(parsed)
    root = parsed.value.root
    @test mapping_entry(mapping_entry(root, "reference").value, "\$ref").value.value ==
          FormatString("asset:line.L1#/terminals/from")
    @test mapping_entry(mapping_entry(root, "artifact").value, "\$artifact").value.value isa
          FormatMapping
    @test mapping_entry(mapping_entry(root, "expression").value, "\$expr").value.value ==
          FormatString("gain * error")
end

@testset "deterministic restricted YAML emission" begin
    source = """z: [null, false, -0, 1200e-2]
a: {quote: "a\\nb", unicode: Ω, empty: ""}
"""
    parsed = parse_restricted_yaml(source; source_name = "emit.yaml")
    @test format_succeeded(parsed)
    first = serialize_restricted_yaml(parsed.value)
    second = serialize_restricted_yaml(parsed.value.root)
    @test format_succeeded(first)
    @test first == second
    @test first.value.media_type == "application/yaml"
    emitted = String(collect(first.value.bytes))
    @test emitted ==
          "{\"z\":[null,false,-0.0,12e+0]," *
          "\"a\":{\"quote\":\"a\\nb\",\"unicode\":\"Ω\",\"empty\":\"\"}}\n"
    reparsed = parse_restricted_yaml(collect(first.value.bytes); source_name = "emitted.yaml")
    @test format_succeeded(reparsed)
    @test semantic_format_value(reparsed.value.root) ==
          semantic_format_value(parsed.value.root)

    escaped = parse_restricted_yaml("s: \"\\u03a9 \\uD834\\uDD1E \\x41\"\n")
    @test format_succeeded(escaped)
    @test mapping_entry(escaped.value.root, "s").value.value == FormatString("Ω 𝄞 A")
    empty = parse_restricted_yaml("# comment only\n")
    @test format_succeeded(empty)
    @test empty.value.root.value == FormatNull()
end

@testset "restricted YAML semantic round-trip corpus" begin
    corpus = [
        "value: null\n",
        "value: true\n",
        "value: false\n",
        "value: 0\n",
        "value: -92233720368547758081234567890\n",
        "value: 6.022e23\n",
        "value: -0e999\n",
        "value: plain-text\n",
        "value: 'single '' quote'\n",
        "value: \"double \\\" slash \\\\ tab \\t\"\n",
        "value: []\n",
        "value: {}\n",
        "value: [1, [2, 3], {a: false}]\n",
        "value:\n  nested:\n    - first\n    - second\n",
    ]
    for (index, text) in enumerate(corpus)
        parsed = parse_restricted_yaml(text; source_name = "roundtrip-$(index).yaml")
        @test format_succeeded(parsed)
        emitted = serialize_restricted_yaml(parsed.value)
        @test format_succeeded(emitted)
        reparsed = parse_restricted_yaml(
            collect(emitted.value.bytes);
            source_name = "roundtrip-$(index)-emitted.yaml",
        )
        @test format_succeeded(reparsed)
        @test semantic_format_value(reparsed.value.root) ==
              semantic_format_value(parsed.value.root)
    end

    package_root = pkgdir(AIMORAFormats)
    child_script = """
    using AIMORAFormats
    parsed = parse_restricted_yaml("b: [2, 3]\\na: {x: true}\\n")
    emitted = serialize_restricted_yaml(parsed.value)
    write(stdout, collect(emitted.value.bytes))
    """
    child_command = `$(Base.julia_cmd()) --startup-file=no`
    child_command = `$child_command --project=$(package_root) -e $(child_script)`
    @test read(child_command, String) == read(child_command, String)
end

@testset "restricted YAML exact source diagnostics" begin
    failures = [
        ("a: 1\na: 2\n", :duplicate_mapping_key, 2, 1),
        ("a: !julia value\n", :yaml_tag_prohibited, 1, 4),
        ("a: &base value\n", :yaml_anchor_prohibited, 1, 4),
        ("a: *base\n", :yaml_alias_prohibited, 1, 4),
        ("<<: {a: 1}\n", :yaml_merge_key_prohibited, 1, 1),
        ("a: yes\n", :implicit_scalar_prohibited, 1, 4),
        ("a: True\n", :implicit_scalar_prohibited, 1, 4),
        ("a: 2026-08-09\n", :implicit_date_prohibited, 1, 4),
        ("a: .nan\n", :nonfinite_number_prohibited, 1, 4),
        ("a: 01\n", :ambiguous_number_prohibited, 1, 4),
        ("a: 0x10\n", :ambiguous_number_prohibited, 1, 4),
        ("a: |\n  text\n", :block_scalar_prohibited, 1, 4),
        ("%YAML 1.2\na: 1\n", :yaml_directive_prohibited, 1, 1),
        ("---\na: 1\n", :multiple_documents_prohibited, 1, 1),
        ("a:\n\tb: 1\n", :tab_indentation, 2, 1),
        ("a: [1,]\n", :trailing_flow_separator, 1, 7),
        ("a: {b: 1,}\n", :trailing_flow_separator, 1, 10),
        ("a: \"unterminated\n", :unterminated_string, 1, 4),
        ("a: \"\\q\"\n", :invalid_string_escape, 1, 5),
        ("a: {b: 1, b: 2}\n", :duplicate_mapping_key, 1, 11),
        ("  a: 1\n", :top_level_indentation, 1, 3),
        ("α: yes\n", :implicit_scalar_prohibited, 1, 4),
    ]
    for (text, code, line, column) in failures
        result = parse_restricted_yaml(text; source_name = "bad.yaml")
        @test !format_succeeded(result)
        @test isnothing(result.value)
        diagnostic = only(result.diagnostics)
        @test diagnostic.code == code
        @test diagnostic.span.source_name == "bad.yaml"
        @test diagnostic.span.start.line == line
        @test diagnostic.span.start.column == column
    end

    bom = parse_restricted_yaml(UInt8[0xef, 0xbb, 0xbf, 0x61, 0x3a, 0x20, 0x31])
    @test !format_succeeded(bom)
    @test only(bom.diagnostics).code == :byte_order_mark_prohibited
    invalid_utf8 = parse_restricted_yaml(UInt8[0x61, 0x3a, 0x20, 0x80])
    @test !format_succeeded(invalid_utf8)
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
end

@testset "restricted YAML resource limits" begin
    oversized = parse_restricted_yaml(
        "a: 12345\n";
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test !format_succeeded(oversized)
    @test only(oversized.diagnostics).code == :document_too_large

    scalar = parse_restricted_yaml(
        "a: abcdef\n";
        policy = FormatInputPolicy(max_scalar_bytes = 4),
    )
    @test !format_succeeded(scalar)
    @test only(scalar.diagnostics).code == :scalar_too_large

    collection = parse_restricted_yaml(
        "a: [1, 2, 3]\n";
        policy = FormatInputPolicy(max_collection_items = 3),
    )
    @test !format_succeeded(collection)
    @test only(collection.diagnostics).code == :collection_too_large

    depth = parse_restricted_yaml(
        "a: [[[1]]]\n";
        policy = FormatInputPolicy(max_nesting_depth = 3),
    )
    @test !format_succeeded(depth)
    @test only(depth.diagnostics).code == :nesting_too_deep

    valid = parse_restricted_yaml("a: [1, 2]\n")
    limited_emission = serialize_restricted_yaml(
        valid.value;
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test !format_succeeded(limited_emission)
    @test only(limited_emission.diagnostics).code == :document_too_large
end
