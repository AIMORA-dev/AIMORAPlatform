function control_time(value, provenance)
    return PhysicalValue(
        ScalarQuantity(parse_exact_decimal(value), UnitId("s"), OrientationScalar),
        provenance,
    )
end

function control_voltage(value, provenance)
    return PhysicalValue(
        ScalarQuantity(parse_exact_decimal(value), UnitId("V"), OrientationScalar),
        provenance,
    )
end

function control_fixture()
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    voltage_dimension = lookup_unit(fixture.units, UnitId("V")).dimension
    time_dimension = lookup_unit(fixture.units, UnitId("s")).dimension
    voltage_contract = SignalContract(voltage_dimension, UnitId("V"), OrientationScalar)
    input_spec = ControlPortSpec("input", PortInput, voltage_contract)
    output_spec = ControlPortSpec("output", PortOutput, voltage_contract)
    all_domains = [ControlContinuous, ControlDiscrete, ControlSampled, ControlEventDriven, ControlHybrid]
    gain_schema = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("c8646371-e0a0-4b8b-bb97-5ecb0d6788f8"),
            NamespaceId("aimora"),
            ProjectId("control.gain"),
            v"1.0.0",
        ),
        all_domains,
        [SchemaField("gain", SchemaDecimal; required = true)],
        [input_spec, output_spec],
        ControlStateSpec[],
        true,
        provenance,
    )
    state_specs = [
        ControlStateSpec(
            SchemaField("continuous", SchemaQuantity; required = true, constraints = [
                QuantityConstraint(voltage_dimension, [OrientationScalar]),
            ]),
            ContinuousControlState,
        ),
        ControlStateSpec(SchemaField("discrete", SchemaInteger; required = true), DiscreteControlState),
        ControlStateSpec(
            SchemaField("delay", SchemaQuantity; required = true, constraints = [
                QuantityConstraint(time_dimension, [OrientationScalar]),
            ]),
            DelayControlState,
        ),
        ControlStateSpec(SchemaField("sample", SchemaDecimal; required = true), SampleControlState),
        ControlStateSpec(SchemaField("event", SchemaBoolean; required = true), EventControlState),
        ControlStateSpec(SchemaField("limiter", SchemaBoolean; required = true), LimiterControlState),
        ControlStateSpec(
            SchemaField("hold", SchemaQuantity; required = true, constraints = [
                QuantityConstraint(voltage_dimension, [OrientationScalar]),
            ]),
            HoldControlState,
        ),
    ]
    state_schema = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("443f7ab8-5ea0-4676-a2f9-324a89c06e08"),
            NamespaceId("aimora"),
            ProjectId("control.hybrid_state"),
            v"1.0.0",
        ),
        [ControlHybrid],
        SchemaField[],
        [input_spec, output_spec],
        state_specs,
        false,
        provenance,
    )
    network_id = ProjectId("control.speed_regulator")
    external_input = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.external_input")),
        network_id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    external_output = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.external_output")),
        network_id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    gain_id = ProjectId("control.speed_regulator.gain")
    gain_input = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.gain.input")),
        gain_id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    gain_output = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.gain.output")),
        gain_id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    state_id = ProjectId("control.speed_regulator.state")
    state_input = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.state.input")),
        state_id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    state_output = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.state.output")),
        state_id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = voltage_contract,
    )
    states = [
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.continuous")),
            "continuous",
            ContinuousControlState,
            control_voltage("0.0", provenance),
            ResetToInitial,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.discrete")),
            "discrete",
            DiscreteControlState,
            0,
            ResetRetain,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.delay")),
            "delay",
            DelayControlState,
            control_time("0.0", provenance),
            ResetToInitial,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.sample")),
            "sample",
            SampleControlState,
            parse_exact_decimal("0.0"),
            ResetToInitial,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.event")),
            "event",
            EventControlState,
            false,
            ResetFromEventValue,
            RollbackRestoreAccepted,
            CheckpointOptional,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.limiter")),
            "limiter",
            LimiterControlState,
            false,
            ResetRetain,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
        ControlStateDeclaration(
            ObjectIdentity(ProjectId("control.speed_regulator.state.hold")),
            "hold",
            HoldControlState,
            control_voltage("0.0", provenance),
            ResetToInitial,
            RollbackRestoreAccepted,
            CheckpointRequired,
            provenance,
        ),
    ]
    gain = ControlBlock(
        ObjectIdentity(gain_id),
        gain_schema.identity,
        [CanonicalField("gain", parse_exact_decimal("2.0"))],
        [
            ControlPortBinding("input", gain_input.identity.id),
            ControlPortBinding("output", gain_output.identity.id),
        ],
        ControlStateDeclaration[],
        provenance,
    )
    state_block = ControlBlock(
        ObjectIdentity(state_id),
        state_schema.identity,
        CanonicalField[],
        [
            ControlPortBinding("input", state_input.identity.id),
            ControlPortBinding("output", state_output.identity.id),
        ],
        states,
        provenance,
    )
    links = [
        SignalConnection(
            ObjectIdentity(ProjectId("control.speed_regulator.link.reference")),
            external_input.identity.id,
            gain_input.identity.id,
            false,
            provenance,
        ),
        SignalConnection(
            ObjectIdentity(ProjectId("control.speed_regulator.link.gain")),
            gain_output.identity.id,
            state_input.identity.id,
            false,
            provenance,
        ),
        SignalConnection(
            ObjectIdentity(ProjectId("control.speed_regulator.link.command")),
            state_output.identity.id,
            external_output.identity.id,
            false,
            provenance,
        ),
    ]
    import_artifact = ArtifactIdentity(
        ProjectId("artifact.tacs_source"),
        "imports/controller.deck",
        repeat("4", 64),
        "text/plain",
        provenance,
    )
    imported = ControlImportProvenance(
        SemanticTypeId(NamespaceId("aimora"), ProjectId("format.bpa_tacs"), v"1.0.0"),
        import_artifact,
        ["TACS TYPE 11 / CARD 0042"],
        ["legacy sample delay retained explicitly"],
        provenance,
    )
    schedule = ControlSchedule(
        ControlHybrid,
        HybridOrderedExecution,
        [gain_id, state_id];
        sample_time = control_time("0.0001", provenance),
        phase_offset = control_time("0.0", provenance),
        computational_delay = control_time("0.00002", provenance),
    )
    network = ControlNetwork(
        ObjectIdentity(network_id),
        schedule,
        [
            ControlExternalPort("measurement", external_input.identity.id, PortInput),
            ControlExternalPort("command", external_output.identity.id, PortOutput),
        ],
        [gain, state_block],
        ProjectId[link.identity.id for link in links],
        ProjectId[state.identity.id for state in states],
        [
            ControlBoundaryBinding(
                ObjectIdentity(ProjectId("control.speed_regulator.boundary.measurement")),
                ControlMeasurementBinding,
                external_input.identity.id,
                ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
                provenance,
            ),
            ControlBoundaryBinding(
                ObjectIdentity(ProjectId("control.speed_regulator.boundary.actuator")),
                ControlActuatorBinding,
                external_output.identity.id,
                ProjectReference(ReferenceAsset, ProjectId("bus.MV")),
                provenance,
            ),
        ],
        AlgebraicLoopDeclaration[],
        provenance;
        import_provenance = imported,
    )
    empty_networks = [
        ControlNetwork(
            ObjectIdentity(ProjectId("control.continuous_monitor")),
            ControlSchedule(ControlContinuous, ContinuousResidualEvaluation, ProjectId[]),
            ControlExternalPort[],
            ControlBlock[],
            ProjectId[],
            ProjectId[],
            ControlBoundaryBinding[],
            AlgebraicLoopDeclaration[],
            provenance,
        ),
        ControlNetwork(
            ObjectIdentity(ProjectId("control.discrete_monitor")),
            ControlSchedule(
                ControlDiscrete,
                DiscreteEventUpdate,
                ProjectId[];
                sample_time = control_time("0.001", provenance),
                phase_offset = control_time("0.0", provenance),
                computational_delay = control_time("0.0", provenance),
            ),
            ControlExternalPort[],
            ControlBlock[],
            ProjectId[],
            ProjectId[],
            ControlBoundaryBinding[],
            AlgebraicLoopDeclaration[],
            provenance,
        ),
        ControlNetwork(
            ObjectIdentity(ProjectId("control.sampled_monitor")),
            ControlSchedule(
                ControlSampled,
                ReadComputeEnqueueReleaseWriteHold,
                ProjectId[];
                sample_time = control_time("0.0001", provenance),
                phase_offset = control_time("0.0", provenance),
                computational_delay = control_time("0.00002", provenance),
            ),
            ControlExternalPort[],
            ControlBlock[],
            ProjectId[],
            ProjectId[],
            ControlBoundaryBinding[],
            AlgebraicLoopDeclaration[],
            provenance,
        ),
        ControlNetwork(
            ObjectIdentity(ProjectId("control.event_monitor")),
            ControlSchedule(ControlEventDriven, DiscreteEventUpdate, ProjectId[]),
            ControlExternalPort[],
            ControlBlock[],
            ProjectId[],
            ProjectId[],
            ControlBoundaryBinding[],
            AlgebraicLoopDeclaration[],
            provenance,
        ),
    ]
    graphs = SemanticGraphs(
        ports = [external_input, external_output, gain_input, gain_output, state_input, state_output],
        signal_connections = links,
    )
    system = ControlSystem(block_schemas = [gain_schema, state_schema], networks = vcat([network], empty_networks))
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        graphs,
        AssetLibrary(),
        HierarchyModel(),
        system,
    )
    return (;
        fixture...,
        project,
        system,
        network,
        gain_schema,
        state_schema,
        gain,
        state_block,
        states,
        links,
        graphs,
        voltage_contract,
        external_input,
        external_output,
    )
end

function algebraic_control_project(;
    declared = false,
    stateful = false,
    delayed = false,
    delay_metadata = delayed,
)
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    contract = SignalContract(lookup_unit(fixture.units, UnitId("V")).dimension, UnitId("V"), OrientationScalar)
    port_specs = [ControlPortSpec("input", PortInput, contract), ControlPortSpec("output", PortOutput, contract)]
    state_specs = stateful ? [ControlStateSpec(SchemaField("memory", SchemaDecimal; required = true), DelayControlState)] : ControlStateSpec[]
    direct = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("fd1e4e07-ffba-4d4f-8dbb-80a8f4d83c65"),
            NamespaceId("aimora"),
            ProjectId("control.loop_gain"),
            v"1.0.0",
        ),
        [ControlSampled],
        SchemaField[],
        port_specs,
        ControlStateSpec[],
        true,
        provenance,
    )
    memory = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("e94b0a02-92af-46d6-b147-33095c601add"),
            NamespaceId("aimora"),
            ProjectId("control.loop_memory"),
            v"1.0.0",
        ),
        [ControlSampled],
        SchemaField[],
        port_specs,
        state_specs,
        !stateful,
        provenance,
    )
    block_ids = [ProjectId("control.loop.a"), ProjectId("control.loop.b")]
    ports = SemanticPort[]
    blocks = ControlBlock[]
    for (index, id) in pairs(block_ids)
        input = SemanticPort(
            ObjectIdentity(ProjectId("$(id.value).input")), id, signal_domain(), PortInput,
            CarrierIdentity[], provenance; signal_contract = contract,
        )
        output = SemanticPort(
            ObjectIdentity(ProjectId("$(id.value).output")), id, signal_domain(), PortOutput,
            CarrierIdentity[], provenance; signal_contract = contract,
        )
        append!(ports, [input, output])
        states = index == 2 && stateful ? [
            ControlStateDeclaration(
                ObjectIdentity(ProjectId("control.loop.b.memory")),
                "memory",
                DelayControlState,
                parse_exact_decimal("0.0"),
                ResetToInitial,
                RollbackRestoreAccepted,
                CheckpointRequired,
                provenance,
            ),
        ] : ControlStateDeclaration[]
        push!(blocks, ControlBlock(
            ObjectIdentity(id),
            index == 2 ? memory.identity : direct.identity,
            CanonicalField[],
            [ControlPortBinding("input", input.identity.id), ControlPortBinding("output", output.identity.id)],
            states,
            provenance,
        ))
    end
    links = [
        SignalConnection(
            ObjectIdentity(ProjectId("control.loop.link_ab")),
            ProjectId("control.loop.a.output"),
            ProjectId("control.loop.b.input"),
            false,
            provenance,
        ),
        SignalConnection(
            ObjectIdentity(ProjectId("control.loop.link_ba")),
            ProjectId("control.loop.b.output"),
            ProjectId("control.loop.a.input"),
            delayed,
            provenance,
        ),
    ]
    declarations = declared ? [
        AlgebraicLoopDeclaration(
            ObjectIdentity(ProjectId("control.loop.solver")),
            block_ids,
            SemanticTypeId(NamespaceId("aimora"), ProjectId("algebraic_solver.newton"), v"1.0.0"),
            SemanticTypeId(NamespaceId("aimora"), ProjectId("algebraic_residual.control_loop"), v"1.0.0"),
            SemanticTypeId(NamespaceId("aimora"), ProjectId("algebraic_jacobian.control_loop"), v"1.0.0"),
            parse_exact_decimal("1.0e-10"),
            20,
            AlgebraicLoopError,
            provenance,
        ),
    ] : AlgebraicLoopDeclaration[]
    link_delays = delay_metadata ? [
        ControlLinkDelay(
            ProjectId("control.loop.link_ba"),
            control_time("0.0001", provenance),
            ControlStateDeclaration(
                ObjectIdentity(ProjectId("control.loop.link_ba.history")),
                "history",
                DelayControlState,
                control_voltage("0.0", provenance),
                ResetToInitial,
                RollbackRestoreAccepted,
                CheckpointRequired,
                provenance,
            ),
        ),
    ] : ControlLinkDelay[]
    state_ids = stateful ? [ProjectId("control.loop.b.memory")] : ProjectId[]
    append!(state_ids, [delay.state.identity.id for delay in link_delays])
    schedule = ControlSchedule(
        ControlSampled,
        ReadComputeEnqueueReleaseWriteHold,
        block_ids;
        sample_time = control_time("0.0001", provenance),
        phase_offset = control_time("0.0", provenance),
        computational_delay = control_time("0.0", provenance),
    )
    network = ControlNetwork(
        ObjectIdentity(ProjectId("control.loop")),
        schedule,
        ControlExternalPort[],
        blocks,
        ProjectId[link.identity.id for link in links],
        state_ids,
        ControlBoundaryBinding[],
        declarations,
        provenance;
        link_delays = link_delays,
    )
    system = ControlSystem(block_schemas = [direct, memory], networks = [network])
    project = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        SemanticGraphs(ports = ports, signal_connections = links),
        AssetLibrary(),
        HierarchyModel(),
        system,
    )
    return (; fixture..., project, network, system, direct, memory, blocks, ports, links)
end

@testset "public typed control-network example" begin
    example_module = Module(:TypedControlNetworkExample, true, true)
    project = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "control_network.jl"))
    @test project.verification == ProjectVerified
    @test length(project.control_system.networks) == 1
    @test project.control_system.networks[1].schedule.semantics == ReadComputeEnqueueReleaseWriteHold
    @test length(project.control_system.networks[1].blocks[1].states) == 1
end

@testset "typed control networks declare domains schedules boundaries and complete state" begin
    control = control_fixture()
    @test validate_control_system(control.project)
    @test control.project.verification == ProjectVerified
    @test Set(network.schedule.domain for network in control.system.networks) == Set([
        ControlContinuous, ControlDiscrete, ControlSampled, ControlEventDriven, ControlHybrid,
    ])
    @test collect(control.network.schedule.task_order) == [
        ProjectId("control.speed_regulator.gain"),
        ProjectId("control.speed_regulator.state"),
    ]
    @test Set(state.kind for state in control.states) == Set([
        ContinuousControlState,
        DiscreteControlState,
        DelayControlState,
        SampleControlState,
        EventControlState,
        LimiterControlState,
        HoldControlState,
    ])
    @test all(state -> state.rollback == RollbackRestoreAccepted, control.states)
    @test count(state -> state.checkpoint == CheckpointRequired, control.states) == 6
    @test control.network.import_provenance.source_records[1] == "TACS TYPE 11 / CARD 0042"
    @test length(control.network.boundary_bindings) == 2
    @test control_block_schema(control.system, control.gain_schema.identity) == control.gain_schema
    @test control_network(control.system, control.network.identity.id) == control.network
    @test control_block(control.network, control.gain.identity.id) == control.gain
end

@testset "general multirate task declarations own exact families resources effects and precedence" begin
    control = control_fixture()
    task_ids = ProjectId[
        ProjectId("task.protection"),
        ProjectId("task.carrier"),
        ProjectId("task.converter_control"),
        ProjectId("task.mechanical"),
        ProjectId("task.source"),
        ProjectId("task.thermal"),
        ProjectId("task.interface"),
        ProjectId("task.user_defined"),
    ]
    families = ControlTaskFamily[
        ProtectionControlTask,
        CarrierControlTask,
        ConverterControlTask,
        MechanicalControlTask,
        SourceControlTask,
        ThermalControlTask,
        InterfaceControlTask,
        UserDefinedControlTask,
    ]
    declarations = ControlTaskDeclaration[
        ControlTaskDeclaration(
            task_ids[index],
            families[index],
            control_time("0.0", control.provenance),
            control_time(string(index, "e-6"), control.provenance),
            control_time("0.0", control.provenance),
            control_time("0.0", control.provenance);
            priority = index - 4,
            read_resources = [ProjectId("resource.input.item_$index")],
            write_resources = [ProjectId("resource.output.item_$index")],
            invalidations = index == 1 ?
                [InvalidateControlPowerHistory, InvalidateControlOutput] :
                ControlTaskInvalidation[],
        ) for index in eachindex(task_ids)
    ]
    schedule = ControlSchedule(
        ControlHybrid,
        HybridOrderedExecution,
        task_ids;
        sample_time = control_time("0.000001", control.provenance),
        phase_offset = control_time("0.0", control.provenance),
        computational_delay = control_time("0.0", control.provenance),
        task_declarations = declarations,
    )
    @test AIMORAProject._validate_control_schedule(control.project, schedule)
    @test collect(schedule.task_declarations) == declarations
    @test Set(declaration.family for declaration in schedule.task_declarations) == Set(families)
    @test collect(schedule.task_declarations[1].invalidations) == [
        InvalidateControlPowerHistory,
        InvalidateControlOutput,
    ]

    shared = ProjectId("resource.shared_command")
    writer = ControlTaskDeclaration(
        ProjectId("task.writer"),
        ConverterControlTask,
        control_time("0.0", control.provenance),
        control_time("0.00001", control.provenance),
        control_time("0.0", control.provenance),
        control_time("0.000002", control.provenance);
        write_resources = [shared],
    )
    reader = ControlTaskDeclaration(
        ProjectId("task.reader"),
        ProtectionControlTask,
        control_time("0.0", control.provenance),
        control_time("0.00002", control.provenance),
        control_time("0.0", control.provenance),
        control_time("0.0", control.provenance);
        read_resources = [shared],
        predecessors = [writer.task],
    )
    ordered = ControlSchedule(
        ControlHybrid,
        HybridOrderedExecution,
        [writer.task, reader.task];
        sample_time = control_time("0.00001", control.provenance),
        phase_offset = control_time("0.0", control.provenance),
        computational_delay = control_time("0.0", control.provenance),
        task_declarations = [writer, reader],
    )
    @test AIMORAProject._validate_control_schedule(control.project, ordered)

    unordered_reader = ControlTaskDeclaration(
        reader.task,
        reader.family,
        reader.epoch,
        reader.period,
        reader.phase,
        reader.computational_delay;
        read_resources = collect(reader.read_resources),
    )
    unordered = ControlSchedule(
        ordered.domain,
        ordered.semantics,
        collect(ordered.task_order);
        sample_time = ordered.sample_time,
        phase_offset = ordered.phase_offset,
        computational_delay = ordered.computational_delay,
        task_declarations = [writer, unordered_reader],
    )
    @test semantic_error_code(() -> AIMORAProject._validate_control_schedule(
        control.project,
        unordered,
    )) == :unordered_control_task_resource_conflict

    cyclic_writer = ControlTaskDeclaration(
        writer.task,
        writer.family,
        writer.epoch,
        writer.period,
        writer.phase,
        writer.computational_delay;
        write_resources = collect(writer.write_resources),
        predecessors = [reader.task],
    )
    cyclic = ControlSchedule(
        ordered.domain,
        ordered.semantics,
        collect(ordered.task_order);
        sample_time = ordered.sample_time,
        phase_offset = ordered.phase_offset,
        computational_delay = ordered.computational_delay,
        task_declarations = [cyclic_writer, reader],
    )
    @test semantic_error_code(() -> AIMORAProject._validate_control_schedule(
        control.project,
        cyclic,
    )) == :cyclic_control_task_dependencies
end

@testset "control validation rejects schedule contract state and physical-signal ambiguity" begin
    control = control_fixture()
    wrong_schedule = ControlSchedule(
        ControlSampled,
        ContinuousResidualEvaluation,
        ProjectId[];
        sample_time = control_time("0.001", control.provenance),
        phase_offset = control_time("0.0", control.provenance),
        computational_delay = control_time("0.0", control.provenance),
    )
    empty = ControlNetwork(
        ObjectIdentity(ProjectId("control.wrong_schedule")),
        wrong_schedule,
        ControlExternalPort[],
        ControlBlock[],
        ProjectId[],
        ProjectId[],
        ControlBoundaryBinding[],
        AlgebraicLoopDeclaration[],
        control.provenance,
    )
    wrong_system = ControlSystem(
        block_schemas = collect(control.system.block_schemas),
        networks = vcat(collect(control.system.networks), [empty]),
    )
    wrong_project = unsafe_project(
        control.metadata,
        control.registry,
        control.units,
        collect(control.project.records),
        control.graphs,
        AssetLibrary(),
        HierarchyModel(),
        wrong_system,
    )
    @test semantic_error_code(() -> validate_project(wrong_project)) == :control_scheduler_semantics_mismatch
    @test semantic_error_code(() -> ControlSchedule(
        ControlSampled,
        ReadComputeEnqueueReleaseWriteHold,
        [ProjectId("control.duplicate"), ProjectId("control.duplicate")];
        sample_time = control_time("0.001", control.provenance),
        phase_offset = control_time("0.0", control.provenance),
        computational_delay = control_time("0.0", control.provenance),
    )) == :duplicate_control_task

    incomplete_block = ControlBlock(
        control.state_block.identity,
        control.state_block.schema,
        collect(control.state_block.parameters),
        collect(control.state_block.ports),
        collect(control.state_block.states)[1:end-1],
        control.state_block.provenance,
    )
    blocks = [control.gain, incomplete_block]
    incomplete_network = ControlNetwork(
        control.network.identity,
        control.network.schedule,
        collect(control.network.external_ports),
        blocks,
        collect(control.network.links),
        ProjectId[state.identity.id for block in blocks for state in block.states],
        collect(control.network.boundary_bindings),
        collect(control.network.algebraic_loops),
        control.network.provenance;
        import_provenance = control.network.import_provenance,
    )
    incomplete_system = ControlSystem(
        block_schemas = collect(control.system.block_schemas),
        networks = [
            network.identity.id == control.network.identity.id ? incomplete_network : network
            for network in control.system.networks
        ],
    )
    incomplete_project = unsafe_project(
        control.metadata,
        control.registry,
        control.units,
        collect(control.project.records),
        control.graphs,
        AssetLibrary(),
        HierarchyModel(),
        incomplete_system,
    )
    @test semantic_error_code(() -> validate_project(incomplete_project)) == :incomplete_control_state_inventory

    incomplete_schedule = ControlSchedule(
        control.network.schedule.domain,
        control.network.schedule.semantics,
        [control.gain.identity.id];
        sample_time = control.network.schedule.sample_time,
        phase_offset = control.network.schedule.phase_offset,
        computational_delay = control.network.schedule.computational_delay,
    )
    incomplete_task_network = ControlNetwork(
        control.network.identity,
        incomplete_schedule,
        collect(control.network.external_ports),
        collect(control.network.blocks),
        collect(control.network.links),
        collect(control.network.initialization_order),
        collect(control.network.boundary_bindings),
        collect(control.network.algebraic_loops),
        control.network.provenance;
        import_provenance = control.network.import_provenance,
    )
    incomplete_task_system = ControlSystem(
        block_schemas = collect(control.system.block_schemas),
        networks = [
            network.identity.id == control.network.identity.id ? incomplete_task_network : network
            for network in control.system.networks
        ],
    )
    incomplete_task_project = unsafe_project(
        control.metadata,
        control.registry,
        control.units,
        collect(control.project.records),
        control.graphs,
        AssetLibrary(),
        HierarchyModel(),
        incomplete_task_system,
    )
    @test semantic_error_code(() -> validate_project(incomplete_task_project)) == :incomplete_control_task_order

    physical = SemanticPort(
        ObjectIdentity(ProjectId("control.speed_regulator.physical")),
        control.network.identity.id,
        electrical_ac_domain(),
        PortBidirectional,
        [CarrierIdentity(electrical_ac_domain(), ProjectId("carrier.A"))],
        control.provenance,
    )
    bad_external = ControlNetwork(
        control.network.identity,
        control.network.schedule,
        [
            ControlExternalPort("measurement", physical.identity.id, PortInput),
            control.network.external_ports[1],
        ],
        collect(control.network.blocks),
        collect(control.network.links),
        collect(control.network.initialization_order),
        collect(control.network.boundary_bindings),
        collect(control.network.algebraic_loops),
        control.network.provenance;
        import_provenance = control.network.import_provenance,
    )
    bad_graphs = SemanticGraphs(
        ports = vcat(collect(control.graphs.ports), [physical]),
        signal_connections = collect(control.graphs.signal_connections),
    )
    bad_system = ControlSystem(
        block_schemas = collect(control.system.block_schemas),
        networks = [
            network.identity.id == control.network.identity.id ? bad_external : network
            for network in control.system.networks
        ],
    )
    bad_project = unsafe_project(
        control.metadata,
        control.registry,
        control.units,
        collect(control.project.records),
        bad_graphs,
        AssetLibrary(),
        HierarchyModel(),
        bad_system,
    )
    @test semantic_error_code(() -> validate_project(bad_project)) == :physical_control_external_port
end

@testset "state and delayed cycles pass while pure algebraic loops require full declarations" begin
    pure = algebraic_control_project()
    @test semantic_error_code(() -> validate_project(pure.project)) == :algebraic_signal_cycle
    declared = algebraic_control_project(declared = true)
    @test validate_project(declared.project)
    stateful = algebraic_control_project(stateful = true)
    @test validate_project(stateful.project)
    delayed = algebraic_control_project(delayed = true)
    @test validate_project(delayed.project)
    undeclared_delay = algebraic_control_project(delayed = true, delay_metadata = false)
    @test semantic_error_code(() -> validate_project(undeclared_delay.project)) == :incomplete_control_link_delay
    @test semantic_error_code(() -> AlgebraicLoopDeclaration(
        ObjectIdentity(ProjectId("control.loop.invalid_tolerance")),
        [ProjectId("control.loop.a"), ProjectId("control.loop.b")],
        SemanticTypeId(NamespaceId("aimora"), ProjectId("solver.newton"), v"1.0.0"),
        SemanticTypeId(NamespaceId("aimora"), ProjectId("residual.loop"), v"1.0.0"),
        SemanticTypeId(NamespaceId("aimora"), ProjectId("jacobian.loop"), v"1.0.0"),
        parse_exact_decimal("0.0"),
        20,
        AlgebraicLoopError,
        pure.provenance,
    )) == :invalid_algebraic_loop_tolerance
end

@testset "reusable subsystem expansion namespaces independent control state and signal owners" begin
    template_module = Module(:ReusableControlTemplate, true, true)
    template = Base.include(template_module, joinpath(@__DIR__, "..", "examples", "control_network.jl"))
    fixture = canonical_project_fixture(two_records = true)
    definition_id = ProjectId("definition.sample_hold")
    definition = ReusableDefinition(
        ObjectIdentity(definition_id),
        SemanticTypeId(NamespaceId("aimora"), definition_id, v"1.0.0"),
        DefinitionParameterSpec[],
        DefinitionExternalPort[],
        DefinitionRecord[],
        CanonicalAsset[],
        template.graphs,
        DefinitionParameterBinding[],
        DefinitionInstance[],
        fixture.provenance;
        controls = template.control_system,
    )
    definition_reference = ProjectReference(ReferenceDefinition, definition_id)
    instances = [
        DefinitionInstance(
            ObjectIdentity(ProjectId("subsystem.first")),
            definition_reference,
            v"1.0.0",
            InstanceParameterValue[],
            InstancePortBinding[],
            fixture.provenance,
        ),
        DefinitionInstance(
            ObjectIdentity(ProjectId("subsystem.second")),
            definition_reference,
            v"1.0.0",
            InstanceParameterValue[],
            InstancePortBinding[],
            fixture.provenance,
        ),
    ]
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        SemanticGraphs(),
        AssetLibrary(),
        HierarchyModel(definitions = [definition], instances = instances),
    )
    first = expand_instance(project, instances[1])
    second = expand_instance(project, instances[2])
    @test first.controls.networks[1].identity.id == ProjectId("subsystem.first.control.sample_hold")
    @test second.controls.networks[1].identity.id == ProjectId("subsystem.second.control.sample_hold")
    @test first.controls.networks[1].blocks[1].states[1].identity.id ==
        ProjectId("subsystem.first.control.sample_hold.hold.held_value")
    @test first.controls.networks[1] != second.controls.networks[1]
    @test Set(item.expanded_owner for item in first.identities) !=
        Set(item.expanded_owner for item in second.identities)
end

@testset "control commands replay undo rollback and invalidate exact downstream owners" begin
    control = control_fixture()
    base = initial_revision(
        control.project,
        ContentDigest(repeat("5", 64)),
        ContentDigest(repeat("6", 64)),
        transaction_provenance(control, "action.control_base", 30),
    )
    additional = ControlNetwork(
        ObjectIdentity(ProjectId("control.additional_monitor")),
        ControlSchedule(ControlContinuous, ContinuousResidualEvaluation, ProjectId[]),
        ControlExternalPort[],
        ControlBlock[],
        ProjectId[],
        ProjectId[],
        ControlBoundaryBinding[],
        AlgebraicLoopDeclaration[],
        control.provenance,
    )
    command = ProjectCommand(ProjectId("command.add_control_network"), AddControlNetworkPatch(additional))
    transaction = begin_project_transaction(base)
    apply!(transaction, command)
    validate!(transaction)
    committed = commit!(
        transaction,
        base,
        ContentDigest(repeat("7", 64)),
        ContentDigest(repeat("8", 64)),
        transaction_provenance(control, "action.add_control_network", 31),
    )
    @test control_network(committed.project.control_system, additional.identity.id) == additional
    @test committed.changed_owners == CanonicalList{ProjectId}([additional.identity.id])
    @test Set(committed.invalidations[1].scopes) == Set([
        InvalidateStudyResults,
        InvalidateWorkflowResults,
        InvalidateViews,
    ])
    undo = inverse_commands(base.project, [command])
    @test replay_commands(committed.project, undo) == base.project
    @test replay_commands(base.project, [command]) == committed.project
    rolled_back = begin_project_transaction(base)
    apply!(rolled_back, command)
    @test rollback!(rolled_back) == base
    @test rolled_back.working == base.project
    @test rolled_back.state == TransactionRolledBack

    diagnostic_schema = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("ff705167-1d60-4c36-abfa-8dbb4b5bd735"),
            NamespaceId("aimora"),
            ProjectId("control.diagnostic_source"),
            v"1.0.0",
        ),
        [ControlContinuous],
        SchemaField[],
        ControlPortSpec[],
        ControlStateSpec[],
        true,
        control.provenance,
    )
    add_schema = ProjectCommand(
        ProjectId("command.add_control_schema"),
        AddControlBlockSchemaPatch(diagnostic_schema),
    )
    with_schema = replay_commands(base.project, [add_schema])
    @test control_block_schema(with_schema.control_system, diagnostic_schema.identity) == diagnostic_schema
    @test replay_commands(with_schema, inverse_commands(base.project, [add_schema])) == base.project
    revised_schedule = ControlSchedule(
        control.network.schedule.domain,
        control.network.schedule.semantics,
        collect(control.network.schedule.task_order);
        sample_time = control.network.schedule.sample_time,
        phase_offset = control.network.schedule.phase_offset,
        computational_delay = control_time("0.00003", control.provenance),
    )
    revised_network = ControlNetwork(
        control.network.identity,
        revised_schedule,
        collect(control.network.external_ports),
        collect(control.network.blocks),
        collect(control.network.links),
        collect(control.network.initialization_order),
        collect(control.network.boundary_bindings),
        collect(control.network.algebraic_loops),
        control.network.provenance;
        import_provenance = control.network.import_provenance,
    )
    replace_network = ProjectCommand(
        ProjectId("command.replace_control_network"),
        ReplaceControlNetworkPatch(revised_network),
    )
    revised_project = replay_commands(base.project, [replace_network])
    @test control_network(revised_project.control_system, revised_network.identity.id) == revised_network
    @test replay_commands(revised_project, inverse_commands(base.project, [replace_network])) == base.project
    remove_added = ProjectCommand(
        ProjectId("command.remove_additional_control"),
        RemoveControlNetworkPatch(additional.identity.id),
    )
    @test replay_commands(committed.project, [remove_added]) == base.project
    @test semantic_error_code(() -> replay_commands(base.project, [ProjectCommand(
        ProjectId("command.remove_used_control_schema"),
        RemoveControlBlockSchemaPatch(control.gain_schema.identity),
    )])) == :control_schema_has_dependents
end

@testset "control declarations contain no controller numerics callbacks or mutable dictionaries" begin
    control = control_fixture()
    delayed = algebraic_control_project(delayed = true)
    values = Any[
        control.gain_schema,
        control.states[1],
        control.gain,
        control.network.schedule,
        control.network,
        control.system,
        delayed.network.link_delays[1],
    ]
    @test all(value -> isimmutable(value), values)
    @test all(value -> all(type -> !(type <: Function) && !(type <: AbstractDict), fieldtypes(typeof(value))), values)
end

record_project_conformance!(:control_networks)
