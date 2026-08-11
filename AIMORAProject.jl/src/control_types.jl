@enum ControlExecutionDomain::UInt8 begin
    ControlContinuous = 0x01
    ControlDiscrete = 0x02
    ControlSampled = 0x03
    ControlEventDriven = 0x04
    ControlHybrid = 0x05
end

@enum ControlSchedulerSemantics::UInt8 begin
    ContinuousResidualEvaluation = 0x01
    DiscreteEventUpdate = 0x02
    ReadComputeEnqueueReleaseWriteHold = 0x03
    HybridOrderedExecution = 0x04
end

@enum ControlStateKind::UInt8 begin
    ContinuousControlState = 0x01
    DiscreteControlState = 0x02
    DelayControlState = 0x03
    SampleControlState = 0x04
    EventControlState = 0x05
    LimiterControlState = 0x06
    HoldControlState = 0x07
end

@enum ControlResetPolicy::UInt8 begin
    ResetRetain = 0x01
    ResetToInitial = 0x02
    ResetFromEventValue = 0x03
end

@enum ControlRollbackPolicy::UInt8 begin
    RollbackRestoreAccepted = 0x01
    RollbackRecompute = 0x02
    RollbackProhibited = 0x03
end

@enum ControlCheckpointPolicy::UInt8 begin
    CheckpointRequired = 0x01
    CheckpointOptional = 0x02
    CheckpointExcluded = 0x03
end

@enum ControlBoundaryKind::UInt8 begin
    ControlMeasurementBinding = 0x01
    ControlActuatorBinding = 0x02
end

@enum AlgebraicLoopFailurePolicy::UInt8 begin
    AlgebraicLoopError = 0x01
    AlgebraicLoopRejectStep = 0x02
end

function _portable_control_name(name::AbstractString, code::Symbol)
    normalized = String(name)
    occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
        _semantic_fail(code, "control role name is not lowercase portable text")
    return normalized
end

"""One named port contract owned by a versioned control-block schema."""
struct ControlPortSpec
    name::String
    direction::PortDirection
    contract::SignalContract

    function ControlPortSpec(
        name::AbstractString,
        direction::PortDirection,
        contract::SignalContract,
    )
        direction in (PortInput, PortOutput) ||
            _semantic_fail(:invalid_control_port_direction, "control block port must be input or output")
        return new(_portable_control_name(name, :invalid_control_port_name), direction, contract)
    end
end

Base.:(==)(left::ControlPortSpec, right::ControlPortSpec) =
    left.name == right.name && left.direction == right.direction && left.contract == right.contract

"""One required state slot in a versioned control-block schema."""
struct ControlStateSpec
    field::SchemaField
    kind::ControlStateKind
end

Base.:(==)(left::ControlStateSpec, right::ControlStateSpec) =
    left.field == right.field && left.kind == right.kind

"""A callback-free, versioned control-block declaration registered as project data."""
struct ControlBlockSchema
    identity::SemanticSchemaIdentity
    execution_domains::CanonicalList{ControlExecutionDomain}
    parameters::CanonicalList{SchemaField}
    ports::CanonicalList{ControlPortSpec}
    states::CanonicalList{ControlStateSpec}
    direct_feedthrough::Bool
    provenance::ProvenanceSource

    function ControlBlockSchema(
        identity::SemanticSchemaIdentity,
        execution_domains::AbstractVector{ControlExecutionDomain},
        parameters::AbstractVector{SchemaField},
        ports::AbstractVector{ControlPortSpec},
        states::AbstractVector{ControlStateSpec},
        direct_feedthrough::Bool,
        provenance::ProvenanceSource,
    )
        domain_copy = sort!(collect(execution_domains); by = UInt8)
        isempty(domain_copy) &&
            _semantic_fail(:missing_control_execution_domain, "control block schema requires an execution domain")
        length(domain_copy) == length(unique(domain_copy)) ||
            _semantic_fail(:duplicate_control_execution_domain, "control block schema repeats an execution domain")
        parameter_copy = sort!(collect(parameters); by = item -> item.name)
        parameter_names = getfield.(parameter_copy, :name)
        length(parameter_names) == length(unique(parameter_names)) ||
            _semantic_fail(:duplicate_control_parameter_spec, "control block schema repeats a parameter")
        port_copy = sort!(collect(ports); by = item -> item.name)
        port_names = getfield.(port_copy, :name)
        length(port_names) == length(unique(port_names)) ||
            _semantic_fail(:duplicate_control_port_spec, "control block schema repeats a port role")
        state_copy = sort!(collect(states); by = item -> item.field.name)
        state_names = [item.field.name for item in state_copy]
        length(state_names) == length(unique(state_names)) ||
            _semantic_fail(:duplicate_control_state_spec, "control block schema repeats a state role")
        !direct_feedthrough && isempty(state_copy) &&
            _semantic_fail(:stateless_nondirect_control_block, "non-direct-feedthrough block requires declared state")
        return new(
            identity,
            CanonicalList{ControlExecutionDomain}(domain_copy),
            CanonicalList{SchemaField}(parameter_copy),
            CanonicalList{ControlPortSpec}(port_copy),
            CanonicalList{ControlStateSpec}(state_copy),
            direct_feedthrough,
            provenance,
        )
    end
end

Base.:(==)(left::ControlBlockSchema, right::ControlBlockSchema) =
    left.identity == right.identity && left.execution_domains == right.execution_domains &&
    left.parameters == right.parameters && left.ports == right.ports &&
    left.states == right.states && left.direct_feedthrough == right.direct_feedthrough &&
    left.provenance == right.provenance

"""A role-to-semantic-port binding for one control block."""
struct ControlPortBinding
    name::String
    port::ProjectId

    function ControlPortBinding(name::AbstractString, port::ProjectId)
        return new(_portable_control_name(name, :invalid_control_port_name), port)
    end
end

Base.:(==)(left::ControlPortBinding, right::ControlPortBinding) =
    left.name == right.name && left.port == right.port

"""One explicitly initialized, resettable, rollback-aware, checkpoint-owned control state."""
struct ControlStateDeclaration
    identity::ObjectIdentity
    name::String
    kind::ControlStateKind
    initial_value::CanonicalFieldData
    reset::ControlResetPolicy
    rollback::ControlRollbackPolicy
    checkpoint::ControlCheckpointPolicy
    provenance::ProvenanceSource

    function ControlStateDeclaration(
        identity::ObjectIdentity,
        name::AbstractString,
        kind::ControlStateKind,
        initial_value::CanonicalFieldData,
        reset::ControlResetPolicy,
        rollback::ControlRollbackPolicy,
        checkpoint::ControlCheckpointPolicy,
        provenance::ProvenanceSource,
    )
        owned_value = initial_value isa String ? String(initial_value) : initial_value
        return new(
            identity,
            _portable_control_name(name, :invalid_control_state_name),
            kind,
            owned_value,
            reset,
            rollback,
            checkpoint,
            provenance,
        )
    end
end

ControlStateDeclaration(
    identity::ObjectIdentity,
    name::AbstractString,
    kind::ControlStateKind,
    initial_value::Integer,
    reset::ControlResetPolicy,
    rollback::ControlRollbackPolicy,
    checkpoint::ControlCheckpointPolicy,
    provenance::ProvenanceSource,
) = ControlStateDeclaration(identity, name, kind, BigInt(initial_value), reset, rollback, checkpoint, provenance)

ControlStateDeclaration(
    identity::ObjectIdentity,
    name::AbstractString,
    kind::ControlStateKind,
    initial_value::AbstractString,
    reset::ControlResetPolicy,
    rollback::ControlRollbackPolicy,
    checkpoint::ControlCheckpointPolicy,
    provenance::ProvenanceSource,
) = ControlStateDeclaration(identity, name, kind, String(initial_value), reset, rollback, checkpoint, provenance)

Base.:(==)(left::ControlStateDeclaration, right::ControlStateDeclaration) =
    left.identity == right.identity && left.name == right.name && left.kind == right.kind &&
    left.initial_value == right.initial_value && left.reset == right.reset &&
    left.rollback == right.rollback && left.checkpoint == right.checkpoint &&
    left.provenance == right.provenance

"""One inert control-block instance; registered consumers own its numerical behavior."""
struct ControlBlock
    identity::ObjectIdentity
    schema::SemanticSchemaIdentity
    parameters::CanonicalList{CanonicalField}
    ports::CanonicalList{ControlPortBinding}
    states::CanonicalList{ControlStateDeclaration}
    provenance::ProvenanceSource

    function ControlBlock(
        identity::ObjectIdentity,
        schema::SemanticSchemaIdentity,
        parameters::AbstractVector{CanonicalField},
        ports::AbstractVector{ControlPortBinding},
        states::AbstractVector{ControlStateDeclaration},
        provenance::ProvenanceSource,
    )
        parameter_copy = sort!(collect(parameters); by = item -> item.name)
        parameter_names = getfield.(parameter_copy, :name)
        length(parameter_names) == length(unique(parameter_names)) ||
            _semantic_fail(:duplicate_control_parameter, "control block repeats a parameter")
        port_copy = sort!(collect(ports); by = item -> item.name)
        port_names = getfield.(port_copy, :name)
        length(port_names) == length(unique(port_names)) ||
            _semantic_fail(:duplicate_control_port_binding, "control block repeats a port role")
        state_copy = sort!(collect(states); by = item -> item.name)
        state_names = getfield.(state_copy, :name)
        state_ids = getfield.(getfield.(state_copy, :identity), :id)
        length(state_names) == length(unique(state_names)) ||
            _semantic_fail(:duplicate_control_state, "control block repeats a state role")
        length(state_ids) == length(unique(state_ids)) ||
            _semantic_fail(:duplicate_control_state_id, "control block repeats a state identity")
        return new(
            identity,
            schema,
            CanonicalList{CanonicalField}(parameter_copy),
            CanonicalList{ControlPortBinding}(port_copy),
            CanonicalList{ControlStateDeclaration}(state_copy),
            provenance,
        )
    end
end

Base.:(==)(left::ControlBlock, right::ControlBlock) =
    left.identity == right.identity && left.schema == right.schema &&
    left.parameters == right.parameters && left.ports == right.ports &&
    left.states == right.states && left.provenance == right.provenance

"""One explicitly ordered scheduler declaration without scheduler execution."""
struct ControlSchedule
    domain::ControlExecutionDomain
    semantics::ControlSchedulerSemantics
    sample_time::Union{Nothing,PhysicalValue{ScalarQuantity}}
    phase_offset::Union{Nothing,PhysicalValue{ScalarQuantity}}
    computational_delay::Union{Nothing,PhysicalValue{ScalarQuantity}}
    task_order::CanonicalList{ProjectId}

    function ControlSchedule(
        domain::ControlExecutionDomain,
        semantics::ControlSchedulerSemantics,
        task_order::AbstractVector{ProjectId};
        sample_time::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
        phase_offset::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
        computational_delay::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
    )
        copied = collect(task_order)
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_control_task, "control schedule repeats a block")
        return new(domain, semantics, sample_time, phase_offset, computational_delay, CanonicalList{ProjectId}(copied))
    end
end

Base.:(==)(left::ControlSchedule, right::ControlSchedule) =
    left.domain == right.domain && left.semantics == right.semantics &&
    left.sample_time == right.sample_time && left.phase_offset == right.phase_offset &&
    left.computational_delay == right.computational_delay && left.task_order == right.task_order

"""A named external control-network port backed by the canonical signal graph."""
struct ControlExternalPort
    name::String
    port::ProjectId
    direction::PortDirection

    function ControlExternalPort(name::AbstractString, port::ProjectId, direction::PortDirection)
        direction in (PortInput, PortOutput) ||
            _semantic_fail(:invalid_control_external_port_direction, "control external port must be input or output")
        return new(_portable_control_name(name, :invalid_control_external_port_name), port, direction)
    end
end

Base.:(==)(left::ControlExternalPort, right::ControlExternalPort) =
    left.name == right.name && left.port == right.port && left.direction == right.direction

"""An explicit signal-to-physical measurement or actuator boundary."""
struct ControlBoundaryBinding
    identity::ObjectIdentity
    kind::ControlBoundaryKind
    control_port::ProjectId
    target::ProjectReference
    provenance::ProvenanceSource
end

Base.:(==)(left::ControlBoundaryBinding, right::ControlBoundaryBinding) =
    left.identity == right.identity && left.kind == right.kind &&
    left.control_port == right.control_port && left.target == right.target &&
    left.provenance == right.provenance

"""Exact history ownership for one delayed signal link."""
struct ControlLinkDelay
    link::ProjectId
    duration::PhysicalValue{ScalarQuantity}
    state::ControlStateDeclaration

    function ControlLinkDelay(
        link::ProjectId,
        duration::PhysicalValue{ScalarQuantity},
        state::ControlStateDeclaration,
    )
        state.kind == DelayControlState ||
            _semantic_fail(:invalid_control_link_delay_state, "delayed signal link requires a delay-state declaration")
        return new(link, duration, state)
    end
end

Base.:(==)(left::ControlLinkDelay, right::ControlLinkDelay) =
    left.link == right.link && left.duration == right.duration && left.state == right.state

"""Preserved source location and assumptions for a TACS or external-control import."""
struct ControlImportProvenance
    source_format::SemanticTypeId
    artifact::ArtifactIdentity
    source_records::CanonicalList{String}
    assumptions::CanonicalList{String}
    provenance::ProvenanceSource

    function ControlImportProvenance(
        source_format::SemanticTypeId,
        artifact::ArtifactIdentity,
        source_records::AbstractVector{<:AbstractString},
        assumptions::AbstractVector{<:AbstractString},
        provenance::ProvenanceSource,
    )
        records = sort!(String[String(item) for item in source_records])
        isempty(records) &&
            _semantic_fail(:missing_control_import_record, "control import provenance requires a source record")
        any(item -> isempty(strip(item)) || occursin('\0', item), records) &&
            _semantic_fail(:invalid_control_import_record, "control import source record is empty or contains NUL")
        length(records) == length(unique(records)) ||
            _semantic_fail(:duplicate_control_import_record, "control import provenance repeats a source record")
        declared_assumptions = sort!(String[String(item) for item in assumptions])
        any(item -> isempty(strip(item)) || occursin('\0', item), declared_assumptions) &&
            _semantic_fail(:invalid_control_import_assumption, "control import assumption is empty or contains NUL")
        length(declared_assumptions) == length(unique(declared_assumptions)) ||
            _semantic_fail(:duplicate_control_import_assumption, "control import provenance repeats an assumption")
        return new(
            source_format,
            artifact,
            CanonicalList{String}(records),
            CanonicalList{String}(declared_assumptions),
            provenance,
        )
    end
end

Base.:(==)(left::ControlImportProvenance, right::ControlImportProvenance) =
    left.source_format == right.source_format && left.artifact == right.artifact &&
    left.source_records == right.source_records && left.assumptions == right.assumptions &&
    left.provenance == right.provenance

"""A fully declared solver contract for one intentional pure algebraic loop."""
struct AlgebraicLoopDeclaration
    identity::ObjectIdentity
    blocks::CanonicalList{ProjectId}
    solver::SemanticTypeId
    residual::SemanticTypeId
    jacobian::SemanticTypeId
    tolerance::ExactDecimal
    maximum_iterations::Int
    on_failure::AlgebraicLoopFailurePolicy
    provenance::ProvenanceSource

    function AlgebraicLoopDeclaration(
        identity::ObjectIdentity,
        blocks::AbstractVector{ProjectId},
        solver::SemanticTypeId,
        residual::SemanticTypeId,
        jacobian::SemanticTypeId,
        tolerance::ExactDecimal,
        maximum_iterations::Integer,
        on_failure::AlgebraicLoopFailurePolicy,
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(blocks); by = item -> item.value)
        isempty(copied) && _semantic_fail(:empty_algebraic_loop, "algebraic loop requires blocks")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_algebraic_loop_block, "algebraic loop repeats a block")
        ExactRational(0) < exact_rational(tolerance) ||
            _semantic_fail(:invalid_algebraic_loop_tolerance, "algebraic-loop tolerance must be positive")
        iterations = try
            Int(maximum_iterations)
        catch
            _semantic_fail(:invalid_algebraic_loop_iterations, "algebraic-loop iteration bound exceeds Int")
        end
        iterations > 0 ||
            _semantic_fail(:invalid_algebraic_loop_iterations, "algebraic-loop iteration bound must be positive")
        return new(
            identity,
            CanonicalList{ProjectId}(copied),
            solver,
            residual,
            jacobian,
            tolerance,
            iterations,
            on_failure,
            provenance,
        )
    end
end

Base.:(==)(left::AlgebraicLoopDeclaration, right::AlgebraicLoopDeclaration) =
    left.identity == right.identity && left.blocks == right.blocks && left.solver == right.solver &&
    left.residual == right.residual && left.jacobian == right.jacobian &&
    left.tolerance == right.tolerance && left.maximum_iterations == right.maximum_iterations &&
    left.on_failure == right.on_failure && left.provenance == right.provenance

"""One declarative continuous, discrete, sampled, event-driven, or hybrid signal network."""
struct ControlNetwork
    identity::ObjectIdentity
    schedule::ControlSchedule
    external_ports::CanonicalList{ControlExternalPort}
    blocks::CanonicalList{ControlBlock}
    links::CanonicalList{ProjectId}
    link_delays::CanonicalList{ControlLinkDelay}
    initialization_order::CanonicalList{ProjectId}
    boundary_bindings::CanonicalList{ControlBoundaryBinding}
    algebraic_loops::CanonicalList{AlgebraicLoopDeclaration}
    import_provenance::Union{Nothing,ControlImportProvenance}
    provenance::ProvenanceSource

    function ControlNetwork(
        identity::ObjectIdentity,
        schedule::ControlSchedule,
        external_ports::AbstractVector{ControlExternalPort},
        blocks::AbstractVector{ControlBlock},
        links::AbstractVector{ProjectId},
        initialization_order::AbstractVector{ProjectId},
        boundary_bindings::AbstractVector{ControlBoundaryBinding},
        algebraic_loops::AbstractVector{AlgebraicLoopDeclaration},
        provenance::ProvenanceSource;
        link_delays::AbstractVector{ControlLinkDelay} = ControlLinkDelay[],
        import_provenance::Union{Nothing,ControlImportProvenance} = nothing,
    )
        external_copy = sort!(collect(external_ports); by = item -> item.name)
        external_names = getfield.(external_copy, :name)
        external_ids = getfield.(external_copy, :port)
        length(external_names) == length(unique(external_names)) ||
            _semantic_fail(:duplicate_control_external_port, "control network repeats an external role")
        length(external_ids) == length(unique(external_ids)) ||
            _semantic_fail(:duplicate_control_external_port, "control network repeats an external port")
        block_copy = sort!(collect(blocks); by = item -> item.identity.id.value)
        block_ids = getfield.(getfield.(block_copy, :identity), :id)
        length(block_ids) == length(unique(block_ids)) ||
            _semantic_fail(:duplicate_control_block, "control network repeats a block ID")
        link_copy = sort!(collect(links); by = item -> item.value)
        length(link_copy) == length(unique(link_copy)) ||
            _semantic_fail(:duplicate_control_link, "control network repeats a signal link")
        delay_copy = sort!(collect(link_delays); by = item -> item.link.value)
        delay_links = getfield.(delay_copy, :link)
        delay_state_ids = [item.state.identity.id for item in delay_copy]
        length(delay_links) == length(unique(delay_links)) ||
            _semantic_fail(:duplicate_control_link_delay, "control network repeats delayed-link metadata")
        length(delay_state_ids) == length(unique(delay_state_ids)) ||
            _semantic_fail(:duplicate_control_state_id, "control network repeats a delayed-link state identity")
        initialization_copy = collect(initialization_order)
        length(initialization_copy) == length(unique(initialization_copy)) ||
            _semantic_fail(:duplicate_control_initialization, "control network repeats a state initialization")
        boundary_copy = sort!(collect(boundary_bindings); by = item -> item.identity.id.value)
        boundary_ids = getfield.(getfield.(boundary_copy, :identity), :id)
        length(boundary_ids) == length(unique(boundary_ids)) ||
            _semantic_fail(:duplicate_control_boundary, "control network repeats a boundary identity")
        loop_copy = sort!(collect(algebraic_loops); by = item -> item.identity.id.value)
        loop_ids = getfield.(getfield.(loop_copy, :identity), :id)
        length(loop_ids) == length(unique(loop_ids)) ||
            _semantic_fail(:duplicate_algebraic_loop, "control network repeats an algebraic-loop identity")
        return new(
            identity,
            schedule,
            CanonicalList{ControlExternalPort}(external_copy),
            CanonicalList{ControlBlock}(block_copy),
            CanonicalList{ProjectId}(link_copy),
            CanonicalList{ControlLinkDelay}(delay_copy),
            CanonicalList{ProjectId}(initialization_copy),
            CanonicalList{ControlBoundaryBinding}(boundary_copy),
            CanonicalList{AlgebraicLoopDeclaration}(loop_copy),
            import_provenance,
            provenance,
        )
    end
end

Base.:(==)(left::ControlNetwork, right::ControlNetwork) =
    left.identity == right.identity && left.schedule == right.schedule &&
    left.external_ports == right.external_ports && left.blocks == right.blocks &&
    left.links == right.links && left.link_delays == right.link_delays &&
    left.initialization_order == right.initialization_order &&
    left.boundary_bindings == right.boundary_bindings && left.algebraic_loops == right.algebraic_loops &&
    left.import_provenance == right.import_provenance && left.provenance == right.provenance

"""The immutable control-schema registry and separated signal-network owners in one project."""
struct ControlSystem
    block_schemas::CanonicalList{ControlBlockSchema}
    networks::CanonicalList{ControlNetwork}

    function ControlSystem(;
        block_schemas::AbstractVector{ControlBlockSchema} = ControlBlockSchema[],
        networks::AbstractVector{ControlNetwork} = ControlNetwork[],
    )
        schema_copy = sort!(collect(block_schemas); by = item -> (
            item.identity.namespace.value,
            item.identity.name.value,
            item.identity.version,
        ))
        schema_keys = [
            (item.identity.namespace, item.identity.name, item.identity.version)
            for item in schema_copy
        ]
        schema_uuids = getfield.(getfield.(schema_copy, :identity), :uuid)
        length(schema_keys) == length(unique(schema_keys)) ||
            _semantic_fail(:duplicate_control_block_schema, "control system repeats a block schema identity")
        length(schema_uuids) == length(unique(schema_uuids)) ||
            _semantic_fail(:duplicate_control_block_schema_uuid, "control system repeats a block schema UUID")
        network_copy = sort!(collect(networks); by = item -> item.identity.id.value)
        network_ids = getfield.(getfield.(network_copy, :identity), :id)
        length(network_ids) == length(unique(network_ids)) ||
            _semantic_fail(:duplicate_control_network, "control system repeats a network ID")
        return new(
            CanonicalList{ControlBlockSchema}(schema_copy),
            CanonicalList{ControlNetwork}(network_copy),
        )
    end
end

Base.:(==)(left::ControlSystem, right::ControlSystem) =
    left.block_schemas == right.block_schemas && left.networks == right.networks

function control_block_schema(system::ControlSystem, identity::SemanticSchemaIdentity)
    index = findfirst(item -> item.identity == identity, system.block_schemas)
    isnothing(index) && _semantic_fail(:unknown_control_block_schema, "control block schema is not registered")
    return system.block_schemas[index]
end

function control_network(system::ControlSystem, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, system.networks)
    isnothing(index) && _semantic_fail(:unknown_control_network, "control network does not exist")
    return system.networks[index]
end

function control_block(network::ControlNetwork, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, network.blocks)
    isnothing(index) && _semantic_fail(:unknown_control_block, "control block does not exist in the network")
    return network.blocks[index]
end
