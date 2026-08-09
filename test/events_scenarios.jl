function event_scenario_fixture()
    asset = asset_fixture()
    control = control_fixture()
    provenance = asset.provenance
    type(name) = SemanticTypeId(NamespaceId("aimora"), ProjectId(name), v"1.0.0")
    base = CanonicalProject(
        asset.metadata,
        asset.registry,
        asset.units,
        collect(asset.project.records),
        control.graphs,
        asset.project.asset_library,
        HierarchyModel(),
        control.system,
    )
    fault = EventDeclaration(
        ObjectIdentity(ProjectId("event.fault")),
        type("event.electrical_fault"),
        RelativeEventTrigger(control_time("0.1", provenance)),
        100,
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        [CanonicalField("kind", "three_phase_ground")],
        [EventResetDeclaration(
            ObjectIdentity(ProjectId("event.fault.reset_integrator")),
            ProjectReference(
                ReferenceControlBlock,
                control.state_block.identity.id;
                path = ReferencePath("/state/continuous"),
            ),
            EventResetAssign,
            control_voltage("0.0", provenance),
            provenance,
        )],
        EventRollbackRestoreAccepted,
        provenance,
    )
    maintenance = EventDeclaration(
        ObjectIdentity(ProjectId("event.maintenance")),
        type("event.maintenance"),
        AbsoluteEventTrigger(DateTime(2026, 8, 10, 1, 0, 0)),
        20,
        ProjectReference(ReferenceAsset, ProjectId("bus.MV")),
        CanonicalField[],
        EventResetDeclaration[],
        EventRollbackReplayDeterministically,
        provenance,
    )
    sampled = EventDeclaration(
        ObjectIdentity(ProjectId("event.sampled_trip")),
        type("event.sampled_trip"),
        SampledEventTrigger(
            ProjectReference(ReferenceControlBlock, control.network.identity.id),
            42,
        ),
        30,
        ProjectReference(ReferenceControlBlock, control.state_block.identity.id),
        CanonicalField[],
        EventResetDeclaration[],
        EventRollbackRestoreAccepted,
        provenance,
    )
    condition = EventDeclaration(
        ObjectIdentity(ProjectId("event.undervoltage")),
        type("event.undervoltage"),
        ConditionEventTrigger(
            type("surface.bus_voltage"),
            type("quantity.voltage"),
            control_voltage("180.0", provenance),
            control_voltage("2.0", provenance),
            EventFallingDirection,
            4,
        ),
        40,
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        CanonicalField[],
        EventResetDeclaration[],
        EventRollbackRestoreAccepted,
        provenance,
    )
    replacement_emt = StudyRealization(
        asset.emt.id,
        asset.emt.model,
        asset.emt.representation,
        asset.emt.fidelity,
        asset.emt.availability,
        asset.emt.qualification,
        [AssetProperty(
            FieldPath("solver.timestep_limit"),
            asset_quantity("10.0e-6", "s", OrientationScalar, provenance),
            provenance,
        )],
        collect(asset.emt.derived_parameters),
        collect(asset.emt.validity),
        provenance,
    )
    base_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.base")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.base.disable_bus")),
            ScenarioDisable,
            SetAssetCommonPropertyPatch(
                ProjectId("bus.HV"),
                AssetProperty(FieldPath("physical.in_service"), false, provenance),
            ),
            10,
            provenance,
        )],
        provenance,
    )
    peak = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.peak")),
        ProjectReference(ReferenceScenario, base_scenario.identity.id),
        [
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.peak.priority")),
                ScenarioSet,
                SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 25)),
                10,
                provenance,
            ),
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.peak.disable_fault")),
                ScenarioDisable,
                SetEventEnabledPatch(fault.identity.id, false),
                10,
                provenance,
            ),
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.peak.profile")),
                ScenarioReplaceProfile,
                SetAssetCommonPropertyPatch(
                    ProjectId("bus.HV"),
                    AssetProperty(
                        FieldPath("operation.profile"),
                        ProjectReference(ReferenceProfile, asset.profile.identity.id),
                        provenance,
                    ),
                ),
                20,
                provenance,
            ),
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.peak.realization")),
                ScenarioReplaceRealization,
                ReplaceStudyRealizationPatch(ProjectId("bus.HV"), replacement_emt),
                30,
                provenance,
            ),
        ],
        provenance,
    )
    model = EventScenarioModel(
        events = [condition, sampled, maintenance, fault],
        scenarios = [peak, base_scenario],
    )
    project = CanonicalProject(
        base.metadata,
        base.registry,
        base.units,
        collect(base.records),
        base.graphs,
        base.asset_library,
        base.hierarchy,
        base.control_system,
        model,
    )
    return (;
        asset,
        control,
        provenance,
        type,
        base,
        project,
        model,
        fault,
        maintenance,
        sampled,
        condition,
        base_scenario,
        peak,
        replacement_emt,
    )
end

@testset "public typed event and scenario example" begin
    example_module = Module(:EventScenarioExample, true, true)
    example = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "event_scenario.jl"))
    @test example.project.verification == ProjectVerified
    @test example.resolved.project.verification == ProjectVerified
    @test example.resolved.lineage == CanonicalList{ProjectId}([example.peak.identity.id])
    @test event_declaration(example.project.event_scenarios, example.fault.identity.id) == example.fault
end

@testset "typed event calendars and scenario materialization are deterministic" begin
    fixture = event_scenario_fixture()
    @test validate_event_scenario_model(fixture.project)
    @test [event.identity.id for event in ordered_events(fixture.project)] == [
        fixture.fault.identity.id,
        fixture.maintenance.identity.id,
        fixture.sampled.identity.id,
        fixture.condition.identity.id,
    ]
    resolved = resolve_scenario(fixture.project, fixture.peak.identity.id)
    @test resolved.lineage == CanonicalList{ProjectId}([
        fixture.base_scenario.identity.id,
        fixture.peak.identity.id,
    ])
    @test resolved.project.verification == ProjectVerified
    @test isempty(resolved.project.event_scenarios.scenarios)
    @test event_declaration(resolved.project.event_scenarios, fixture.fault.identity.id).enabled == false
    @test event_declaration(fixture.project.event_scenarios, fixture.fault.identity.id).enabled == true
    @test project_record(resolved.project, ProjectId("bus.HV")).fields[
        findfirst(field -> field.name == "priority", project_record(resolved.project, ProjectId("bus.HV")).fields)
    ].value == BigInt(25)
    resolved_asset = canonical_asset(resolved.project, ProjectId("bus.HV"))
    @test only(property for property in resolved_asset.common if string(property.path) == "physical.in_service").value == false
    @test only(property for property in resolved_asset.common if string(property.path) == "operation.profile").value ==
        ProjectReference(ReferenceProfile, fixture.asset.profile.identity.id)
    @test select_realization(resolved_asset, InstantaneousEMT, SwitchingDetailed) == fixture.replacement_emt
    @test collect(resolved.changed_owners) == [ProjectId("bus.HV"), fixture.fault.identity.id]
    @test length(resolved.invalidations) == 2
    @test resolved.content_hash == scenario_content_hash(fixture.project, fixture.peak.identity.id)
    reordered = EventScenarioModel(
        events = reverse(collect(fixture.model.events)),
        scenarios = reverse(collect(fixture.model.scenarios)),
    )
    equivalent = CanonicalProject(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        reordered,
    )
    @test scenario_content_hash(equivalent, fixture.peak.identity.id) == resolved.content_hash
    changed_base = replay_commands(
        fixture.project,
        [ProjectCommand(
            ProjectId("command.change_base_priority"),
            SetRecordFieldPatch(ProjectId("bus.MV"), CanonicalField("priority", 26)),
        )],
    )
    @test scenario_content_hash(changed_base, fixture.peak.identity.id) != resolved.content_hash
    reenable = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.reenable_fault")),
        ProjectReference(ReferenceScenario, fixture.peak.identity.id),
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.reenable_fault")),
            ScenarioEnable,
            SetEventEnabledPatch(fixture.fault.identity.id, true),
            10,
            fixture.provenance,
        )],
        fixture.provenance,
    )
    enabled_project = CanonicalProject(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(
            events = collect(fixture.model.events),
            scenarios = vcat(collect(fixture.model.scenarios), [reenable]),
        ),
    )
    @test event_declaration(
        resolve_scenario(enabled_project, reenable.identity.id).project.event_scenarios,
        fixture.fault.identity.id,
    ).enabled
end

@testset "event validation rejects invalid timing targets reset contracts and conflicts" begin
    fixture = event_scenario_fixture()
    provenance = fixture.provenance
    bad_relative = EventDeclaration(
        ObjectIdentity(ProjectId("event.bad_relative")),
        fixture.type("event.bad"),
        RelativeEventTrigger(control_time("-0.1", provenance)),
        1,
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        CanonicalField[],
        EventResetDeclaration[],
        EventRollbackRestoreAccepted,
        provenance,
    )
    bad_model = EventScenarioModel(events = [bad_relative])
    bad_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        bad_model,
    )
    @test semantic_error_code(() -> validate_project(bad_project)) == :negative_relative_event_time

    dangling = EventDeclaration(
        ObjectIdentity(ProjectId("event.dangling")),
        fixture.type("event.bad"),
        AbsoluteEventTrigger(DateTime(2026, 8, 10)),
        1,
        ProjectReference(ReferenceAsset, ProjectId("asset.missing")),
        CanonicalField[],
        EventResetDeclaration[],
        EventRollbackRestoreAccepted,
        provenance,
    )
    dangling_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(events = [dangling]),
    )
    @test semantic_error_code(() -> validate_project(dangling_project)) == :dangling_event_target
    @test semantic_error_code(() -> EventResetDeclaration(
        ObjectIdentity(ProjectId("reset.bad")),
        ProjectReference(ReferenceControlBlock, fixture.control.state_block.identity.id),
        EventResetAssign,
        nothing,
        provenance,
    )) == :missing_event_reset_value

    conflicting = EventDeclaration(
        ObjectIdentity(ProjectId("event.fault_duplicate")),
        fixture.fault.event_type,
        fixture.fault.trigger,
        fixture.fault.priority,
        fixture.fault.target,
        collect(fixture.fault.parameters),
        EventResetDeclaration[],
        fixture.fault.rollback,
        provenance,
    )
    conflict_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(events = [fixture.fault, conflicting]),
    )
    @test semantic_error_code(() -> validate_project(conflict_project)) == :conflicting_events
end

@testset "scenario graph rejects cycles ambiguity invalid operations units and missing targets" begin
    fixture = event_scenario_fixture()
    provenance = fixture.provenance
    first = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.first")),
        ProjectReference(ReferenceScenario, ProjectId("scenario.second")),
        ScenarioPatchDeclaration[],
        provenance,
    )
    second = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.second")),
        ProjectReference(ReferenceScenario, ProjectId("scenario.first")),
        ScenarioPatchDeclaration[],
        provenance,
    )
    cycle_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [first, second]),
    )
    @test semantic_error_code(() -> validate_project(cycle_project)) == :scenario_parent_cycle

    ambiguous = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.ambiguous")),
        nothing,
        [
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.ambiguous.first")),
                ScenarioSet,
                SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 20)),
                10,
                provenance,
            ),
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.ambiguous.second")),
                ScenarioSet,
                SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 30)),
                10,
                provenance,
            ),
        ],
        provenance,
    )
    ambiguous_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [ambiguous]),
    )
    @test semantic_error_code(() -> validate_project(ambiguous_project)) == :ambiguous_scenario_precedence

    mismatch = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.mismatch")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.mismatch")),
            ScenarioConnect,
            SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 20)),
            10,
            provenance,
        )],
        provenance,
    )
    mismatch_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [mismatch]),
    )
    @test semantic_error_code(() -> validate_project(mismatch_project)) == :scenario_operation_patch_mismatch

    bad_unit = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.bad_unit")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.bad_unit")),
            ScenarioSet,
            SetRecordFieldPatch(
                ProjectId("bus.HV"),
                CanonicalField("nominal_voltage", control_time("1.0", provenance)),
            ),
            10,
            provenance,
        )],
        provenance,
    )
    bad_unit_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [bad_unit]),
    )
    @test semantic_error_code(() -> validate_project(bad_unit_project)) == :dimension_mismatch

    missing = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.missing")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.missing")),
            ScenarioSet,
            SetRecordFieldPatch(ProjectId("bus.missing"), CanonicalField("priority", 20)),
            10,
            provenance,
        )],
        provenance,
    )
    missing_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [missing]),
    )
    @test semantic_error_code(() -> validate_project(missing_project)) == :unknown_record_id

    runtime = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.runtime")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.runtime")),
            ScenarioSet,
            UnsafeReplaceRecordsPatch(collect(fixture.base.records)),
            10,
            provenance,
        )],
        provenance,
    )
    runtime_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [runtime]),
    )
    @test semantic_error_code(() -> validate_project(runtime_project)) == :scenario_runtime_writeback_prohibited

    nested = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.nested_mutation")),
        nothing,
        ScenarioPatchDeclaration[],
        provenance,
    )
    patch_cycle = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.patch_cycle")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.scenario_graph")),
            ScenarioAdd,
            AddScenarioDefinitionPatch(nested),
            10,
            provenance,
        )],
        provenance,
    )
    patch_cycle_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [patch_cycle]),
    )
    @test semantic_error_code(() -> validate_project(patch_cycle_project)) == :scenario_graph_mutation_prohibited

    ac_domain = electrical_ac_domain()
    phase_a = CarrierIdentity(ac_domain, ProjectId("A"))
    node = GraphNode(
        ObjectIdentity(ProjectId("node.cross_domain")),
        ac_domain,
        [phase_a],
        provenance,
    )
    cross_domain = PhysicalConnection(
        ObjectIdentity(ProjectId("connection.cross_domain")),
        fixture.control.external_input.identity.id,
        node.identity.id,
        [CarrierMapping(phase_a, phase_a)],
        provenance,
    )
    cross_domain_graphs = SemanticGraphs(
        nodes = [node],
        ports = collect(fixture.base.graphs.ports),
        signal_connections = collect(fixture.base.graphs.signal_connections),
    )
    cross_domain_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.cross_domain")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.cross_domain")),
            ScenarioConnect,
            ConnectGraphPatch(cross_domain),
            10,
            provenance,
        )],
        provenance,
    )
    cross_domain_project = unsafe_project(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        cross_domain_graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [cross_domain_scenario]),
    )
    @test semantic_error_code(() -> validate_project(cross_domain_project)) == :signal_port_in_physical_connection
end

@testset "scenario add remove connect disconnect and unset operations use project commands" begin
    fixture = event_scenario_fixture()
    provenance = fixture.provenance
    template = project_record(fixture.base, ProjectId("bus.MV"))
    added_record = CanonicalRecord(
        ObjectIdentity(ProjectId("bus.TEST")),
        template.schema,
        [
            field.name == "id" ? CanonicalField("id", "bus.TEST") : field
            for field in template.fields
        ],
        provenance,
    )
    add_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.add")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.add_record")),
            ScenarioAdd,
            AddRecordPatch(added_record),
            10,
            provenance,
        )],
        provenance,
    )
    remove_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.remove")),
        ProjectReference(ReferenceScenario, add_scenario.identity.id),
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.remove_record")),
            ScenarioRemove,
            RemoveRecordPatch(added_record.identity.id),
            10,
            provenance,
        )],
        provenance,
    )
    add_remove_project = CanonicalProject(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [add_scenario, remove_scenario]),
    )
    @test project_record(resolve_scenario(add_remove_project, add_scenario.identity.id).project, added_record.identity.id) == added_record
    removed = resolve_scenario(add_remove_project, remove_scenario.identity.id)
    @test semantic_error_code(() -> project_record(removed.project, added_record.identity.id)) == :unknown_record_id

    unset_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.unset")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.unset_priority")),
            ScenarioUnset,
            UnsetRecordFieldPatch(ProjectId("bus.HV"), "priority"),
            10,
            provenance,
        )],
        provenance,
    )
    unset_project = CanonicalProject(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(scenarios = [unset_scenario]),
    )
    unset_record = project_record(resolve_scenario(unset_project, unset_scenario.identity.id).project, ProjectId("bus.HV"))
    @test all(field -> field.name != "priority", unset_record.fields)

    graph = graph_fixture()
    disconnected_graphs = SemanticGraphs(
        nodes = collect(graph.graphs.nodes),
        ports = collect(graph.graphs.ports),
        signal_connections = collect(graph.graphs.signal_connections),
        workflow_dependencies = collect(graph.graphs.workflow_dependencies),
        cross_references = collect(graph.graphs.cross_references),
        view_projections = ViewProjection[
            projection for projection in graph.graphs.view_projections
            if projection.semantic_owner != graph.connection.identity.id
        ],
    )
    connect_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.connect")),
        nothing,
        [ScenarioPatchDeclaration(
            ObjectIdentity(ProjectId("patch.connect")),
            ScenarioConnect,
            ConnectGraphPatch(graph.connection),
            10,
            provenance,
        )],
        provenance,
    )
    connect_project = CanonicalProject(
        graph.project.metadata,
        graph.project.registry,
        graph.project.units,
        collect(graph.project.records),
        disconnected_graphs,
        graph.project.asset_library,
        graph.project.hierarchy,
        graph.project.control_system,
        EventScenarioModel(scenarios = [connect_scenario]),
    )
    @test length(resolve_scenario(connect_project, connect_scenario.identity.id).project.graphs.physical_connections) == 1

    disconnect_scenario = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.disconnect")),
        nothing,
        [
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.disconnect")),
                ScenarioDisconnect,
                DisconnectGraphPatch(PhysicalConnectionElement, graph.connection.identity.id),
                10,
                provenance,
            ),
            ScenarioPatchDeclaration(
                ObjectIdentity(ProjectId("patch.disconnect_view")),
                ScenarioRemove,
                RemoveGraphElementPatch(GraphViewProjectionElement, graph.projection.identity.id),
                20,
                provenance,
            ),
        ],
        provenance,
    )
    disconnect_project = CanonicalProject(
        graph.project.metadata,
        graph.project.registry,
        graph.project.units,
        collect(graph.project.records),
        graph.project.graphs,
        graph.project.asset_library,
        graph.project.hierarchy,
        graph.project.control_system,
        EventScenarioModel(scenarios = [disconnect_scenario]),
    )
    @test isempty(resolve_scenario(disconnect_project, disconnect_scenario.identity.id).project.graphs.physical_connections)
end

@testset "event and scenario commands replay undo rollback and preserve accepted source" begin
    fixture = event_scenario_fixture()
    base_revision = initial_revision(
        fixture.base,
        ContentDigest(repeat("a", 64)),
        ContentDigest(repeat("b", 64)),
        transaction_provenance(fixture.asset, "action.event_base", 40),
    )
    transaction = begin_project_transaction(base_revision)
    add_event = ProjectCommand(
        ProjectId("command.add_fault"),
        AddEventDeclarationPatch(fixture.fault),
    )
    apply!(transaction, add_event)
    @test length(transaction.working.event_scenarios.events) == 1
    @test replay_commands(fixture.base, [add_event]) == verified_project(transaction.working)
    @test replay_commands(transaction.working, inverse_commands(fixture.base, [add_event])) == fixture.base
    @test rollback!(transaction) == base_revision
    @test isempty(fixture.base.event_scenarios.events)

    with_event = CanonicalProject(
        fixture.base.metadata,
        fixture.base.registry,
        fixture.base.units,
        collect(fixture.base.records),
        fixture.base.graphs,
        fixture.base.asset_library,
        fixture.base.hierarchy,
        fixture.base.control_system,
        EventScenarioModel(events = [fixture.fault]),
    )
    disable = ProjectCommand(
        ProjectId("command.disable_fault"),
        SetEventEnabledPatch(fixture.fault.identity.id, false),
    )
    disabled = replay_commands(with_event, [disable])
    @test !event_declaration(disabled.event_scenarios, fixture.fault.identity.id).enabled
    @test replay_commands(disabled, inverse_commands(with_event, [disable])) == with_event

    isolated = ScenarioDefinition(
        ObjectIdentity(ProjectId("scenario.isolated")),
        nothing,
        ScenarioPatchDeclaration[],
        fixture.provenance,
    )
    add_scenario = ProjectCommand(
        ProjectId("command.add_isolated_scenario"),
        AddScenarioDefinitionPatch(isolated),
    )
    with_scenario = replay_commands(fixture.project, [add_scenario])
    @test scenario_definition(with_scenario.event_scenarios, isolated.identity.id) == isolated
    @test replay_commands(with_scenario, inverse_commands(fixture.project, [add_scenario])) == fixture.project
    inherited = ScenarioDefinition(
        isolated.identity,
        ProjectReference(ReferenceScenario, fixture.base_scenario.identity.id),
        ScenarioPatchDeclaration[],
        fixture.provenance,
    )
    replace_scenario = ProjectCommand(
        ProjectId("command.replace_isolated_scenario"),
        ReplaceScenarioDefinitionPatch(inherited),
    )
    replaced = replay_commands(with_scenario, [replace_scenario])
    @test scenario_definition(replaced.event_scenarios, isolated.identity.id) == inherited
    @test replay_commands(replaced, inverse_commands(with_scenario, [replace_scenario])) == with_scenario
    @test semantic_error_code(() -> replay_commands(
        fixture.project,
        [ProjectCommand(
            ProjectId("command.remove_parent_scenario"),
            RemoveScenarioDefinitionPatch(fixture.base_scenario.identity.id),
        )],
    )) == :scenario_has_children
end

@testset "event and scenario canonical declarations contain no runtime callbacks or mutable maps" begin
    fixture = event_scenario_fixture()
    @test all(type -> !ismutabletype(type), [
        RelativeEventTrigger,
        AbsoluteEventTrigger,
        SampledEventTrigger,
        ConditionEventTrigger,
        EventResetDeclaration,
        EventDeclaration,
        ScenarioPatchDeclaration,
        ScenarioDefinition,
        EventScenarioModel,
        ResolvedScenario,
    ])
    @test all(value -> !(value isa Function) && !(value isa AbstractDict), [
        fixture.fault,
        fixture.condition.trigger,
        fixture.peak,
        resolve_scenario(fixture.project, fixture.peak.identity.id),
    ])
end
