using Test
using AIMORAFormats
using SHA
using UUIDs

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
        sort!(
            [
            (entry.key.value.value, semantic_format_value(entry.value))
            for entry in value.entries
            ];
            by = first,
        ),
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

@testset "exact source-located JSON grammar" begin
    text = """{
  "project": {"id": "grid.α", "enabled": true},
  "values": [null, false, 0, -0, 123456789012345678901234567890, 1.20e2],
  "music": "\\uD834\\uDD1E"
}
"""
    parsed = parse_json(text; source_name = "project.json")
    @test format_succeeded(parsed)
    @test isempty(parsed.diagnostics)
    document = parsed.value
    @test document.root.span.start == SourcePosition(1, 1, 1)
    @test document.root.span.stop == SourcePosition(ncodeunits(text), 5, 2)
    project = mapping_entry(document.root, "project").value
    @test mapping_entry(project, "id").value.value == FormatString("grid.α")
    @test mapping_entry(project, "enabled").value.value == FormatBoolean(true)
    values = mapping_entry(document.root, "values").value.value.elements
    @test values[1].value == FormatNull()
    @test values[2].value == FormatBoolean(false)
    @test values[3].value == FormatInteger(0)
    @test values[4].value == FormatDecimal(0, 0; negative_zero = true)
    @test values[5].value ==
          FormatInteger(parse(BigInt, "123456789012345678901234567890"))
    @test values[6].value == FormatDecimal(12, 1)
    @test mapping_entry(document.root, "music").value.value == FormatString("𝄞")

    bytes = Vector{UInt8}(codeunits(text))
    @test parse_json(bytes; source_name = "project.json") == parsed
    source = source_document(bytes; source_name = "project.json").value
    @test parse_json(source) == parsed
end

@testset "canonical JSON normalization and content identity" begin
    first_json = """{
      "z": [1, -0, 1.20e2, "line\\nfeed"],
      "a": {"Ω": true, "control": "\\u0001", "slash": "\\/"}
    }"""
    second_json =
        "{\"a\":{\"slash\":\"/\",\"control\":\"\\u0001\",\"Ω\":true}," *
        "\"z\":[1,-0.0,12e1,\"line\\nfeed\"]}"
    yaml = """# syntax and order do not own canonical identity
a:
  slash: /
  control: "\\u0001"
  Ω: true
z: [1, -0, 120.0, "line\\nfeed"]
"""
    first = parse_json(first_json; source_name = "first.json")
    second = parse_json(second_json; source_name = "second.json")
    authoring = parse_restricted_yaml(yaml; source_name = "project.aimora.yaml")
    @test format_succeeded(first)
    @test format_succeeded(second)
    @test format_succeeded(authoring)

    first_canonical = serialize_canonical_json(first.value)
    second_canonical = serialize_canonical_json(second.value.root)
    yaml_canonical = serialize_canonical_json(authoring.value)
    @test format_succeeded(first_canonical)
    @test first_canonical == second_canonical == yaml_canonical
    @test first_canonical.value.media_type == "application/json"
    canonical_text = String(collect(first_canonical.value.bytes))
    @test canonical_text ==
          "{\"a\":{\"control\":\"\\u0001\",\"slash\":\"/\",\"Ω\":true}," *
          "\"z\":[1,-0e0,12e1,\"line\\nfeed\"]}"
    reparsed = parse_json(collect(first_canonical.value.bytes))
    @test format_succeeded(reparsed)
    @test semantic_format_value(reparsed.value.root) ==
          semantic_format_value(first.value.root)

    first_hash = canonical_json_sha256(first.value)
    second_hash = canonical_json_sha256(second.value.root)
    yaml_hash = canonical_json_sha256(authoring.value)
    @test format_succeeded(first_hash)
    @test first_hash == second_hash == yaml_hash
    @test occursin(r"^[0-9a-f]{64}$", first_hash.value)
    @test bytes2hex(SHA.sha256(collect(first_canonical.value.bytes))) == first_hash.value

    changed_value = parse_json("{\"a\": 2}")
    original_value = parse_json("{\"a\": 1}")
    reordered_array = parse_json("[2, 1]")
    original_array = parse_json("[1, 2]")
    @test canonical_json_sha256(changed_value.value).value !=
          canonical_json_sha256(original_value.value).value
    @test canonical_json_sha256(reordered_array.value).value !=
          canonical_json_sha256(original_array.value).value
    @test canonical_json_sha256(parse_json("0").value).value !=
          canonical_json_sha256(parse_json("0.0").value).value
    @test canonical_json_sha256(parse_json("0.0").value).value !=
          canonical_json_sha256(parse_json("-0.0").value).value
end

@testset "canonical JSON Unicode order and fresh-process stability" begin
    parsed = parse_json("{\"😀\":4,\"Ω\":3,\"a\":2,\"Z\":1}")
    canonical = serialize_canonical_json(parsed.value)
    @test String(collect(canonical.value.bytes)) ==
          "{\"Z\":1,\"a\":2,\"Ω\":3,\"😀\":4}"

    package_root = pkgdir(AIMORAFormats)
    child_script = """
    using AIMORAFormats
    parsed = parse_json("{\\\"z\\\":2,\\\"a\\\":[-0,1.0]}")
    canonical = serialize_canonical_json(parsed.value)
    print(String(collect(canonical.value.bytes)))
    """
    child_command = `$(Base.julia_cmd()) --startup-file=no`
    child_command = `$child_command --project=$(package_root) -e $(child_script)`
    @test read(child_command, String) == read(child_command, String) ==
          "{\"a\":[-0e0,1e0],\"z\":2}"
end

@testset "JSON adversarial diagnostics" begin
    failures = [
        ("", :missing_json_value, 1, 1),
        ("{\"a\":1,\"a\":2}", :duplicate_json_key, 1, 8),
        ("{\"a\":1,\"\\u0061\":2}", :duplicate_json_key, 1, 8),
        ("{a:1}", :json_key_must_be_string, 1, 2),
        ("{\"a\" 1}", :missing_json_colon, 1, 6),
        ("[1,]", :json_trailing_comma, 1, 4),
        ("{\"a\":1,}", :json_trailing_comma, 1, 8),
        ("{\"a\": // comment\n1}", :json_comment_prohibited, 1, 7),
        ("NaN", :invalid_json_token, 1, 1),
        ("True", :invalid_json_token, 1, 1),
        ("+1", :invalid_json_token, 1, 1),
        ("01", :invalid_json_number, 1, 1),
        ("1.", :invalid_json_number, 1, 1),
        ("1e", :invalid_json_number, 1, 1),
        ("truex", :invalid_json_literal, 1, 5),
        ("true false", :trailing_json_content, 1, 6),
        ("\"\\x\"", :invalid_json_escape, 1, 2),
        ("\"\\uD800\"", :invalid_json_unicode, 1, 2),
        ("\"\\uDC00\"", :invalid_json_unicode, 1, 2),
        ("\"a\nb\"", :invalid_json_control_character, 1, 3),
        ("[1 2]", :missing_json_separator, 1, 4),
        ("{\"a\":1 \"b\":2}", :missing_json_separator, 1, 8),
    ]
    for (text, code, line, column) in failures
        result = parse_json(text; source_name = "bad.json")
        @test !format_succeeded(result)
        @test isnothing(result.value)
        diagnostic = only(result.diagnostics)
        @test diagnostic.code == code
        @test diagnostic.span.source_name == "bad.json"
        @test diagnostic.span.start.line == line
        @test diagnostic.span.start.column == column
    end

    bom = parse_json(UInt8[0xef, 0xbb, 0xbf, 0x6e, 0x75, 0x6c, 0x6c])
    @test !format_succeeded(bom)
    @test only(bom.diagnostics).code == :json_byte_order_mark_prohibited
    invalid_utf8 = parse_json(UInt8[0x22, 0x80, 0x22])
    @test !format_succeeded(invalid_utf8)
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
end

@testset "JSON and canonicalization resource limits" begin
    oversized = parse_json(
        "{\"a\":1}";
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test !format_succeeded(oversized)
    @test only(oversized.diagnostics).code == :document_too_large

    scalar = parse_json(
        "\"abcdef\"";
        policy = FormatInputPolicy(max_scalar_bytes = 4),
    )
    @test !format_succeeded(scalar)
    @test only(scalar.diagnostics).code == :scalar_too_large

    collection = parse_json(
        "{\"a\":[1,2,3]}";
        policy = FormatInputPolicy(max_collection_items = 3),
    )
    @test !format_succeeded(collection)
    @test only(collection.diagnostics).code == :collection_too_large

    depth = parse_json(
        "[[[1]]]";
        policy = FormatInputPolicy(max_nesting_depth = 3),
    )
    @test !format_succeeded(depth)
    @test only(depth.diagnostics).code == :nesting_too_deep

    parsed = parse_json("{\"a\":1}")
    limited = serialize_canonical_json(
        parsed.value;
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test !format_succeeded(limited)
    @test only(limited.diagnostics).code == :document_too_large
    limited_hash = canonical_json_sha256(
        parsed.value;
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test !format_succeeded(limited_hash)
    @test only(limited_hash.diagnostics).code == :document_too_large

    invalid_string = String(UInt8[0xff])
    span = parsed.value.root.span
    invalid_node = FormatNode(FormatString(invalid_string), span)
    invalid_serialization = serialize_canonical_json(invalid_node)
    @test !format_succeeded(invalid_serialization)
    @test only(invalid_serialization.diagnostics).code == :invalid_unicode_value
end

function test_lock_entry_section(
    id::String;
    family::String = "schema",
    uuid::Union{Nothing,String} = nothing,
    trust::String = "data_only",
    permissions::Vector{String} = String[],
    entrypoint::Union{Nothing,String} = nothing,
    environment::Union{Nothing,String} = nothing,
    revision::String = repeat("a", 40),
    sha256::String = repeat("b", 64),
    compatibility::String = ">=1.0.0,<2.0.0",
    source::String = "https://registry.aimora.dev/$(family)/$(id)",
)
    permission_text = join(("\"$(permission)\"" for permission in permissions), ", ")
    optional = isnothing(uuid) ? "" : "uuid = \"$(uuid)\"\n"
    optional *= isnothing(entrypoint) ? "" : "entrypoint = \"$(entrypoint)\"\n"
    optional *= isnothing(environment) ? "" : "environment = \"$(environment)\"\n"
    filesystem = family in ("plugin", "automation") ? "project_only" : "none"
    timeout = family in ("plugin", "automation") ? 300 : 0
    memory = family in ("plugin", "automation") ? 1024 : 0
    return """[[entry]]
id = "$(id)"
$(optional)version = "1.2.3"
revision = "$(revision)"
sha256 = "$(sha256)"
licence = "MIT"
compatibility = "$(compatibility)"
source = "$(source)"
trust = "$(trust)"
permissions = [$(permission_text)]
provenance = "test registry"

[entry.resources]
network = false
processes = false
filesystem = "$(filesystem)"
timeout_seconds = $(timeout)
memory_megabytes = $(memory)
"""
end

function test_lock_text(family::String, sections::String)
    return """format = "aimora-lock-v1"
family = "$(family)"
version = "1.0.0"

$(sections)"""
end

@testset "typed format-lock families" begin
    family_cases = [
        (
            "schema",
            LockSchema,
            test_lock_entry_section("schema.project"; family = "schema"),
        ),
        (
            "catalog",
            LockCatalog,
            test_lock_entry_section("catalog.generic"; family = "catalog"),
        ),
        (
            "import",
            LockImport,
            test_lock_entry_section("import.current"; family = "import"),
        ),
        (
            "plugin",
            LockPlugin,
            test_lock_entry_section(
                "plugin.wind";
                family = "plugin",
                uuid = "12345678-1234-1234-1234-123456789abc",
                trust = "trusted_plugin",
                permissions = ["project.read", "result.write"],
                entrypoint = "AIMORAWind:register!",
                environment = "plugins/wind",
            ),
        ),
        (
            "automation",
            LockAutomation,
            test_lock_entry_section(
                "automation.review";
                family = "automation",
                uuid = "87654321-4321-4321-4321-cba987654321",
                trust = "isolated_untrusted_script",
                permissions = ["project.read", "study.run"],
                entrypoint = "ProjectAutomation:run_review",
                environment = "automation",
            ),
        ),
    ]
    for (family_name, family, section) in family_cases
        text = test_lock_text(family_name, section)
        parsed = parse_format_lock(text; source_name = "$(family_name)-lock.toml")
        @test format_succeeded(parsed)
        @test isempty(parsed.diagnostics)
        @test parsed.value.lock.family == family
        @test parsed.value.lock.format_version == v"1.0.0"
        @test length(parsed.value.lock.entries) == 1
        @test parsed.value.lock.entries[1].family == family
        @test parsed.value.source.provenance.source_name == "$(family_name)-lock.toml"
        serialized = serialize_format_lock(parsed.value)
        @test format_succeeded(serialized)
        @test serialized.value.media_type == "application/toml"
        reparsed = parse_format_lock(collect(serialized.value.bytes))
        @test format_succeeded(reparsed)
        @test reparsed.value.lock == parsed.value.lock
    end

    plugin = parse_format_lock(test_lock_text("plugin", family_cases[4][3])).value.lock
    entry = only(plugin.entries)
    @test entry.uuid == UUID("12345678-1234-1234-1234-123456789abc")
    @test entry.permissions == ["project.read", "result.write"]
    @test entry.entrypoint == "AIMORAWind:register!"
    @test entry.environment == "plugins/wind"
    @test entry.resources == LockResourcePolicy(
        filesystem = LockFilesystemProjectOnly,
        timeout_seconds = 300,
        memory_megabytes = 1024,
    )
end

@testset "deterministic lock construction and serialization" begin
    function schema_entry(id, revision_character, hash_character)
        return FormatLockEntry(
            LockSchema,
            id,
            v"1.0.0",
            repeat(revision_character, 40),
            repeat(hash_character, 64),
            "MIT",
            ">=1.0.0,<2.0.0",
            "https://schema.aimora.dev/$(id)",
            LockDataOnly;
            provenance = "test schema registry",
        )
    end
    later = schema_entry("schema.z", "a", "b")
    earlier = schema_entry("schema.a", "c", "d")
    lock = FormatLockDocument(LockSchema, [later, earlier])
    @test getfield.(lock.entries, :id) == ["schema.a", "schema.z"]
    first = serialize_format_lock(lock)
    second = serialize_format_lock(lock)
    @test first == second
    text = String(collect(first.value.bytes))
    @test findfirst("schema.a", text) < findfirst("schema.z", text)
    @test !occursin(r"(?:^|[= ])(?:/|~|[A-Za-z]:\\)", text)
    @test parse_format_lock(collect(first.value.bytes)).value.lock == lock

    @test_throws ArgumentError FormatLockDocument(LockSchema, [earlier, earlier])
    @test_throws ArgumentError FormatLockEntry(
        LockSchema,
        "schema.bad",
        v"1.0.0",
        repeat("a", 40),
        repeat("b", 64),
        "MIT",
        "*",
        "https://schema.aimora.dev/bad",
        LockDataOnly;
        provenance = "test",
    )
    @test_throws ArgumentError FormatLockEntry(
        LockSchema,
        "schema.bad",
        v"1.0.0",
        repeat("a", 40),
        repeat("b", 64),
        "MIT",
        ">=1.0.0,<2.0.0",
        "/home/user/schema",
        LockDataOnly;
        provenance = "test",
    )
    @test_throws ArgumentError LockResourcePolicy(timeout_seconds = -1)
end

@testset "format-lock exact diagnostics" begin
    valid_section = test_lock_entry_section("schema.project"; family = "schema")
    valid = test_lock_text("schema", valid_section)
    bad_hash = replace(valid, repeat("b", 64) => "BAD")
    bad_hash_result = parse_format_lock(bad_hash; source_name = "bad-lock.toml")
    @test !format_succeeded(bad_hash_result)
    @test only(bad_hash_result.diagnostics).code == :invalid_lock_entry
    @test only(bad_hash_result.diagnostics).span.start.line == 9
    @test only(bad_hash_result.diagnostics).span.start.column == 1

    cases = [
        (
            replace(valid, "format = \"aimora-lock-v1\"" => "format = \"aimora-lock-v2\""),
            :unknown_lock_format,
        ),
        (
            replace(
                valid,
                "version = \"1.0.0\"" => "version = \"2.0.0\"";
                count = 1,
            ),
            :unknown_lock_version,
        ),
        (replace(valid, "family = \"schema\"" => "family = \"unknown\""), :unknown_lock_family),
        (
            replace(
                valid,
                "compatibility = \">=1.0.0,<2.0.0\"" =>
                    "compatibility = \"latest\"",
            ),
            :invalid_lock_entry,
        ),
        (
            replace(
                valid,
                "source = \"https://registry.aimora.dev/schema/schema.project\"" =>
                    "source = \"https://user:secret@example.com/repo\"",
            ),
            :invalid_lock_entry,
        ),
        (
            replace(
                valid,
                "trust = \"data_only\"" => "trust = \"trusted_plugin\"",
            ),
            :invalid_lock_entry,
        ),
        (replace(valid, "sha256 = \"$(repeat("b", 64))\"\n" => ""), :missing_lock_field),
        (
            replace(
                valid,
                "version = \"1.0.0\"\n\n" =>
                    "version = \"1.0.0\"\nmystery = 1\n\n";
                count = 1,
            ),
            :unknown_lock_field,
        ),
        ("format = \"aimora-lock-v1\"\nformat = \"aimora-lock-v1\"\n", :invalid_lock_toml),
    ]
    for (text, code) in cases
        result = parse_format_lock(text; source_name = "bad-lock.toml")
        @test !format_succeeded(result)
        @test isnothing(result.value)
        @test any(diagnostic -> diagnostic.code == code, result.diagnostics)
        @test all(diagnostic -> !isnothing(diagnostic.span), result.diagnostics)
    end

    duplicate = test_lock_text("schema", valid_section * "\n" * valid_section)
    duplicate_result = parse_format_lock(duplicate; source_name = "duplicate-lock.toml")
    @test !format_succeeded(duplicate_result)
    @test only(duplicate_result.diagnostics).code == :duplicate_lock_id
    @test only(duplicate_result.diagnostics).span.start.line > 20

    plugin = test_lock_text(
        "plugin",
        test_lock_entry_section(
            "plugin.bad";
            family = "plugin",
            uuid = "12345678-1234-1234-1234-123456789abc",
            trust = "trusted_plugin",
            permissions = ["project.read"],
            entrypoint = "Plugin:register!",
            environment = "../outside",
        ),
    )
    plugin_result = parse_format_lock(plugin; source_name = "plugin-lock.toml")
    @test !format_succeeded(plugin_result)
    @test only(plugin_result.diagnostics).span.start.line == 9

    oversized = parse_format_lock(
        valid;
        policy = FormatInputPolicy(max_document_bytes = 10),
    )
    @test !format_succeeded(oversized)
    @test only(oversized.diagnostics).code == :document_too_large
    scalar_limited = parse_format_lock(
        valid;
        policy = FormatInputPolicy(max_scalar_bytes = 8),
    )
    @test !format_succeeded(scalar_limited)
    @test only(scalar_limited.diagnostics).code == :scalar_too_large
    collection_limited = parse_format_lock(
        valid;
        policy = FormatInputPolicy(max_collection_items = 4),
    )
    @test !format_succeeded(collection_limited)
    @test only(collection_limited.diagnostics).code == :collection_too_large
    limited = serialize_format_lock(
        parse_format_lock(valid).value;
        policy = FormatInputPolicy(max_document_bytes = 10),
    )
    @test !format_succeeded(limited)
    @test only(limited.diagnostics).code == :document_too_large
end

@testset "inert Julia environment inspection" begin
    project = """name = "DemoAutomation"
uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
version = "1.0.0"

[deps]
Example = "12345678-1234-1234-1234-123456789abc"

[automation]
source = "run(`never execute`)"
"""
    manifest = """julia_version = "1.10.11"
manifest_format = "2.0"
project_hash = "$(repeat("f", 40))"

[[deps.Example]]
uuid = "12345678-1234-1234-1234-123456789abc"
version = "1.2.3"
git-tree-sha1 = "$(repeat("a", 40))"
"""
    inspected = inspect_julia_environment(project, manifest)
    @test format_succeeded(inspected)
    fingerprint = inspected.value
    @test fingerprint.project_uuid == UUID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
    @test fingerprint.project_version == v"1.0.0"
    @test fingerprint.julia_version == v"1.10.11"
    @test fingerprint.manifest_format == "2.0"
    @test occursin(r"^[0-9a-f]{64}$", fingerprint.project_sha256)
    @test occursin(r"^[0-9a-f]{64}$", fingerprint.manifest_sha256)
    dependency = only(fingerprint.dependencies)
    @test dependency.name == "Example"
    @test dependency.version == v"1.2.3"
    @test dependency.git_tree_sha1 == repeat("a", 40)

    project_source = source_document(project; source_name = "automation/Project.toml").value
    manifest_source = source_document(manifest; source_name = "automation/Manifest.toml").value
    @test inspect_julia_environment(project_source, manifest_source).value == fingerprint
    @test inspect_julia_environment(project).value.manifest_sha256 === nothing
    changed = inspect_julia_environment(project, replace(manifest, "1.2.3" => "1.2.4"))
    @test changed.value.manifest_sha256 != fingerprint.manifest_sha256

    local_manifest = replace(
        manifest,
        "git-tree-sha1 = \"$(repeat("a", 40))\"" => "path = \"/tmp/Example\"",
    )
    local_result = inspect_julia_environment(project, local_manifest)
    @test !format_succeeded(local_result)
    @test any(
        diagnostic -> diagnostic.code == :local_julia_dependency_prohibited,
        local_result.diagnostics,
    )
    floating_manifest = replace(
        manifest,
        "git-tree-sha1 = \"$(repeat("a", 40))\"" =>
            "repo-url = \"https://example.com/Example.jl\"\nrepo-rev = \"main\"",
    )
    floating_result = inspect_julia_environment(project, floating_manifest)
    @test !format_succeeded(floating_result)
    @test any(
        diagnostic -> diagnostic.code == :floating_julia_dependency,
        floating_result.diagnostics,
    )
    missing_result = inspect_julia_environment(project, replace(manifest, "Example" => "Other"))
    @test !format_succeeded(missing_result)
    @test any(
        diagnostic -> diagnostic.code == :julia_manifest_dependency_missing,
        missing_result.diagnostics,
    )
    malformed = inspect_julia_environment("name = [\n")
    @test !format_succeeded(malformed)
    @test only(malformed.diagnostics).code == :invalid_julia_project_toml
    limited = inspect_julia_environment(
        project,
        manifest;
        policy = FormatInputPolicy(max_scalar_bytes = 8),
    )
    @test !format_succeeded(limited)
    @test only(limited.diagnostics).code == :scalar_too_large
end

include("bulk_tables.jl")
include("structural_schemas.jl")
include("migrations.jl")
include("inert_envelopes.jl")
include("restricted_expressions.jl")
