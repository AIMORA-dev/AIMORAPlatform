# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_path_explosion

"""Replace drafting polylines and rectangles with exact independent line entities in one reversible batch."""
function plan_drafting_path_explosion(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId})
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "Explode requires one to 100000 drafting paths.")
    length(unique(selection)) == length(selection) || _semantic_fail(
        :duplicate_drafting_owner, "Explode cannot contain duplicate paths.")
    additions = CanonicalDrawingRecord[]
    view = nothing
    for id in sort(collect(selection); by = id -> id.value)
        record = _require_drafting_record(drawing_record(project.drawings, id))
        record isa DrawingEntity && isnothing(record.block_definition) &&
            record.kind.value in ("entity.polyline", "entity.rectangle") || _semantic_fail(
                :unsupported_drafting_explosion, "Select drafting polylines or rectangles, not blocks or electrical objects.")
        isnothing(view) && (view = record.container)
        record.container == view || _semantic_fail(:cross_view_drafting_explosion,
            "Explode paths within one drawing view.")
        points = collect(record.points)
        if record.kind.value == "entity.rectangle"
            length(points) == 4 || _semantic_fail(:invalid_drafting_rectangle,
                "A canonical rectangle must have four defining corners.")
            push!(points, first(points))
        end
        length(points) >= 2 || _semantic_fail(:invalid_drafting_path, "A path needs at least two points.")
        length(additions) + length(points) - 1 + length(selection) <= 100_000 || _semantic_fail(
            :invalid_drafting_batch_size, "Exploded lines and removed paths exceed the transaction budget.")
        for index in 1:(length(points) - 1)
            points[index] != points[index + 1] || _semantic_fail(:degenerate_drafting_segment,
                "A path with coincident consecutive vertices cannot be exploded into nonzero lines.")
            identity = ObjectIdentity(ProjectId(action.value * ".line" * string(length(additions) + 1)))
            push!(additions, DrawingEntity(identity, record.container, record.layer, ProjectId("entity.line"),
                [points[index], points[index + 1]], record.provenance; style = record.style))
        end
    end
    return plan_drafting_edit(project, action; additions, removals = selection)
end
