export DraftingEditPlan, plan_drafting_edit, plan_drafting_translation, apply_drafting_edit!
export plan_drafting_rectangle
export plan_drafting_copy
export plan_drafting_scale
export resolve_drafting_cartesian
export plan_drafting_command_replay

"""Replan a retained drawing-only command batch against the current canonical project."""
function plan_drafting_command_replay(project::CanonicalProject, action::ProjectId, commands)
    additions = CanonicalDrawingRecord[]
    replacements = CanonicalDrawingRecord[]
    removals = ProjectId[]
    for command in commands
        patch = command.patch
        if patch isa AddDrawingRecordPatch
            push!(additions, patch.record)
        elseif patch isa ReplaceDrawingRecordPatch
            push!(replacements, patch.record)
        elseif patch isa RemoveDrawingRecordPatch
            push!(removals, patch.owner)
        else
            _semantic_fail(:non_drafting_history, "Drafting history may replay only drawing record patches.")
        end
    end
    return plan_drafting_edit(project, action; additions, replacements, removals, allow_layer_changes = true)
end

"""Resolve an absolute or relative Cartesian literal using exact decimal coordinates."""
function resolve_drafting_cartesian(input::AbstractString, anchor::DrawingCoordinate)
    text = strip(input)
    relative = startswith(text, "@")
    coordinates = split(relative ? text[2:end] : text, ','; keepempty = true)
    length(coordinates) == 2 || _semantic_fail(:invalid_drafting_coordinate, "Cartesian input requires x,y")
    point = DrawingCoordinate(parse_exact_decimal(strip(coordinates[1])),
        parse_exact_decimal(strip(coordinates[2])))
    return relative ? _translated_drafting_point(anchor, point) : point
end

function _scaled_drafting_coordinate(value::ExactDecimal, pivot::ExactDecimal, factor::ExactDecimal)
    delta = _drafting_coordinate_sum(value, ExactDecimal(-pivot.coefficient, pivot.exponent))
    return _drafting_coordinate_sum(pivot,
        ExactDecimal(delta.coefficient * factor.coefficient, delta.exponent + factor.exponent))
end

function _scaled_drafting_point(point::DrawingCoordinate, pivot::DrawingCoordinate, factor::ExactDecimal)
    return DrawingCoordinate(_scaled_drafting_coordinate(point.x, pivot.x, factor),
        _scaled_drafting_coordinate(point.y, pivot.y, factor))
end

"""Scale drafting geometry about an exact pivot without changing physical owners or lineweights."""
function plan_drafting_scale(
    project::CanonicalProject, action::ProjectId, selection::AbstractVector{ProjectId},
    pivot::DrawingCoordinate, factor::ExactDecimal,
)
    factor.coefficient > 0 || _semantic_fail(:invalid_drafting_scale, "scale factor must be positive")
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting selection requires one to 100000 records",
    )
    replacements = CanonicalDrawingRecord[]
    for id in selection
        record = _require_drafting_record(drawing_record(project.drawings, id))
        if record isa DrawingEntity && isnothing(record.block_definition)
            push!(replacements, DrawingEntity(record.identity, record.container, record.layer, record.kind,
                [_scaled_drafting_point(point, pivot, factor) for point in record.points],
                record.provenance; style = record.style))
        elseif record isa DrawingRoute
            push!(replacements, DrawingRoute(record.identity, record.view, record.layer,
                [_scaled_drafting_point(point, pivot, factor) for point in record.points],
                record.provenance; style = record.style))
        else
            _semantic_fail(:unsupported_drafting_scale, "text and block scaling require their dedicated transformations")
        end
    end
    return plan_drafting_edit(project, action; replacements)
end

function _copied_drafting_record(record::DrawingEntity, identity::ObjectIdentity)
    return DrawingEntity(identity, record.container, record.layer, record.kind,
        collect(record.points), record.provenance; style = record.style,
        block_definition = record.block_definition)
end

function _copied_drafting_record(record::DrawingRoute, identity::ObjectIdentity)
    return DrawingRoute(identity, record.view, record.layer, collect(record.points),
        record.provenance; style = record.style)
end

function _copied_drafting_record(record::DrawingLabel, identity::ObjectIdentity)
    return DrawingLabel(identity, record.view, record.layer, record.anchor, record.text,
        record.provenance; style = record.style)
end

"""Copy selected drafting records with fresh identities and an exact base-to-destination displacement."""
function plan_drafting_copy(
    project::CanonicalProject, action::ProjectId, selection::AbstractVector{ProjectId},
    start::DrawingCoordinate, destination::DrawingCoordinate,
)
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting selection requires one to 100000 records",
    )
    length(unique(selection)) == length(selection) || _semantic_fail(
        :duplicate_drafting_target, "a copy selection may address each identity only once",
    )
    delta = DrawingCoordinate(
        _drafting_coordinate_sum(destination.x, ExactDecimal(-start.x.coefficient, start.x.exponent)),
        _drafting_coordinate_sum(destination.y, ExactDecimal(-start.y.coefficient, start.y.exponent)),
    )
    additions = CanonicalDrawingRecord[]
    for (index, id) in enumerate(sort!(collect(selection); by = id -> id.value))
        record = _require_drafting_record(drawing_record(project.drawings, id))
        translated = _translated_drafting_record(record, delta)
        identity = ObjectIdentity(ProjectId(action.value * ".copy" * string(index)))
        push!(additions, _copied_drafting_record(translated, identity))
    end
    return plan_drafting_edit(project, action; additions)
end

"""Create an axis-aligned drafting rectangle from two exact opposite corners."""
function plan_drafting_rectangle(
    project::CanonicalProject, action::ProjectId, identity::ObjectIdentity,
    view::ProjectId, layer::ProjectId, first::DrawingCoordinate,
    second::DrawingCoordinate, provenance::ProvenanceSource,
)
    first_x, second_x = exact_rational(first.x), exact_rational(second.x)
    first_y, second_y = exact_rational(first.y), exact_rational(second.y)
    (first_x < second_x || second_x < first_x) &&
        (first_y < second_y || second_y < first_y) || _semantic_fail(
            :degenerate_drafting_rectangle, "rectangle width and height must both be nonzero",
        )
    left, right = first_x < second_x ? (first.x, second.x) : (second.x, first.x)
    top, bottom = first_y < second_y ? (first.y, second.y) : (second.y, first.y)
    entity = DrawingEntity(identity, view, layer, ProjectId("entity.rectangle"),
        [DrawingCoordinate(left, top), DrawingCoordinate(right, top),
         DrawingCoordinate(right, bottom), DrawingCoordinate(left, bottom)], provenance)
    return plan_drafting_edit(project, action; additions = [entity])
end

"""A validated drawing-only command batch against one exact canonical project."""
struct DraftingEditPlan
    base_hash::ContentDigest
    commands::CanonicalList{ProjectCommand}
    changed_owners::CanonicalList{ProjectId}
    invalidations::CanonicalList{DependencyInvalidation}
end

function _require_drafting_record(record::CanonicalDrawingRecord)
    admitted = record isa DrawingEntity ||
        (record isa DrawingRoute && isnothing(record.semantic_connection)) ||
        (record isa DrawingLabel && isnothing(record.bound_owner))
    admitted || _semantic_fail(
        :non_drafting_selection,
        "drafting edits require geometry, unbound routes, or unbound labels",
    )
    return record
end

"""Plan one atomic drafting batch; each stable identity may appear only once."""
function plan_drafting_edit(
    project::CanonicalProject,
    action::ProjectId;
    additions::AbstractVector{<:CanonicalDrawingRecord} = CanonicalDrawingRecord[],
    replacements::AbstractVector{<:CanonicalDrawingRecord} = CanonicalDrawingRecord[],
    removals::AbstractVector{ProjectId} = ProjectId[],
    allow_layer_changes::Bool = false,
)
    require_record(record) = allow_layer_changes && record isa DrawingLayer ? record : _require_drafting_record(record)
    count = length(additions) + length(replacements) + length(removals)
    0 < count <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting batches require one to 100000 records",
    )
    ids = ProjectId[]
    patches = ProjectPatch[]
    for record in additions
        require_record(record)
        push!(ids, record.identity.id)
        push!(patches, AddDrawingRecordPatch(record))
    end
    for record in replacements
        require_record(record)
        original = require_record(drawing_record(project.drawings, record.identity.id))
        typeof(original) == typeof(record) || _semantic_fail(
            :drafting_record_type_change, "replacement must preserve the drawing record type",
        )
        push!(ids, record.identity.id)
        push!(patches, ReplaceDrawingRecordPatch(record))
    end
    for id in removals
        require_record(drawing_record(project.drawings, id))
        push!(ids, id)
        push!(patches, RemoveDrawingRecordPatch(id))
    end
    length(unique(ids)) == count || _semantic_fail(
        :duplicate_drafting_target, "a drafting batch may address each identity only once",
    )
    # Stable ordering makes selection enumeration irrelevant to replay identity.
    order = sortperm(ids; by = id -> id.value)
    commands = ProjectCommand[
        _semantic_sld_command(action, index, "drafting", patches[position])
        for (index, position) in enumerate(order)
    ]
    working = project
    effects = CommandEffect[]
    for command in commands
        working, effect = _apply_command(working, command)
        push!(effects, effect)
    end
    verified_project(working)
    project_physics_hash(working) == project_physics_hash(project) || _semantic_fail(
        :drafting_physics_change, "drafting commands must preserve physical project identity",
    )
    return DraftingEditPlan(
        project_resolved_hash(project),
        CanonicalList{ProjectCommand}(commands),
        CanonicalList{ProjectId}(_unique_changed_owners(effects)),
        CanonicalList{DependencyInvalidation}(_unique_invalidations(effects)),
    )
end

function _drafting_coordinate_sum(left::ExactDecimal, right::ExactDecimal)
    iszero(right.coefficient) && return left
    iszero(left.coefficient) && return right
    exponent = min(left.exponent, right.exponent)
    coefficient = left.coefficient * big(10)^(left.exponent - exponent) +
        right.coefficient * big(10)^(right.exponent - exponent)
    return ExactDecimal(coefficient, exponent)
end

_translated_drafting_point(point::DrawingCoordinate, delta::DrawingCoordinate) =
    DrawingCoordinate(
        _drafting_coordinate_sum(point.x, delta.x),
        _drafting_coordinate_sum(point.y, delta.y),
    )

function _translated_drafting_record(record::DrawingEntity, delta::DrawingCoordinate)
    return DrawingEntity(
        record.identity, record.container, record.layer, record.kind,
        [_translated_drafting_point(point, delta) for point in record.points],
        record.provenance; style = record.style, block_definition = record.block_definition,
    )
end

function _translated_drafting_record(record::DrawingRoute, delta::DrawingCoordinate)
    return DrawingRoute(
        record.identity, record.view, record.layer,
        [_translated_drafting_point(point, delta) for point in record.points],
        record.provenance; style = record.style,
    )
end

function _translated_drafting_record(record::DrawingLabel, delta::DrawingCoordinate)
    return DrawingLabel(
        record.identity, record.view, record.layer,
        _translated_drafting_point(record.anchor, delta), record.text,
        record.provenance; style = record.style,
    )
end

"""Translate selected drafting records in exact base-ten coordinates, preserving bindings and styles."""
function plan_drafting_translation(
    project::CanonicalProject,
    action::ProjectId,
    selection::AbstractVector{ProjectId},
    delta::DrawingCoordinate,
)
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting selection requires one to 100000 records",
    )
    replacements = CanonicalDrawingRecord[
        _translated_drafting_record(
            _require_drafting_record(drawing_record(project.drawings, id)), delta,
        ) for id in selection
    ]
    return plan_drafting_edit(project, action; replacements)
end

"""Apply a validated drafting batch through the canonical transaction and undo machinery."""
function plan_drafting_translation(
    project::CanonicalProject, action::ProjectId, selection::AbstractVector{ProjectId},
    start::DrawingCoordinate, destination::DrawingCoordinate,
)
    delta = DrawingCoordinate(
        _drafting_coordinate_sum(destination.x, ExactDecimal(-start.x.coefficient, start.x.exponent)),
        _drafting_coordinate_sum(destination.y, ExactDecimal(-start.y.coefficient, start.y.exponent)),
    )
    return plan_drafting_translation(project, action, selection, delta)
end

"""Apply a validated drafting batch through the canonical transaction and undo machinery."""
function apply_drafting_edit!(transaction::ProjectTransaction, plan::DraftingEditPlan)
    project_resolved_hash(transaction.working) == plan.base_hash || _semantic_fail(
        :drafting_edit_base_mismatch, "drafting plan does not match the transaction working state",
    )
    for command in plan.commands
        apply!(transaction, command)
    end
    validate!(transaction)
    return transaction
end
