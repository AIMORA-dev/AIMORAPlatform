# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export DraftingSession, register_drafting_session!, drafting_revision

include("drafting_history.jl")

"""Canonical Julia drawing state owned by one open service project."""
mutable struct DraftingSession
    revision::AIMORAProject.ProjectRevision
    view::AIMORAProject.ProjectId
    layer::AIMORAProject.ProjectId
    limits::ServiceLimits
    saved_revision::String
    history::DraftingHistory
    saved_resolved_hash::AIMORAProject.ContentDigest
end

DraftingSession(revision::AIMORAProject.ProjectRevision, view::AIMORAProject.ProjectId,
    layer::AIMORAProject.ProjectId, limits::ServiceLimits, saved_revision::String) =
    DraftingSession(revision, view, layer, limits, saved_revision, DraftingHistory(), revision.resolved_hash)

drafting_revision(session::DraftingSession) = "sha256:" * session.revision.id.sha256

function register_drafting_session!(
    state::ServiceState, project_id::AbstractString,
    revision::AIMORAProject.ProjectRevision,
    view_id::AIMORAProject.ProjectId, layer_id::AIMORAProject.ProjectId,
)
    haskey(state.semantic_edit_providers, String(project_id)) && throw(ServiceError(
        "INVALID_REQUEST", "The project already has a canonical edit provider.",
    ))
    project = AIMORAProject.verified_project(revision.project)
    view = AIMORAProject.drawing_record(project.drawings, view_id)
    layer = AIMORAProject.drawing_record(project.drawings, layer_id)
    view isa AIMORAProject.DrawingView && layer isa AIMORAProject.DrawingLayer &&
        view.document == layer.document || throw(ServiceError(
            "INVALID_REQUEST", "Drafting view and layer must belong to the same document.",
        ))
    session = DraftingSession(revision, view_id, layer_id, state.configuration.limits,
        "sha256:" * revision.id.sha256)
    registered_path = state.projects[String(project_id)].canonical_path
    _drafting_description(session)
    provider = SemanticEditProvider(
        commit = request -> _commit_drafting!(session, request),
        describe = () -> merge(_drafting_description(session),
            Dict("can_save" => endswith(lowercase(registered_path), ".aimora.yaml"))),
        save = parameters -> _save_drafting_session!(state, String(project_id), session, registered_path, parameters),
    )
    register_semantic_edit_provider!(state, project_id, provider)
    return session
end

function _bounded_drafting_response(session::DraftingSession, result)
    ncodeunits(JSON3.write(result)) <= session.limits.max_control_frame_bytes - 1024 ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "The drawing display exceeds the control-frame budget."))
    return result
end

function _drafting_scene(project, view_id, limits)
    items = Any[]
    unsupported = String[]
    point_count = 0
    item_ids = Set{String}()
    function display_point(point)
        values = [parse(Float64, string(point.x)), parse(Float64, string(point.y))]
        all(isfinite, values) || throw(ServiceError("RESOURCE_TOO_LARGE", "Drawing coordinates exceed display range."))
        return values
    end
    function add_item(record, kind, points; text = nothing, rendered_points = nothing)
        point_count += isnothing(rendered_points) ? length(points) : length(rendered_points)
        point_count <= limits.max_semantic_points ||
            throw(ServiceError("RESOURCE_TOO_LARGE", "The drawing display point budget was exceeded."))
        id = string(parse(UInt64, bytes2hex(sha256(record.identity.id.value))[1:16]; base = 16))
        id != "0" && !(id in item_ids) ||
            throw(ServiceError("INTERNAL_ERROR", "Drawing display identity collision."))
        push!(item_ids, id)
        item = Dict{String,Any}("item_id" => id, "owner_id" => record.identity.id.value,
            "kind" => kind, "points" => isnothing(rendered_points) ? display_point.(points) : rendered_points)
        if kind == "circle"
            length(points) == 2 || throw(ServiceError("INVALID_PROJECT", "A circle requires a center and circumference point."))
            center, edge = item["points"]
            radius = hypot(edge[1] - center[1], edge[2] - center[2])
            isfinite(radius) && radius > 0 &&
                all(isfinite, (center[1] - radius, center[1] + radius, center[2] - radius, center[2] + radius)) ||
                throw(ServiceError("RESOURCE_TOO_LARGE", "The circle exceeds the drawing display range."))
        end
        isnothing(text) || (item["text"] = text)
        push!(items, item)
    end
    visible_layers = Set(layer.identity.id for layer in project.drawings.layers if layer.visible)
    for entity in project.drawings.entities
        entity.container == view_id && entity.layer in visible_layers || continue
        if isnothing(entity.block_definition) && entity.kind.value == "entity.ellipse"
            length(entity.points) == 2 || throw(ServiceError("INVALID_PROJECT", "An ellipse requires two bounding corners."))
            rendered = AIMORAProject.drawing_ellipse_display_points(entity.points...)
            add_item(entity, "polyline", entity.points; rendered_points = rendered)
        elseif isnothing(entity.block_definition) && entity.kind.value == "entity.arc"
            length(entity.points) == 3 || throw(ServiceError("INVALID_PROJECT", "An arc requires three ordered points."))
            rendered = AIMORAProject.drawing_arc_display_points(entity.points...)
            add_item(entity, "polyline", entity.points; rendered_points = rendered)
        elseif isnothing(entity.block_definition) && entity.kind.value in ("entity.line", "entity.polyline", "entity.rectangle", "entity.circle")
            kind = entity.kind.value == "entity.line" ? "line" :
                entity.kind.value == "entity.rectangle" ? "polygon" :
                entity.kind.value == "entity.circle" ? "circle" : "polyline"
            add_item(entity, kind, entity.points)
        else
            push!(unsupported, entity.identity.id.value)
        end
    end
    for route in project.drawings.routes
        route.view == view_id && route.layer in visible_layers || continue
        add_item(route, "polyline", route.points)
    end
    for label in project.drawings.labels
        label.view == view_id && label.layer in visible_layers || continue
        add_item(label, "text", [label.anchor]; text = label.text)
    end
    for projection in project.drawings.projections
        projection.view == view_id && projection.layer in visible_layers || continue
        push!(unsupported, projection.identity.id.value)
    end
    length(items) + length(unsupported) <= limits.max_semantic_ids ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "The drawing display item budget was exceeded."))
    sort!(items; by = item -> item["owner_id"])
    return Dict("items" => items, "unsupported_owner_ids" => sort!(unsupported))
end

function _drafting_description(session::DraftingSession)
    view = AIMORAProject.drawing_record(session.revision.project.drawings, session.view)
    layers = [Dict("id" => layer.identity.id.value, "name" => layer.name,
        "visible" => layer.visible, "printable" => layer.printable)
        for layer in session.revision.project.drawings.layers if layer.document == view.document]
    return _bounded_drafting_response(session, Dict{String,Any}(
        "drawing_layers" => layers,
        "revision" => drafting_revision(session),
        "modified" => session.revision.resolved_hash != session.saved_resolved_hash,
        "drawing_view_id" => session.view.value,
        "drawing_layer_id" => session.layer.value,
        "edit_operations" => ["draw.line", "draw.polyline", "draw.rectangle", "draw.text", "draw.circle", "draw.arc", "draw.ellipse", "modify.move", "modify.copy", "modify.scale", "modify.erase", "modify.mirror_horizontal", "modify.mirror_vertical", "modify.rotate_quarter", "modify.align_anchor_x", "modify.align_anchor_y", "modify.distribute_anchor_x", "modify.distribute_anchor_y", "modify.text", "modify.explode_paths", "modify.join_lines", "layer.create", "layer.update", "modify.layer", "edit.undo", "edit.redo"],
        "can_undo" => !isempty(session.history.undo),
        "can_redo" => !isempty(session.history.redo),
        "drawing_scene" => _drafting_scene(session.revision.project, session.view, session.limits),
    ))
end

function _save_drafting_session!(state, project_id, session, registered_path, parameters)
    _required_semantic_revision(parameters) == drafting_revision(session) ||
        throw(ServiceError("REVISION_CONFLICT", "The drawing changed before save."))
    record = state.projects[project_id]
    record.canonical_path == registered_path ||
        throw(ServiceError("REVISION_CONFLICT", "The project reference changed before save."))
    path = confine_existing_file(state.path_policy, registered_path)
    path == registered_path && endswith(lowercase(path), ".aimora.yaml") ||
        throw(ServiceError("PATH_NOT_ALLOWED", "Save requires the original canonical project file."))
    bounded_file_size(path, session.limits.max_project_bytes)
    sha256_file(path) == record.sha256 ||
        throw(ServiceError("REVISION_CONFLICT", "The project file was changed outside Studio."))
    policy = AIMORAProject.AIMORAFormats.FormatInputPolicy(
        max_document_bytes = session.limits.max_project_bytes)
    saved = try
        AIMORAProject.save_project(path, session.revision.project; overwrite = true, policy,
            expected_source = AIMORAProject.ContentDigest(record.sha256))
    catch error
        if error isa AIMORAProject.SemanticValidationError
            code = error.code == :project_source_conflict ? "REVISION_CONFLICT" : "SEMANTIC_EDIT_REJECTED"
            throw(ServiceError(code, "The project could not be saved without changing its declared format or source."))
        end
        rethrow()
    end
    isnothing(saved.value) && throw(ServiceError("SEMANTIC_EDIT_REJECTED", "The project could not be serialized."))
    bytes = collect(saved.value.bytes)
    state.projects[project_id] = ProjectRecord(record.id, record.display_name, path,
        length(bytes), bytes2hex(sha256(bytes)))
    session.saved_revision = drafting_revision(session)
    session.saved_resolved_hash = session.revision.resolved_hash
    return Dict("project_id" => project_id, "revision" => session.saved_revision,
        "saved" => true, "modified" => false, "size_bytes" => length(bytes))
end

function _open_drafting_session!(state::ServiceState, record::ProjectRecord, parameters)
    if haskey(state.semantic_edit_providers, record.id)
        provider = state.semantic_edit_providers[record.id]
        isnothing(provider.describe) && throw(ServiceError(
            "INVALID_REQUEST", "The open project already has a different edit provider.",
        ))
        return merge(_project_descriptor(record), provider.describe())
    end
    policy = AIMORAProject.AIMORAFormats.ProjectResolutionPolicy(
        max_files = state.configuration.limits.max_pending_requests,
        max_authoritative_bytes = state.configuration.limits.max_project_bytes,
        max_hashed_resource_bytes = state.configuration.limits.max_project_bytes,
    )
    loaded = AIMORAProject.open_project(record.canonical_path; policy)
    isnothing(loaded.value) && throw(ServiceError(
        "INVALID_PROJECT", "The file is not a valid canonical AIMORA project.",
    ))
    project = loaded.value.project
    view_text = get(parameters, "drawing_view_id", nothing)
    views = [view for view in project.drawings.views if
        isnothing(view_text) ? view.space == AIMORAProject.DrawingModelSpace : view.identity.id.value == view_text]
    length(views) == 1 || throw(ServiceError(
        "DRAWING_VIEW_REQUIRED", "Choose one existing drawing view to open for editing.",
    ))
    view = only(views)
    layer_text = get(parameters, "drawing_layer_id", nothing)
    layers = [layer for layer in project.drawings.layers if layer.document == view.document &&
        (isnothing(layer_text) ? layer.visible : layer.identity.id.value == layer_text)]
    !isempty(layers) || throw(ServiceError(
        "DRAWING_LAYER_REQUIRED", "Choose an existing layer; the document has no matching visible default layer.",
    ))
    sort!(layers; by = layer -> layer.identity.id.value)
    register_drafting_session!(state, record.id, loaded.value, view.identity.id, first(layers).identity.id)
    return merge(_project_descriptor(record), state.semantic_edit_providers[record.id].describe())
end

function _drafting_points(request)
    # Exact text may be supplied by precision input; pointer coordinates use the
    # round-trip decimal spelling of the admitted finite display number.
    exact = get(request["attributes"], "exact_points", nothing)
    inputs = get(request["attributes"], "coordinate_inputs", nothing)
    isnothing(exact) || isnothing(inputs) || throw(ServiceError(
        "INVALID_REQUEST", "Use exact points or coordinate inputs, not both.",
    ))
    values = isnothing(exact) ? request["points"] : exact
    values isa AbstractVector && length(values) == length(request["points"]) ||
        throw(ServiceError("INVALID_REQUEST", "Exact points must match the display point count."))
    points = AIMORAProject.DrawingCoordinate[]
    for pair in values
        pair isa AbstractVector && length(pair) == 2 ||
            throw(ServiceError("INVALID_REQUEST", "A drafting point requires two coordinates."))
        texts = String[]
        for value in pair
            if isnothing(exact)
                value isa Real && !(value isa Bool) && isfinite(value) ||
                    throw(ServiceError("INVALID_REQUEST", "Drafting coordinates must be finite."))
                push!(texts, string(value))
            else
                value isa AbstractString ||
                    throw(ServiceError("INVALID_REQUEST", "Exact coordinates must be decimal strings."))
                push!(texts, String(value))
            end
        end
        push!(points, AIMORAProject.DrawingCoordinate(
            AIMORAProject.parse_exact_decimal(texts[1]),
            AIMORAProject.parse_exact_decimal(texts[2]),
        ))
    end
    if !isnothing(inputs)
        inputs isa AbstractVector && length(inputs) == length(points) ||
            throw(ServiceError("INVALID_REQUEST", "Coordinate input count must match display points."))
        for (index, input) in enumerate(inputs)
            isnothing(input) && continue
            input isa AbstractDict || throw(ServiceError("INVALID_REQUEST", "Invalid coordinate input."))
            if haskey(input, "reference")
                reference = input["reference"]
                reference isa Integer && !(reference isa Bool) && 0 <= reference < index - 1 ||
                    throw(ServiceError("INVALID_REQUEST", "Coordinate references must address earlier points."))
                points[index] = points[Int(reference) + 1]
                continue
            end
            text = _required_string(input, "text"; maximum_bytes = 8192)
            anchor = index > 1 ? points[index - 1] : points[index]
            if index == 1 && startswith(strip(text), "@")
                source_anchor = get(input, "anchor", nothing)
                source_anchor isa AbstractVector && length(source_anchor) == 2 &&
                    all(value -> value isa AbstractString, source_anchor) ||
                    throw(ServiceError("INVALID_REQUEST", "Initial relative input requires an explicit anchor."))
                anchor = AIMORAProject.DrawingCoordinate(
                    AIMORAProject.parse_exact_decimal(source_anchor[1]),
                    AIMORAProject.parse_exact_decimal(source_anchor[2]))
            end
            points[index] = AIMORAProject.resolve_drafting_cartesian(text, anchor)
        end
    end
    return points
end

function _drafting_plan(session::DraftingSession, request)
    project = session.revision.project
    action = AIMORAProject.ProjectId("action.drafting.h" * bytes2hex(sha256(request["transaction_id"])))
    operation = request["operation"]
    points = _drafting_points(request)
    close_path = get(request["attributes"], "close_path", false)
    close_path isa Bool || throw(ServiceError("INVALID_REQUEST", "Path closure must be a boolean."))
    if close_path
        operation in ("draw.line", "draw.polyline") && length(points) >= 3 ||
            throw(ServiceError("INVALID_REQUEST", "Path closure requires at least three line or polyline points."))
        if last(points) != first(points)
            length(points) < session.limits.max_semantic_points ||
                throw(ServiceError("RESOURCE_TOO_LARGE", "The closing point exceeds the drawing point budget."))
            push!(points, first(points))
        end
    end
    selection = AIMORAProject.ProjectId.(request["semantic_ids"])
    if operation in ("layer.create", "layer.update", "modify.layer")
        isempty(points) || throw(ServiceError("INVALID_REQUEST", "Layer edits do not accept drawing points."))
        attributes = request["attributes"]
        if operation == "modify.layer"
            layer_id = AIMORAProject.ProjectId(_required_string(attributes, "layer_id"; maximum_bytes = 1024))
            return AIMORAProject.plan_drafting_layer_assignment(project, action, session.view, selection, layer_id)
        end
        isempty(selection) || throw(ServiceError("INVALID_REQUEST", "Layer definitions do not accept selected objects."))
        name = _required_string(attributes, "name"; maximum_bytes = 1024)
        visible = get(attributes, "visible", true)
        printable = get(attributes, "printable", true)
        visible isa Bool && printable isa Bool || throw(ServiceError("INVALID_REQUEST", "Layer flags must be booleans."))
        if operation == "layer.create"
            return AIMORAProject.plan_drafting_layer_creation(project, action, session.view, name; visible, printable)
        end
        layer_id = AIMORAProject.ProjectId(_required_string(attributes, "layer_id"; maximum_bytes = 1024))
        return AIMORAProject.plan_drafting_layer_update(project, action, session.view, layer_id, name; visible, printable)
    end
    if operation in ("edit.undo", "edit.redo")
        isempty(selection) && isempty(points) || throw(ServiceError(
            "INVALID_REQUEST", "History replay does not accept selected owners or drawing points."))
        history = operation == "edit.undo" ? session.history.undo : session.history.redo
        isempty(history) && throw(ServiceError("DRAFTING_HISTORY_EMPTY", "No retained drawing edit is available."))
        entry = last(history)
        commands = operation == "edit.undo" ? entry.backward : entry.forward
        return AIMORAProject.plan_drafting_command_replay(project, action, commands)
    end
    if operation in ("modify.explode_paths", "modify.join_lines")
        isempty(points) || throw(ServiceError("INVALID_REQUEST", "Join and explode do not accept drawing points."))
        for id in selection
            record = AIMORAProject.drawing_record(project.drawings, id)
            record isa AIMORAProject.DrawingEntity && record.container == session.view || throw(ServiceError(
                "INVALID_REQUEST", "Select drafting paths in the active view only."))
        end
        return operation == "modify.join_lines" ?
            AIMORAProject.plan_drafting_line_join(project, action, selection) :
            AIMORAProject.plan_drafting_path_explosion(project, action, selection)
    end
    if operation in ("modify.align_anchor_x", "modify.align_anchor_y", "modify.distribute_anchor_x", "modify.distribute_anchor_y")
        alignment = operation in ("modify.align_anchor_x", "modify.align_anchor_y")
        length(points) == (alignment ? 1 : 0) || throw(ServiceError(
            "INVALID_REQUEST", "Alignment needs one target point; distribution needs no points."))
        for id in selection
            record = AIMORAProject.drawing_record(project.drawings, id)
            record_view = record isa AIMORAProject.DrawingEntity ? record.container :
                record isa Union{AIMORAProject.DrawingRoute,AIMORAProject.DrawingLabel} ? record.view : nothing
            record_view == session.view || throw(ServiceError(
                "INVALID_REQUEST", "Arrange drafting objects in the active drawing view only."))
        end
        axis = endswith(operation, "_x") ? :x : :y
        if alignment
            target = axis == :x ? only(points).x : only(points).y
            return AIMORAProject.plan_drafting_anchor_alignment(project, action, selection, axis, target)
        end
        return AIMORAProject.plan_drafting_anchor_distribution(project, action, selection, axis)
    end
    if operation in ("modify.mirror_horizontal", "modify.mirror_vertical", "modify.rotate_quarter")
        !isempty(selection) && length(points) == 1 || throw(ServiceError(
            "INVALID_REQUEST", "This transform requires selected owners and one pivot or mirror-line point."))
        for id in selection
            record = AIMORAProject.drawing_record(project.drawings, id)
            record_view = record isa AIMORAProject.DrawingEntity ? record.container :
                record isa Union{AIMORAProject.DrawingRoute,AIMORAProject.DrawingLabel} ? record.view : nothing
            record_view == session.view || throw(ServiceError(
                "INVALID_REQUEST", "Transform targets must belong to the active drawing view."))
        end
        if operation == "modify.rotate_quarter"
            return AIMORAProject.plan_drafting_quarter_rotation(project, action, selection, points[1])
        end
        axis = operation == "modify.mirror_vertical" ? :vertical : :horizontal
        coordinate = axis == :vertical ? points[1].x : points[1].y
        return AIMORAProject.plan_drafting_axis_mirror(project, action, selection, axis, coordinate)
    end
    if operation == "draw.ellipse"
        isempty(selection) && length(points) == 2 || throw(ServiceError(
            "INVALID_REQUEST", "An ellipse requires two bounding corners and no selected owners."))
        view = AIMORAProject.drawing_record(project.drawings, session.view)
        return AIMORAProject.plan_drafting_ellipse(project, action,
            AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value * ".entity")),
            session.view, session.layer, points[1], points[2], view.provenance)
    end
    if operation == "draw.arc"
        isempty(selection) && length(points) == 3 || throw(ServiceError(
            "INVALID_REQUEST", "An arc requires start, through, and end points and no selected owners."))
        view = AIMORAProject.drawing_record(project.drawings, session.view)
        return AIMORAProject.plan_drafting_arc(project, action,
            AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value * ".entity")),
            session.view, session.layer, points[1], points[2], points[3], view.provenance)
    end
    if operation == "draw.text"
        isempty(selection) || throw(ServiceError("INVALID_REQUEST", "New text does not accept selected labels."))
    elseif operation == "modify.text"
        isempty(points) || throw(ServiceError("INVALID_REQUEST", "Text replacement does not move label anchors."))
        for id in selection
            record = AIMORAProject.drawing_record(project.drawings, id)
            record isa AIMORAProject.DrawingLabel && record.view == session.view || throw(ServiceError(
                "INVALID_REQUEST", "Select drafting labels in the active view only."))
        end
        text = _required_string(request["attributes"], "text"; maximum_bytes = 65536)
        return AIMORAProject.plan_drafting_text_replacement(project, action, selection, text)
    end
    if operation == "draw.text"
        isempty(selection) && length(points) == 1 || throw(ServiceError(
            "INVALID_REQUEST", "Text requires one insertion point and no selected owners.",
        ))
        text = _required_string(request["attributes"], "text"; maximum_bytes = 65536)
        any(character -> character in ('\n', '\r'), text) && throw(ServiceError(
            "INVALID_REQUEST", "This text command accepts one line of text.",
        ))
        view = AIMORAProject.drawing_record(project.drawings, session.view)
        label = AIMORAProject.DrawingLabel(
            AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value * ".label")),
            session.view, session.layer, only(points), text, view.provenance,
        )
        return AIMORAProject.plan_drafting_edit(project, action; additions = [label])
    end
    if operation in ("draw.line", "draw.polyline", "draw.rectangle", "draw.circle")
        isempty(selection) || throw(ServiceError("INVALID_REQUEST", "New drafting geometry has no selected owners."))
        valid_count = operation in ("draw.line", "draw.polyline") ? length(points) >= 2 : length(points) == 2
        valid_count || throw(ServiceError("INVALID_REQUEST", "The drafting command has an invalid point count."))
        any(point -> point != first(points), points) ||
            throw(ServiceError("INVALID_REQUEST", "Drafting geometry must have nonzero extent."))
        view = AIMORAProject.drawing_record(project.drawings, session.view)
        if operation == "draw.line"
            length(points) - 1 <= session.limits.max_semantic_ids || throw(ServiceError(
                "RESOURCE_TOO_LARGE", "The line sequence exceeds the drawing item budget.",
            ))
            all(index -> points[index] != points[index + 1], 1:(length(points) - 1)) ||
                throw(ServiceError("INVALID_REQUEST", "Every line segment must have nonzero extent."))
            lines = AIMORAProject.DrawingEntity[
                AIMORAProject.DrawingEntity(
                    AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value *
                        (length(points) == 2 ? ".entity" : ".entity.segment$index"))),
                    session.view, session.layer, AIMORAProject.ProjectId("entity.line"),
                    points[index:(index + 1)], view.provenance,
                ) for index in 1:(length(points) - 1)
            ]
            return AIMORAProject.plan_drafting_edit(project, action; additions = lines)
        end
        if operation == "draw.rectangle"
            return AIMORAProject.plan_drafting_rectangle(project, action,
                AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value * ".entity")),
                session.view, session.layer, points[1], points[2], view.provenance)
        end
        entity = AIMORAProject.DrawingEntity(
            AIMORAProject.ObjectIdentity(AIMORAProject.ProjectId(action.value * ".entity")),
            session.view, session.layer,
            AIMORAProject.ProjectId(operation == "draw.line" ? "entity.line" :
                operation == "draw.circle" ? "entity.circle" : "entity.polyline"),
            points, view.provenance,
        )
        return AIMORAProject.plan_drafting_edit(project, action; additions = [entity])
    end
    isempty(selection) && throw(ServiceError("INVALID_REQUEST", "Select drafting records first."))
    for id in selection
        record = AIMORAProject.drawing_record(project.drawings, id)
        owner_view = record isa AIMORAProject.DrawingEntity ? record.container :
            record isa Union{AIMORAProject.DrawingLabel,AIMORAProject.DrawingRoute} ? record.view : nothing
        owner_view == session.view || throw(ServiceError(
            "INVALID_REQUEST", "Selected drafting records must belong to the active view.",
        ))
    end
    if operation == "modify.scale"
        length(points) == 1 || throw(ServiceError("INVALID_REQUEST", "Scale requires one pivot point."))
        factor = AIMORAProject.parse_exact_decimal(
            _required_string(request["attributes"], "factor"; maximum_bytes = 4096))
        return AIMORAProject.plan_drafting_scale(project, action, selection, only(points), factor)
    end
    if operation in ("modify.move", "modify.copy")
        length(points) == 2 || throw(ServiceError("INVALID_REQUEST", "Move or copy requires base and destination points."))
        if operation == "modify.copy"
            return AIMORAProject.plan_drafting_copy(project, action, selection, points[1], points[2])
        end
        return AIMORAProject.plan_drafting_translation(project, action, selection, points[1], points[2])
    elseif operation == "modify.erase"
        isempty(points) || throw(ServiceError("INVALID_REQUEST", "Erase does not accept points."))
        return AIMORAProject.plan_drafting_edit(project, action; removals = selection)
    end
    throw(ServiceError("SEMANTIC_EDIT_UNAVAILABLE", "This session does not implement the requested edit."))
end

function _commit_drafting!(session::DraftingSession, request)
    request["base_revision"] == drafting_revision(session) || return Dict{String,Any}(
        "status" => "conflict", "revision" => drafting_revision(session), "issues" => Any[],
    )
    try
        plan = _drafting_plan(session, request)
        history_operation = request["operation"] in ("edit.undo", "edit.redo")
        history_entry = history_operation ? nothing : DraftingHistoryEntry(plan.commands,
            AIMORAProject.inverse_commands(session.revision.project, plan.commands))
        transaction = AIMORAProject.begin_project_transaction(session.revision)
        AIMORAProject.apply_drafting_edit!(transaction, plan)
        view = AIMORAProject.drawing_record(transaction.working.drawings, session.view)
        provenance = AIMORAProject.RevisionProvenance(
            AIMORAProject.ProjectId("action.drafting.h" * bytes2hex(sha256(request["transaction_id"]))),
            now(UTC), view.provenance,
        )
        revision = AIMORAProject.commit!(
            transaction, session.revision, session.revision.source_hash,
            AIMORAProject.project_resolved_hash(transaction.working), provenance,
        )
        result = Dict{String,Any}(
            "status" => "accepted", "revision" => "sha256:" * revision.id.sha256,
            "modified" => revision.resolved_hash != session.saved_resolved_hash,
            "changed_owner_ids" => [id.value for id in plan.changed_owners],
            "affected_view_ids" => [session.view.value],
            "invalidations" => ["views"], "issues" => Any[],
            "drawing_scene" => _drafting_scene(revision.project, session.view, session.limits),
            "can_undo" => request["operation"] == "edit.undo" ? length(session.history.undo) > 1 :
                request["operation"] == "edit.redo" ? true : history_entry.retained_bytes <= session.history.maximum_bytes,
            "can_redo" => request["operation"] == "edit.undo" ? true :
                request["operation"] == "edit.redo" ? length(session.history.redo) > 1 : false,
        )
        _bounded_drafting_response(session, result)
        if request["operation"] == "edit.undo"
            push!(session.history.redo, pop!(session.history.undo))
        elseif request["operation"] == "edit.redo"
            push!(session.history.undo, pop!(session.history.redo))
        else
            _remember_drafting_edit!(session.history, history_entry)
        end
        session.revision = revision
        return result
    catch error
        error isa AIMORAProject.SemanticValidationError || rethrow()
        return Dict{String,Any}(
            "status" => "rejected", "revision" => drafting_revision(session),
            "issues" => [Dict("code" => String(error.code), "message" => error.message)],
        )
    end
end
