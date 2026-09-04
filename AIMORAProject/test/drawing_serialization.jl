import AIMORAFormats
using SHA

@testset "typed drawing workspace serialization and migration" begin
    decimal(value, exponent = 0) = ExactDecimal(value, exponent)
    coordinate(x, y) = DrawingCoordinate(decimal(x), decimal(y))
    identity(id) = ObjectIdentity(ProjectId(id))
    licence = LicenceIdentity("PolyForm-Noncommercial-1.0.0", "PolyForm Noncommercial 1.0.0")
    provenance = ProvenanceSource(ProjectId("source.test"), "independently authored test drawing", licence)

    document_id = ProjectId("drawing.main")
    model_view_id = ProjectId("view.model")
    paper_view_id = ProjectId("view.paper")
    sheet_id = ProjectId("sheet.a1")
    layer_id = ProjectId("layer.primary")
    style_id = ProjectId("style.primary")
    block_id = ProjectId("block.bay")
    entity_id = ProjectId("entity.frame")
    projection_id = ProjectId("projection.breaker")
    route_id = ProjectId("route.bus")
    label_id = ProjectId("label.breaker")

    document = DrawingDocument(identity(document_id.value), "Main SLD", [model_view_id, paper_view_id], [sheet_id], provenance)
    model_view = DrawingView(identity(model_view_id.value), document_id, "Model", DrawingModelSpace, provenance)
    paper_view = DrawingView(identity(paper_view_id.value), document_id, "A1", DrawingPaperSpace, provenance)
    sheet = DrawingSheet(identity(sheet_id.value), document_id, paper_view_id, "A1", decimal(841), decimal(594), provenance)
    layer = DrawingLayer(identity(layer_id.value), document_id, "Primary", provenance; visible = true, printable = true)
    style = DrawingStyle(identity(style_id.value), document_id, "Primary line", DrawingLineStyle, [
        DrawingStyleProperty(ProjectId("stroke_width"), decimal(35, -2)),
        DrawingStyleProperty(ProjectId("colour"), "#1b2630"),
        DrawingStyleProperty(ProjectId("enabled"), true),
        DrawingStyleProperty(ProjectId("reference"), layer_id),
    ], provenance)
    block = DrawingBlockDefinition(identity(block_id.value), document_id, "Reusable bay", coordinate(0, 0), provenance)
    entity = DrawingEntity(identity(entity_id.value), block_id, layer_id, ProjectId("polyline"), [coordinate(0, 0), coordinate(10, 0), coordinate(10, 5)], provenance; style = style_id)
    projection = DrawingProjection(identity(projection_id.value), model_view_id, ProjectId("semantic.breaker"), layer_id, coordinate(20, 10), decimal(90), decimal(1), provenance)
    route = DrawingRoute(identity(route_id.value), model_view_id, layer_id, [coordinate(0, 0), coordinate(20, 0), coordinate(20, 10)], provenance; semantic_connection = ProjectId("semantic.bus"), style = style_id)
    label = DrawingLabel(identity(label_id.value), model_view_id, layer_id, coordinate(22, 12), "Q1", provenance; style = style_id, bound_owner = ProjectId("semantic.breaker"), bound_field = "designator")
    lock = DrawingLock(identity("lock.breaker"), projection_id, [DrawingPositionLock, DrawingContentLock], provenance; reason = "reviewed placement")
    viewport = DrawingViewport(identity("viewport.main"), sheet_id, model_view_id, coordinate(10, 10), decimal(800), decimal(550), decimal(1), decimal(0), [layer_id], provenance)
    workspace = DrawingWorkspace(
        documents = [document],
        views = [model_view, paper_view],
        sheets = [sheet],
        viewports = [viewport],
        layers = [layer],
        styles = [style],
        blocks = [block],
        entities = [entity],
        projections = [projection],
        routes = [route],
        labels = [label],
        locks = [lock],
    )
    binding = DrawingSymbolBinding(projection_id, "switching.circuit_breaker", "aimora-public-symbols", repeat("a", 64); state = "open")
    cache = AIMORAFormats.NativeDrawingCacheReference("previews/main.bin", repeat("b", 64))

    first = serialize_drawing_workspace(ProjectId("project.demo"), workspace; symbols = [binding], caches = [cache])
    second = serialize_drawing_workspace(ProjectId("project.demo"), workspace; symbols = [binding], caches = [cache])
    @test AIMORAFormats.format_succeeded(first)
    @test first == second
    @test drawing_workspace_sha256(ProjectId("project.demo"), workspace; symbols = [binding], caches = [cache]).value == bytes2hex(sha256(collect(first.value.bytes)))

    parsed = parse_drawing_workspace(collect(first.value.bytes); source_name = "drawing.json")
    @test AIMORAFormats.format_succeeded(parsed)
    @test parsed.value.project_id == ProjectId("project.demo")
    @test collect(parsed.value.symbols) == [binding]
    @test collect(parsed.value.missing_cache_paths) == ["previews/main.bin"]
    @test length(parsed.value.workspace.documents) == 1
    @test length(parsed.value.workspace.views) == 2
    @test length(parsed.value.workspace.sheets) == 1
    @test length(parsed.value.workspace.viewports) == 1
    @test length(parsed.value.workspace.layers) == 1
    @test length(parsed.value.workspace.styles) == 1
    @test length(parsed.value.workspace.blocks) == 1
    @test length(parsed.value.workspace.entities) == 1
    @test length(parsed.value.workspace.projections) == 1
    @test length(parsed.value.workspace.routes) == 1
    @test length(parsed.value.workspace.labels) == 1
    @test length(parsed.value.workspace.locks) == 1
    roundtrip = serialize_drawing_workspace(parsed.value.project_id, parsed.value.workspace; symbols = collect(parsed.value.symbols), caches = [cache])
    @test collect(roundtrip.value.bytes) == collect(first.value.bytes)

    recovered = parse_drawing_workspace(collect(first.value.bytes); available_cache_hashes = Dict("previews/main.bin" => repeat("b", 64)))
    @test isempty(recovered.value.missing_cache_paths)
    unknown_owner = DrawingSymbolBinding(ProjectId("projection.missing"), "power.busbar", "aimora-public-symbols", repeat("c", 64))
    @test_throws ArgumentError serialize_drawing_workspace(ProjectId("project.demo"), workspace; symbols = [binding, unknown_owner])

    malicious = replace(String(collect(first.value.bytes)), "\"documents\":[" => "\"unknown\":true,\"documents\":["; count = 1)
    rejected = parse_drawing_workspace(malicious)
    @test !AIMORAFormats.format_succeeded(rejected)
    @test only(rejected.diagnostics).code == :invalid_drawing_workspace
end

record_project_conformance!(:drawing_serialization)
