@testset "native drawing documents, migration, and recovery" begin
    drawing = Dict(
        "documents" => [Dict("id" => "drawing.main", "name" => "Main")],
        "sheets" => [Dict("id" => "sheet.a1", "width" => "841", "height" => "594")],
        "styles" => [Dict("id" => "style.primary", "stroke" => "0.35")],
        "blocks" => [Dict("id" => "block.bay", "base" => ["0", "0"])],
        "projections" => [Dict("id" => "projection.q1", "owner" => "equipment.q1")],
        "routes" => [Dict("id" => "route.bus", "points" => [["0", "0"], ["20", "0"]])],
    )
    symbols = [
        NativeSymbolReference("projection.q1", "switching.circuit_breaker", "aimora-public-symbols", repeat("a", 64); state = "open"),
        NativeSymbolReference("projection.t1", "transformer.two_winding", "aimora-public-symbols", repeat("b", 64)),
    ]
    caches = [NativeDrawingCacheReference("previews/main.bin", repeat("c", 64))]
    document = NativeDrawingDocument("project.demo", drawing, reverse(symbols), caches)

    first = serialize_native_drawing(document)
    second = serialize_native_drawing(document)
    @test format_succeeded(first)
    @test first == second
    @test first.value.media_type == "application/json"
    @test String(collect(first.value.bytes)) == String(collect(second.value.bytes))
    @test native_drawing_sha256(document).value == bytes2hex(sha256(collect(first.value.bytes)))

    parsed = parse_native_drawing(collect(first.value.bytes); source_name = "drawing.aimora.json")
    @test format_succeeded(parsed)
    @test parsed.value.document.project_id == "project.demo"
    @test native_drawing_payload(parsed.value.document) == drawing
    @test collect(parsed.value.document.symbols) == sort(symbols; by = item -> (item.owner_id, item.symbol_id))
    @test collect(parsed.value.document.caches) == caches
    @test collect(parsed.value.missing_cache_paths) == ["previews/main.bin"]
    @test parsed.value.migration.source_version == v"2.0.0"
    @test isempty(parsed.value.migration.changes)
    recovered = parse_native_drawing(
        collect(first.value.bytes);
        available_cache_hashes = Dict("previews/main.bin" => repeat("c", 64)),
    )
    @test isempty(recovered.value.missing_cache_paths)

    current_text = String(collect(first.value.bytes))
    previous_text = replace(
        replace(
            replace(current_text, "\"schema_version\":\"2.0.0\"" => "\"schema_version\":\"1.0.0\""),
            "\"drawing\":" => "\"workspace\":";
            count = 1,
        ),
        "\"symbols\":" => "\"symbol_bindings\":";
        count = 1,
    )
    previous_text = replace(previous_text, r"\"caches\":\[[^]]*\]," => "")
    migrated = parse_native_drawing(previous_text; source_name = "drawing-v1.json")
    @test format_succeeded(migrated)
    @test migrated.value.migration.source_version == v"1.0.0"
    @test migrated.value.migration.target_version == v"2.0.0"
    @test migrated.value.migration.lossless
    @test length(migrated.value.migration.changes) == 3
    @test native_drawing_payload(migrated.value.document) == drawing

    @test_throws ArgumentError NativeDrawingDocument("project.demo", drawing, [symbols[1], symbols[1]])
    @test_throws ArgumentError NativeDrawingCacheReference("../escape.bin", repeat("d", 64))
    @test_throws ArgumentError NativeDrawingCacheReference("C:/escape.bin", repeat("d", 64))

    first_symbol = only(match(r"\"symbols\":\[(\{[^}]+\})", current_text).captures)
    duplicate = replace(current_text, "\"symbols\":[" => "\"symbols\":[$(first_symbol),"; count = 1)
    duplicate_result = parse_native_drawing(duplicate)
    @test !format_succeeded(duplicate_result)
    @test only(duplicate_result.diagnostics).code == :native_drawing_conflict
    unknown = parse_native_drawing(replace(current_text, "\"format\":" => "\"unexpected\":true,\"format\":"; count = 1))
    @test !format_succeeded(unknown)
    @test only(unknown.diagnostics).code == :unknown_native_drawing_field
    traversal = parse_native_drawing(replace(current_text, "previews/main.bin" => "../escape.bin"))
    @test !format_succeeded(traversal)
    @test only(traversal.diagnostics).code == :invalid_native_cache_reference
    oversized = parse_native_drawing(current_text; policy = FormatInputPolicy(max_document_bytes = 20))
    @test !format_succeeded(oversized)
    @test only(oversized.diagnostics).code == :document_too_large

    schema_path = joinpath(@__DIR__, "..", "schemas", "native", "drawing-v2.schema.json")
    schema_identity = StructuralSchemaIdentity(
        "native.drawing",
        v"2.0.0";
        uri = "https://schemas.aimora.dev/native/drawing-v2.schema.json",
    )
    schema = compile_structural_schema(
        read(schema_path, String),
        schema_identity;
        source_name = "drawing-v2.schema.json",
    )
    @test format_succeeded(schema)
    format_succeeded(schema) || error(join((diagnostic.message for diagnostic in schema.diagnostics), "; "))
    instance = parse_json(current_text; source_name = "drawing.json")
    validation = validate_structural_document(schema.value, instance.value)
    @test format_succeeded(validation)
    @test validation.value.valid
end

record_format_conformance!(:native_drawing_documents)
