function _validate_signal_contract(project::CanonicalProject, contract::SignalContract)
    unit = lookup_unit(project.units, contract.unit)
    unit.dimension == contract.dimension ||
        _semantic_fail(:signal_unit_dimension_mismatch, "control signal unit has a different dimension")
    unit.per_unit &&
        _semantic_fail(:per_unit_signal_contract, "control signal requires a physical unit and explicit base semantics")
    return true
end

function _find_signal_connection(graphs::SemanticGraphs, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, graphs.signal_connections)
    isnothing(index) && _semantic_fail(:unknown_control_link, "control network link does not exist in the signal graph")
    return graphs.signal_connections[index]
end

function _time_value(project::CanonicalProject, value::PhysicalValue{ScalarQuantity})
    validate_quantity(project.units, value)
    isnothing(value.uncertainty) ||
        _semantic_fail(:uncertain_control_schedule, "control scheduler time cannot carry uncertainty")
    value.quantity.orientation == OrientationScalar ||
        _semantic_fail(:invalid_control_schedule_orientation, "control scheduler time requires scalar orientation")
    unit = lookup_unit(project.units, value.quantity.unit)
    unit.dimension == _dimension(0, 0, 1, 0, 0) ||
        _semantic_fail(:invalid_control_schedule_unit, "control scheduler value requires a time unit")
    isnothing(value.quantity.base) ||
        _semantic_fail(:invalid_control_schedule_base, "control scheduler time cannot use a per-unit base")
    return exact_rational(convert_quantity(project.units, value.quantity, UnitId("s")).value)
end

function _validate_control_schedule(project::CanonicalProject, schedule::ControlSchedule)
    expected_semantics = if schedule.domain == ControlContinuous
        ContinuousResidualEvaluation
    elseif schedule.domain in (ControlDiscrete, ControlEventDriven)
        DiscreteEventUpdate
    elseif schedule.domain == ControlSampled
        ReadComputeEnqueueReleaseWriteHold
    else
        HybridOrderedExecution
    end
    schedule.semantics == expected_semantics ||
        _semantic_fail(:control_scheduler_semantics_mismatch, "control scheduler semantics do not match its execution domain")
    periodic = schedule.domain in (ControlDiscrete, ControlSampled, ControlHybrid)
    periodic == !isnothing(schedule.sample_time) ||
        _semantic_fail(:control_sample_time_mismatch, periodic ?
            "periodic control network requires a sample time" :
            "continuous or event-driven control network cannot declare a sample time")
    if periodic
        sample_time = _time_value(project, schedule.sample_time)
        ExactRational(0) < sample_time ||
            _semantic_fail(:invalid_control_sample_time, "control sample time must be positive")
        isnothing(schedule.phase_offset) &&
            _semantic_fail(:missing_control_phase_offset, "periodic control network requires an explicit phase offset")
        isnothing(schedule.computational_delay) &&
            _semantic_fail(:missing_control_computational_delay, "periodic control network requires an explicit computational delay")
        offset = _time_value(project, schedule.phase_offset)
        delay = _time_value(project, schedule.computational_delay)
        ExactRational(0) <= offset < sample_time ||
            _semantic_fail(:invalid_control_phase_offset, "control phase offset must be in [0, sample_time)")
        ExactRational(0) <= delay ||
            _semantic_fail(:invalid_control_computational_delay, "control computational delay must be nonnegative")
    elseif !isnothing(schedule.phase_offset) || !isnothing(schedule.computational_delay)
        _semantic_fail(:nonperiodic_control_timing, "continuous or event-driven control network cannot declare periodic timing")
    end
    return true
end

function _validate_control_block_schema(project::CanonicalProject, schema::ControlBlockSchema)
    registered_namespaces = Set{NamespaceId}(item.namespace for item in project.registry.namespaces)
    schema.identity.namespace in registered_namespaces ||
        _semantic_fail(:unknown_control_schema_namespace, "control block schema namespace is not registered")
    foreach(port -> _validate_signal_contract(project, port.contract), schema.ports)
    return true
end

function _control_parameter_spec(schema::ControlBlockSchema, name::String)
    index = findfirst(item -> item.name == name, schema.parameters)
    isnothing(index) && _semantic_fail(:unknown_control_parameter, "control block supplies an undeclared parameter")
    return schema.parameters[index]
end

function _control_port_spec(schema::ControlBlockSchema, name::String)
    index = findfirst(item -> item.name == name, schema.ports)
    isnothing(index) && _semantic_fail(:unknown_control_port_role, "control block supplies an undeclared port role")
    return schema.ports[index]
end

function _control_state_spec(schema::ControlBlockSchema, name::String)
    index = findfirst(item -> item.field.name == name, schema.states)
    isnothing(index) && _semantic_fail(:unknown_control_state_role, "control block supplies an undeclared state role")
    return schema.states[index]
end

function _validate_control_block(
    project::CanonicalProject,
    system::ControlSystem,
    network::ControlNetwork,
    block::ControlBlock,
)
    schema = control_block_schema(system, block.schema)
    network.schedule.domain in schema.execution_domains ||
        _semantic_fail(:control_execution_domain_mismatch, "control block schema is incompatible with its network execution domain")
    supplied_parameters = Set(item.name for item in block.parameters)
    for parameter in block.parameters
        validate_field_value(_control_parameter_spec(schema, parameter.name), parameter.value, project.units)
    end
    for specification in schema.parameters
        specification.required && specification.name ∉ supplied_parameters &&
            _semantic_fail(:missing_control_parameter, "control block omits a required parameter")
    end
    supplied_ports = Set(item.name for item in block.ports)
    required_ports = Set(item.name for item in schema.ports)
    supplied_ports == required_ports ||
        _semantic_fail(:incomplete_control_port_inventory, "control block port inventory differs from its schema")
    for binding in block.ports
        specification = _control_port_spec(schema, binding.name)
        port = _find_port(project.graphs, binding.port)
        port.owner == block.identity.id ||
            _semantic_fail(:control_port_owner_mismatch, "control block port has a different semantic owner")
        port.domain.family == SignalGraph ||
            _semantic_fail(:physical_port_in_control_block, "control block port must belong to the signal graph")
        port.direction == specification.direction && port.signal_contract == specification.contract ||
            _semantic_fail(:control_port_contract_mismatch, "control block port differs from its schema contract")
    end
    supplied_states = Set(item.name for item in block.states)
    required_states = Set(item.field.name for item in schema.states)
    supplied_states == required_states ||
        _semantic_fail(:incomplete_control_state_inventory, "control block state inventory differs from its schema")
    for state in block.states
        specification = _control_state_spec(schema, state.name)
        state.kind == specification.kind ||
            _semantic_fail(:control_state_kind_mismatch, "control state category differs from its schema")
        validate_field_value(specification.field, state.initial_value, project.units)
    end
    return true
end

function _strong_components(vertices::AbstractVector{ProjectId}, edges)
    ordered_vertices = sort!(unique(collect(vertices)); by = item -> item.value)
    adjacency = Dict(vertex => ProjectId[] for vertex in ordered_vertices)
    reverse_adjacency = Dict(vertex => ProjectId[] for vertex in ordered_vertices)
    for (source, target) in edges
        haskey(adjacency, source) || (adjacency[source] = ProjectId[])
        haskey(adjacency, target) || (adjacency[target] = ProjectId[])
        haskey(reverse_adjacency, source) || (reverse_adjacency[source] = ProjectId[])
        haskey(reverse_adjacency, target) || (reverse_adjacency[target] = ProjectId[])
        push!(adjacency[source], target)
        push!(reverse_adjacency[target], source)
    end
    for values in values(adjacency)
        sort!(unique!(values); by = item -> item.value)
    end
    for values in values(reverse_adjacency)
        sort!(unique!(values); by = item -> item.value)
    end
    visited = Set{ProjectId}()
    order = ProjectId[]
    function forward(vertex)
        vertex in visited && return
        push!(visited, vertex)
        foreach(forward, adjacency[vertex])
        push!(order, vertex)
    end
    foreach(forward, sort!(collect(keys(adjacency)); by = item -> item.value))
    empty!(visited)
    components = Vector{Vector{ProjectId}}()
    function backward(vertex, component)
        vertex in visited && return
        push!(visited, vertex)
        push!(component, vertex)
        foreach(target -> backward(target, component), reverse_adjacency[vertex])
    end
    for vertex in reverse(order)
        vertex in visited && continue
        component = ProjectId[]
        backward(vertex, component)
        push!(components, sort!(component; by = item -> item.value))
    end
    sort!(components; by = component -> first(component).value)
    return components
end

function _cyclic_components(vertices::AbstractVector{ProjectId}, edges)
    edge_set = Set(edges)
    return [
        component for component in _strong_components(vertices, edges)
        if length(component) > 1 || (first(component), first(component)) in edge_set
    ]
end

function _validate_control_algebraic_loops(
    project::CanonicalProject,
    system::ControlSystem,
    network::ControlNetwork,
    links::AbstractVector{SignalConnection},
)
    block_ids = ProjectId[item.identity.id for item in network.blocks]
    external_port_ids = Set{ProjectId}(port.port for port in network.external_ports)
    cycle_vertex(port_id) = port_id in external_port_ids ? port_id : _find_port(project.graphs, port_id).owner
    edges = Tuple{ProjectId,ProjectId}[
        (
            cycle_vertex(link.source_port),
            cycle_vertex(link.target_port),
        ) for link in links if !link.delayed
    ]
    components = _cyclic_components(vcat(block_ids, collect(external_port_ids)), edges)
    loop_key(blocks) = join((id.value for id in blocks), '\0')
    declarations = Dict{String,AlgebraicLoopDeclaration}(
        loop_key(loop.blocks) => loop for loop in network.algebraic_loops
    )
    length(declarations) == length(network.algebraic_loops) ||
        _semantic_fail(:duplicate_algebraic_loop_blocks, "control network repeats an algebraic-loop block set")
    accepted = Set{String}()
    for component in components
        !isempty(intersect(Set(component), external_port_ids)) &&
            _semantic_fail(:external_control_cycle, "control cycle passes through a network external port")
        component_set = Set(component)
        component_key = loop_key(component)
        schemas = ControlBlockSchema[
            control_block_schema(system, control_block(network, id).schema) for id in component
        ]
        any(schema -> !schema.direct_feedthrough, schemas) && continue
        haskey(declarations, component_key) ||
            _semantic_fail(:algebraic_signal_cycle, "pure algebraic control cycle lacks a declared solver contract")
        push!(accepted, component_key)
    end
    for loop in network.algebraic_loops
        loop_key(loop.blocks) in accepted ||
            _semantic_fail(:invalid_algebraic_loop_declaration, "algebraic-loop declaration does not match one pure cyclic component")
        all(id -> id in block_ids, loop.blocks) ||
            _semantic_fail(:unknown_algebraic_loop_block, "algebraic-loop declaration references a missing block")
        for implementation in (loop.solver, loop.residual, loop.jacobian)
            implementation.namespace in Set{NamespaceId}(item.namespace for item in project.registry.namespaces) ||
                _semantic_fail(:unknown_algebraic_loop_namespace, "algebraic-loop implementation namespace is not registered")
        end
    end
    return true
end

function _signal_cycle_vertex(project::CanonicalProject, port_id::ProjectId)
    for network in project.control_system.networks, external in network.external_ports
        external.port == port_id && return port_id
    end
    return _find_port(project.graphs, port_id).owner
end

function _asset_or_record_exists(project::CanonicalProject, id::ProjectId)
    any(item -> item.identity.id == id, project.asset_library.assets) && return true
    return any(item -> item.identity.id == id, project.records)
end

function _validate_control_boundary(
    project::CanonicalProject,
    network::ControlNetwork,
    binding::ControlBoundaryBinding,
)
    external_ids = Set{ProjectId}(item.port for item in network.external_ports)
    binding.control_port in external_ids ||
        _semantic_fail(:control_boundary_not_external, "control boundary must use a network external signal port")
    port = _find_port(project.graphs, binding.control_port)
    port.domain.family == SignalGraph ||
        _semantic_fail(:physical_port_in_control_boundary, "control boundary must use a signal port")
    if binding.kind == ControlMeasurementBinding
        external = only(item for item in network.external_ports if item.port == binding.control_port)
        external.direction == PortInput ||
            _semantic_fail(:control_measurement_direction, "measurement boundary requires an input signal port")
        binding.target.kind in (ReferenceAsset, ReferenceNode) ||
            _semantic_fail(:invalid_control_measurement_target, "measurement boundary requires an asset or node target")
    else
        external = only(item for item in network.external_ports if item.port == binding.control_port)
        external.direction == PortOutput ||
            _semantic_fail(:control_actuator_direction, "actuator boundary requires an output signal port")
        binding.target.kind == ReferenceAsset ||
            _semantic_fail(:invalid_control_actuator_target, "actuator boundary requires a physical asset target")
    end
    if binding.target.target isa LocalReferenceTarget
        target = binding.target.target.id
        if binding.target.kind == ReferenceAsset
            _asset_or_record_exists(project, target) ||
                _semantic_fail(:dangling_control_boundary_target, "control boundary asset target does not exist")
        else
            _find_node(project.graphs, target)
        end
    end
    return true
end

function _validate_control_link_delay(
    project::CanonicalProject,
    link::SignalConnection,
    delay::ControlLinkDelay,
)
    _time_value(project, delay.duration) > ExactRational(0) ||
        _semantic_fail(:invalid_control_link_delay, "control link delay duration must be positive")
    initial = delay.state.initial_value
    initial isa PhysicalValue{ScalarQuantity} ||
        _semantic_fail(:invalid_control_link_delay_initial, "control link history requires a scalar physical initial value")
    validate_quantity(project.units, initial)
    source = _find_port(project.graphs, link.source_port)
    contract = source.signal_contract
    initial.quantity.unit == contract.unit &&
        initial.quantity.orientation == contract.orientation &&
        isnothing(initial.quantity.base) ||
        _semantic_fail(:control_link_delay_contract_mismatch, "delayed-link initial state differs from the signal contract")
    lookup_unit(project.units, initial.quantity.unit).dimension == contract.dimension ||
        _semantic_fail(:control_link_delay_contract_mismatch, "delayed-link initial state has a different dimension")
    return true
end

function _validate_control_network(
    project::CanonicalProject,
    system::ControlSystem,
    network::ControlNetwork,
)
    _validate_control_schedule(project, network.schedule)
    block_ids = Set{ProjectId}(item.identity.id for item in network.blocks)
    Set{ProjectId}(network.schedule.task_order) == block_ids ||
        _semantic_fail(:incomplete_control_task_order, "control task order must contain every block exactly once")
    external_port_ids = Set{ProjectId}(item.port for item in network.external_ports)
    for external in network.external_ports
        port = _find_port(project.graphs, external.port)
        port.owner == network.identity.id ||
            _semantic_fail(:control_external_port_owner_mismatch, "external signal port has a different network owner")
        port.domain.family == SignalGraph ||
            _semantic_fail(:physical_control_external_port, "control external port must belong to the signal graph")
        expected_internal_direction = external.direction == PortInput ? PortOutput : PortInput
        port.direction == expected_internal_direction ||
            _semantic_fail(:control_external_port_direction_mismatch, "external control direction disagrees with its internal-facing signal port")
    end
    foreach(block -> _validate_control_block(project, system, network, block), network.blocks)
    state_ids = ProjectId[]
    block_port_ids = Set{ProjectId}()
    for block in network.blocks
        append!(state_ids, [state.identity.id for state in block.states])
        union!(block_port_ids, Set{ProjectId}(binding.port for binding in block.ports))
    end
    isempty(intersect(external_port_ids, block_port_ids)) ||
        _semantic_fail(:shared_control_port_owner, "network and block roles share a signal port")
    all_ports = union(external_port_ids, block_port_ids)
    links = SignalConnection[_find_signal_connection(project.graphs, id) for id in network.links]
    delayed_links = Set{ProjectId}(link.identity.id for link in links if link.delayed)
    declared_delays = Set{ProjectId}(delay.link for delay in network.link_delays)
    delayed_links == declared_delays ||
        _semantic_fail(:incomplete_control_link_delay, "every delayed control link requires exactly one history declaration")
    for delay in network.link_delays
        link = _find_signal_connection(project.graphs, delay.link)
        link.identity.id in Set{ProjectId}(network.links) ||
            _semantic_fail(:control_link_delay_outside_network, "delayed-link metadata targets another signal network")
        _validate_control_link_delay(project, link, delay)
        push!(state_ids, delay.state.identity.id)
    end
    length(state_ids) == length(unique(state_ids)) ||
        _semantic_fail(:duplicate_control_state_id, "control network repeats a state identity")
    collect(network.initialization_order) == state_ids || begin
        Set{ProjectId}(network.initialization_order) == Set{ProjectId}(state_ids) ||
            _semantic_fail(:incomplete_control_initialization, "control initialization order must contain every state exactly once")
        nothing
    end
    link_ids = Set{ProjectId}(network.links)
    for link in links
        link.source_port in all_ports && link.target_port in all_ports ||
            _semantic_fail(:control_link_outside_network, "control link leaves its declared signal network")
    end
    for link in project.graphs.signal_connections
        touches = link.source_port in all_ports || link.target_port in all_ports
        touches || continue
        link.identity.id in link_ids && continue
        source_external = link.source_port in external_port_ids
        target_external = link.target_port in external_port_ids
        source_inside = link.source_port in all_ports
        target_inside = link.target_port in all_ports
        external_bridge = xor(source_external, target_external) && xor(source_inside, target_inside)
        external_bridge ||
            _semantic_fail(:undeclared_control_link, "signal connection touching a control network is not owned by it")
    end
    foreach(binding -> _validate_control_boundary(project, network, binding), network.boundary_bindings)
    if !isnothing(network.import_provenance)
        imported = network.import_provenance
        imported.source_format.namespace in Set{NamespaceId}(item.namespace for item in project.registry.namespaces) ||
            _semantic_fail(:unknown_control_import_namespace, "control import format namespace is not registered")
    end
    _validate_control_algebraic_loops(project, system, network, links)
    return true
end

function _control_owner_ids(system::ControlSystem)
    ids = ProjectId[]
    for network in system.networks
        push!(ids, network.identity.id)
        append!(ids, [item.identity.id for item in network.blocks])
        for block in network.blocks
            append!(ids, [item.identity.id for item in block.states])
        end
        append!(ids, [item.state.identity.id for item in network.link_delays])
        append!(ids, [item.identity.id for item in network.boundary_bindings])
        append!(ids, [item.identity.id for item in network.algebraic_loops])
    end
    return ids
end

function _control_port_owner_ids(system::ControlSystem)
    ids = ProjectId[]
    for network in system.networks
        push!(ids, network.identity.id)
        append!(ids, [item.identity.id for item in network.blocks])
    end
    return ids
end

"""Validate registered block contracts, state completeness, scheduling, boundaries, and loops without execution."""
function validate_control_system(project::CanonicalProject)
    system = project.control_system
    foreach(schema -> _validate_control_block_schema(project, schema), system.block_schemas)
    control_ids = _control_owner_ids(system)
    length(control_ids) == length(unique(control_ids)) ||
        _semantic_fail(:duplicate_control_identity, "control system repeats an owner identity")
    other_ids = Set(vcat(
        [project.metadata.identity.id],
        [item.identity.id for item in project.records],
        _graph_element_ids(project.graphs),
        [item.identity.id for item in project.asset_library.assets],
        [item.identity.id for item in project.asset_library.profiles],
        [item.identity.id for item in project.asset_library.curves],
        [item.identity.id for item in project.asset_library.matrices],
        [item.identity.id for item in project.asset_library.measurements],
        [item.identity.id for item in project.hierarchy.instances],
    ))
    isempty(intersect(other_ids, Set(control_ids))) ||
        _semantic_fail(:control_identity_collision, "control owner identity collides with other project semantics")
    foreach(network -> _validate_control_network(project, system, network), system.networks)
    used_ports = Set{ProjectId}()
    used_links = Set{ProjectId}()
    for network in system.networks
        network_ports = Set{ProjectId}(item.port for item in network.external_ports)
        for block in network.blocks, binding in block.ports
            push!(network_ports, binding.port)
        end
        isempty(intersect(used_ports, network_ports)) ||
            _semantic_fail(:control_port_in_multiple_networks, "signal port belongs to multiple control networks")
        union!(used_ports, network_ports)
        network_links = Set{ProjectId}(network.links)
        isempty(intersect(used_links, network_links)) ||
            _semantic_fail(:control_link_in_multiple_networks, "signal link belongs to multiple control networks")
        union!(used_links, network_links)
    end
    unowned_edges = Tuple{ProjectId,ProjectId}[
        (
            _signal_cycle_vertex(project, link.source_port),
            _signal_cycle_vertex(project, link.target_port),
        ) for link in project.graphs.signal_connections
        if !link.delayed && link.identity.id ∉ used_links
    ]
    unowned_vertices = ProjectId[_signal_cycle_vertex(project, port.identity.id) for port in project.graphs.ports]
    isempty(_cyclic_components(unowned_vertices, unowned_edges)) ||
        _semantic_fail(:algebraic_signal_cycle, "signal graph contains an undeclared pure algebraic cycle")
    return true
end
