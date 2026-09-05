# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_quarter_rotation

function _quarter_rotated_drafting_point(point::DrawingCoordinate, pivot::DrawingCoordinate)
    delta_x = _drafting_coordinate_sum(point.x, ExactDecimal(-pivot.x.coefficient, pivot.x.exponent))
    delta_y = _drafting_coordinate_sum(point.y, ExactDecimal(-pivot.y.coefficient, pivot.y.exponent))
    return DrawingCoordinate(
        _drafting_coordinate_sum(pivot.x, ExactDecimal(-delta_y.coefficient, delta_y.exponent)),
        _drafting_coordinate_sum(pivot.y, delta_x))
end

"""Rotate drafting geometry by positive 90 degrees about an exact pivot; text remains upright."""
function plan_drafting_quarter_rotation(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId}, pivot::DrawingCoordinate)
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting selection requires one to 100000 records")
    replacements = CanonicalDrawingRecord[]
    for id in selection
        record = _require_drafting_record(drawing_record(project.drawings, id))
        if record isa DrawingEntity && isnothing(record.block_definition)
            push!(replacements, DrawingEntity(record.identity, record.container, record.layer, record.kind,
                [_quarter_rotated_drafting_point(point, pivot) for point in record.points],
                record.provenance; style = record.style))
        elseif record isa DrawingRoute
            push!(replacements, DrawingRoute(record.identity, record.view, record.layer,
                [_quarter_rotated_drafting_point(point, pivot) for point in record.points],
                record.provenance; style = record.style))
        elseif record isa DrawingLabel
            push!(replacements, DrawingLabel(record.identity, record.view, record.layer,
                _quarter_rotated_drafting_point(record.anchor, pivot), record.text,
                record.provenance; style = record.style))
        else
            _semantic_fail(:unsupported_drafting_rotation, "Block rotation requires its dedicated transformation.")
        end
    end
    return plan_drafting_edit(project, action; replacements)
end
