"""
Return deterministic sample indices that preserve boundaries, declared events,
neighbours of events, and local extrema. The returned set may exceed `target`
when the mandatory event set itself is larger than the requested budget.
"""
function event_preserving_indices(
    x::AbstractVector,
    y::AbstractVector,
    target::Integer;
    events = Int[],
)
    length(x) == length(y) || throw(ArgumentError("x and y lengths differ"))
    count = length(x)
    count == 0 && return Int[]
    target >= 2 || throw(ArgumentError("target must be at least 2"))
    count <= target && return collect(1:count)

    mandatory = Set{Int}((1, count))
    for event in events
        1 <= event <= count || throw(ArgumentError("event index $event is outside the series"))
        for candidate in (event - 1, event, event + 1)
            1 <= candidate <= count && push!(mandatory, candidate)
        end
    end

    optional = Set{Int}()
    bucket_count = max(1, fld(max(target - length(mandatory), 2), 2))
    edges = round.(Int, range(1, count + 1; length = bucket_count + 1))
    for bucket in 1:bucket_count
        first_index = clamp(edges[bucket], 1, count)
        last_index = clamp(edges[bucket + 1] - 1, first_index, count)
        range_indices = first_index:last_index
        local_values = y[range_indices]
        finite_positions = findall(isfinite, local_values)
        isempty(finite_positions) && continue
        minimum_position = finite_positions[argmin(local_values[finite_positions])]
        maximum_position = finite_positions[argmax(local_values[finite_positions])]
        push!(optional, first_index + minimum_position - 1)
        push!(optional, first_index + maximum_position - 1)
    end

    candidates = sort!(collect(setdiff(optional, mandatory)))
    allowance = max(0, target - length(mandatory))
    if length(candidates) > allowance && allowance > 0
        chosen_positions = unique(round.(Int, range(1, length(candidates); length = allowance)))
        candidates = candidates[chosen_positions]
    elseif allowance == 0
        empty!(candidates)
    end
    return sort!(vcat(collect(mandatory), candidates))
end

function downsample_series(series::PlotSeries, target::Integer)
    indices = event_preserving_indices(series.x, series.y, target; events = series.event_indices)
    remap = Dict(original => new for (new, original) in enumerate(indices))
    events = sort!([remap[index] for index in series.event_indices if haskey(remap, index)])
    lower = isnothing(series.uncertainty_lower) ? nothing : series.uncertainty_lower[indices]
    upper = isnothing(series.uncertainty_upper) ? nothing : series.uncertainty_upper[indices]
    return PlotSeries(
        series.id,
        series.label,
        series.x[indices],
        series.y[indices];
        x_unit = series.x_unit,
        y_unit = series.y_unit,
        source_hash = series.source_hash,
        event_indices = events,
        uncertainty_lower = lower,
        uncertainty_upper = upper,
        style_key = series.style_key,
    )
end

function _finite_bounds(values::AbstractVector{<:Real})
    finite_values = Float64[value for value in values if isfinite(value)]
    isempty(finite_values) && return (0.0, 1.0)
    minimum_value, maximum_value = extrema(finite_values)
    if minimum_value == maximum_value
        padding = iszero(minimum_value) ? 1.0 : abs(minimum_value) * 0.05
        return (minimum_value - padding, maximum_value + padding)
    end
    return (minimum_value, maximum_value)
end
