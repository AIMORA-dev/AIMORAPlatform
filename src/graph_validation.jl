function _graph_collections(graphs::SemanticGraphs)
    return (
        graphs.nodes,
        graphs.ports,
        graphs.physical_connections,
        graphs.signal_connections,
        graphs.workflow_dependencies,
        graphs.cross_references,
        graphs.view_projections,
    )
end

function _graph_element_ids(graphs::SemanticGraphs)
    ids = ProjectId[]
    for collection in _graph_collections(graphs), element in collection
        push!(ids, element.identity.id)
    end
    return ids
end

function _find_node(graphs::SemanticGraphs, id::ProjectId)
    index = findfirst(node -> node.identity.id == id, graphs.nodes)
    isnothing(index) && _semantic_fail(:unknown_graph_node, "graph node does not exist")
    return graphs.nodes[index]
end

function _find_port(graphs::SemanticGraphs, id::ProjectId)
    index = findfirst(port -> port.identity.id == id, graphs.ports)
    isnothing(index) && _semantic_fail(:unknown_graph_port, "graph port does not exist")
    return graphs.ports[index]
end

function _nominal_levels_match(project::CanonicalProject, left, right)
    (isnothing(left) || isnothing(right)) && return true
    validate_quantity(project.units, left)
    validate_quantity(project.units, right)
    left_quantity = left.quantity
    right_quantity = right.quantity
    left_quantity.orientation == right_quantity.orientation || return false
    if left_quantity.unit == UnitId("pu") || right_quantity.unit == UnitId("pu")
        return left_quantity.unit == right_quantity.unit &&
            left_quantity.base == right_quantity.base &&
            exact_rational(left_quantity.value) == exact_rational(right_quantity.value)
    end
    converted = convert_quantity(project.units, left_quantity, right_quantity.unit)
    return exact_rational(converted.value) == exact_rational(right_quantity.value)
end

function _validate_physical_connection(project::CanonicalProject, connection::PhysicalConnection)
    port = _find_port(project.graphs, connection.port)
    node = _find_node(project.graphs, connection.node)
    port.domain.family == PhysicalGraph ||
        _semantic_fail(:signal_port_in_physical_connection, "physical connection references a signal port")
    port.domain == node.domain ||
        _semantic_fail(:physical_domain_mismatch, "physical connection crosses incompatible domains")
    mapped_port = Set(mapping.port_carrier for mapping in connection.mappings)
    mapped_port == Set(port.carriers) ||
        _semantic_fail(:incomplete_port_carrier_map, "physical connection does not map every port carrier exactly once")
    node_carriers = Set(node.carriers)
    all(mapping -> mapping.node_carrier in node_carriers, connection.mappings) ||
        _semantic_fail(:unknown_node_carrier, "physical connection maps to an absent node carrier")
    all(mapping -> (
        mapping.port_carrier.domain == port.domain &&
        mapping.node_carrier.domain == node.domain
    ), connection.mappings) ||
        _semantic_fail(:carrier_domain_mismatch, "physical connection carrier map crosses domains")
    _nominal_levels_match(project, port.nominal_level, node.nominal_level) ||
        _semantic_fail(:nominal_level_mismatch, "physical port and node nominal levels differ")
    return true
end

function _validate_signal_connection(project::CanonicalProject, connection::SignalConnection)
    source = _find_port(project.graphs, connection.source_port)
    target = _find_port(project.graphs, connection.target_port)
    source.domain.family == SignalGraph && target.domain.family == SignalGraph ||
        _semantic_fail(:physical_port_in_signal_connection, "signal connection references a physical port")
    source.direction == PortOutput && target.direction == PortInput ||
        _semantic_fail(:invalid_signal_direction, "signal connection must link output to input")
    source.signal_contract == target.signal_contract ||
        _semantic_fail(:signal_contract_mismatch, "signal connection quantity contracts differ")
    return true
end

function _has_directed_cycle(vertices::AbstractVector{ProjectId}, edges)
    adjacency = Dict{ProjectId,Vector{ProjectId}}(vertex => ProjectId[] for vertex in vertices)
    for (source, target) in edges
        haskey(adjacency, source) || (adjacency[source] = ProjectId[])
        haskey(adjacency, target) || (adjacency[target] = ProjectId[])
        push!(adjacency[source], target)
    end
    state = Dict{ProjectId,UInt8}(vertex => 0x00 for vertex in keys(adjacency))
    function visit(vertex)
        state[vertex] == 0x01 && return true
        state[vertex] == 0x02 && return false
        state[vertex] = 0x01
        any(visit, adjacency[vertex]) && return true
        state[vertex] = 0x02
        return false
    end
    return any(visit, sort!(collect(keys(adjacency)); by = id -> id.value))
end

function _validate_local_reference(project::CanonicalProject, reference::ProjectReference)
    reference.target isa GlobalReferenceTarget && return true
    id = reference.target.id
    if reference.kind == ReferenceNode
        _find_node(project.graphs, id)
    elseif reference.kind == ReferenceAsset
        _asset_or_record_exists(project, id) ||
            _semantic_fail(:dangling_cross_graph_reference, "typed asset target does not exist")
    elseif reference.kind in (ReferenceControlBlock, ReferenceEvent, ReferenceStudy, ReferenceWorkflow, ReferenceResult, ReferenceView)
        any(record -> record.identity.id == id, project.records) ||
            _semantic_fail(:dangling_cross_graph_reference, "typed cross-graph target record does not exist")
    else
        _semantic_fail(:invalid_cross_graph_target, "reference kind cannot target a project graph")
    end
    return true
end

function _validate_cross_reference(project::CanonicalProject, reference::CrossGraphReference)
    semantic_ids = Set(vcat(
        [record.identity.id for record in project.records],
        _graph_element_ids(project.graphs),
    ))
    reference.source in semantic_ids ||
        _semantic_fail(:dangling_cross_graph_source, "cross-graph source does not exist")
    if reference.kind == EventTargetReference
        reference.target.kind in (ReferenceAsset, ReferenceNode, ReferenceControlBlock) ||
            _semantic_fail(:invalid_event_target, "event target must be physical or control semantics")
    elseif reference.kind == StudyResultReference
        reference.target.kind == ReferenceResult ||
            _semantic_fail(:invalid_study_result_reference, "study result reference must target a result")
    else
        reference.target.kind in (ReferenceStudy, ReferenceResult, ReferenceWorkflow) ||
            _semantic_fail(:invalid_workflow_input_reference, "workflow input must target a study, result, or workflow")
    end
    return _validate_local_reference(project, reference.target)
end

"""Validate graph separation, references, topology, direction, levels, and prohibited cycles."""
function validate_graphs(project::CanonicalProject)
    graphs = project.graphs
    graph_ids = _graph_element_ids(graphs)
    length(graph_ids) == length(unique(graph_ids)) ||
        _semantic_fail(:duplicate_graph_element_id, "semantic graphs repeat an element ID")
    record_ids = Set(record.identity.id for record in project.records)
    isempty(intersect(record_ids, Set(graph_ids))) ||
        _semantic_fail(:graph_record_identity_collision, "graph element ID collides with a canonical record ID")
    port_owner_ids = union(
        record_ids,
        Set(item.identity.id for item in project.asset_library.assets),
        Set(_control_port_owner_ids(project.control_system)),
    )
    registered_namespaces = Set(item.namespace for item in project.registry.namespaces)
    for node in graphs.nodes
        node.domain.type.namespace in registered_namespaces ||
            _semantic_fail(:unknown_graph_domain_namespace, "node domain namespace is not registered")
        !isnothing(node.nominal_level) && validate_quantity(project.units, node.nominal_level)
    end
    for port in graphs.ports
        port.owner in port_owner_ids || _semantic_fail(:dangling_port_owner, "port owner semantic object does not exist")
        port.domain.type.namespace in registered_namespaces ||
            _semantic_fail(:unknown_graph_domain_namespace, "port domain namespace is not registered")
        !isnothing(port.nominal_level) && validate_quantity(project.units, port.nominal_level)
        if !isnothing(port.signal_contract)
            unit = lookup_unit(project.units, port.signal_contract.unit)
            unit.dimension == port.signal_contract.dimension ||
                _semantic_fail(:signal_unit_dimension_mismatch, "signal contract unit has a different dimension")
            unit.per_unit && _semantic_fail(:per_unit_signal_contract, "signal contract requires a physical unit and explicit base semantics")
        end
    end
    foreach(connection -> _validate_physical_connection(project, connection), graphs.physical_connections)
    foreach(connection -> _validate_signal_connection(project, connection), graphs.signal_connections)
    workflow_vertices = ProjectId[collect(record_ids)...]
    workflow_edges = Tuple{ProjectId,ProjectId}[(edge.upstream, edge.downstream) for edge in graphs.workflow_dependencies]
    all(edge -> edge.upstream in record_ids && edge.downstream in record_ids, graphs.workflow_dependencies) ||
        _semantic_fail(:dangling_workflow_dependency, "workflow dependency references a missing owner")
    _has_directed_cycle(workflow_vertices, workflow_edges) &&
        _semantic_fail(:workflow_cycle, "workflow dependency graph contains a cycle")
    foreach(reference -> _validate_cross_reference(project, reference), graphs.cross_references)
    nonview_ids = Set{ProjectId}()
    for collection in (
        graphs.nodes,
        graphs.ports,
        graphs.physical_connections,
        graphs.signal_connections,
        graphs.workflow_dependencies,
        graphs.cross_references,
    ), element in collection
        push!(nonview_ids, element.identity.id)
    end
    semantic_owners = union(port_owner_ids, nonview_ids, Set(_control_owner_ids(project.control_system)))
    for projection in graphs.view_projections
        projection.view in record_ids || _semantic_fail(:dangling_view_owner, "view projection references a missing view record")
        projection.semantic_owner in semantic_owners ||
            _semantic_fail(:dangling_view_projection, "view projection references missing semantics")
        projection.semantic_owner == projection.identity.id &&
            _semantic_fail(:recursive_view_projection, "view projection cannot project itself")
    end
    return true
end
