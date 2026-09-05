# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_line_join

function _drafting_join_point_precedes(left::DrawingCoordinate, right::DrawingCoordinate)
    horizontal = _drafting_arrangement_difference(left.x, right.x).coefficient
    return iszero(horizontal) ? _drafting_arrangement_difference(left.y, right.y).coefficient < 0 : horizontal < 0
end

"""Join one exact nonbranching chain or ring of compatible drafting lines without inferring topology."""
function plan_drafting_line_join(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId})
    2 <= length(selection) < 100_000 || _semantic_fail(:invalid_drafting_batch_size,
        "Join requires two to 99999 drafting lines.")
    length(unique(selection)) == length(selection) || _semantic_fail(:duplicate_drafting_owner,
        "Join cannot contain duplicate owners.")
    records = DrawingEntity[]
    adjacency = Dict{DrawingCoordinate,Vector{Int}}()
    edges = Set{Tuple{DrawingCoordinate,DrawingCoordinate}}()
    for id in sort(collect(selection); by = id -> id.value)
        record = _require_drafting_record(drawing_record(project.drawings, id))
        record isa DrawingEntity && record.kind.value == "entity.line" &&
            isnothing(record.block_definition) && length(record.points) == 2 || _semantic_fail(
                :unsupported_drafting_join, "Select only independent drafting lines.")
        if !isempty(records)
            reference = first(records)
            record.container == reference.container && record.layer == reference.layer &&
                record.style == reference.style && record.provenance == reference.provenance || _semantic_fail(
                    :incompatible_drafting_join, "Joined lines must share a view, layer, style and provenance.")
        end
        start, finish = record.points
        start != finish || _semantic_fail(:degenerate_drafting_join, "Zero-length lines cannot be joined.")
        edge = _drafting_join_point_precedes(start, finish) ? (start, finish) : (finish, start)
        edge in edges && _semantic_fail(:duplicate_drafting_segment, "Duplicate or reversed duplicate lines cannot be joined.")
        push!(edges, edge)
        push!(records, record)
        for point in record.points
            incident = get!(adjacency, point, Int[])
            push!(incident, length(records))
            length(incident) <= 2 || _semantic_fail(:branching_drafting_join,
                "Join requires a nonbranching chain; choose lines with at most two incident endpoints.")
        end
    end
    ends = [point for (point, incident) in adjacency if length(incident) == 1]
    length(ends) in (0, 2) || _semantic_fail(:disconnected_drafting_join,
        "Selected lines must form one connected chain or closed ring.")
    candidates = isempty(ends) ? collect(keys(adjacency)) : ends
    sort!(candidates; lt = _drafting_join_point_precedes)
    current = first(candidates)
    points = DrawingCoordinate[current]
    visited = falses(length(records))
    for _ in eachindex(records)
        available = [index for index in adjacency[current] if !visited[index]]
        isempty(available) && _semantic_fail(:disconnected_drafting_join,
            "Selected lines contain disconnected paths or rings.")
        other(index) = records[index].points[1] == current ? records[index].points[2] : records[index].points[1]
        sort!(available; lt = (left, right) -> _drafting_join_point_precedes(other(left), other(right)))
        edge_index = first(available)
        visited[edge_index] = true
        current = other(edge_index)
        push!(points, current)
    end
    reference = first(records)
    joined = DrawingEntity(ObjectIdentity(ProjectId(action.value * ".path")), reference.container,
        reference.layer, ProjectId("entity.polyline"), points, reference.provenance; style = reference.style)
    return plan_drafting_edit(project, action; additions = [joined], removals = selection)
end
