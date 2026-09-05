# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_arc
export drawing_arc_display_points
export plan_drafting_ellipse, drawing_ellipse_display_points

function _drawing_ellipse_basis(first::DrawingCoordinate, opposite::DrawingCoordinate)
    first_x, first_y = exact_rational(first.x), exact_rational(first.y)
    opposite_x, opposite_y = exact_rational(opposite.x), exact_rational(opposite.y)
    width, height = opposite_x - first_x, opposite_y - first_y
    !iszero(width.numerator) && !iszero(height.numerator) || _semantic_fail(
        :degenerate_drawing_ellipse, "An ellipse requires distinct horizontal and vertical bounds.")
    radius_x = (width.numerator < 0 ? -width : width) / ExactRational(2)
    radius_y = (height.numerator < 0 ? -height : height) / ExactRational(2)
    return (; center_x = (first_x + opposite_x) / ExactRational(2),
        center_y = (first_y + opposite_y) / ExactRational(2), radius_x, radius_y)
end

"""Plan an axis-aligned drafting ellipse from two exact bounding-box corners."""
function plan_drafting_ellipse(
    project::CanonicalProject, action::ProjectId, identity::ObjectIdentity,
    view::ProjectId, layer::ProjectId, first::DrawingCoordinate,
    opposite::DrawingCoordinate, provenance,
)
    _drawing_ellipse_basis(first, opposite)
    entity = DrawingEntity(identity, view, layer, ProjectId("entity.ellipse"),
        [first, opposite], provenance)
    return plan_drafting_edit(project, action; additions = [entity])
end

"""Sample an axis-aligned ellipse for display, retaining its exact canonical bounds."""
function drawing_ellipse_display_points(first::DrawingCoordinate, opposite::DrawingCoordinate;
    segments_per_ellipse::Int = 128)
    8 <= segments_per_ellipse <= 4096 || _semantic_fail(
        :drawing_ellipse_display_budget, "Ellipse display detail must be between 8 and 4096 segments.")
    basis = _drawing_ellipse_basis(first, opposite)
    display(value::ExactRational) = Float64(BigFloat(value.numerator) / BigFloat(value.denominator))
    center_x, center_y = display(basis.center_x), display(basis.center_y)
    radius_x, radius_y = display(basis.radius_x), display(basis.radius_y)
    all(isfinite, (center_x, center_y, radius_x, radius_y,
        center_x - radius_x, center_x + radius_x, center_y - radius_y, center_y + radius_y)) &&
        radius_x > 0 && radius_y > 0 || _semantic_fail(
            :drawing_ellipse_display_range, "The exact ellipse exceeds finite display range.")
    samples = Vector{Float64}[]
    sizehint!(samples, segments_per_ellipse + 1)
    for index in 0:(segments_per_ellipse - 1)
        angle = 2pi * (index / segments_per_ellipse)
        push!(samples, [center_x + radius_x * cos(angle), center_y + radius_y * sin(angle)])
    end
    push!(samples, copy(samples[1]))
    return samples
end

function _drawing_arc_basis(start::DrawingCoordinate, through::DrawingCoordinate, finish::DrawingCoordinate)
    through_dx = exact_rational(through.x) - exact_rational(start.x)
    through_dy = exact_rational(through.y) - exact_rational(start.y)
    finish_dx = exact_rational(finish.x) - exact_rational(start.x)
    finish_dy = exact_rational(finish.y) - exact_rational(start.y)
    orientation = through_dx * finish_dy - through_dy * finish_dx
    iszero(orientation.numerator) && _semantic_fail(
        :degenerate_drawing_arc, "A circular arc requires three distinct, noncollinear points.")
    return (; through_dx, through_dy, finish_dx, finish_dy, orientation)
end

"""Plan a circular drawing arc through three ordered, exact drawing points."""
function plan_drafting_arc(
    project::CanonicalProject, action::ProjectId, identity::ObjectIdentity,
    view::ProjectId, layer::ProjectId, start::DrawingCoordinate,
    through::DrawingCoordinate, finish::DrawingCoordinate, provenance,
)
    _drawing_arc_basis(start, through, finish)
    entity = DrawingEntity(identity, view, layer, ProjectId("entity.arc"),
        [start, through, finish], provenance)
    return plan_drafting_edit(project, action; additions = [entity])
end

"""Return bounded approximate display segments, without changing the exact arc record."""
function drawing_arc_display_points(start::DrawingCoordinate, through::DrawingCoordinate,
    finish::DrawingCoordinate; segments_per_circle::Int = 128)
    8 <= segments_per_circle <= 4096 || _semantic_fail(
        :drawing_arc_display_budget, "Arc display detail must be between 8 and 4096 segments per circle.")
    basis = _drawing_arc_basis(start, through, finish)
    through_squared = basis.through_dx * basis.through_dx + basis.through_dy * basis.through_dy
    finish_squared = basis.finish_dx * basis.finish_dx + basis.finish_dy * basis.finish_dy
    denominator = ExactRational(2) * basis.orientation
    offset_x = (through_squared * basis.finish_dy - finish_squared * basis.through_dy) / denominator
    offset_y = (basis.through_dx * finish_squared - basis.finish_dx * through_squared) / denominator
    display(value::ExactRational) = Float64(BigFloat(value.numerator) / BigFloat(value.denominator))
    display_point(point::DrawingCoordinate) = [display(exact_rational(point.x)), display(exact_rational(point.y))]
    center_x = display(exact_rational(start.x) + offset_x)
    center_y = display(exact_rational(start.y) + offset_y)
    radius = hypot(display(offset_x), display(offset_y))
    all(isfinite, (center_x, center_y, radius, center_x - radius, center_x + radius,
        center_y - radius, center_y + radius)) && radius > 0 || _semantic_fail(
        :drawing_arc_display_range, "The exact arc exceeds finite display range.")
    start_angle = atan(-display(offset_y), -display(offset_x))
    through_angle = atan(display(basis.through_dy - offset_y), display(basis.through_dx - offset_x))
    finish_angle = atan(display(basis.finish_dy - offset_y), display(basis.finish_dx - offset_x))
    clockwise = basis.orientation.numerator < 0
    samples = Vector{Float64}[display_point(start)]
    for (angle, next_angle, endpoint) in ((start_angle, through_angle, through), (through_angle, finish_angle, finish))
        sweep = mod(next_angle - angle, 2pi)
        sweep > 0 || _semantic_fail(:drawing_arc_display_range, "The arc span cannot be resolved for display.")
        clockwise && (sweep -= 2pi)
        segments = max(1, ceil(Int, abs(sweep) * segments_per_circle / (2pi)))
        for index in 1:segments
            theta = angle + sweep * (index / segments)
            point = index == segments ? display_point(endpoint) :
                [center_x + radius * cos(theta), center_y + radius * sin(theta)]
            all(isfinite, point) || _semantic_fail(:drawing_arc_display_range, "The arc display point is not finite.")
            push!(samples, point)
        end
    end
    return samples
end
