@enum GraphElementKind::UInt8 begin
    GraphNodeElement = 0x01
    GraphPortElement = 0x02
    GraphCrossReferenceElement = 0x03
    GraphViewProjectionElement = 0x04
end

@enum GraphConnectionKind::UInt8 begin
    PhysicalConnectionElement = 0x01
    SignalConnectionElement = 0x02
    WorkflowDependencyElement = 0x03
end

struct AddGraphElementPatch <: ProjectPatch
    element::SemanticGraphElement

    function AddGraphElementPatch(element::SemanticGraphElement)
        element isa SemanticConnection &&
            _semantic_fail(:invalid_graph_patch, "connections require ConnectGraphPatch")
        return new(element)
    end
end

Base.:(==)(left::AddGraphElementPatch, right::AddGraphElementPatch) = left.element == right.element

struct RemoveGraphElementPatch <: ProjectPatch
    kind::GraphElementKind
    id::ProjectId
end

Base.:(==)(left::RemoveGraphElementPatch, right::RemoveGraphElementPatch) =
    left.kind == right.kind && left.id == right.id

struct ConnectGraphPatch <: ProjectPatch
    connection::SemanticConnection
end

Base.:(==)(left::ConnectGraphPatch, right::ConnectGraphPatch) =
    left.connection == right.connection

struct DisconnectGraphPatch <: ProjectPatch
    kind::GraphConnectionKind
    id::ProjectId
end

Base.:(==)(left::DisconnectGraphPatch, right::DisconnectGraphPatch) =
    left.kind == right.kind && left.id == right.id

function _graphs_with(
    graphs::SemanticGraphs;
    nodes = collect(graphs.nodes),
    ports = collect(graphs.ports),
    physical_connections = collect(graphs.physical_connections),
    signal_connections = collect(graphs.signal_connections),
    workflow_dependencies = collect(graphs.workflow_dependencies),
    cross_references = collect(graphs.cross_references),
    view_projections = collect(graphs.view_projections),
)
    return SemanticGraphs(;
        nodes,
        ports,
        physical_connections,
        signal_connections,
        workflow_dependencies,
        cross_references,
        view_projections,
    )
end

function _graph_id_available(project::CanonicalProject, id::ProjectId)
    id == project.metadata.identity.id && return false
    any(record -> record.identity.id == id, project.records) && return false
    return id ∉ _graph_element_ids(project.graphs)
end

function _graph_change_effect(owner::ProjectId, view_only::Bool = false)
    scopes = view_only ? [InvalidateViews] : [InvalidateStudyResults, InvalidateWorkflowResults]
    return CommandEffect(owner, DependencyInvalidation(owner, scopes))
end

function _apply_patch(project::CanonicalProject, patch::AddGraphElementPatch)
    element = patch.element
    _graph_id_available(project, element.identity.id) ||
        _semantic_fail(:duplicate_graph_element_id, "graph element patch repeats an existing ID")
    graphs = if element isa GraphNode
        _graphs_with(project.graphs; nodes = vcat(collect(project.graphs.nodes), [element]))
    elseif element isa SemanticPort
        _graphs_with(project.graphs; ports = vcat(collect(project.graphs.ports), [element]))
    elseif element isa CrossGraphReference
        _graphs_with(project.graphs; cross_references = vcat(collect(project.graphs.cross_references), [element]))
    else
        _graphs_with(project.graphs; view_projections = vcat(collect(project.graphs.view_projections), [element]))
    end
    updated = _replace_project_graphs(project, graphs)
    return updated, _graph_change_effect(element.identity.id, element isa ViewProjection)
end

function _remove_by_id(items, id::ProjectId, code::Symbol, message::String)
    copied = collect(items)
    index = findfirst(item -> item.identity.id == id, copied)
    isnothing(index) && _semantic_fail(code, message)
    removed = copied[index]
    deleteat!(copied, index)
    return copied, removed
end

function _apply_patch(project::CanonicalProject, patch::RemoveGraphElementPatch)
    if patch.kind == GraphNodeElement
        items, _ = _remove_by_id(project.graphs.nodes, patch.id, :unknown_graph_node, "graph node does not exist")
        graphs = _graphs_with(project.graphs; nodes = items)
    elseif patch.kind == GraphPortElement
        items, _ = _remove_by_id(project.graphs.ports, patch.id, :unknown_graph_port, "graph port does not exist")
        graphs = _graphs_with(project.graphs; ports = items)
    elseif patch.kind == GraphCrossReferenceElement
        items, _ = _remove_by_id(project.graphs.cross_references, patch.id, :unknown_cross_graph_reference, "cross-graph reference does not exist")
        graphs = _graphs_with(project.graphs; cross_references = items)
    else
        items, _ = _remove_by_id(project.graphs.view_projections, patch.id, :unknown_view_projection, "view projection does not exist")
        graphs = _graphs_with(project.graphs; view_projections = items)
    end
    updated = _replace_project_graphs(project, graphs)
    return updated, _graph_change_effect(patch.id, patch.kind == GraphViewProjectionElement)
end

function _apply_patch(project::CanonicalProject, patch::ConnectGraphPatch)
    connection = patch.connection
    _graph_id_available(project, connection.identity.id) ||
        _semantic_fail(:duplicate_graph_element_id, "connection patch repeats an existing ID")
    graphs = if connection isa PhysicalConnection
        _graphs_with(project.graphs; physical_connections = vcat(collect(project.graphs.physical_connections), [connection]))
    elseif connection isa SignalConnection
        _graphs_with(project.graphs; signal_connections = vcat(collect(project.graphs.signal_connections), [connection]))
    else
        _graphs_with(project.graphs; workflow_dependencies = vcat(collect(project.graphs.workflow_dependencies), [connection]))
    end
    return _replace_project_graphs(project, graphs), _graph_change_effect(connection.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::DisconnectGraphPatch)
    if patch.kind == PhysicalConnectionElement
        items, _ = _remove_by_id(project.graphs.physical_connections, patch.id, :unknown_physical_connection, "physical connection does not exist")
        graphs = _graphs_with(project.graphs; physical_connections = items)
    elseif patch.kind == SignalConnectionElement
        items, _ = _remove_by_id(project.graphs.signal_connections, patch.id, :unknown_signal_connection, "signal connection does not exist")
        graphs = _graphs_with(project.graphs; signal_connections = items)
    else
        items, _ = _remove_by_id(project.graphs.workflow_dependencies, patch.id, :unknown_workflow_dependency, "workflow dependency does not exist")
        graphs = _graphs_with(project.graphs; workflow_dependencies = items)
    end
    return _replace_project_graphs(project, graphs), _graph_change_effect(patch.id)
end

function _graph_element(project::CanonicalProject, kind::GraphElementKind, id::ProjectId)
    collection = if kind == GraphNodeElement
        project.graphs.nodes
    elseif kind == GraphPortElement
        project.graphs.ports
    elseif kind == GraphCrossReferenceElement
        project.graphs.cross_references
    else
        project.graphs.view_projections
    end
    index = findfirst(item -> item.identity.id == id, collection)
    isnothing(index) && _semantic_fail(:invalid_command_inverse, "graph element is absent before removal")
    return collection[index]
end

function _graph_connection(project::CanonicalProject, kind::GraphConnectionKind, id::ProjectId)
    collection = if kind == PhysicalConnectionElement
        project.graphs.physical_connections
    elseif kind == SignalConnectionElement
        project.graphs.signal_connections
    else
        project.graphs.workflow_dependencies
    end
    index = findfirst(item -> item.identity.id == id, collection)
    isnothing(index) && _semantic_fail(:invalid_command_inverse, "graph connection is absent before disconnection")
    return collection[index]
end

function _element_kind(element::SemanticGraphElement)
    element isa GraphNode && return GraphNodeElement
    element isa SemanticPort && return GraphPortElement
    element isa CrossGraphReference && return GraphCrossReferenceElement
    element isa ViewProjection && return GraphViewProjectionElement
    _semantic_fail(:invalid_graph_patch, "semantic connection is not a standalone graph element")
end

function _connection_kind(connection::SemanticConnection)
    connection isa PhysicalConnection && return PhysicalConnectionElement
    connection isa SignalConnection && return SignalConnectionElement
    return WorkflowDependencyElement
end

_inverse_patch(patch::AddGraphElementPatch, ::CanonicalProject) =
    RemoveGraphElementPatch(_element_kind(patch.element), patch.element.identity.id)
_inverse_patch(patch::RemoveGraphElementPatch, project::CanonicalProject) =
    AddGraphElementPatch(_graph_element(project, patch.kind, patch.id))
_inverse_patch(patch::ConnectGraphPatch, ::CanonicalProject) =
    DisconnectGraphPatch(_connection_kind(patch.connection), patch.connection.identity.id)
_inverse_patch(patch::DisconnectGraphPatch, project::CanonicalProject) =
    ConnectGraphPatch(_graph_connection(project, patch.kind, patch.id))

_patch_signature(patch::AddGraphElementPatch) =
    "add-graph:" * patch.element.identity.id.value
_patch_signature(patch::RemoveGraphElementPatch) =
    "remove-graph:" * string(UInt8(patch.kind)) * ":" * patch.id.value
_patch_signature(patch::ConnectGraphPatch) =
    "connect-graph:" * patch.connection.identity.id.value
_patch_signature(patch::DisconnectGraphPatch) =
    "disconnect-graph:" * string(UInt8(patch.kind)) * ":" * patch.id.value

_declared_patch_effect(::CanonicalProject, patch::AddGraphElementPatch) =
    _graph_change_effect(patch.element.identity.id, patch.element isa ViewProjection)
_declared_patch_effect(::CanonicalProject, patch::RemoveGraphElementPatch) =
    _graph_change_effect(patch.id, patch.kind == GraphViewProjectionElement)
_declared_patch_effect(::CanonicalProject, patch::ConnectGraphPatch) =
    _graph_change_effect(patch.connection.identity.id)
_declared_patch_effect(::CanonicalProject, patch::DisconnectGraphPatch) =
    _graph_change_effect(patch.id)
