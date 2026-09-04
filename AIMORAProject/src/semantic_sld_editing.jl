"""A validated, replayable semantic SLD edit against one exact project state."""
struct SemanticSldEditPlan
    base_hash::ContentDigest
    commands::CanonicalList{ProjectCommand}
    changed_owners::CanonicalList{ProjectId}
    invalidations::CanonicalList{DependencyInvalidation}
    physical_topology_changed::Bool
end

function _semantic_sld_command(
    action::ProjectId,
    index::Integer,
    role::AbstractString,
    patch::ProjectPatch,
)
    suffix = lpad(string(index), 2, '0')
    return ProjectCommand(ProjectId("$(action.value).$(role)$(suffix)"), patch)
end

function _semantic_sld_plan(
    project::CanonicalProject,
    commands::Vector{ProjectCommand};
    physical_topology_changed::Bool,
)
    isempty(commands) &&
        _semantic_fail(:empty_semantic_sld_edit, "semantic SLD edit requires at least one command")
    working = project
    effects = CommandEffect[]
    for command in commands
        working, effect = _apply_command(working, command)
        push!(effects, effect)
    end
    verified_project(working)
    return SemanticSldEditPlan(
        project_resolved_hash(project),
        CanonicalList{ProjectCommand}(commands),
        CanonicalList{ProjectId}(_unique_changed_owners(effects)),
        CanonicalList{DependencyInvalidation}(_unique_invalidations(effects)),
        physical_topology_changed,
    )
end

"""Plan placement of one Julia-owned asset and its view projection without deriving topology."""
function plan_equipment_placement(
    project::CanonicalProject,
    action::ProjectId,
    asset::CanonicalAsset,
    ports::AbstractVector{SemanticPort},
    semantic_projection::ViewProjection,
    drawing_projection::DrawingProjection,
)
    isempty(ports) && _semantic_fail(
        :equipment_without_ports,
        "semantic equipment placement requires at least one explicit typed port",
    )
    all(port -> port.owner == asset.identity.id, ports) || _semantic_fail(
        :equipment_port_owner_mismatch,
        "placed equipment ports must explicitly name the placed asset",
    )
    semantic_projection.semantic_owner == asset.identity.id || _semantic_fail(
        :equipment_projection_owner_mismatch,
        "equipment view projection must explicitly name the placed asset",
    )
    drawing_projection.semantic_projection == semantic_projection.identity.id || _semantic_fail(
        :drawing_projection_owner_mismatch,
        "drawing projection must explicitly name the semantic view projection",
    )
    commands = ProjectCommand[]
    push!(commands, _semantic_sld_command(action, 1, "asset", AddAssetPatch(asset)))
    for (index, port) in enumerate(ports)
        push!(commands, _semantic_sld_command(action, index + 1, "port", AddGraphElementPatch(port)))
    end
    projection_index = length(commands) + 1
    push!(commands, _semantic_sld_command(
        action,
        projection_index,
        "semantic_projection",
        AddGraphElementPatch(semantic_projection),
    ))
    push!(commands, _semantic_sld_command(
        action,
        projection_index + 1,
        "drawing_projection",
        AddDrawingRecordPatch(drawing_projection),
    ))
    return _semantic_sld_plan(project, commands; physical_topology_changed = true)
end

"""Plan explicit port-to-node connections and display routes; coordinates never imply connectivity."""
function plan_typed_conductor(
    project::CanonicalProject,
    action::ProjectId,
    node::GraphNode,
    connections::AbstractVector{PhysicalConnection},
    routes::AbstractVector{DrawingRoute},
)
    length(connections) >= 2 || _semantic_fail(
        :insufficient_conductor_connections,
        "a direct conductor or junction requires at least two explicit port connections",
    )
    all(connection -> connection.node == node.identity.id, connections) || _semantic_fail(
        :conductor_node_mismatch,
        "every conductor connection must explicitly name the supplied node",
    )
    port_ids = getfield.(connections, :port)
    length(port_ids) == length(unique(port_ids)) || _semantic_fail(
        :duplicate_conductor_port,
        "a conductor edit repeats a semantic port",
    )
    connection_ids = Set(getfield.(getfield.(connections, :identity), :id))
    route_connections = ProjectId[]
    for route in routes
        isnothing(route.semantic_connection) && _semantic_fail(
            :drafting_route_without_connection,
            "semantic conductor routes require explicit physical connection identities",
        )
        push!(route_connections, route.semantic_connection)
    end
    (Set(route_connections) == connection_ids &&
     length(route_connections) == length(connection_ids)) || _semantic_fail(
        :conductor_route_mismatch,
        "each explicit physical connection requires exactly one display route",
    )

    commands = ProjectCommand[]
    existing_node = findfirst(item -> item.identity.id == node.identity.id, project.graphs.nodes)
    if isnothing(existing_node)
        push!(commands, _semantic_sld_command(action, 1, "node", AddGraphElementPatch(node)))
    elseif project.graphs.nodes[existing_node] != node
        _semantic_fail(
            :junction_identity_conflict,
            "junction identity already resolves to a different physical node",
        )
    end
    for connection in connections
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "connection",
            ConnectGraphPatch(connection),
        ))
    end
    for route in routes
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "route",
            AddDrawingRecordPatch(route),
        ))
    end
    return _semantic_sld_plan(project, commands; physical_topology_changed = true)
end

function _plan_drawing_replacement(
    project::CanonicalProject,
    action::ProjectId,
    role::String,
    replacement::CanonicalDrawingRecord,
)
    return _semantic_sld_plan(
        project,
        [_semantic_sld_command(action, 1, role, ReplaceDrawingRecordPatch(replacement))];
        physical_topology_changed = false,
    )
end

"""Plan a view-only equipment or busbar projection edit."""
plan_projection_edit(
    project::CanonicalProject,
    action::ProjectId,
    replacement::DrawingProjection,
) = _plan_drawing_replacement(project, action, "projection", replacement)

"""Plan a view-only conductor-handle edit without changing its bound connection."""
plan_conductor_route_edit(
    project::CanonicalProject,
    action::ProjectId,
    replacement::DrawingRoute,
) = _plan_drawing_replacement(project, action, "route", replacement)

"""Plan an explicit semantic cross-reference label addition or update."""
function plan_cross_reference_label(
    project::CanonicalProject,
    action::ProjectId,
    label::DrawingLabel,
)
    isnothing(label.bound_owner) && _semantic_fail(
        :unbound_cross_reference_label,
        "semantic cross-reference labels require an explicit owner and field",
    )
    exists = label.identity.id in drawing_workspace_ids(project.drawings)
    patch = exists ? ReplaceDrawingRecordPatch(label) : AddDrawingRecordPatch(label)
    return _semantic_sld_plan(
        project,
        [_semantic_sld_command(action, 1, "cross_reference", patch)];
        physical_topology_changed = false,
    )
end

"""Remove one drawing/view projection while preserving its physical semantic owner."""
function plan_projection_removal(
    project::CanonicalProject,
    action::ProjectId,
    drawing_projection_id::ProjectId,
)
    record = drawing_record(project.drawings, drawing_projection_id)
    record isa DrawingProjection || _semantic_fail(
        :projection_removal_type_mismatch,
        "projection removal requires a drawing projection identity",
    )
    semantic_projection_id = record.semantic_projection
    any(
        projection -> projection.identity.id == semantic_projection_id,
        project.graphs.view_projections,
    ) || _semantic_fail(
        :unknown_view_projection,
        "drawing projection does not resolve to a semantic view projection",
    )
    commands = [
        _semantic_sld_command(
            action,
            1,
            "drawing_projection",
            RemoveDrawingRecordPatch(drawing_projection_id),
        ),
        _semantic_sld_command(
            action,
            2,
            "semantic_projection",
            RemoveGraphElementPatch(GraphViewProjectionElement, semantic_projection_id),
        ),
    ]
    return _semantic_sld_plan(project, commands; physical_topology_changed = false)
end

"""Plan explicit physical deletion and report every dependent identity invalidated by it."""
function plan_physical_asset_deletion(
    project::CanonicalProject,
    action::ProjectId,
    asset_id::ProjectId,
)
    canonical_asset(project, asset_id)
    port_ids = Set(
        port.identity.id for port in project.graphs.ports if port.owner == asset_id
    )
    connection_ids = Set(
        connection.identity.id for connection in project.graphs.physical_connections
        if connection.port in port_ids
    )
    signal_connection_ids = Set(
        connection.identity.id for connection in project.graphs.signal_connections
        if connection.source_port in port_ids || connection.target_port in port_ids
    )
    dependent_ids = union(
        Set([asset_id]),
        port_ids,
        connection_ids,
        signal_connection_ids,
    )
    view_projection_ids = Set(
        projection.identity.id for projection in project.graphs.view_projections
        if projection.semantic_owner in dependent_ids
    )
    drawing_projection_ids = Set(
        projection.identity.id for projection in project.drawings.projections
        if projection.semantic_projection in view_projection_ids
    )
    route_ids = Set(
        route.identity.id for route in project.drawings.routes
        if !isnothing(route.semantic_connection) && route.semantic_connection in connection_ids
    )
    label_ids = Set(
        label.identity.id for label in project.drawings.labels
        if !isnothing(label.bound_owner) && label.bound_owner in dependent_ids
    )

    commands = ProjectCommand[]
    for id in sort!(collect(union(route_ids, label_ids, drawing_projection_ids)); by = item -> item.value)
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "drawing_dependent",
            RemoveDrawingRecordPatch(id),
        ))
    end
    for id in sort!(collect(view_projection_ids); by = item -> item.value)
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "view_projection",
            RemoveGraphElementPatch(GraphViewProjectionElement, id),
        ))
    end
    for id in sort!(collect(connection_ids); by = item -> item.value)
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "connection",
            DisconnectGraphPatch(PhysicalConnectionElement, id),
        ))
    end
    for id in sort!(collect(signal_connection_ids); by = item -> item.value)
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "signal_connection",
            DisconnectGraphPatch(SignalConnectionElement, id),
        ))
    end
    for id in sort!(collect(port_ids); by = item -> item.value)
        push!(commands, _semantic_sld_command(
            action,
            length(commands) + 1,
            "port",
            RemoveGraphElementPatch(GraphPortElement, id),
        ))
    end
    push!(commands, _semantic_sld_command(
        action,
        length(commands) + 1,
        "asset",
        RemoveAssetPatch(asset_id),
    ))
    return _semantic_sld_plan(project, commands; physical_topology_changed = true)
end

"""Apply an already validated plan only to its exact base state."""
function apply_semantic_sld_edit!(
    transaction::ProjectTransaction,
    plan::SemanticSldEditPlan,
)
    project_resolved_hash(transaction.working) == plan.base_hash || _semantic_fail(
        :semantic_edit_base_mismatch,
        "semantic SLD edit plan does not match the transaction working state",
    )
    for command in plan.commands
        apply!(transaction, command)
    end
    validate!(transaction)
    return transaction
end
