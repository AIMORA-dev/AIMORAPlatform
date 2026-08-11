function graph_fixture()
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    ac = electrical_ac_domain()
    carriers = [CarrierIdentity(ac, ProjectId("carrier.$phase")) for phase in ("A", "B", "C", "N")]
    nominal = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
        provenance,
    )
    node = GraphNode(
        ObjectIdentity(ProjectId("node.HV")),
        ac,
        carriers,
        provenance;
        nominal_level = nominal,
    )
    port = SemanticPort(
        ObjectIdentity(ProjectId("port.bus_HV")),
        ProjectId("bus.HV"),
        ac,
        PortBidirectional,
        carriers,
        provenance;
        nominal_level = nominal,
    )
    connection = PhysicalConnection(
        ObjectIdentity(ProjectId("connection.bus_HV")),
        port.identity.id,
        node.identity.id,
        [CarrierMapping(carrier, carrier) for carrier in carriers],
        provenance,
    )
    voltage_dimension = lookup_unit(fixture.units, UnitId("V")).dimension
    contract = SignalContract(voltage_dimension, UnitId("V"), OrientationScalar)
    output_port = SemanticPort(
        ObjectIdentity(ProjectId("signal.measurement")),
        ProjectId("bus.HV"),
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    input_port = SemanticPort(
        ObjectIdentity(ProjectId("signal.command")),
        ProjectId("bus.MV"),
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    signal = SignalConnection(
        ObjectIdentity(ProjectId("signal.link")),
        output_port.identity.id,
        input_port.identity.id,
        false,
        provenance,
    )
    workflow = WorkflowDependency(
        ObjectIdentity(ProjectId("workflow.dependency")),
        ProjectId("bus.HV"),
        ProjectId("bus.MV"),
        provenance,
    )
    event_target = CrossGraphReference(
        ObjectIdentity(ProjectId("reference.event_target")),
        EventTargetReference,
        ProjectId("bus.HV"),
        ProjectReference(ReferenceNode, node.identity.id),
        provenance,
    )
    projection = ViewProjection(
        ObjectIdentity(ProjectId("projection.bus_HV")),
        ProjectId("bus.MV"),
        connection.identity.id,
        provenance,
    )
    graphs = SemanticGraphs(;
        nodes = [node],
        ports = [port, output_port, input_port],
        physical_connections = [connection],
        signal_connections = [signal],
        workflow_dependencies = [workflow],
        cross_references = [event_target],
        view_projections = [projection],
    )
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        graphs,
    )
    return (; fixture..., project, graphs, node, port, connection, output_port, input_port, signal, workflow, event_target, projection, carriers, nominal)
end

@testset "public semantic graph example" begin
    example_module = Module(:SemanticGraphExample, true, true)
    revision = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "semantic_graphs.jl"))
    @test revision.project.verification == ProjectVerified
    @test length(revision.project.graphs.nodes) == 1
    @test length(revision.project.graphs.ports) == 1
    @test length(revision.project.graphs.physical_connections) == 1
end

@testset "typed physical signal workflow event and view graphs" begin
    graph = graph_fixture()
    @test validate_graphs(graph.project)
    @test graph.project.verification == ProjectVerified
    @test graph.node.domain == electrical_ac_domain()
    @test length(graph.node.carriers) == 4
    @test graph.port.owner == ProjectId("bus.HV")
    @test graph.signal.source_port == ProjectId("signal.measurement")
    @test graph.event_target.target.kind == ReferenceNode
    @test graph.projection.semantic_owner == graph.connection.identity.id
    @test electrical_dc_domain().family == PhysicalGraph
    @test grounding_domain().family == PhysicalGraph
    @test mechanical_rotational_domain().family == PhysicalGraph
    @test mechanical_translational_domain().family == PhysicalGraph
    @test thermal_domain().family == PhysicalGraph
    @test event_domain().family == EventGraph
    @test study_result_domain().family == StudyResultGraph
    @test workflow_domain().family == WorkflowGraph
    @test view_domain().family == ViewGraph
end

@testset "multidomain terminal shapes are explicit and independent" begin
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    ac = electrical_ac_domain()
    dc = electrical_dc_domain()
    earth = grounding_domain()
    carriers(domain, names) = [CarrierIdentity(domain, ProjectId("carrier.$name")) for name in names]
    split = carriers(ac, ("L1", "L2", "N"))
    three_phase = carriers(ac, ("A", "B", "C"))
    bipolar = carriers(dc, ("positive", "negative"))
    protective_earth = carriers(earth, ("PE",))
    ports = [
        SemanticPort(ObjectIdentity(ProjectId("port.split_phase")), ProjectId("bus.HV"), ac, PortBidirectional, split, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.breaker_source")), ProjectId("bus.HV"), ac, PortBidirectional, three_phase, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.breaker_load")), ProjectId("bus.HV"), ac, PortBidirectional, three_phase, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.transformer_hv")), ProjectId("bus.HV"), ac, PortBidirectional, three_phase, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.transformer_lv")), ProjectId("bus.HV"), ac, PortBidirectional, three_phase, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.converter_ac")), ProjectId("bus.MV"), ac, PortBidirectional, three_phase, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.converter_dc")), ProjectId("bus.MV"), dc, PortBidirectional, bipolar, provenance),
        SemanticPort(ObjectIdentity(ProjectId("port.converter_earth")), ProjectId("bus.MV"), earth, PortBidirectional, protective_earth, provenance),
    ]
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        SemanticGraphs(ports = ports),
    )
    @test validate_graphs(project)
    @test length(project.graphs.ports) == 8
    @test length(project.graphs.ports[1].carriers) in (1, 2, 3)
    @test count(port -> port.domain == ac, project.graphs.ports) == 6
    @test count(port -> port.domain == dc, project.graphs.ports) == 1
    @test count(port -> port.domain == earth, project.graphs.ports) == 1
end

@testset "graph compatibility dangling references and cycles reject" begin
    graph = graph_fixture()
    dc = electrical_dc_domain()
    dc_carrier = CarrierIdentity(dc, ProjectId("carrier.positive"))
    dc_node = GraphNode(ObjectIdentity(ProjectId("node.DC")), dc, [dc_carrier], graph.provenance)
    mismatched = PhysicalConnection(
        ObjectIdentity(ProjectId("connection.mismatch")),
        graph.port.identity.id,
        dc_node.identity.id,
        [CarrierMapping(graph.carriers[1], dc_carrier)],
        graph.provenance,
    )
    invalid_domain = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(;
            nodes = [dc_node],
            ports = [graph.port],
            physical_connections = [mismatched],
        ),
    )
    @test semantic_error_code(() -> validate_project(invalid_domain)) == :physical_domain_mismatch
    incomplete = PhysicalConnection(
        ObjectIdentity(ProjectId("connection.incomplete")),
        graph.port.identity.id,
        graph.node.identity.id,
        [CarrierMapping(graph.carriers[1], graph.carriers[1])],
        graph.provenance,
    )
    incomplete_project = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(nodes = [graph.node], ports = [graph.port], physical_connections = [incomplete]),
    )
    @test semantic_error_code(() -> validate_project(incomplete_project)) == :incomplete_port_carrier_map
    dangling_port = SemanticPort(
        ObjectIdentity(ProjectId("port.dangling")),
        ProjectId("asset.missing"),
        electrical_ac_domain(),
        PortBidirectional,
        graph.carriers,
        graph.provenance,
    )
    dangling_project = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(ports = [dangling_port]),
    )
    @test semantic_error_code(() -> validate_project(dangling_project)) == :dangling_port_owner

    bad_level = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("11.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
        graph.provenance,
    )
    bad_port = SemanticPort(
        ObjectIdentity(ProjectId("port.bad_level")),
        ProjectId("bus.HV"),
        electrical_ac_domain(),
        PortBidirectional,
        graph.carriers,
        graph.provenance;
        nominal_level = bad_level,
    )
    bad_connection = PhysicalConnection(
        ObjectIdentity(ProjectId("connection.bad_level")),
        bad_port.identity.id,
        graph.node.identity.id,
        [CarrierMapping(carrier, carrier) for carrier in graph.carriers],
        graph.provenance,
    )
    invalid_level = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(nodes = [graph.node], ports = [bad_port], physical_connections = [bad_connection]),
    )
    @test semantic_error_code(() -> validate_project(invalid_level)) == :nominal_level_mismatch

    reverse_signal = SignalConnection(
        ObjectIdentity(ProjectId("signal.reverse")),
        graph.input_port.identity.id,
        graph.output_port.identity.id,
        false,
        graph.provenance,
    )
    invalid_signal = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(ports = [graph.output_port, graph.input_port], signal_connections = [reverse_signal]),
    )
    @test semantic_error_code(() -> validate_project(invalid_signal)) == :invalid_signal_direction
    wrong_contract_port = SemanticPort(
        ObjectIdentity(ProjectId("signal.wrong_unit")),
        ProjectId("bus.MV"),
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        graph.provenance;
        signal_contract = SignalContract(
            lookup_unit(graph.units, UnitId("V")).dimension,
            UnitId("A"),
            OrientationScalar,
        ),
    )
    wrong_unit_project = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(ports = [wrong_contract_port]),
    )
    @test semantic_error_code(() -> validate_project(wrong_unit_project)) == :signal_unit_dimension_mismatch
    kilovolt_input = SemanticPort(
        ObjectIdentity(ProjectId("signal.kilovolt_input")),
        ProjectId("bus.MV"),
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        graph.provenance;
        signal_contract = SignalContract(
            lookup_unit(graph.units, UnitId("kV")).dimension,
            UnitId("kV"),
            OrientationScalar,
        ),
    )
    unit_mismatch_link = SignalConnection(
        ObjectIdentity(ProjectId("signal.unit_mismatch")),
        graph.output_port.identity.id,
        kilovolt_input.identity.id,
        false,
        graph.provenance,
    )
    unit_mismatch_project = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(ports = [graph.output_port, kilovolt_input], signal_connections = [unit_mismatch_link]),
    )
    @test semantic_error_code(() -> validate_project(unit_mismatch_project)) == :signal_contract_mismatch

    feedback_output = SemanticPort(
        ObjectIdentity(ProjectId("signal.feedback_output")),
        ProjectId("bus.MV"),
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        graph.provenance;
        signal_contract = graph.output_port.signal_contract,
    )
    feedback_input = SemanticPort(
        ObjectIdentity(ProjectId("signal.feedback_input")),
        ProjectId("bus.HV"),
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        graph.provenance;
        signal_contract = graph.output_port.signal_contract,
    )
    feedback = SignalConnection(
        ObjectIdentity(ProjectId("signal.feedback")),
        feedback_output.identity.id,
        feedback_input.identity.id,
        false,
        graph.provenance,
    )
    cyclic_signal = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(
            ports = [graph.output_port, graph.input_port, feedback_output, feedback_input],
            signal_connections = [graph.signal, feedback],
        ),
    )
    @test semantic_error_code(() -> validate_project(cyclic_signal)) == :algebraic_signal_cycle
    delayed_feedback = SignalConnection(
        feedback.identity,
        feedback.source_port,
        feedback.target_port,
        true,
        feedback.provenance,
    )
    delayed_signal = CanonicalProject(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(
            ports = [graph.output_port, graph.input_port, feedback_output, feedback_input],
            signal_connections = [graph.signal, delayed_feedback],
        ),
    )
    @test validate_project(delayed_signal)

    workflow_cycle = WorkflowDependency(
        ObjectIdentity(ProjectId("workflow.reverse")),
        ProjectId("bus.MV"),
        ProjectId("bus.HV"),
        graph.provenance,
    )
    cyclic_workflow = unsafe_project(
        graph.metadata,
        graph.registry,
        graph.units,
        collect(graph.project.records),
        SemanticGraphs(workflow_dependencies = [graph.workflow, workflow_cycle]),
    )
    @test semantic_error_code(() -> validate_project(cyclic_workflow)) == :workflow_cycle
end

@testset "graph commands replay undo and preserve physical-view separation" begin
    graph = graph_fixture()
    base = initial_revision(
        graph.project,
        ContentDigest(repeat("5", 64)),
        ContentDigest(repeat("6", 64)),
        transaction_provenance(graph, "action.graph_base", 11),
    )
    transaction = begin_project_transaction(base)
    command = ProjectCommand(
        ProjectId("command.remove_projection"),
        RemoveGraphElementPatch(GraphViewProjectionElement, graph.projection.identity.id),
    )
    apply!(transaction, command)
    revision = commit!(
        transaction,
        base,
        ContentDigest(repeat("7", 64)),
        ContentDigest(repeat("8", 64)),
        transaction_provenance(graph, "action.remove_projection", 12),
    )
    @test isempty(revision.project.graphs.view_projections)
    @test revision.project.graphs.physical_connections == graph.project.graphs.physical_connections
    @test collect(revision.invalidations[1].scopes) == [InvalidateViews]
    undo = inverse_commands(graph.project, [command])
    @test replay_commands(revision.project, undo).graphs == graph.project.graphs

    dangling = begin_project_transaction(base)
    apply!(dangling, ProjectCommand(
        ProjectId("command.remove_node"),
        RemoveGraphElementPatch(GraphNodeElement, graph.node.identity.id),
    ))
    @test semantic_error_code(() -> validate!(dangling)) == :unknown_graph_node
    @test rollback!(dangling) === base

    empty_base = graph.revision
    build_commands = [
        ProjectCommand(ProjectId("command.add_node"), AddGraphElementPatch(graph.node)),
        ProjectCommand(ProjectId("command.add_port"), AddGraphElementPatch(graph.port)),
        ProjectCommand(ProjectId("command.connect_physical"), ConnectGraphPatch(graph.connection)),
    ]
    built = replay_commands(empty_base.project, build_commands)
    @test built.graphs.nodes == CanonicalList{GraphNode}([graph.node])
    @test built.graphs.ports == CanonicalList{SemanticPort}([graph.port])
    @test built.graphs.physical_connections == CanonicalList{PhysicalConnection}([graph.connection])
    restored_empty = replay_commands(built, inverse_commands(empty_base.project, build_commands))
    @test restored_empty.graphs == empty_base.project.graphs

    delete_asset = begin_project_transaction(base)
    apply!(delete_asset, ProjectCommand(
        ProjectId("command.remove_asset"),
        RemoveRecordPatch(ProjectId("bus.HV")),
    ))
    @test semantic_error_code(() -> validate!(delete_asset)) == :dangling_port_owner
    @test rollback!(delete_asset) === base
end

record_project_conformance!(:graph_domains_topology)
