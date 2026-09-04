using Dates

@testset "semantic SLD edits preserve topology and projection boundaries" begin
    drawing = drawing_project_fixture()
    assets = asset_fixture()
    placed_asset = CanonicalAsset(
        project_record(drawing.project, ProjectId("bus.MV")).identity,
        assets.asset.asset_type,
        AssetProperty[],
        StudyRealization[],
        drawing.provenance,
    )
    placed_port = SemanticPort(
        ObjectIdentity(ProjectId("port.bus_MV.terminal")),
        placed_asset.identity.id,
        electrical_ac_domain(),
        PortBidirectional,
        drawing.carriers,
        drawing.provenance;
        nominal_level = drawing.nominal,
    )
    semantic_projection = ViewProjection(
        ObjectIdentity(ProjectId("projection.bus_MV.asset")),
        ProjectId("bus.MV"),
        placed_asset.identity.id,
        drawing.provenance,
    )
    drawing_projection = DrawingProjection(
        ObjectIdentity(ProjectId("drawing.projection.bus_MV.asset")),
        drawing.model_view.identity.id,
        semantic_projection.identity.id,
        drawing.layer.identity.id,
        drawing.coordinate("55", "25"),
        parse_exact_decimal("0"),
        parse_exact_decimal("1"),
        drawing.provenance,
    )
    placement = plan_equipment_placement(
        drawing.project,
        ProjectId("action.place_equipment"),
        placed_asset,
        [placed_port],
        semantic_projection,
        drawing_projection,
    )
    @test placement.physical_topology_changed
    placed = replay_commands(drawing.project, collect(placement.commands))
    @test canonical_asset(placed, placed_asset.identity.id) == placed_asset
    @test any(port -> port.identity.id == placed_port.identity.id, placed.graphs.ports)
    @test any(
        projection -> projection.semantic_owner == placed_asset.identity.id,
        placed.graphs.view_projections,
    )

    base = initial_revision(
        drawing.project,
        ContentDigest(repeat("1", 64)),
        project_resolved_hash(drawing.project),
        RevisionProvenance(
            ProjectId("action.semantic_sld_base"),
            DateTime(2026, 9, 4, 16, 0, 0),
            drawing.provenance,
        ),
    )
    transaction = begin_project_transaction(base)
    @test apply_semantic_sld_edit!(transaction, placement) === transaction
    @test transaction.working == placed

    removal = plan_projection_removal(
        placed,
        ProjectId("action.remove_projection"),
        drawing_projection.identity.id,
    )
    @test !removal.physical_topology_changed
    without_projection = replay_commands(placed, collect(removal.commands))
    @test project_physics_hash(without_projection) == project_physics_hash(placed)
    @test any(asset -> asset.identity.id == placed_asset.identity.id, without_projection.asset_library.assets)
    @test any(port -> port.identity.id == placed_port.identity.id, without_projection.graphs.ports)

    second_projection = ViewProjection(
        ObjectIdentity(ProjectId("projection.bus_MV.asset.second")),
        ProjectId("bus.MV"),
        placed_asset.identity.id,
        drawing.provenance,
    )
    second_drawing_projection = DrawingProjection(
        ObjectIdentity(ProjectId("drawing.projection.bus_MV.asset.second")),
        drawing.model_view.identity.id,
        second_projection.identity.id,
        drawing.layer.identity.id,
        drawing.coordinate("60", "30"),
        parse_exact_decimal("0"),
        parse_exact_decimal("1"),
        drawing.provenance,
    )
    multi_view = replay_commands(placed, [
        ProjectCommand(
            ProjectId("command.add_second_semantic_projection"),
            AddGraphElementPatch(second_projection),
        ),
        ProjectCommand(
            ProjectId("command.add_second_drawing_projection"),
            AddDrawingRecordPatch(second_drawing_projection),
        ),
    ])

    junction = GraphNode(
        ObjectIdentity(ProjectId("node.bus_tie")),
        electrical_ac_domain(),
        drawing.carriers,
        drawing.provenance;
        nominal_level = drawing.nominal,
    )
    connections = [
        PhysicalConnection(
            ObjectIdentity(ProjectId("connection.bus_HV.tie")),
            drawing.port.identity.id,
            junction.identity.id,
            [CarrierMapping(carrier, carrier) for carrier in drawing.carriers],
            drawing.provenance,
        ),
        PhysicalConnection(
            ObjectIdentity(ProjectId("connection.bus_MV.tie")),
            placed_port.identity.id,
            junction.identity.id,
            [CarrierMapping(carrier, carrier) for carrier in drawing.carriers],
            drawing.provenance,
        ),
    ]
    routes = [
        DrawingRoute(
            ObjectIdentity(ProjectId("drawing.route.bus_HV.tie")),
            drawing.model_view.identity.id,
            drawing.layer.identity.id,
            [drawing.coordinate("25", "25"), drawing.coordinate("40", "30")],
            drawing.provenance;
            semantic_connection = connections[1].identity.id,
        ),
        DrawingRoute(
            ObjectIdentity(ProjectId("drawing.route.bus_MV.tie")),
            drawing.model_view.identity.id,
            drawing.layer.identity.id,
            [drawing.coordinate("60", "30"), drawing.coordinate("40", "30")],
            drawing.provenance;
            semantic_connection = connections[2].identity.id,
        ),
    ]
    conductor = plan_typed_conductor(
        multi_view,
        ProjectId("action.connect_typed_ports"),
        junction,
        connections,
        routes,
    )
    connected = replay_commands(multi_view, collect(conductor.commands))
    @test issubset(
        Set([drawing.port.identity.id, placed_port.identity.id]),
        Set(getfield.(connected.graphs.physical_connections, :port)),
    )

    moved_route = DrawingRoute(
        routes[2].identity,
        routes[2].view,
        routes[2].layer,
        [
            drawing.coordinate("60", "30"),
            drawing.coordinate("50", "35"),
            drawing.coordinate("40", "30"),
        ],
        drawing.provenance;
        semantic_connection = routes[2].semantic_connection,
    )
    route_edit = plan_conductor_route_edit(
        connected,
        ProjectId("action.edit_conductor_route"),
        moved_route,
    )
    rerouted = replay_commands(connected, collect(route_edit.commands))
    @test project_physics_hash(rerouted) == project_physics_hash(connected)

    label = DrawingLabel(
        ObjectIdentity(ProjectId("drawing.label.bus_MV.reference")),
        drawing.model_view.identity.id,
        drawing.layer.identity.id,
        drawing.coordinate("62", "32"),
        "MV BUS",
        drawing.provenance;
        bound_owner = placed_asset.identity.id,
        bound_field = "name",
    )
    label_plan = plan_cross_reference_label(
        rerouted,
        ProjectId("action.bind_cross_reference"),
        label,
    )
    labelled = replay_commands(rerouted, collect(label_plan.commands))
    @test drawing_record(labelled.drawings, label.identity.id) == label

    deletion = plan_physical_asset_deletion(
        labelled,
        ProjectId("action.delete_physical_asset"),
        placed_asset.identity.id,
    )
    @test deletion.physical_topology_changed
    @test placed_asset.identity.id in deletion.changed_owners
    deleted = replay_commands(labelled, collect(deletion.commands))
    @test all(asset -> asset.identity.id != placed_asset.identity.id, deleted.asset_library.assets)
    @test all(port -> port.owner != placed_asset.identity.id, deleted.graphs.ports)
    @test all(
        projection -> projection.semantic_owner != placed_asset.identity.id,
        deleted.graphs.view_projections,
    )

    wrong_route = DrawingRoute(
        routes[1].identity,
        routes[1].view,
        routes[1].layer,
        collect(routes[1].points),
        drawing.provenance;
        semantic_connection = drawing.connection.identity.id,
    )
    @test semantic_error_code(() -> plan_typed_conductor(
        multi_view,
        ProjectId("action.reject_geometry_inference"),
        junction,
        connections,
        [wrong_route, routes[2]],
    )) == :conductor_route_mismatch
end

record_project_conformance!(:semantic_sld_editing)
