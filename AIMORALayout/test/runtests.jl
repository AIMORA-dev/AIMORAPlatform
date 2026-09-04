using Test
using AIMORALayout
using AIMORAProject
using Dates

identity(value) = ObjectIdentity(ProjectId(value))
coordinate(x, y) = DrawingCoordinate(ExactDecimal(x, 0), ExactDecimal(y, 0))

function layout_fixture()
    licence = LicenceIdentity("test-permissive", "Test permissive licence")
    provenance = ProvenanceSource(ProjectId("source.layout-test"), "layout test", licence)
    domain = electrical_ac_domain()
    carrier = CarrierIdentity(domain, ProjectId("phase-a"))
    owner_ids = ProjectId[ProjectId("source"), ProjectId("bus"), ProjectId("feeder")]
    nodes = GraphNode[
        GraphNode(identity("bus"), domain, [carrier], provenance),
        GraphNode(identity("feeder"), domain, [carrier], provenance),
    ]
    ports = SemanticPort[
        SemanticPort(
            identity("source.port"),
            ProjectId("source"),
            domain,
            PortBidirectional,
            [carrier],
            provenance,
        ),
        SemanticPort(
            identity("bus.port"),
            ProjectId("bus"),
            domain,
            PortBidirectional,
            [carrier],
            provenance,
        ),
    ]
    connections = PhysicalConnection[
        PhysicalConnection(
            identity("connection.source-bus"),
            ProjectId("source.port"),
            ProjectId("bus"),
            [CarrierMapping(carrier, carrier)],
            provenance,
        ),
        PhysicalConnection(
            identity("connection.bus-feeder"),
            ProjectId("bus.port"),
            ProjectId("feeder"),
            [CarrierMapping(carrier, carrier)],
            provenance,
        ),
    ]
    semantic_view = ProjectId("semantic-view.sld")
    semantic_projections = ViewProjection[
        ViewProjection(
            identity("semantic-projection.$(owner.value)"),
            semantic_view,
            owner,
            provenance,
        ) for owner in owner_ids
    ]
    graphs = SemanticGraphs(;
        nodes,
        ports,
        physical_connections = connections,
        signal_connections = SignalConnection[],
        workflow_dependencies = WorkflowDependency[],
        cross_references = CrossGraphReference[],
        view_projections = semantic_projections,
    )
    document_id = ProjectId("drawing.document")
    view_id = ProjectId("drawing.view.sld")
    layer_id = ProjectId("drawing.layer.primary")
    document = DrawingDocument(
        identity(document_id.value),
        "SLD",
        [view_id],
        ProjectId[],
        provenance,
    )
    view = DrawingView(
        identity(view_id.value),
        document_id,
        "Model",
        DrawingModelSpace,
        provenance;
        semantic_view,
    )
    layer = DrawingLayer(
        identity(layer_id.value),
        document_id,
        "Primary",
        provenance;
        visible = true,
        printable = true,
    )
    source_projection = DrawingProjection(
        identity("drawing.projection.source"),
        view_id,
        semantic_projections[1].identity.id,
        layer_id,
        coordinate(-100, 0),
        ExactDecimal(0, 0),
        ExactDecimal(1, 0),
        provenance,
    )
    source_lock = DrawingLock(
        identity("drawing.lock.source"),
        source_projection.identity.id,
        [DrawingPositionLock],
        provenance;
        reason = "operator placement",
    )
    drawings = DrawingWorkspace(;
        documents = [document],
        views = [view],
        sheets = DrawingSheet[],
        viewports = DrawingViewport[],
        layers = [layer],
        styles = DrawingStyle[],
        blocks = DrawingBlockDefinition[],
        entities = DrawingEntity[],
        projections = [source_projection],
        routes = DrawingRoute[],
        labels = DrawingLabel[],
        locks = [source_lock],
    )
    metadata = ProjectMetadata(
        identity("project.layout-test"),
        "Layout test",
        NamespaceId("layout-test"),
        v"2.0.0",
        DateTime(2026, 1, 1),
        provenance,
    )
    base_project = unsafe_project(
        metadata,
        SemanticSchemaRegistry(),
        UnitRegistry(),
        CanonicalRecord[],
        graphs,
    )
    project = unsafe_project(
        base_project.metadata,
        base_project.registry,
        base_project.units,
        CanonicalRecord[],
        base_project.graphs,
        base_project.asset_library,
        base_project.hierarchy,
        base_project.control_system,
        base_project.event_scenarios,
        base_project.orchestration,
        drawings,
    )
    return project, provenance, view_id, layer_id, owner_ids
end

function is_orthogonal(route)
    return all(zip(route.points, Iterators.drop(route.points, 1))) do pair
        first, second = pair
        first.x == second.x || first.y == second.y
    end
end

@testset "deterministic topology-safe automatic layout" begin
    @test nameof(AIMORALayout) === :AIMORALayout
    project, provenance, view, layer, owners = layout_fixture()
    request = LayoutRequest(
        view,
        layer,
        provenance;
        mode = LayoutFull,
        labels = [LayoutLabelSpec(owner, uppercase(owner.value)) for owner in owners],
        repeated_bays = [
            RepeatedBaySpec(ProjectId("bay.feeder"), owners[2:3], "Feeder bay"),
        ],
        options = LayoutOptions(
            page_width = 80,
            page_height = 80,
            page_margin = 10,
            default_node_width = 50,
            default_node_height = 30,
        ),
    )
    first_result = layout_project(project, request)
    second_result = layout_project(project, request)

    @test first_result.physics_hash_before == first_result.physics_hash_after
    @test project_physics_hash(project) == project_physics_hash(first_result.project)
    @test project_view_hash(first_result.project) == project_view_hash(second_result.project)
    @test length(first_result.plan.placements) == 3
    @test length(first_result.plan.routes) == 2
    @test all(is_orthogonal, first_result.project.drawings.routes)
    @test length(first_result.plan.labels) == 4
    @test length(first_result.plan.boundaries) == 1
    @test length(first_result.plan.pages) >= 2
    @test length(first_result.project.drawings.sheets) == length(first_result.plan.pages)
    locked = only(
        filter(
            projection ->
                projection.identity.id == ProjectId("drawing.projection.source"),
            collect(first_result.project.drawings.projections),
        ),
    )
    @test locked.position == coordinate(-100, 0)
end

@testset "local scope and manual preservation" begin
    project, provenance, view, layer, owners = layout_fixture()
    initial = layout_project(
        project,
        LayoutRequest(view, layer, provenance; mode = LayoutFull),
    ).project
    feeder = only(
        filter(
            projection ->
                projection.semantic_projection == ProjectId("semantic-projection.feeder"),
            collect(initial.drawings.projections),
        ),
    )
    request = LayoutRequest(
        view,
        layer,
        provenance;
        mode = LayoutIncremental,
        focus = [owners[1]],
        manual_records = [feeder.identity.id],
        rank_hints = [owners[1] => 3],
    )
    result = layout_project(initial, request)
    preserved = only(
        filter(
            projection -> projection.identity.id == feeder.identity.id,
            collect(result.project.drawings.projections),
        ),
    )
    @test preserved.position == feeder.position
    @test result.physics_hash_before == result.physics_hash_after
end
