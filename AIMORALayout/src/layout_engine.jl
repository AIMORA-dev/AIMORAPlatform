struct _LayoutEdge
    connection::ProjectId
    source::ProjectId
    target::ProjectId
end

struct _LayoutRect
    left::Int
    bottom::Int
    right::Int
    top::Int
end

_coordinate(x::Integer, y::Integer) =
    DrawingCoordinate(ExactDecimal(x, 0), ExactDecimal(y, 0))

function _coordinate_value(value::ExactDecimal)
    coefficient = Int(value.coefficient)
    exponent = Int(value.exponent)
    if exponent >= 0
        return coefficient * (10^exponent)
    end
    divisor = 10^(-exponent)
    coefficient % divisor == 0 ||
        throw(ArgumentError("automatic layout requires integer-grid drawing coordinates"))
    return div(coefficient, divisor)
end

_position_tuple(position::DrawingCoordinate) =
    (_coordinate_value(position.x), _coordinate_value(position.y))

function _stable_digest(parts::AbstractString...)
    state = UInt64(0xcbf29ce484222325)
    for part in parts
        for byte in codeunits(part)
            state = xor(state, UInt64(byte)) * UInt64(0x100000001b3)
        end
        state = xor(state, UInt64(0xff)) * UInt64(0x100000001b3)
    end
    return string(state; base = 16, pad = 16)
end

_layout_prefix(request::LayoutRequest) =
    "aimora.layout.v" * _stable_digest(request.view.value)

function _generated_id(request::LayoutRequest, role::AbstractString, sources::ProjectId...)
    digest = _stable_digest(request.view.value, role, (source.value for source in sources)...)
    return ProjectId(_layout_prefix(request) * "." * role * ".v" * digest)
end

_page_id(request::LayoutRequest, index::Integer, role::AbstractString) =
    ProjectId(_layout_prefix(request) * ".page.p" * string(index) * "." * role)

function _unique_dictionary(records, key, description::AbstractString)
    result = Dict()
    for record in records
        identity = key(record)
        haskey(result, identity) &&
            throw(ArgumentError("duplicate $description identity $(identity.value)"))
        result[identity] = record
    end
    return result
end

function _record_locked(
    workspace::DrawingWorkspace,
    identity::ProjectId,
    aspects::Tuple,
)
    return any(workspace.locks) do lock
        lock.owner == identity && any(aspect -> aspect in aspects, lock.aspects)
    end
end

function _manual(request::LayoutRequest, identities::ProjectId...)
    manual = Set(request.manual_records)
    return any(identity -> identity in manual, identities)
end

function _view_projection_data(project::CanonicalProject, request::LayoutRequest)
    view_records = filter(
        view -> view.identity.id == request.view,
        collect(project.drawings.views),
    )
    length(view_records) == 1 ||
        throw(ArgumentError("layout view $(request.view.value) must exist exactly once"))
    drawing_view = only(view_records)
    semantic_view = drawing_view.semantic_view
    isnothing(semantic_view) &&
        throw(ArgumentError("automatic layout requires a semantic model-space view"))
    projections = filter(
        projection -> projection.view == semantic_view,
        collect(project.graphs.view_projections),
    )
    sort!(projections; by = projection -> projection.identity.id.value)
    owners = _unique_dictionary(
        projections,
        projection -> projection.semantic_owner,
        "semantic owner",
    )
    return drawing_view, projections, owners
end

function _layout_edges(project::CanonicalProject, owners)
    ports = _unique_dictionary(
        project.graphs.ports,
        port -> port.identity.id,
        "semantic port",
    )
    edges = _LayoutEdge[]
    for connection in project.graphs.physical_connections
        port = get(ports, connection.port, nothing)
        isnothing(port) && continue
        haskey(owners, port.owner) || continue
        haskey(owners, connection.node) || continue
        port.owner == connection.node && continue
        push!(edges, _LayoutEdge(connection.identity.id, port.owner, connection.node))
    end
    sort!(edges; by = edge -> edge.connection.value)
    return edges
end

function _adjacency(owner_ids::Vector{ProjectId}, edges::Vector{_LayoutEdge})
    adjacent = Dict(owner => ProjectId[] for owner in owner_ids)
    for edge in edges
        push!(adjacent[edge.source], edge.target)
        push!(adjacent[edge.target], edge.source)
    end
    for neighbors in values(adjacent)
        sort!(unique!(neighbors); by = id -> id.value)
    end
    return adjacent
end

function _layout_ranks(
    owner_ids::Vector{ProjectId},
    adjacent::Dict{ProjectId,Vector{ProjectId}},
    request::LayoutRequest,
)
    hints = Dict(request.rank_hints)
    unknown_hints = setdiff(Set(keys(hints)), Set(owner_ids))
    isempty(unknown_hints) || throw(
        ArgumentError(
            "rank hints reference owners outside the semantic view: " *
            join(sort!(getfield.(collect(unknown_hints), :value)), ", "),
        ),
    )
    ranks = Dict{ProjectId,Int}()
    unseen = Set(owner_ids)
    while !isempty(unseen)
        component_start = first(sort!(collect(unseen); by = id -> id.value))
        component = ProjectId[]
        queue = ProjectId[component_start]
        delete!(unseen, component_start)
        cursor = 1
        while cursor <= length(queue)
            current = queue[cursor]
            cursor += 1
            push!(component, current)
            for neighbor in adjacent[current]
                if neighbor in unseen
                    delete!(unseen, neighbor)
                    push!(queue, neighbor)
                end
            end
        end
        hinted = filter(owner -> haskey(hints, owner), component)
        leaves = filter(owner -> length(adjacent[owner]) <= 1, component)
        root = if !isempty(hinted)
            first(sort!(hinted; by = owner -> (hints[owner], owner.value)))
        elseif !isempty(leaves)
            first(sort!(leaves; by = owner -> owner.value))
        else
            first(sort!(component; by = owner -> owner.value))
        end
        component_queue = ProjectId[root]
        ranks[root] = get(hints, root, 0)
        visited = Set([root])
        cursor = 1
        while cursor <= length(component_queue)
            current = component_queue[cursor]
            cursor += 1
            for neighbor in adjacent[current]
                if !(neighbor in visited)
                    ranks[neighbor] = ranks[current] + 1
                    push!(visited, neighbor)
                    push!(component_queue, neighbor)
                end
            end
        end
    end
    for (owner, rank) in hints
        ranks[owner] = rank
    end
    return ranks
end

function _layout_slots(owner_ids::Vector{ProjectId}, request::LayoutRequest)
    slots = Dict{ProjectId,Int}()
    owner_set = Set(owner_ids)
    for (index, bay) in enumerate(request.repeated_bays)
        for member in bay.members
            member in owner_set || continue
            haskey(slots, member) &&
                throw(ArgumentError("semantic owner $(member.value) belongs to multiple bays"))
            slots[member] = index - 1
        end
    end
    next_slot = length(request.repeated_bays)
    for owner in owner_ids
        if !haskey(slots, owner)
            slots[owner] = next_slot
            next_slot += 1
        end
    end
    return slots
end

function _layout_scope(
    owner_ids::Vector{ProjectId},
    adjacent::Dict{ProjectId,Vector{ProjectId}},
    existing,
    semantic_projections,
    request::LayoutRequest,
)
    missing = Set(
        owner for owner in owner_ids if
        !haskey(existing, semantic_projections[owner].identity.id)
    )
    if request.mode == LayoutInitial
        return missing
    elseif request.mode == LayoutFull
        return Set(owner_ids)
    end
    isempty(request.focus) &&
        throw(ArgumentError("local and incremental layout require a semantic focus"))
    owner_set = Set(owner_ids)
    all(owner -> owner in owner_set, request.focus) ||
        throw(ArgumentError("layout focus must belong to the requested semantic view"))
    scope = Set(request.focus)
    for owner in request.focus
        union!(scope, adjacent[owner])
    end
    request.mode == LayoutIncremental && union!(scope, missing)
    return scope
end

function _metric_dictionary(request::LayoutRequest)
    metrics = Dict{ProjectId,LayoutNodeMetric}()
    for metric in request.node_metrics
        haskey(metrics, metric.semantic_owner) &&
            throw(ArgumentError("duplicate node metric for $(metric.semantic_owner.value)"))
        metrics[metric.semantic_owner] = metric
    end
    return metrics
end

function _metric(owner::ProjectId, metrics, options::LayoutOptions)
    return get(
        metrics,
        owner,
        LayoutNodeMetric(owner, options.default_node_width, options.default_node_height),
    )
end

_rect(x::Int, y::Int, width::Int, height::Int) = _LayoutRect(
    x - cld(width, 2),
    y - cld(height, 2),
    x + fld(width, 2),
    y + fld(height, 2),
)

function _overlaps(first::_LayoutRect, second::_LayoutRect, clearance::Int)
    return !(
        first.right + clearance < second.left ||
        second.right + clearance < first.left ||
        first.top + clearance < second.bottom ||
        second.top + clearance < first.bottom
    )
end

function _preferred_position(
    rank::Int,
    slot::Int,
    metric::LayoutNodeMetric,
    request::LayoutRequest,
)
    options = request.options
    column_pitch = options.default_node_width + options.column_gap
    row_pitch = options.default_node_height + options.row_gap
    if options.orientation == LayoutTopDown
        return (
            request.origin_x + slot * column_pitch,
            request.origin_y + rank * row_pitch,
        )
    end
    return (
        request.origin_x + rank * column_pitch,
        request.origin_y + slot * row_pitch,
    )
end

function _collision_reduced_position(
    preferred::Tuple{Int,Int},
    metric::LayoutNodeMetric,
    occupied::Vector{_LayoutRect},
    request::LayoutRequest,
)
    options = request.options
    cross_pitch = if options.orientation == LayoutTopDown
        metric.width + options.column_gap
    else
        metric.height + options.row_gap
    end
    for attempt in 0:(2 * length(occupied) + 2)
        direction = isodd(attempt) ? 1 : -1
        distance = cld(attempt, 2) * cross_pitch * direction
        candidate = if options.orientation == LayoutTopDown
            (preferred[1] + distance, preferred[2])
        else
            (preferred[1], preferred[2] + distance)
        end
        rectangle = _rect(candidate..., metric.width, metric.height)
        all(existing -> !_overlaps(rectangle, existing, options.clearance), occupied) &&
            return candidate, rectangle
    end
    throw(ArgumentError("unable to place a semantic owner without a collision"))
end

function _placement_records(project::CanonicalProject, request::LayoutRequest)
    _, _, semantic_projections = _view_projection_data(project, request)
    owner_ids = sort!(
        ProjectId[owner for owner in keys(semantic_projections)];
        by = id -> id.value,
    )
    edges = _layout_edges(project, semantic_projections)
    adjacent = _adjacency(owner_ids, edges)
    ranks = _layout_ranks(owner_ids, adjacent, request)
    slots = _layout_slots(owner_ids, request)
    existing = _unique_dictionary(
        filter(
            projection -> projection.view == request.view,
            collect(project.drawings.projections),
        ),
        projection -> projection.semantic_projection,
        "drawing projection",
    )
    scope = _layout_scope(
        owner_ids,
        adjacent,
        existing,
        semantic_projections,
        request,
    )
    metrics = _metric_dictionary(request)
    preserved = Set{ProjectId}()
    occupied = _LayoutRect[]
    for owner in owner_ids
        semantic_projection = semantic_projections[owner]
        record = get(existing, semantic_projection.identity.id, nothing)
        isnothing(record) && continue
        immutable =
            !(owner in scope) ||
            _manual(request, owner, semantic_projection.identity.id, record.identity.id) ||
            _record_locked(
                project.drawings,
                record.identity.id,
                (DrawingPositionLock, DrawingGeometryLock),
            )
        if immutable
            push!(preserved, owner)
            x, y = _position_tuple(record.position)
            metric = _metric(owner, metrics, request.options)
            push!(occupied, _rect(x, y, metric.width, metric.height))
        end
    end
    ordered_owners = sort!(owner_ids; by = owner -> (ranks[owner], slots[owner], owner.value))
    records = Dict{ProjectId,DrawingProjection}()
    placements = LayoutPlacement[]
    for owner in ordered_owners
        semantic_projection = semantic_projections[owner]
        record = get(existing, semantic_projection.identity.id, nothing)
        if isnothing(record) && !(owner in scope)
            continue
        end
        metric = _metric(owner, metrics, request.options)
        if owner in preserved
            position = record.position
            moved = false
        else
            preferred = _preferred_position(ranks[owner], slots[owner], metric, request)
            candidate, rectangle =
                _collision_reduced_position(preferred, metric, occupied, request)
            push!(occupied, rectangle)
            position = _coordinate(candidate...)
            moved = isnothing(record) || record.position != position
        end
        if isnothing(record)
            identity = ObjectIdentity(
                _generated_id(request, "projection", semantic_projection.identity.id),
            )
            record = DrawingProjection(
                identity,
                request.view,
                semantic_projection.identity.id,
                request.layer,
                position,
                ExactDecimal(0, 0),
                ExactDecimal(1, 0),
                request.provenance,
            )
        elseif moved
            record = DrawingProjection(
                record.identity,
                record.view,
                record.semantic_projection,
                record.layer,
                position,
                record.rotation_degrees,
                record.scale,
                record.provenance,
            )
        end
        records[record.identity.id] = record
        push!(
            placements,
            LayoutPlacement(
                owner,
                semantic_projection.identity.id,
                record.identity.id,
                position,
                metric.width,
                metric.height,
                ranks[owner],
                0,
                moved,
            ),
        )
    end
    return placements, records, edges, scope
end

function _layout_pages(placements::Vector{LayoutPlacement}, options::LayoutOptions)
    isempty(placements) && return LayoutPlacement[], LayoutPage[]
    left = minimum(
        _coordinate_value(item.position.x) - cld(item.width, 2) for item in placements
    )
    bottom = minimum(
        _coordinate_value(item.position.y) - cld(item.height, 2) for item in placements
    )
    usable_width = options.page_width - 2 * options.page_margin
    usable_height = options.page_height - 2 * options.page_margin
    cells = Dict{Tuple{Int,Int},Vector{ProjectId}}()
    owner_cells = Dict{ProjectId,Tuple{Int,Int}}()
    for item in placements
        x, y = _position_tuple(item.position)
        cell = (fld(x - left, usable_width), fld(y - bottom, usable_height))
        push!(get!(cells, cell, ProjectId[]), item.semantic_owner)
        owner_cells[item.semantic_owner] = cell
    end
    ordered_cells = sort!(collect(keys(cells)); by = cell -> (cell[2], cell[1]))
    page_number = Dict(cell => index for (index, cell) in enumerate(ordered_cells))
    pages = LayoutPage[]
    for cell in ordered_cells
        page_left = left + cell[1] * usable_width
        page_bottom = bottom + cell[2] * usable_height
        members = sort!(unique(cells[cell]); by = id -> id.value)
        push!(
            pages,
            LayoutPage(
                page_number[cell],
                _coordinate(page_left, page_bottom),
                _coordinate(page_left + usable_width, page_bottom + usable_height),
                members,
            ),
        )
    end
    paged = LayoutPlacement[
        LayoutPlacement(
            item.semantic_owner,
            item.semantic_projection,
            item.drawing_projection,
            item.position,
            item.width,
            item.height,
            item.rank,
            page_number[owner_cells[item.semantic_owner]],
            item.moved,
        ) for item in placements
    ]
    return paged, pages
end

function _orthogonal_points(
    source::DrawingCoordinate,
    target::DrawingCoordinate,
    channel::Int,
    request::LayoutRequest,
)
    source_x, source_y = _position_tuple(source)
    target_x, target_y = _position_tuple(target)
    offset = channel * request.options.clearance
    tuples = if request.options.orientation == LayoutTopDown
        middle = div(source_y + target_y, 2) + offset
        [(source_x, source_y), (source_x, middle), (target_x, middle), (target_x, target_y)]
    else
        middle = div(source_x + target_x, 2) + offset
        [(source_x, source_y), (middle, source_y), (middle, target_y), (target_x, target_y)]
    end
    unique_points = Tuple{Int,Int}[]
    for point in tuples
        isempty(unique_points) || point != last(unique_points) || continue
        push!(unique_points, point)
    end
    if length(unique_points) == 1
        push!(
            unique_points,
            (unique_points[1][1] + request.options.grid, unique_points[1][2]),
        )
    end
    return DrawingCoordinate[_coordinate(point...) for point in unique_points]
end

function _route_records(
    project::CanonicalProject,
    request::LayoutRequest,
    placements::Vector{LayoutPlacement},
    edges::Vector{_LayoutEdge},
    scope::Set{ProjectId},
)
    positions = Dict(item.semantic_owner => item.position for item in placements)
    existing = _unique_dictionary(
        filter(
            route -> route.view == request.view && !isnothing(route.semantic_connection),
            collect(project.drawings.routes),
        ),
        route -> route.semantic_connection,
        "semantic drawing route",
    )
    records = Dict{ProjectId,DrawingRoute}()
    plans = LayoutRoutePlan[]
    for (index, edge) in enumerate(edges)
        haskey(positions, edge.source) && haskey(positions, edge.target) || continue
        record = get(existing, edge.connection, nothing)
        affected = edge.source in scope || edge.target in scope
        immutable = !isnothing(record) && (
            !affected ||
            _manual(request, edge.connection, record.identity.id) ||
            _record_locked(
                project.drawings,
                record.identity.id,
                (DrawingPositionLock, DrawingGeometryLock),
            )
        )
        if immutable
            points = record.points
        else
            channel = mod(index - 1, 7) - 3
            points = _orthogonal_points(
                positions[edge.source],
                positions[edge.target],
                channel,
                request,
            )
            if isnothing(record)
                record = DrawingRoute(
                    ObjectIdentity(_generated_id(request, "route", edge.connection)),
                    request.view,
                    request.layer,
                    points,
                    request.provenance;
                    semantic_connection = edge.connection,
                    style = nothing,
                )
            else
                record = DrawingRoute(
                    record.identity,
                    record.view,
                    record.layer,
                    points,
                    record.provenance;
                    semantic_connection = record.semantic_connection,
                    style = record.style,
                )
            end
        end
        records[record.identity.id] = record
        push!(plans, LayoutRoutePlan(edge.connection, record.identity.id, collect(points)))
    end
    return plans, records
end

function _default_label(owner::ProjectId)
    parts = split(owner.value, r"[./:]")
    return replace(last(parts), '_' => ' ')
end

function _label_rectangle(anchor::Tuple{Int,Int}, text::AbstractString, grid::Int)
    width = max(2 * grid, length(text) * cld(grid, 2))
    return _LayoutRect(anchor[1], anchor[2] - grid, anchor[1] + width, anchor[2] + grid)
end

function _label_anchor(
    placement::LayoutPlacement,
    text::AbstractString,
    occupied::Vector{_LayoutRect},
    request::LayoutRequest,
)
    x, y = _position_tuple(placement.position)
    clearance = request.options.clearance
    candidates = (
        (x + cld(placement.width, 2) + clearance, y),
        (
            x - cld(placement.width, 2) -
            clearance -
            length(text) * cld(request.options.grid, 2),
            y,
        ),
        (x, y + cld(placement.height, 2) + 2 * clearance),
        (x, y - cld(placement.height, 2) - 2 * clearance),
    )
    for candidate in candidates
        rectangle = _label_rectangle(candidate, text, request.options.grid)
        all(existing -> !_overlaps(rectangle, existing, 0), occupied) &&
            return candidate, rectangle
    end
    candidate = (x + cld(placement.width, 2) + clearance, y + 3 * clearance)
    return candidate, _label_rectangle(candidate, text, request.options.grid)
end

function _label_records(
    project::CanonicalProject,
    request::LayoutRequest,
    placements::Vector{LayoutPlacement},
    scope::Set{ProjectId},
)
    specified = Dict{ProjectId,String}()
    for label in request.labels
        haskey(specified, label.semantic_owner) &&
            throw(ArgumentError("duplicate label for $(label.semantic_owner.value)"))
        specified[label.semantic_owner] = label.text
    end
    existing = Dict{ProjectId,DrawingLabel}()
    existing_by_id = Dict{ProjectId,DrawingLabel}()
    for label in project.drawings.labels
        label.view == request.view || continue
        existing_by_id[label.identity.id] = label
        isnothing(label.bound_owner) && continue
        haskey(existing, label.bound_owner) || (existing[label.bound_owner] = label)
    end
    occupied = _LayoutRect[
        _rect(
            _coordinate_value(item.position.x),
            _coordinate_value(item.position.y),
            item.width,
            item.height,
        ) for item in placements
    ]
    records = Dict{ProjectId,DrawingLabel}()
    plans = LayoutLabelPlan[]
    for placement in sort!(copy(placements); by = item -> item.semantic_owner.value)
        owner = placement.semantic_owner
        generated_id = _generated_id(request, "label", owner)
        record = get(existing, owner, get(existing_by_id, generated_id, nothing))
        if isnothing(record) && !(owner in scope)
            continue
        end
        text = isnothing(record) ? get(specified, owner, _default_label(owner)) : record.text
        immutable = !isnothing(record) && (
            !(owner in scope) ||
            _manual(request, owner, record.identity.id) ||
            _record_locked(
                project.drawings,
                record.identity.id,
                (DrawingPositionLock, DrawingGeometryLock),
            )
        )
        if immutable
            anchor = record.anchor
            push!(
                occupied,
                _label_rectangle(_position_tuple(anchor), text, request.options.grid),
            )
        else
            anchor_tuple, rectangle = _label_anchor(placement, text, occupied, request)
            push!(occupied, rectangle)
            anchor = _coordinate(anchor_tuple...)
            if isnothing(record)
                record = DrawingLabel(
                    ObjectIdentity(generated_id),
                    request.view,
                    request.layer,
                    anchor,
                    text,
                    request.provenance;
                    style = nothing,
                    bound_owner = nothing,
                    bound_field = nothing,
                )
            else
                record = DrawingLabel(
                    record.identity,
                    record.view,
                    record.layer,
                    anchor,
                    text,
                    record.provenance;
                    style = record.style,
                    bound_owner = record.bound_owner,
                    bound_field = record.bound_field,
                )
            end
        end
        records[record.identity.id] = record
        push!(plans, LayoutLabelPlan(owner, record.identity.id, anchor, text))
    end
    return plans, records
end

function _boundary_points(rectangle::_LayoutRect)
    return DrawingCoordinate[
        _coordinate(rectangle.left, rectangle.bottom),
        _coordinate(rectangle.right, rectangle.bottom),
        _coordinate(rectangle.right, rectangle.top),
        _coordinate(rectangle.left, rectangle.top),
        _coordinate(rectangle.left, rectangle.bottom),
    ]
end

function _boundary_records(
    project::CanonicalProject,
    request::LayoutRequest,
    placements::Vector{LayoutPlacement},
)
    placement_by_owner = Dict(item.semantic_owner => item for item in placements)
    existing_entities = Dict(entity.identity.id => entity for entity in project.drawings.entities)
    existing_labels = Dict(label.identity.id => label for label in project.drawings.labels)
    entities = Dict{ProjectId,DrawingEntity}()
    labels = Dict{ProjectId,DrawingLabel}()
    boundaries = LayoutBoundary[]
    label_plans = LayoutLabelPlan[]
    for bay in request.repeated_bays
        members = [
            placement_by_owner[id] for id in bay.members if haskey(placement_by_owner, id)
        ]
        isempty(members) && continue
        padding = 2 * request.options.clearance
        rectangle = _LayoutRect(
            minimum(
                _coordinate_value(item.position.x) - cld(item.width, 2) for
                item in members
            ) - padding,
            minimum(
                _coordinate_value(item.position.y) - cld(item.height, 2) for
                item in members
            ) - padding,
            maximum(
                _coordinate_value(item.position.x) + fld(item.width, 2) for
                item in members
            ) + padding,
            maximum(
                _coordinate_value(item.position.y) + fld(item.height, 2) for
                item in members
            ) + padding,
        )
        points = _boundary_points(rectangle)
        entity_id = _generated_id(request, "bay-boundary", bay.identity)
        existing_entity = get(existing_entities, entity_id, nothing)
        if !isnothing(existing_entity) && (
            _manual(request, bay.identity, entity_id) ||
            _record_locked(
                project.drawings,
                entity_id,
                (DrawingPositionLock, DrawingGeometryLock),
            )
        )
            entity = existing_entity
            points = entity.points
        else
            entity = DrawingEntity(
                isnothing(existing_entity) ? ObjectIdentity(entity_id) : existing_entity.identity,
                request.view,
                request.layer,
                ProjectId("aimora.layout.repeated_bay_boundary"),
                points,
                isnothing(existing_entity) ? request.provenance : existing_entity.provenance;
                style = isnothing(existing_entity) ? nothing : existing_entity.style,
                block_definition = nothing,
            )
        end
        entities[entity_id] = entity
        push!(boundaries, LayoutBoundary(entity_id, bay.identity, collect(points), bay.label))
        isempty(strip(bay.label)) && continue
        label_id = _generated_id(request, "bay-label", bay.identity)
        anchor = points[4]
        existing_label = get(existing_labels, label_id, nothing)
        if !isnothing(existing_label) && (
            _manual(request, bay.identity, label_id) ||
            _record_locked(
                project.drawings,
                label_id,
                (DrawingPositionLock, DrawingGeometryLock, DrawingContentLock),
            )
        )
            label = existing_label
            anchor = label.anchor
        else
            label = DrawingLabel(
                isnothing(existing_label) ? ObjectIdentity(label_id) : existing_label.identity,
                request.view,
                request.layer,
                anchor,
                bay.label,
                isnothing(existing_label) ? request.provenance : existing_label.provenance;
                style = isnothing(existing_label) ? nothing : existing_label.style,
                bound_owner = nothing,
                bound_field = nothing,
            )
        end
        labels[label_id] = label
        push!(label_plans, LayoutLabelPlan(nothing, label_id, anchor, label.text))
    end
    return boundaries, entities, label_plans, labels
end

function _merge_records(records, replacements)
    merged = collect(records)
    seen = Set{ProjectId}()
    for index in eachindex(merged)
        identity = merged[index].identity.id
        push!(seen, identity)
        haskey(replacements, identity) && (merged[index] = replacements[identity])
    end
    additions = sort!(
        [record for (identity, record) in replacements if !(identity in seen)];
        by = record -> record.identity.id.value,
    )
    append!(merged, additions)
    return merged
end

function _page_records_locked(workspace::DrawingWorkspace, request::LayoutRequest)
    prefix = _layout_prefix(request) * ".page."
    records = Iterators.flatten((workspace.views, workspace.sheets, workspace.viewports))
    return any(records) do record
        startswith(record.identity.id.value, prefix) && (
            _manual(request, record.identity.id) ||
            _record_locked(
                workspace,
                record.identity.id,
                (
                    DrawingPositionLock,
                    DrawingGeometryLock,
                    DrawingContentLock,
                    DrawingVisibilityLock,
                ),
            )
        )
    end
end

function _materialize_pages(
    workspace::DrawingWorkspace,
    drawing_view::DrawingView,
    pages::Vector{LayoutPage},
    request::LayoutRequest,
)
    request.options.materialize_pages || return workspace
    isempty(pages) && return workspace
    documents = filter(
        document -> document.identity.id == drawing_view.document,
        collect(workspace.documents),
    )
    length(documents) == 1 ||
        throw(ArgumentError("layout view document must exist exactly once"))
    document = only(documents)
    if _manual(request, document.identity.id) ||
       _record_locked(workspace, document.identity.id, (DrawingContentLock,)) ||
       _page_records_locked(workspace, request)
        return workspace
    end
    page_prefix = _layout_prefix(request) * ".page."
    views = filter(
        view -> !startswith(view.identity.id.value, page_prefix),
        collect(workspace.views),
    )
    sheets = filter(
        sheet -> !startswith(sheet.identity.id.value, page_prefix),
        collect(workspace.sheets),
    )
    viewports = filter(
        viewport -> !startswith(viewport.identity.id.value, page_prefix),
        collect(workspace.viewports),
    )
    document_views = filter(
        id -> !startswith(id.value, page_prefix),
        collect(document.views),
    )
    document_sheets = filter(
        id -> !startswith(id.value, page_prefix),
        collect(document.sheets),
    )
    usable_width = request.options.page_width - 2 * request.options.page_margin
    usable_height = request.options.page_height - 2 * request.options.page_margin
    for page in pages
        paper_view_id = _page_id(request, page.index, "view")
        sheet_id = _page_id(request, page.index, "sheet")
        viewport_id = _page_id(request, page.index, "viewport")
        push!(
            views,
            DrawingView(
                ObjectIdentity(paper_view_id),
                drawing_view.document,
                "Automatic layout page $(page.index)",
                DrawingPaperSpace,
                request.provenance;
                semantic_view = nothing,
            ),
        )
        push!(
            sheets,
            DrawingSheet(
                ObjectIdentity(sheet_id),
                drawing_view.document,
                paper_view_id,
                "Automatic layout page $(page.index)",
                ExactDecimal(request.options.page_width, 0),
                ExactDecimal(request.options.page_height, 0),
                request.provenance,
            ),
        )
        page_left, page_bottom = _position_tuple(page.lower_left)
        push!(
            viewports,
            DrawingViewport(
                ObjectIdentity(viewport_id),
                sheet_id,
                request.view,
                _coordinate(
                    request.options.page_margin - page_left,
                    request.options.page_margin - page_bottom,
                ),
                ExactDecimal(usable_width, 0),
                ExactDecimal(usable_height, 0),
                ExactDecimal(1, 0),
                ExactDecimal(0, 0),
                ProjectId[request.layer],
                request.provenance,
            ),
        )
        push!(document_views, paper_view_id)
        push!(document_sheets, sheet_id)
    end
    updated_document = DrawingDocument(
        document.identity,
        document.name,
        sort!(unique(document_views); by = id -> id.value),
        sort!(unique(document_sheets); by = id -> id.value),
        document.provenance,
    )
    updated_documents = _merge_records(
        workspace.documents,
        Dict(updated_document.identity.id => updated_document),
    )
    return DrawingWorkspace(;
        documents = updated_documents,
        views,
        sheets,
        viewports,
        layers = collect(workspace.layers),
        styles = collect(workspace.styles),
        blocks = collect(workspace.blocks),
        entities = collect(workspace.entities),
        projections = collect(workspace.projections),
        routes = collect(workspace.routes),
        labels = collect(workspace.labels),
        locks = collect(workspace.locks),
    )
end

function _layout_workspace(project::CanonicalProject, request::LayoutRequest)
    drawing_view, _, _ = _view_projection_data(project, request)
    placements, projection_records, edges, scope = _placement_records(project, request)
    placements, pages = _layout_pages(placements, request.options)
    routes, route_records = _route_records(project, request, placements, edges, scope)
    labels, label_records = _label_records(project, request, placements, scope)
    boundaries, entity_records, bay_label_plans, bay_label_records =
        _boundary_records(project, request, placements)
    merge!(label_records, bay_label_records)
    append!(labels, bay_label_plans)
    workspace = DrawingWorkspace(;
        documents = collect(project.drawings.documents),
        views = collect(project.drawings.views),
        sheets = collect(project.drawings.sheets),
        viewports = collect(project.drawings.viewports),
        layers = collect(project.drawings.layers),
        styles = collect(project.drawings.styles),
        blocks = collect(project.drawings.blocks),
        entities = _merge_records(project.drawings.entities, entity_records),
        projections = _merge_records(project.drawings.projections, projection_records),
        routes = _merge_records(project.drawings.routes, route_records),
        labels = _merge_records(project.drawings.labels, label_records),
        locks = collect(project.drawings.locks),
    )
    workspace = _materialize_pages(workspace, drawing_view, pages, request)
    plan = LayoutPlan(
        request.mode,
        request.view,
        placements,
        routes,
        labels,
        boundaries,
        pages,
    )
    return plan, workspace
end

"""Return the deterministic layout plan without changing the supplied project."""
function plan_layout(project::CanonicalProject, request::LayoutRequest)
    plan, _ = _layout_workspace(project, request)
    return plan
end

function _with_drawings(project::CanonicalProject, drawings::DrawingWorkspace)
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
        project.verification,
        drawings,
    )
end

"""
Apply deterministic presentation layout and prove that the engineering hash is unchanged.

Topology is read exclusively from semantic view projections, ports, and physical
connections. Geometry is never used to infer an engineering connection.
"""
function layout_project(project::CanonicalProject, request::LayoutRequest)
    before = project_physics_hash(project)
    plan, drawings = _layout_workspace(project, request)
    updated = _with_drawings(project, drawings)
    after = project_physics_hash(updated)
    before == after || error("automatic layout changed the canonical physics hash")
    return LayoutResult(updated, plan, before, after)
end
