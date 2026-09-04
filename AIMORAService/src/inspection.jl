# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
Base.@kwdef struct InspectionProvider
    describe::Function
    commit::Function
    undo::Function
    redo::Function
end

function register_inspection_provider!(
    state,
    project_id::AbstractString,
    provider::InspectionProvider,
)
    normalized_id = String(project_id)
    haskey(state.projects, normalized_id) ||
        throw(ServiceError("RESOURCE_NOT_FOUND", "The inspection project is not open."))
    state.inspection_providers[normalized_id] = provider
    return provider
end

function unregister_inspection_provider!(state, project_id::AbstractString)
    return pop!(state.inspection_providers, String(project_id), nothing) !== nothing
end

function _inspection_provider(state, parameters::AbstractDict)
    project_id = _required_string(parameters, "project_id"; maximum_bytes = 128)
    haskey(state.projects, project_id) ||
        throw(ServiceError("RESOURCE_NOT_FOUND", "The inspection project is not open."))
    provider = get(state.inspection_providers, project_id, nothing)
    provider === nothing && throw(ServiceError(
        "INSPECTOR_SCHEMA_UNAVAILABLE",
        "The project has no registered Julia inspection provider.",
    ))
    return project_id, provider
end

function _required_revision(parameters::AbstractDict, key::AbstractString)
    revision = _required_string(parameters, key; maximum_bytes = 32)
    occursin(r"^[1-9][0-9]{0,19}$", revision) ||
        throw(ServiceError("INVALID_REQUEST", "The inspector revision is invalid."))
    return revision
end

function _optional_inspection_asset_ids(parameters::AbstractDict)
    asset_ids = get(parameters, "asset_ids", nothing)
    asset_ids === nothing && return nothing
    asset_ids isa AbstractVector ||
        throw(ServiceError("INVALID_REQUEST", "Inspector asset IDs must be an array."))
    0 < length(asset_ids) <= 4096 ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "Inspector selection count is invalid."))
    normalized = String[
        _required_string(Dict{String,Any}("asset_id" => value), "asset_id"; maximum_bytes = 512)
        for value in asset_ids
    ]
    length(unique(normalized)) == length(normalized) ||
        throw(ServiceError("INVALID_REQUEST", "Inspector asset IDs contain duplicates."))
    return normalized
end

function _required_inspection_identity(parameters::AbstractDict)
    identity = Dict{String,Any}(
        "project_id" => _required_string(parameters, "project_id"; maximum_bytes = 128),
        "asset_id" => _required_string(parameters, "asset_id"; maximum_bytes = 512),
        "projection_id" =>
            _required_string(parameters, "projection_id"; maximum_bytes = 512),
        "view_id" => _required_string(parameters, "view_id"; maximum_bytes = 512),
    )
    asset_ids = _optional_inspection_asset_ids(parameters)
    if asset_ids !== nothing
        identity["asset_ids"] = asset_ids
    end
    return identity
end

function _required_edit_array(state, parameters::AbstractDict)
    edits = get(parameters, "edits", nothing)
    edits isa AbstractVector ||
        throw(ServiceError("INVALID_REQUEST", "Inspector edits must be an array."))
    0 < length(edits) <= state.configuration.limits.max_inspector_edits ||
        throw(ServiceError("RESOURCE_TOO_LARGE", "Inspector edit count is invalid."))
    normalized = Any[]
    sizehint!(normalized, length(edits))
    for edit in edits
        edit isa AbstractDict ||
            throw(ServiceError("INVALID_REQUEST", "Each inspector edit must be an object."))
        path = _required_string(edit, "path"; maximum_bytes = 512)
        haskey(edit, "value") ||
            throw(ServiceError("INVALID_REQUEST", "An inspector edit value is missing."))
        display_unit = _optional_string(edit, "display_unit"; maximum_bytes = 128)
        push!(
            normalized,
            Dict{String,Any}(
                "path" => path,
                "value" => edit["value"],
                "display_unit" => display_unit,
            ),
        )
    end
    paths = String[edit["path"] for edit in normalized]
    length(unique(paths)) == length(paths) ||
        throw(ServiceError("INVALID_REQUEST", "Inspector edits contain duplicate paths."))
    return normalized
end

function _bounded_inspection_document(state, document, method::AbstractString)
    document isa AbstractDict ||
        throw(ServiceError("INTERNAL_ERROR", "The Julia inspection provider returned no object."))
    normalized = Dict{String,Any}(String(key) => value for (key, value) in pairs(document))
    if method == "inspector.describe"
        _required_string(normalized, "schema_version"; maximum_bytes = 32)
        _required_string(normalized, "revision"; maximum_bytes = 32)
        sections = get(normalized, "sections", nothing)
        sections isa AbstractVector ||
            throw(ServiceError("INTERNAL_ERROR", "The inspector schema omitted sections."))
        length(sections) <= state.configuration.limits.max_inspector_sections ||
            throw(ServiceError("RESOURCE_TOO_LARGE", "The inspector section limit was exceeded."))
        field_count = sum(
            section isa AbstractDict && get(section, "fields", nothing) isa AbstractVector ?
            length(section["fields"]) : 0 for section in sections
        )
        field_count <= state.configuration.limits.max_inspector_fields ||
            throw(ServiceError("RESOURCE_TOO_LARGE", "The inspector field limit was exceeded."))
    else
        status = _required_string(normalized, "status"; maximum_bytes = 32)
        status in ("accepted", "rejected", "conflict", "unavailable") ||
            throw(ServiceError("INTERNAL_ERROR", "The inspector result status is invalid."))
        _required_string(normalized, "revision"; maximum_bytes = 32)
    end
    return normalized
end

function _describe_inspection(state, parameters::AbstractDict)
    _, provider = _inspection_provider(state, parameters)
    identity = _required_inspection_identity(parameters)
    result = provider.describe(identity)
    return _bounded_inspection_document(state, result, "inspector.describe")
end

function _commit_inspection(state, parameters::AbstractDict)
    project_id, provider = _inspection_provider(state, parameters)
    request = Dict{String,Any}(
        "project_id" => project_id,
        "asset_id" => _required_string(parameters, "asset_id"; maximum_bytes = 512),
        "base_revision" => _required_revision(parameters, "base_revision"),
        "edits" => _required_edit_array(state, parameters),
    )
    asset_ids = _optional_inspection_asset_ids(parameters)
    asset_ids === nothing || (request["asset_ids"] = asset_ids)
    result = _bounded_inspection_document(state, provider.commit(request), "inspector.commit")
    status = result["status"]
    status == "conflict" && throw(ServiceError("REVISION_CONFLICT", "Inspector revision conflict.", result))
    status == "rejected" && throw(ServiceError(
        "INSPECTOR_VALIDATION_REJECTED",
        "The Julia owner rejected the inspector transaction.",
        result,
    ))
    return result
end

function _history_inspection(state, parameters::AbstractDict, operation::Symbol)
    project_id, provider = _inspection_provider(state, parameters)
    request = Dict{String,Any}(
        "project_id" => project_id,
        "asset_id" => _required_string(parameters, "asset_id"; maximum_bytes = 512),
        "base_revision" => _required_revision(parameters, "base_revision"),
    )
    asset_ids = _optional_inspection_asset_ids(parameters)
    asset_ids === nothing || (request["asset_ids"] = asset_ids)
    callback = operation == :undo ? provider.undo : provider.redo
    result = _bounded_inspection_document(state, callback(request), "inspector.$(operation)")
    result["status"] == "conflict" && throw(ServiceError(
        "REVISION_CONFLICT",
        "Inspector revision conflict.",
        result,
    ))
    return result
end
