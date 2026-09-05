# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_axis_mirror

function _reflected_drafting_point(point::DrawingCoordinate, axis::Symbol, coordinate::ExactDecimal)
    axis in (:horizontal, :vertical) || _semantic_fail(
        :invalid_drafting_mirror_axis, "An axis mirror requires horizontal or vertical orientation.")
    original = axis == :vertical ? point.x : point.y
    reflected = _drafting_coordinate_sum(
        ExactDecimal(2 * coordinate.coefficient, coordinate.exponent),
        ExactDecimal(-original.coefficient, original.exponent))
    return axis == :vertical ? DrawingCoordinate(reflected, point.y) : DrawingCoordinate(point.x, reflected)
end

"""Reflect drafting geometry across an exact horizontal or vertical line; text remains upright."""
function plan_drafting_axis_mirror(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId}, axis::Symbol, coordinate::ExactDecimal)
    axis in (:horizontal, :vertical) || _semantic_fail(
        :invalid_drafting_mirror_axis, "An axis mirror requires horizontal or vertical orientation.")
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "drafting selection requires one to 100000 records")
    replacements = CanonicalDrawingRecord[]
    for id in selection
        record = _require_drafting_record(drawing_record(project.drawings, id))
        if record isa DrawingEntity && isnothing(record.block_definition)
            push!(replacements, DrawingEntity(record.identity, record.container, record.layer, record.kind,
                [_reflected_drafting_point(point, axis, coordinate) for point in record.points],
                record.provenance; style = record.style))
        elseif record isa DrawingRoute
            push!(replacements, DrawingRoute(record.identity, record.view, record.layer,
                [_reflected_drafting_point(point, axis, coordinate) for point in record.points],
                record.provenance; style = record.style))
        elseif record isa DrawingLabel
            push!(replacements, DrawingLabel(record.identity, record.view, record.layer,
                _reflected_drafting_point(record.anchor, axis, coordinate), record.text,
                record.provenance; style = record.style))
        else
            _semantic_fail(:unsupported_drafting_mirror, "Block mirroring requires its dedicated transformation.")
        end
    end
    return plan_drafting_edit(project, action; replacements)
end
