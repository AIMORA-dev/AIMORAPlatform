# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_layer_creation, plan_drafting_layer_update, plan_drafting_layer_assignment

function _require_drawing_layer(project, view_id::ProjectId, layer_id::ProjectId)
    view = drawing_record(project.drawings, view_id)
    layer = drawing_record(project.drawings, layer_id)
    view isa DrawingView && layer isa DrawingLayer && layer.document == view.document ||
        _semantic_fail(:invalid_drawing_layer, "The layer must belong to the drawing view's document.")
    return layer
end

function _require_unique_layer_name(project, document, name, excluded = nothing)
    !isempty(strip(name)) && ncodeunits(name) <= 1024 || _semantic_fail(:invalid_drawing_layer_name,
        "A layer needs a nonempty name of at most 1024 UTF-8 bytes.")
    any(layer -> layer.document == document && layer.identity.id != excluded &&
        lowercase(layer.name) == lowercase(strip(name)), project.drawings.layers) &&
        _semantic_fail(:duplicate_drawing_layer_name, "Layer names must be distinct within a document.")
end

function plan_drafting_layer_creation(project::CanonicalProject, action::ProjectId, view_id::ProjectId,
    name::AbstractString; visible::Bool = true, printable::Bool = true)
    view = drawing_record(project.drawings, view_id)
    view isa DrawingView || _semantic_fail(:invalid_drawing_view, "Create layers in a drawing view.")
    _require_unique_layer_name(project, view.document, name)
    layer = DrawingLayer(ObjectIdentity(ProjectId(action.value * ".layer")), view.document,
        strip(name), view.provenance; visible, printable)
    return plan_drafting_edit(project, action; additions = [layer], allow_layer_changes = true)
end

function plan_drafting_layer_update(project::CanonicalProject, action::ProjectId, view_id::ProjectId,
    layer_id::ProjectId, name::AbstractString; visible::Bool, printable::Bool)
    original = _require_drawing_layer(project, view_id, layer_id)
    _require_unique_layer_name(project, original.document, name, layer_id)
    replacement = DrawingLayer(original.identity, original.document, strip(name), original.provenance; visible, printable)
    return plan_drafting_edit(project, action; replacements = [replacement], allow_layer_changes = true)
end

function plan_drafting_layer_assignment(project::CanonicalProject, action::ProjectId, view_id::ProjectId,
    selection::AbstractVector{ProjectId}, layer_id::ProjectId)
    _require_drawing_layer(project, view_id, layer_id)
    0 < length(selection) <= 100_000 && length(unique(selection)) == length(selection) ||
        _semantic_fail(:invalid_drafting_selection, "Choose one to 100000 distinct drafting objects.")
    replacements = CanonicalDrawingRecord[]
    for id in selection
        record = _require_drafting_record(drawing_record(project.drawings, id))
        container = record isa DrawingEntity ? record.container : record.view
        container == view_id || _semantic_fail(:cross_view_layer_assignment, "Assign objects in the active view only.")
        record.layer == layer_id && continue
        replacement = if record isa DrawingEntity
            DrawingEntity(record.identity, record.container, layer_id, record.kind, record.points,
                record.provenance; style = record.style, block_definition = record.block_definition)
        elseif record isa DrawingRoute
            DrawingRoute(record.identity, record.view, layer_id, record.points, record.provenance; style = record.style)
        else
            DrawingLabel(record.identity, record.view, layer_id, record.anchor, record.text,
                record.provenance; style = record.style)
        end
        push!(replacements, replacement)
    end
    isempty(replacements) && _semantic_fail(:no_effect_command, "Selected objects already use this layer.")
    return plan_drafting_edit(project, action; replacements)
end
