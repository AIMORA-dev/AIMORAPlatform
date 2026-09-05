# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_anchor_alignment, plan_drafting_anchor_distribution

function _drafting_arrangement_records(project, selection, minimum_count)
    minimum_count <= length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "The selected arrangement requires $minimum_count to 100000 records.")
    length(unique(selection)) == length(selection) || _semantic_fail(
        :duplicate_drafting_owner, "An arrangement cannot contain duplicate owners.")
    records = [_require_drafting_record(drawing_record(project.drawings, id)) for id in selection]
    container(record) = record isa DrawingEntity ? record.container : record.view
    all(record -> container(record) == container(first(records)), records) || _semantic_fail(
        :cross_view_drafting_arrangement, "Arrange drafting objects within one view.")
    return records
end

function _drafting_arrangement_anchor(record)
    record isa DrawingLabel && return record.anchor
    isempty(record.points) && _semantic_fail(:missing_drafting_anchor, "The drawing object has no anchor.")
    return first(record.points)
end

function _drafting_arrangement_coordinate(record, axis::Symbol)
    axis in (:x, :y) || _semantic_fail(:invalid_drafting_axis, "Choose the x or y drawing axis.")
    anchor = _drafting_arrangement_anchor(record)
    return axis == :x ? anchor.x : anchor.y
end

_drafting_arrangement_difference(left::ExactDecimal, right::ExactDecimal) =
    _drafting_coordinate_sum(left, ExactDecimal(-right.coefficient, right.exponent))

function _drafting_arrangement_translation(record, axis::Symbol, target::ExactDecimal)
    offset = _drafting_arrangement_difference(target, _drafting_arrangement_coordinate(record, axis))
    zero = ExactDecimal(0, 0)
    delta = axis == :x ? DrawingCoordinate(offset, zero) : DrawingCoordinate(zero, offset)
    return _translated_drafting_record(record, delta)
end

"""Align first defining points or text anchors to one exact axis coordinate without changing shape."""
function plan_drafting_anchor_alignment(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId}, axis::Symbol, target::ExactDecimal)
    records = _drafting_arrangement_records(project, selection, 2)
    replacements = CanonicalDrawingRecord[]
    for record in records
        replacement = _drafting_arrangement_translation(record, axis, target)
        replacement == record || push!(replacements, replacement)
    end
    isempty(replacements) && _semantic_fail(:no_effect_command, "The selected anchors are already aligned.")
    return plan_drafting_edit(project, action; replacements)
end

function _drafting_distribution_step(extent::ExactDecimal, intervals::Int)
    intervals > 0 || _semantic_fail(:invalid_drafting_intervals, "Distribution needs a positive interval count.")
    divisor = gcd(abs(extent.coefficient), intervals)
    coefficient = div(extent.coefficient, divisor)
    denominator = div(BigInt(intervals), divisor)
    twos = 0
    fives = 0
    while iseven(denominator)
        denominator = div(denominator, 2)
        twos += 1
    end
    while iszero(rem(denominator, 5))
        denominator = div(denominator, 5)
        fives += 1
    end
    denominator == 1 || _semantic_fail(:non_decimal_drafting_spacing,
        "Equal anchor spacing is not an exact decimal; adjust the outer anchors or selected object count.")
    places = max(twos, fives)
    return ExactDecimal(coefficient * big(2)^(places - twos) * big(5)^(places - fives),
        extent.exponent - places)
end

"""Distribute anchors between fixed extremes, retaining orthogonal coordinates and breaking ties by owner ID."""
function plan_drafting_anchor_distribution(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId}, axis::Symbol)
    records = _drafting_arrangement_records(project, selection, 3)
    sort!(records; lt = (left, right) -> begin
        difference = _drafting_arrangement_difference(
            _drafting_arrangement_coordinate(left, axis), _drafting_arrangement_coordinate(right, axis))
        iszero(difference.coefficient) ? left.identity.id.value < right.identity.id.value : difference.coefficient < 0
    end)
    start = _drafting_arrangement_coordinate(first(records), axis)
    finish = _drafting_arrangement_coordinate(last(records), axis)
    step = _drafting_distribution_step(_drafting_arrangement_difference(finish, start), length(records) - 1)
    replacements = CanonicalDrawingRecord[]
    for (index, record) in enumerate(records)
        target = _drafting_coordinate_sum(start, ExactDecimal(step.coefficient * (index - 1), step.exponent))
        replacement = _drafting_arrangement_translation(record, axis, target)
        replacement == record || push!(replacements, replacement)
    end
    isempty(replacements) && _semantic_fail(:no_effect_command, "The selected anchors are already evenly distributed.")
    return plan_drafting_edit(project, action; replacements)
end
