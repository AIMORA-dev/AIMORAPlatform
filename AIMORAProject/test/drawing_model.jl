using Dates

function drawing_project_fixture()
    graph = graph_fixture()
    provenance = graph.provenance
    decimal(value) = parse_exact_decimal(value)
    coordinate(x, y) = DrawingCoordinate(decimal(x), decimal(y))

    model_view = DrawingView(
        ObjectIdentity(ProjectId("drawing.view.model")),
        ProjectId("drawing.document.main"),
        "Main model",
        DrawingModelSpace,
        provenance;
        semantic_view = graph.projection.view,
    )
    paper_view = DrawingView(
        ObjectIdentity(ProjectId("drawing.view.paper")),
        ProjectId("drawing.document.main"),
        "Sheet A3",
        DrawingPaperSpace,
        provenance,
    )
    sheet = DrawingSheet(
        ObjectIdentity(ProjectId("drawing.sheet.a3")),
        ProjectId("drawing.document.main"),
        paper_view.identity.id,
        "A3",
        decimal("420"),
        decimal("297"),
        provenance,
    )
    document = DrawingDocument(
        ObjectIdentity(ProjectId("drawing.document.main")),
        "Primary SLD",
        [paper_view.identity.id, model_view.identity.id],
        [sheet.identity.id],
        provenance,
    )
    layer = DrawingLayer(
        ObjectIdentity(ProjectId("drawing.layer.equipment")),
        document.identity.id,
        "Equipment",
        provenance,
    )
    style = DrawingStyle(
        ObjectIdentity(ProjectId("drawing.style.primary")),
        document.identity.id,
        "Primary",
        DrawingLineStyle,
        [
            DrawingStyleProperty(ProjectId("property.lineweight"), decimal("0.35")),
            DrawingStyleProperty(ProjectId("property.color"), "#20242b"),
        ],
        provenance,
    )
    block = DrawingBlockDefinition(
        ObjectIdentity(ProjectId("drawing.block.breaker")),
        document.identity.id,
        "Breaker",
        coordinate("0", "0"),
        provenance,
    )
    block_member = DrawingEntity(
        ObjectIdentity(ProjectId("drawing.entity.breaker_line")),
        block.identity.id,
        layer.identity.id,
        ProjectId("entity.line"),
        [coordinate("-5", "0"), coordinate("5", "0")],
        provenance;
        style = style.identity.id,
    )
    block_instance = DrawingEntity(
        ObjectIdentity(ProjectId("drawing.entity.breaker_instance")),
        model_view.identity.id,
        layer.identity.id,
        ProjectId("entity.block_instance"),
        [coordinate("40", "25")],
        provenance;
        block_definition = block.identity.id,
    )
    projection = DrawingProjection(
        ObjectIdentity(ProjectId("drawing.projection.bus")),
        model_view.identity.id,
        graph.projection.identity.id,
        layer.identity.id,
        coordinate("25", "25"),
        decimal("0"),
        decimal("1"),
        provenance,
    )
    route = DrawingRoute(
        ObjectIdentity(ProjectId("drawing.route.connection")),
        model_view.identity.id,
        layer.identity.id,
        [coordinate("25", "25"), coordinate("40", "25")],
        provenance;
        semantic_connection = graph.connection.identity.id,
        style = style.identity.id,
    )
    label = DrawingLabel(
        ObjectIdentity(ProjectId("drawing.label.connection")),
        model_view.identity.id,
        layer.identity.id,
        coordinate("32.5", "27"),
        "Connection",
        provenance;
        style = style.identity.id,
        bound_owner = graph.connection.identity.id,
        bound_field = "identity",
    )
    viewport = DrawingViewport(
        ObjectIdentity(ProjectId("drawing.viewport.main")),
        sheet.identity.id,
        model_view.identity.id,
        coordinate("10", "10"),
        decimal("400"),
        decimal("277"),
        decimal("1"),
        decimal("0"),
        [layer.identity.id],
        provenance,
    )
    lock = DrawingLock(
        ObjectIdentity(ProjectId("drawing.lock.bus")),
        projection.identity.id,
        [DrawingGeometryLock, DrawingPositionLock],
        provenance;
        reason = "Reviewed placement",
    )
    workspace = DrawingWorkspace(
        documents = [document],
        views = [paper_view, model_view],
        sheets = [sheet],
        viewports = [viewport],
        layers = [layer],
        styles = [style],
        blocks = [block],
        entities = [block_instance, block_member],
        projections = [projection],
        routes = [route],
        labels = [label],
        locks = [lock],
    )
    project = CanonicalProject(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        graph.graphs,
        graph.project.asset_library,
        graph.project.hierarchy,
        graph.project.control_system,
        graph.project.event_scenarios,
        graph.project.orchestration,
        workspace,
    )
    return (;
        graph...,
        graph_project = graph.project,
        graph_projection = graph.projection,
        project,
        workspace,
        document,
        model_view,
        paper_view,
        sheet,
        viewport,
        layer,
        style,
        block,
        block_member,
        block_instance,
        projection,
        route,
        label,
        lock,
        coordinate,
        decimal,
    )
end

function unverified_with_drawings(project::CanonicalProject, workspace::DrawingWorkspace)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        workspace,
    )
end

@testset "canonical drawing documents spaces and references" begin
    fixture = drawing_project_fixture()
    @test fixture.project.verification == ProjectVerified
    @test validate_drawing_workspace(fixture.project, fixture.workspace)
    @test collect(fixture.document.views) ==
        [ProjectId("drawing.view.model"), ProjectId("drawing.view.paper")]
    @test drawing_record(fixture.workspace, fixture.route.identity.id) == fixture.route
    @test length(drawing_workspace_ids(fixture.workspace)) == 14
    @test fixture.viewport.visible_layers == CanonicalList{ProjectId}([fixture.layer.identity.id])
    @test fixture.paper_view.semantic_view === nothing
    @test fixture.route.semantic_connection == fixture.connection.identity.id
    @test fixture.projection.semantic_projection == fixture.graph_projection.identity.id
    @test semantic_error_code(
        () -> drawing_record(fixture.workspace, ProjectId("drawing.unknown")),
    ) == :unknown_drawing_id
    @test semantic_error_code(
        () -> DrawingSheet(
            ObjectIdentity(ProjectId("drawing.sheet.invalid")),
            fixture.document.identity.id,
            fixture.paper_view.identity.id,
            "Invalid",
            fixture.decimal("0"),
            fixture.decimal("10"),
            fixture.provenance,
        ),
    ) == :invalid_sheet_geometry
    @test semantic_error_code(
        () -> DrawingLabel(
            ObjectIdentity(ProjectId("drawing.label.invalid")),
            fixture.model_view.identity.id,
            fixture.layer.identity.id,
            fixture.coordinate("0", "0"),
            "",
            fixture.provenance,
        ),
    ) == :empty_drawing_label
end

@testset "drawing validation rejects cross-domain and structural corruption" begin
    fixture = drawing_project_fixture()
    wrong_route = DrawingRoute(
        fixture.route.identity,
        fixture.route.view,
        fixture.route.layer,
        collect(fixture.route.points),
        fixture.provenance;
        semantic_connection = ProjectId("connection.missing"),
        style = fixture.route.style,
    )
    records = AIMORAProject._drawing_records(fixture.workspace)
    records[findfirst(item -> item.identity.id == wrong_route.identity.id, records)] = wrong_route
    invalid_route = unverified_with_drawings(
        fixture.project,
        AIMORAProject._drawing_workspace(records),
    )
    @test semantic_error_code(() -> validate_project(invalid_route)) ==
        :drawing_connection_missing

    wrong_sheet = DrawingSheet(
        fixture.sheet.identity,
        fixture.sheet.document,
        fixture.model_view.identity.id,
        fixture.sheet.name,
        fixture.sheet.width,
        fixture.sheet.height,
        fixture.provenance,
    )
    records = AIMORAProject._drawing_records(fixture.workspace)
    records[findfirst(item -> item.identity.id == wrong_sheet.identity.id, records)] = wrong_sheet
    invalid_sheet = unverified_with_drawings(
        fixture.project,
        AIMORAProject._drawing_workspace(records),
    )
    @test semantic_error_code(() -> validate_project(invalid_sheet)) ==
        :drawing_sheet_not_paper_space

    recursive_entity = DrawingEntity(
        fixture.block_member.identity,
        fixture.block.identity.id,
        fixture.layer.identity.id,
        ProjectId("entity.block_instance"),
        collect(fixture.block_member.points),
        fixture.provenance;
        block_definition = fixture.block.identity.id,
    )
    records = AIMORAProject._drawing_records(fixture.workspace)
    records[findfirst(item -> item.identity.id == recursive_entity.identity.id, records)] =
        recursive_entity
    invalid_block = unverified_with_drawings(
        fixture.project,
        AIMORAProject._drawing_workspace(records),
    )
    @test semantic_error_code(() -> validate_project(invalid_block)) ==
        :recursive_drawing_block

    duplicate_lock = DrawingLock(
        ObjectIdentity(ProjectId("drawing.lock.duplicate")),
        fixture.projection.identity.id,
        [DrawingPositionLock],
        fixture.provenance,
    )
    invalid_locks = DrawingWorkspace(
        documents = collect(fixture.workspace.documents),
        views = collect(fixture.workspace.views),
        sheets = collect(fixture.workspace.sheets),
        viewports = collect(fixture.workspace.viewports),
        layers = collect(fixture.workspace.layers),
        styles = collect(fixture.workspace.styles),
        blocks = collect(fixture.workspace.blocks),
        entities = collect(fixture.workspace.entities),
        projections = collect(fixture.workspace.projections),
        routes = collect(fixture.workspace.routes),
        labels = collect(fixture.workspace.labels),
        locks = [collect(fixture.workspace.locks); duplicate_lock],
    )
    @test semantic_error_code(
        () -> validate_project(unverified_with_drawings(fixture.project, invalid_locks)),
    ) == :duplicate_drawing_lock
end

@testset "drawing transactions replay undo and invalidate views only" begin
    fixture = drawing_project_fixture()
    base = initial_revision(
        fixture.project,
        ContentDigest(repeat("1", 64)),
        ContentDigest(repeat("2", 64)),
        RevisionProvenance(
            ProjectId("action.drawing_base"),
            DateTime(2026, 9, 4, 10, 0, 0),
            fixture.provenance,
        ),
    )
    moved = DrawingEntity(
        fixture.block_instance.identity,
        fixture.block_instance.container,
        fixture.block_instance.layer,
        fixture.block_instance.kind,
        [fixture.coordinate("45", "30")],
        fixture.provenance;
        style = fixture.block_instance.style,
        block_definition = fixture.block_instance.block_definition,
    )
    command = ProjectCommand(
        ProjectId("command.move_drawing_entity"),
        ReplaceDrawingRecordPatch(moved),
    )
    transaction = begin_project_transaction(base)
    apply!(transaction, command)
    validate!(transaction)
    committed = commit!(
        transaction,
        base,
        ContentDigest(repeat("3", 64)),
        ContentDigest(repeat("4", 64)),
        RevisionProvenance(
            ProjectId("action.move_drawing_entity"),
            DateTime(2026, 9, 4, 10, 1, 0),
            fixture.provenance,
        ),
    )
    @test collect(committed.changed_owners) == [moved.identity.id]
    @test collect(committed.invalidations) == [
        DependencyInvalidation(moved.identity.id, [InvalidateViews]),
    ]
    @test project_physics_hash(committed.project) == project_physics_hash(base.project)
    @test project_view_hash(committed.project) != project_view_hash(base.project)

    replayed = replay_commands(base.project, [command])
    @test replayed == committed.project
    @test validate_drawing_replay_identity(committed.project.drawings, replayed.drawings)
    restored = replay_commands(replayed, collect(inverse_commands(base.project, [command])))
    @test restored == base.project
    @test validate_drawing_rollback_identity(base.project.drawings, restored.drawings)

    remove_label = ProjectCommand(
        ProjectId("command.remove_drawing_label"),
        RemoveDrawingRecordPatch(fixture.label.identity.id),
    )
    without_label = replay_commands(base.project, [remove_label])
    @test isempty(without_label.drawings.labels)
    restored_label = replay_commands(
        without_label,
        collect(inverse_commands(base.project, [remove_label])),
    )
    @test restored_label == base.project
    @test semantic_error_code(
        () -> validate_drawing_replay_identity(
            base.project.drawings,
            without_label.drawings,
        ),
    ) == :drawing_replay_id_mismatch

    no_effect = begin_project_transaction(base)
    @test semantic_error_code(
        () -> apply!(
            no_effect,
            ProjectCommand(
                ProjectId("command.no_effect_drawing"),
                ReplaceDrawingRecordPatch(fixture.block_instance),
            ),
        ),
    ) == :no_effect_command
    wrong_type = DrawingLabel(
        fixture.block_instance.identity,
        fixture.model_view.identity.id,
        fixture.layer.identity.id,
        fixture.coordinate("0", "0"),
        "Wrong type",
        fixture.provenance,
    )
    @test semantic_error_code(
        () -> apply!(
            no_effect,
            ProjectCommand(
                ProjectId("command.wrong_drawing_type"),
                ReplaceDrawingRecordPatch(wrong_type),
            ),
        ),
    ) == :drawing_record_type_mismatch

    moved_locked_projection = DrawingProjection(
        fixture.projection.identity,
        fixture.projection.view,
        fixture.projection.semantic_projection,
        fixture.projection.layer,
        fixture.coordinate("30", "25"),
        fixture.projection.rotation_degrees,
        fixture.projection.scale,
        fixture.provenance,
    )
    @test semantic_error_code(
        () -> apply!(
            no_effect,
            ProjectCommand(
                ProjectId("command.move_locked_projection"),
                ReplaceDrawingRecordPatch(moved_locked_projection),
            ),
        ),
    ) == :drawing_record_locked
    @test semantic_error_code(
        () -> apply!(
            no_effect,
            ProjectCommand(
                ProjectId("command.remove_locked_projection"),
                RemoveDrawingRecordPatch(fixture.projection.identity.id),
            ),
        ),
    ) == :drawing_record_locked
end

@testset "view-only drawing changes preserve physical identity" begin
    fixture = drawing_project_fixture()
    @test project_physics_hash(fixture.graph_project) ==
        project_physics_hash(fixture.project)
    @test project_view_hash(fixture.graph_project) != project_view_hash(fixture.project)
    @test project_resolved_hash(fixture.graph_project) !=
        project_resolved_hash(fixture.project)
end

record_project_conformance!(:drawing_model)
