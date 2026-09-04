# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
Base.@kwdef struct SemanticEditProvider
    commit::Function
end

function register_semantic_edit_provider!(
    state,
    project_id::AbstractString,
    provider::SemanticEditProvider,
)
    normalized_id = String(project_id)
    haskey(state.projects, normalized_id) ||
        throw(ServiceError("RESOURCE_NOT_FOUND", "The semantic-edit project is not open."))
    state.semantic_edit_providers[normalized_id] = provider
    return provider
end

function unregister_semantic_edit_provider!(state, project_id::AbstractString)
    return pop!(state.semantic_edit_providers, String(project_id), nothing) !== nothing
end

function _semantic_edit_provider(state, parameters::AbstractDict)
    project_id = _required_string(parameters, "project_id"; maximum_bytes = 128)
    haskey(state.projects, project_id) ||
        throw(ServiceError("RESOURCE_NOT_FOUND", "The semantic-edit project is not open."))
    provider = get(state.semantic_edit_providers, project_id, nothing)
    provider === nothing && throw(ServiceError(
        "SEMANTIC_EDIT_UNAVAILABLE",
        "The project has no registered Julia semantic-edit provider.",
    ))
    return project_id, provider
end

function _required_semantic_revision(parameters::AbstractDict)
    revision = _required_string(parameters, "base_revision"; maximum_bytes = 128)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$", revision) ||
        throw(ServiceError("INVALID_REQUEST", "The semantic-edit revision is invalid."))
    return revision
end

function _required_semantic_ids(state, parameters::AbstractDict; allow_empty::Bool = false)
    values = get(parameters, "semantic_ids", nothing)
    values isa AbstractVector ||
        throw(ServiceError("INVALID_REQUEST", "Semantic identities must be an array."))
    isempty(values) && !allow_empty &&
        throw(ServiceError("INVALID_REQUEST", "The semantic edit requires an identity."))
    length(values) <= state.configuration.limits.max_semantic_ids ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "Semantic identity count is invalid."))
    ids = String[
        _required_string(Dict{String,Any}("id" => value), "id"; maximum_bytes = 1024)
        for value in values
    ]
    length(ids) == length(unique(ids)) ||
        throw(ServiceError("INVALID_REQUEST", "Semantic identities contain duplicates."))
    return ids
end

function _required_display_points(state, parameters::AbstractDict)
    values = get(parameters, "points", nothing)
    values isa AbstractVector ||
        throw(ServiceError("INVALID_REQUEST", "Semantic-edit display points must be an array."))
    length(values) <= state.configuration.limits.max_semantic_points ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "Semantic-edit display point limit was exceeded."))
    points = Any[]
    for value in values
        value isa AbstractVector && length(value) == 2 ||
            throw(ServiceError("INVALID_REQUEST", "Each display point must contain x and y."))
        all(coordinate -> coordinate isa Real && isfinite(Float64(coordinate)), value) ||
            throw(ServiceError("INVALID_REQUEST", "Display point coordinates must be finite numbers."))
        push!(points, Any[Float64(value[1]), Float64(value[2])])
    end
    return points
end

function _optional_semantic_attributes(state, parameters::AbstractDict)
    attributes = get(parameters, "attributes", Dict{String,Any}())
    attributes isa AbstractDict ||
        throw(ServiceError("INVALID_REQUEST", "Semantic-edit attributes must be an object."))
    length(attributes) <= state.configuration.limits.max_semantic_attributes ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "Semantic-edit attribute limit was exceeded."))
    normalized = Dict{String,Any}()
    for (key, value) in pairs(attributes)
        name = String(key)
        if isempty(name) || ncodeunits(name) > 128 || occursin('\0', name)
            throw(ServiceError("INVALID_REQUEST", "A semantic-edit attribute name is invalid."))
        end
        normalized[name] = value
    end
    return normalized
end

const _SEMANTIC_EDIT_OPERATIONS = Set([
    "equipment.place",
    "conductor.connect",
    "junction.update",
    "projection.edit",
    "route.edit",
    "projection.remove",
    "asset.delete",
    "cross_reference.update",
    "layout.initial",
    "layout.full",
    "layout.local",
    "layout.incremental",
])

function _bounded_semantic_edit_result(state, result)
    result isa AbstractDict ||
        throw(ServiceError("INTERNAL_ERROR", "The Julia semantic-edit provider returned no object."))
    normalized = Dict{String,Any}(String(key) => value for (key, value) in pairs(result))
    status = _required_string(normalized, "status"; maximum_bytes = 32)
    status in ("accepted", "rejected", "conflict", "unavailable") ||
        throw(ServiceError("INTERNAL_ERROR", "The semantic-edit result status is invalid."))
    _required_string(normalized, "revision"; maximum_bytes = 128)
    for key in ("changed_owner_ids", "affected_view_ids", "invalidations", "issues")
        values = get(normalized, key, Any[])
        values isa AbstractVector ||
            throw(ServiceError("INTERNAL_ERROR", "Semantic-edit impact fields must be arrays."))
        length(values) <= state.configuration.limits.max_semantic_ids ||
            throw(ServiceError("RESOURCE_TOO_LARGE", "Semantic-edit impact limit was exceeded."))
    end
    return normalized
end

function _commit_semantic_edit(state, parameters::AbstractDict)
    project_id, provider = _semantic_edit_provider(state, parameters)
    operation = _required_string(parameters, "operation"; maximum_bytes = 64)
    operation in _SEMANTIC_EDIT_OPERATIONS ||
        throw(ServiceError("INVALID_REQUEST", "The semantic-edit operation is unsupported."))
    whole_view_layout = operation in ("layout.initial", "layout.full")
    request = Dict{String,Any}(
        "project_id" => project_id,
        "base_revision" => _required_semantic_revision(parameters),
        "transaction_id" =>
            _required_string(parameters, "transaction_id"; maximum_bytes = 128),
        "operation" => operation,
        "semantic_ids" =>
            _required_semantic_ids(state, parameters; allow_empty = whole_view_layout),
        "points" => _required_display_points(state, parameters),
        "attributes" => _optional_semantic_attributes(state, parameters),
    )
    result = _bounded_semantic_edit_result(state, provider.commit(request))
    result["status"] == "conflict" && throw(ServiceError(
        "REVISION_CONFLICT",
        "Semantic-edit revision conflict.",
        result,
    ))
    result["status"] == "rejected" && throw(ServiceError(
        "SEMANTIC_EDIT_REJECTED",
        "The Julia owner rejected the semantic edit.",
        result,
    ))
    result["status"] == "unavailable" && throw(ServiceError(
        "SEMANTIC_EDIT_UNAVAILABLE",
        "The Julia semantic-edit owner is unavailable.",
        result,
    ))
    return result
end
