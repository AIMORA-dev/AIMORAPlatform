const STRUCTURAL_DIALECT = "https://json-schema.org/draft/2020-12/schema"

function project_structural_schema_text()
    return """{
  "\$schema": "$(STRUCTURAL_DIALECT)",
  "\$id": "https://schema.aimora.dev/demo/1.0",
  "title": "Demo project structure",
  "description": "Structural fields only",
  "type": "object",
  "properties": {
    "kind": {"enum": ["compact", "package"]},
    "count": {"type": "integer", "minimum": 0, "maximum": 10},
    "ratio": {"type": "number", "exclusiveMinimum": 0e0},
    "name": {"type": "string", "minLength": 1, "maxLength": 5},
    "tags": {
      "type": "array",
      "items": {"type": "string"},
      "minItems": 1,
      "maxItems": 3,
      "uniqueItems": true
    },
    "tuple": {
      "type": "array",
      "prefixItems": [{"type": "string"}, {"type": "integer"}],
      "items": false
    },
    "settings": {"\$ref": "#/\$defs/settings"},
    "optional": {
      "type": ["null", "string"],
      "default": null,
      "examples": [null, "value"]
    },
    "choice": {"oneOf": [{"const": "a"}, {"const": "b"}]},
    "guard": {"anyOf": [{"type": "boolean"}, {"type": "null"}]},
    "positive": {"allOf": [{"type": "integer"}, {"minimum": 1}]},
    "not_bad": {"not": {"const": "bad"}}
  },
  "required": ["kind", "count", "name", "tags", "tuple", "choice", "guard", "positive", "not_bad"],
  "dependentRequired": {"ratio": ["count"]},
  "additionalProperties": false,
  "if": {"properties": {"kind": {"const": "package"}}},
  "then": {"required": ["settings"]},
  "else": true,
  "\$defs": {
    "settings": {
      "type": "object",
      "properties": {"enabled": {"type": "boolean"}},
      "required": ["enabled"],
      "additionalProperties": false
    }
  }
}"""
end

function compiled_project_structural_schema()
    identity = StructuralSchemaIdentity(
        "schema.demo",
        v"1.0.0";
        uri = "https://schema.aimora.dev/demo/1.0",
    )
    return compile_structural_schema(
        project_structural_schema_text(),
        identity;
        source_name = "demo.schema.json",
    ).value
end

function valid_structural_project_text(; order_variant::Bool = false)
    if order_variant
        return """{"tuple":["x",2],"tags":["north","south"],"positive":1,"not_bad":"ok","name":"Grid","kind":"package","guard":null,"count":2,"choice":"a","settings":{"enabled":true}}"""
    end
    return """{
  "kind": "package",
  "count": 2,
  "name": "Grid",
  "tags": ["north", "south"],
  "tuple": ["x", 2],
  "settings": {"enabled": true},
  "choice": "a",
  "guard": null,
  "positive": 1,
  "not_bad": "ok"
}"""
end

function _structural_test_entry(node::FormatNode, key::String)
    node.value isa FormatMapping || return nothing
    return findfirst(entry -> entry.key.value.value == key, node.value.entries)
end

@testset "typed structural schema identity and version policy" begin
    identity = StructuralSchemaIdentity(
        "schema.demo",
        v"2.0.0";
        uri = "https://schema.aimora.dev/demo/2.0",
    )
    @test identity.id == "schema.demo"
    @test identity.uri == "https://schema.aimora.dev/demo/2.0"
    @test identity.version == v"2.0.0"
    @test identity == StructuralSchemaIdentity(
        "schema.demo",
        v"2.0.0";
        uri = "https://schema.aimora.dev/demo/2.0",
    )
    @test_throws ArgumentError StructuralSchemaIdentity("bad id", v"1.0.0")
    @test_throws ArgumentError StructuralSchemaIdentity(
        "schema.demo",
        v"1.0.0";
        uri = "https://user:secret@example.com/schema",
    )
    @test_throws MethodError StructuralSchema(
        identity,
        source_document("").value,
        parse_json("true").value.root,
        repeat("a", 64),
    )

    policy = SchemaVersionPolicy(
        "schema.demo",
        v"2.0.0";
        backward_readers = [v"1.1.0"],
    )
    @test schema_compatibility(policy, v"2.0.0").kind == SchemaExact
    @test schema_compatibility(policy, v"1.1.0").kind == SchemaBackwardReadable
    @test schema_compatibility(
        policy,
        v"1.0.0";
        migration_available = true,
    ).kind == SchemaMigrationRequired
    @test schema_compatibility(policy, v"1.0.0").kind == SchemaPastUnsupported
    @test schema_compatibility(policy, v"3.0.0"; migration_available = true).kind ==
          SchemaFutureUnsupported
    @test_throws ArgumentError SchemaVersionPolicy(
        "schema.demo",
        v"2.0.0";
        backward_readers = [v"2.0.0"],
    )
    @test_throws ArgumentError SchemaVersionPolicy(
        "schema.demo",
        v"2.0.0";
        backward_readers = [v"1.0.0", v"1.0.0"],
    )
    @test_throws ArgumentError SchemaVersionPolicy("bad id", v"1.0.0")
end

@testset "strict structural schema compilation and lock identity" begin
    identity = StructuralSchemaIdentity(
        "schema.demo",
        v"1.0.0";
        uri = "https://schema.aimora.dev/demo/1.0",
    )
    compiled = compile_structural_schema(
        project_structural_schema_text(),
        identity;
        source_name = "demo.schema.json",
    )
    @test format_succeeded(compiled)
    @test isempty(compiled.diagnostics)
    schema = compiled.value
    @test schema.identity == identity
    @test schema.source.provenance.source_name == "demo.schema.json"
    @test occursin(r"^[0-9a-f]{64}$", schema.canonical_sha256)
    @test canonical_json_sha256(schema.root).value == schema.canonical_sha256

    schema_lock_entry = FormatLockEntry(
        LockSchema,
        identity.id,
        identity.version,
        repeat("a", 40),
        schema.canonical_sha256,
        "MIT",
        ">=1.0.0,<2.0.0",
        identity.uri,
        LockDataOnly;
        provenance = "https://schema.aimora.dev/provenance/demo",
    )
    schema_lock = FormatLockDocument(LockSchema, [schema_lock_entry])
    locked = compile_structural_schema(
        parse_json(
            project_structural_schema_text();
            source_name = "locked.schema.json",
        ).value,
        identity;
        lock = schema_lock,
    )
    @test format_succeeded(locked)

    bad_hash_entry = FormatLockEntry(
        LockSchema,
        identity.id,
        identity.version,
        repeat("a", 40),
        repeat("b", 64),
        "MIT",
        ">=1.0.0,<2.0.0",
        identity.uri,
        LockDataOnly;
        provenance = "https://schema.aimora.dev/provenance/demo",
    )
    bad_hash = compile_structural_schema(
        project_structural_schema_text(),
        identity;
        lock = FormatLockDocument(LockSchema, [bad_hash_entry]),
    )
    @test !format_succeeded(bad_hash)
    @test only(bad_hash.diagnostics).code == :structural_schema_lock_hash_mismatch

    missing_lock = compile_structural_schema(
        project_structural_schema_text(),
        identity;
        lock = FormatLockDocument(LockSchema, FormatLockEntry[]),
    )
    @test only(missing_lock.diagnostics).code == :structural_schema_lock_missing
    wrong_family = compile_structural_schema(
        project_structural_schema_text(),
        identity;
        lock = FormatLockDocument(LockCatalog, FormatLockEntry[]),
    )
    @test only(wrong_family.diagnostics).code ==
          :structural_schema_lock_family_mismatch

    wrong_uri_entry = FormatLockEntry(
        LockSchema,
        identity.id,
        identity.version,
        repeat("a", 40),
        schema.canonical_sha256,
        "MIT",
        ">=1.0.0,<2.0.0",
        "https://schema.aimora.dev/demo/other",
        LockDataOnly;
        provenance = "https://schema.aimora.dev/provenance/demo",
    )
    wrong_uri = compile_structural_schema(
        project_structural_schema_text(),
        identity;
        lock = FormatLockDocument(LockSchema, [wrong_uri_entry]),
    )
    @test only(wrong_uri.diagnostics).code == :structural_schema_lock_uri_mismatch

    reordered = replace(
        project_structural_schema_text(),
        "\"title\": \"Demo project structure\",\n  \"description\": \"Structural fields only\"," =>
            "\"description\": \"Structural fields only\",\n  \"title\": \"Demo project structure\",";
        count = 1,
    )
    reordered_schema = compile_structural_schema(reordered, identity)
    @test format_succeeded(reordered_schema)
    @test reordered_schema.value.canonical_sha256 == schema.canonical_sha256
end

@testset "JSON Schema 2020-12 structural subset validation" begin
    schema = compiled_project_structural_schema()
    valid_document = parse_json(
        valid_structural_project_text();
        source_name = "project.json",
    ).value
    valid_result = validate_structural_document(schema, valid_document)
    @test format_succeeded(valid_result)
    @test valid_result.value.valid
    @test valid_result.value.schema_identity == schema.identity
    @test valid_result.value.evaluated_nodes > 10
    @test valid_result.value.document_sha256 == canonical_json_sha256(valid_document).value
    @test valid_document == parse_json(valid_structural_project_text(); source_name = "project.json").value

    reordered_document = parse_json(valid_structural_project_text(order_variant = true)).value
    reordered_result = validate_structural_document(schema, reordered_document)
    @test format_succeeded(reordered_result)
    @test reordered_result.value.document_sha256 == valid_result.value.document_sha256

    compact = parse_json("""{
      "kind":"compact",
      "count":0e0,
      "name":"A",
      "tags":["one"],
      "tuple":["x",1e0],
      "choice":"b",
      "guard":false,
      "positive":1e0,
      "not_bad":"good"
    }""").value
    @test format_succeeded(validate_structural_document(schema, compact))
    @test isnothing(_structural_test_entry(compact.root, "optional"))
end

@testset "structural validation diagnostics cover every admitted family" begin
    schema = compiled_project_structural_schema()
    cases = [
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_string_length,
        ),
        (
            "{\"kind\":\"compact\",\"count\":11,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_numeric_bound,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\",\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_duplicate_item,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1,2],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_additional_item,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"c\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_composition_mismatch,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":0,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_composition_mismatch,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":0,\"not_bad\":\"ok\"}",
            :structural_numeric_bound,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"bad\"}",
            :structural_not_mismatch,
        ),
        (
            "{\"kind\":\"package\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_required_property_missing,
        ),
        (
            "{\"kind\":\"compact\",\"count\":0,\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\",\"extra\":true}",
            :structural_additional_property,
        ),
        (
            "{\"kind\":\"compact\",\"count\":\"zero\",\"name\":\"Grid\",\"tags\":[\"x\"],\"tuple\":[\"x\",1],\"choice\":\"a\",\"guard\":null,\"positive\":1,\"not_bad\":\"ok\"}",
            :structural_type_mismatch,
        ),
    ]
    for (text, code) in cases
        result = validate_structural_document(
            schema,
            parse_json(text; source_name = "invalid-project.json").value,
        )
        @test !format_succeeded(result)
        @test !result.value.valid
        @test code in getfield.(result.diagnostics, :code)
        @test all(diagnostic -> diagnostic.span.source_name == "invalid-project.json", result.diagnostics)
    end

    duplicate_numeric = replace(
        valid_structural_project_text(),
        "[\"north\", \"south\"]" => "[1, 1e0]",
    )
    duplicate_result = validate_structural_document(
        schema,
        parse_json(duplicate_numeric).value,
    )
    @test :structural_duplicate_item in getfield.(duplicate_result.diagnostics, :code)

    limited = validate_structural_document(
        schema,
        parse_json(valid_structural_project_text()).value;
        policy = FormatInputPolicy(max_nesting_depth = 2),
    )
    @test !format_succeeded(limited)
    @test any(
        code -> code in (:nesting_too_deep, :structural_validation_too_deep),
        getfield.(limited.diagnostics, :code),
    )
end

@testset "strict schema meta-validation rejects unsupported or ambiguous declarations" begin
    identity = StructuralSchemaIdentity("schema.bad", v"1.0.0")
    function schema_case(fragment::String; id::String = "schema.bad")
        return "{\"\$schema\":\"$(STRUCTURAL_DIALECT)\",\"\$id\":\"$(id)\",$(fragment)}"
    end
    cases = [
        ("{\"type\":\"object\"}", :missing_structural_schema_identity),
        ("true", :structural_schema_root_must_be_object),
        (schema_case("\"pattern\":\".*\""), :unsupported_structural_schema_keyword),
        (replace(schema_case("\"type\":\"object\""), STRUCTURAL_DIALECT => "https://json-schema.org/draft/2019-09/schema"), :unsupported_structural_schema_dialect),
        (schema_case("\"type\":\"object\""; id = "other.schema"), :structural_schema_id_mismatch),
        (schema_case("\"type\":\"unknown\""), :invalid_structural_schema_type),
        (schema_case("\"type\":[\"string\",\"string\"]"), :invalid_structural_schema_type),
        (schema_case("\"properties\":[]"), :invalid_structural_schema_properties),
        (schema_case("\"required\":[\"x\",\"x\"]"), :invalid_structural_schema_required),
        (schema_case("\"additionalProperties\":0"), :invalid_structural_schema_additional_properties),
        (schema_case("\"minItems\":-1"), :invalid_structural_schema_limit),
        (schema_case("\"minItems\":2,\"maxItems\":1"), :contradictory_structural_schema_limits),
        (schema_case("\"dependentRequired\":[]"), :invalid_structural_schema_dependencies),
        (schema_case("\"prefixItems\":[]"), :invalid_structural_schema_items),
        (schema_case("\"uniqueItems\":1"), :invalid_structural_schema_items),
        (schema_case("\"minimum\":\"zero\""), :invalid_structural_schema_numeric_bound),
        (schema_case("\"minimum\":2,\"maximum\":1"), :contradictory_structural_schema_limits),
        (schema_case("\"minimum\":2,\"exclusiveMaximum\":2"), :contradictory_structural_schema_limits),
        (schema_case("\"exclusiveMinimum\":2,\"maximum\":2"), :contradictory_structural_schema_limits),
        (schema_case("\"enum\":[]"), :invalid_structural_schema_enum),
        (schema_case("\"enum\":[1,1e0]"), :duplicate_structural_schema_enum),
        (schema_case("\"allOf\":[]"), :invalid_structural_schema_composition),
        (schema_case("\"then\":true"), :orphan_structural_schema_branch),
        (schema_case("\"title\":true"), :invalid_structural_schema_annotation),
        (schema_case("\"deprecated\":\"false\""), :invalid_structural_schema_annotation),
        (schema_case("\"examples\":true"), :invalid_structural_schema_annotation),
        (schema_case("\"\$ref\":\"https://example.com/schema\""), :unsupported_structural_schema_reference),
        (schema_case("\"\$ref\":\"#/\$defs/missing\""), :missing_structural_schema_reference),
        (schema_case("\"\$defs\":{\"bad name\":true}"), :invalid_structural_schema_definition_name),
        (schema_case("\"properties\":{\"nested\":{\"\$id\":\"nested\"}}"), :nested_structural_schema_identity),
    ]
    for (text, code) in cases
        result = compile_structural_schema(text, identity; source_name = "bad.schema.json")
        @test !format_succeeded(result)
        @test code in getfield.(result.diagnostics, :code)
        @test all(diagnostic -> !isnothing(diagnostic.span), result.diagnostics)
    end

    deeply_nested = schema_case(
        "\"properties\":{\"a\":{\"properties\":{\"b\":{\"type\":\"string\"}}}}",
    )
    depth_result = compile_structural_schema(
        deeply_nested,
        identity;
        policy = FormatInputPolicy(max_nesting_depth = 3),
    )
    @test !format_succeeded(depth_result)
    @test any(
        code -> code in (:nesting_too_deep, :structural_schema_too_deep),
        getfield.(depth_result.diagnostics, :code),
    )
end

@testset "structural validation has a global branch evaluation budget" begin
    identity = StructuralSchemaIdentity("schema.branch-budget", v"1.0.0")
    schema_text = """{
      "\$schema":"$(STRUCTURAL_DIALECT)",
      "\$id":"schema.branch-budget",
      "anyOf":[true,true]
    }"""
    schema = compile_structural_schema(schema_text, identity)
    @test format_succeeded(schema)
    document = parse_json("{}"; source_name = "bounded-branch.json").value
    result = validate_structural_document(
        schema.value,
        document;
        policy = FormatInputPolicy(max_collection_items = 1),
    )
    @test !format_succeeded(result)
    @test !result.value.valid
    @test result.value.evaluated_nodes == 1
    @test only(result.diagnostics).code == :structural_validation_too_large
    @test only(result.diagnostics).span.source_name == "bounded-branch.json"
end

@testset "local schema references are bounded and do not recurse in place" begin
    identity = StructuralSchemaIdentity("schema.reference", v"1.0.0")
    recursive_text = """{
      "\$schema":"$(STRUCTURAL_DIALECT)",
      "\$id":"schema.reference",
      "\$ref":"#/\$defs/self",
      "\$defs":{"self":{"\$ref":"#/\$defs/self"}}
    }"""
    recursive = compile_structural_schema(recursive_text, identity)
    @test format_succeeded(recursive)
    result = validate_structural_document(recursive.value, parse_json("{}").value)
    @test !format_succeeded(result)
    @test :structural_reference_cycle in getfield.(result.diagnostics, :code)

    nested_text = """{
      "\$schema":"$(STRUCTURAL_DIALECT)",
      "\$id":"schema.reference",
      "type":"object",
      "properties":{"child":{"\$ref":"#/\$defs/node"}},
      "additionalProperties":false,
      "\$defs":{"node":{"type":"object","properties":{"child":{"\$ref":"#/\$defs/node"}},"additionalProperties":false}}
    }"""
    nested = compile_structural_schema(nested_text, identity)
    @test format_succeeded(nested)
    @test format_succeeded(validate_structural_document(
        nested.value,
        parse_json("{\"child\":{\"child\":{}}}").value,
    ))
end

record_format_conformance!(:structural_schemas)
