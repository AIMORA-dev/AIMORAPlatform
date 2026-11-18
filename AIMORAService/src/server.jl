# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
struct ProjectRecord
    id::String
    display_name::String
    canonical_path::String
    size_bytes::Int
    sha256::String
end

struct ArtifactRecord
    id::String
    display_name::String
    canonical_path::String
    size_bytes::Int
    sha256::String
end

mutable struct ServiceState
    configuration::ServiceConfiguration
    path_policy::PathPolicy
    projects::Dict{String,ProjectRecord}
    artifacts::Dict{String,ArtifactRecord}
    cancelled_requests::Set{String}
    workers::WorkerSupervisor
    shutting_down::Bool
end

function ServiceState(configuration::ServiceConfiguration)
    isvalid(configuration) ||
        throw(ServiceError("INVALID_REQUEST", "The service configuration is invalid."))
    return ServiceState(
        configuration,
        PathPolicy(configuration.allowed_roots, configuration.limits.max_path_bytes),
        Dict{String,ProjectRecord}(),
        Dict{String,ArtifactRecord}(),
        Set{String}(),
        WorkerSupervisor(configuration.worker_command, configuration.limits.max_workers),
        false,
    )
end

function _required_string(
    values::AbstractDict,
    key::AbstractString;
    maximum_bytes::Int = 4096,
)
    haskey(values, key) ||
        throw(ServiceError("INVALID_REQUEST", "A required string field is missing."))
    value = values[key]
    value isa AbstractString ||
        throw(ServiceError("INVALID_REQUEST", "A required field must be a string."))
    normalized = String(value)
    !isempty(normalized) ||
        throw(ServiceError("INVALID_REQUEST", "A required string field is empty."))
    ncodeunits(normalized) <= maximum_bytes ||
        throw(ServiceError("INVALID_REQUEST", "A string field exceeds the configured limit."))
    return normalized
end

function _optional_string(
    values::AbstractDict,
    key::AbstractString,
    default::AbstractString = "";
    maximum_bytes::Int = 4096,
)
    haskey(values, key) || return String(default)
    value = values[key]
    value isa AbstractString ||
        throw(ServiceError("INVALID_REQUEST", "An optional field must be a string."))
    normalized = String(value)
    ncodeunits(normalized) <= maximum_bytes ||
        throw(ServiceError("INVALID_REQUEST", "A string field exceeds the configured limit."))
    return normalized
end

function _required_nonnegative_integer(values::AbstractDict, key::AbstractString)
    haskey(values, key) ||
        throw(ServiceError("INVALID_REQUEST", "A required integer field is missing."))
    value = values[key]
    value isa Integer && !(value isa Bool) ||
        throw(ServiceError("INVALID_REQUEST", "A required field must be an integer."))
    value >= 0 ||
        throw(ServiceError("INVALID_REQUEST", "An integer field must be nonnegative."))
    value <= typemax(Int) ||
        throw(ServiceError("INVALID_REQUEST", "An integer field exceeds the host range."))
    return Int(value)
end

function _request_parameters(request::AbstractDict)
    parameters = get(request, "params", Dict{String,Any}())
    parameters isa AbstractDict ||
        throw(ServiceError("INVALID_REQUEST", "Request params must be an object."))
    return Dict{String,Any}(String(key) => value for (key, value) in pairs(parameters))
end

function _validate_request_envelope(request::AbstractDict)
    protocol_version = _required_string(request, "protocol_version"; maximum_bytes = 32)
    protocol_version == PROTOCOL_VERSION ||
        throw(ServiceError(
            "PROTOCOL_VERSION_UNSUPPORTED",
            "The requested protocol version is unsupported.",
            Dict{String,Any}("supported_protocol_version" => PROTOCOL_VERSION),
        ))
    request_id = _required_string(request, "request_id"; maximum_bytes = 128)
    occursin(r"^[A-Za-z0-9._:-]+$", request_id) ||
        throw(ServiceError("INVALID_REQUEST", "The request identifier is invalid."))
    method = _required_string(request, "method"; maximum_bytes = 128)
    return request_id, method, _request_parameters(request)
end

function _success_response(request_id::AbstractString, result::AbstractDict)
    return Dict{String,Any}(
        "protocol_version" => PROTOCOL_VERSION,
        "request_id" => String(request_id),
        "ok" => true,
        "result" => Dict{String,Any}(String(key) => value for (key, value) in pairs(result)),
    )
end

function _error_response(request_id::AbstractString, error::ServiceError)
    return Dict{String,Any}(
        "protocol_version" => PROTOCOL_VERSION,
        "request_id" => String(request_id),
        "ok" => false,
        "error" => Dict{String,Any}(
            "code" => error.code,
            "message" => error.message,
            "details" => error.details,
        ),
    )
end

function _internal_error_response(request_id::AbstractString)
    return _error_response(
        request_id,
        ServiceError("INTERNAL_ERROR", "The service could not complete the request."),
    )
end

function _project_descriptor(record::ProjectRecord)
    return Dict{String,Any}(
        "project_id" => record.id,
        "display_name" => record.display_name,
        "size_bytes" => record.size_bytes,
        "revision" => "sha256:" * record.sha256,
    )
end

function _artifact_descriptor(record::ArtifactRecord)
    return Dict{String,Any}(
        "artifact_id" => record.id,
        "display_name" => record.display_name,
        "size_bytes" => record.size_bytes,
        "sha256" => record.sha256,
    )
end

function _open_project!(state::ServiceState, parameters::AbstractDict)
    requested_path = _required_string(
        parameters,
        "path";
        maximum_bytes = state.configuration.limits.max_path_bytes,
    )
    path = confine_existing_file(state.path_policy, requested_path)
    size_bytes = bounded_file_size(path, state.configuration.limits.max_project_bytes)
    digest = sha256_file(path)
    project_id = "project-" * digest
    record = ProjectRecord(project_id, basename(path), path, size_bytes, digest)
    if !haskey(state.projects, project_id) &&
       length(state.projects) >= state.configuration.limits.max_pending_requests
        throw(ServiceError("RESOURCE_TOO_LARGE", "Too many project references are open."))
    end
    state.projects[project_id] = record
    return _project_descriptor(record)
end

function _describe_project(state::ServiceState, parameters::AbstractDict)
    project_id = _required_string(parameters, "project_id"; maximum_bytes = 128)
    record = get(state.projects, project_id, nothing)
    record === nothing &&
        throw(ServiceError("RESOURCE_NOT_FOUND", "The requested project is not open."))
    return _project_descriptor(record)
end

function _close_project!(state::ServiceState, parameters::AbstractDict)
    project_id = _required_string(parameters, "project_id"; maximum_bytes = 128)
    pop!(state.projects, project_id, nothing) === nothing &&
        throw(ServiceError("RESOURCE_NOT_FOUND", "The requested project is not open."))
    return Dict{String,Any}("project_id" => project_id, "closed" => true)
end

function _open_artifact!(state::ServiceState, parameters::AbstractDict)
    requested_path = _required_string(
        parameters,
        "path";
        maximum_bytes = state.configuration.limits.max_path_bytes,
    )
    path = confine_existing_file(state.path_policy, requested_path)
    size_bytes = bounded_file_size(path, state.configuration.limits.max_artifact_bytes)
    digest = sha256_file(path)
    artifact_id = "artifact-" * digest
    record = ArtifactRecord(artifact_id, basename(path), path, size_bytes, digest)
    if !haskey(state.artifacts, artifact_id) &&
       length(state.artifacts) >= state.configuration.limits.max_pending_requests
        throw(ServiceError("RESOURCE_TOO_LARGE", "Too many artifact references are open."))
    end
    state.artifacts[artifact_id] = record
    return _artifact_descriptor(record)
end

function _result_window(state::ServiceState, parameters::AbstractDict)
    artifact_id = _required_string(parameters, "artifact_id"; maximum_bytes = 128)
    record = get(state.artifacts, artifact_id, nothing)
    record === nothing &&
        throw(ServiceError("RESOURCE_NOT_FOUND", "The requested artifact is not open."))
    current_size = bounded_file_size(
        record.canonical_path,
        state.configuration.limits.max_artifact_bytes,
    )
    current_digest = sha256_file(record.canonical_path)
    current_size == record.size_bytes && current_digest == record.sha256 ||
        throw(ServiceError("RESOURCE_NOT_FOUND", "The artifact reference is stale."))
    offset = _required_nonnegative_integer(parameters, "offset")
    requested_length = _required_nonnegative_integer(parameters, "length")
    data = read_file_window(
        record.canonical_path,
        offset,
        requested_length,
        state.configuration.limits.max_window_bytes,
    )
    window_length = length(data)
    metadata = Dict{String,Any}(
        "artifact_id" => record.id,
        "source_sha256" => record.sha256,
        "dtype" => "uint8",
        "endianness" => "not_applicable",
        "shape" => Any[window_length],
        "units" => "byte",
        "quantity" => "opaque_artifact_window",
        "offset" => offset,
        "length" => window_length,
    )
    return ServiceReply(
        result = Dict{String,Any}(
            "binary_frame" => true,
            "artifact_id" => record.id,
            "offset" => offset,
            "length" => window_length,
        ),
        binary_metadata = metadata,
        binary_data = data,
    )
end

function _cancel_request!(state::ServiceState, parameters::AbstractDict)
    target_request_id = _required_string(
        parameters,
        "target_request_id";
        maximum_bytes = 128,
    )
    if !(target_request_id in state.cancelled_requests) &&
       length(state.cancelled_requests) >= state.configuration.limits.max_pending_requests
        throw(ServiceError("RESOURCE_TOO_LARGE", "Too many cancellation markers are pending."))
    end
    push!(state.cancelled_requests, target_request_id)
    return Dict{String,Any}(
        "target_request_id" => target_request_id,
        "cancelled" => true,
    )
end

function dispatch_request!(
    state::ServiceState,
    request_id::AbstractString,
    method::AbstractString,
    parameters::AbstractDict,
)
    if method != "request.cancel" && request_id in state.cancelled_requests
        delete!(state.cancelled_requests, String(request_id))
        throw(ServiceError("REQUEST_CANCELLED", "The request was cancelled before execution."))
    end

    if method == "service.capabilities"
        return ServiceReply(
            result = Dict{String,Any}(
                "protocol_version" => PROTOCOL_VERSION,
                "service_version" => SERVICE_VERSION,
                "capabilities" => copy(CAPABILITIES),
                "limits" => Dict{String,Any}(
                    "control_frame_bytes" => state.configuration.limits.max_control_frame_bytes,
                    "binary_frame_bytes" => state.configuration.limits.max_binary_frame_bytes,
                    "pending_requests" => state.configuration.limits.max_pending_requests,
                    "window_bytes" => state.configuration.limits.max_window_bytes,
                    "workers" => state.configuration.limits.max_workers,
                ),
            ),
        )
    elseif method == "service.ping"
        return ServiceReply(
            result = Dict{String,Any}(
                "nonce" => _optional_string(parameters, "nonce"; maximum_bytes = 256),
                "service_time_ns" => time_ns(),
            ),
        )
    elseif method == "service.shutdown"
        return ServiceReply(
            result = Dict{String,Any}("accepted" => true),
            shutdown_after_response = true,
        )
    elseif method == "project.open"
        return ServiceReply(result = _open_project!(state, parameters))
    elseif method == "project.describe"
        return ServiceReply(result = _describe_project(state, parameters))
    elseif method == "project.close"
        return ServiceReply(result = _close_project!(state, parameters))
    elseif method == "artifact.open"
        return ServiceReply(result = _open_artifact!(state, parameters))
    elseif method == "result.window"
        return _result_window(state, parameters)
    elseif method == "request.cancel"
        return ServiceReply(result = _cancel_request!(state, parameters))
    elseif method == "worker.start"
        return ServiceReply(result = start_worker!(state.workers))
    elseif method == "worker.status"
        worker_id = _required_string(parameters, "worker_id"; maximum_bytes = 128)
        return ServiceReply(result = worker_status(state.workers, worker_id))
    elseif method == "worker.stop"
        worker_id = _required_string(parameters, "worker_id"; maximum_bytes = 128)
        return ServiceReply(result = stop_worker!(state.workers, worker_id))
    end
    throw(ServiceError("METHOD_NOT_FOUND", "The requested method is not supported."))
end

function _hello_reply(state::ServiceState)
    return Dict{String,Any}(
        "protocol_version" => PROTOCOL_VERSION,
        "service_version" => SERVICE_VERSION,
        "capabilities" => copy(CAPABILITIES),
        "authenticated" => true,
        "limits" => Dict{String,Any}(
            "control_frame_bytes" => state.configuration.limits.max_control_frame_bytes,
            "binary_frame_bytes" => state.configuration.limits.max_binary_frame_bytes,
            "pending_requests" => state.configuration.limits.max_pending_requests,
        ),
    )
end

function _handle_client!(socket, state::ServiceState)
    authenticated = false
    limits = state.configuration.limits
    try
        while !state.shutting_down
            frame = read_frame(socket, limits)
            frame === nothing && break
            request_id = "unknown"
            try
                request = decode_control_message(frame)
                request_id, method, parameters = _validate_request_envelope(request)

                if !authenticated
                    method == "service.hello" ||
                        throw(ServiceError(
                            "AUTHENTICATION_REQUIRED",
                            "The first request must authenticate the session.",
                        ))
                    token = _required_string(parameters, "token"; maximum_bytes = 256)
                    constant_time_equal(token, state.configuration.session_token) ||
                        throw(ServiceError("AUTHENTICATION_FAILED", "Session authentication failed."))
                    authenticated = true
                    write_frame(
                        socket,
                        Frame(
                            CONTROL_FRAME,
                            collect(codeunits(JSON3.write(_success_response(request_id, _hello_reply(state))))),
                        ),
                        limits,
                    )
                    continue
                end

                method == "service.hello" &&
                    throw(ServiceError("INVALID_REQUEST", "The session is already authenticated."))
                reply = dispatch_request!(state, request_id, method, parameters)
                write_frame(
                    socket,
                    Frame(
                        CONTROL_FRAME,
                        collect(codeunits(JSON3.write(_success_response(request_id, reply.result)))),
                    ),
                    limits,
                )
                if reply.binary_metadata !== nothing && reply.binary_data !== nothing
                    binary_payload = encode_binary_payload(
                        reply.binary_metadata,
                        reply.binary_data,
                    )
                    write_frame(socket, Frame(BINARY_FRAME, binary_payload), limits)
                end
                if reply.shutdown_after_response
                    state.shutting_down = true
                    break
                end
            catch error
                response = error isa ServiceError ?
                           _error_response(request_id, error) :
                           _internal_error_response(request_id)
                try
                    write_frame(
                        socket,
                        Frame(CONTROL_FRAME, collect(codeunits(JSON3.write(response)))),
                        limits,
                    )
                catch
                    break
                end
            end
        end
    finally
        try
            close(socket)
        catch
        end
    end
    return nothing
end

function _remove_stale_endpoint(endpoint::AbstractString)
    if !Sys.iswindows() && ispath(endpoint)
        rm(endpoint; force = true)
    end
    return nothing
end

function serve(configuration::ServiceConfiguration; ready_io::IO = stdout)
    isvalid(configuration) ||
        throw(ServiceError("INVALID_REQUEST", "The service configuration is invalid."))
    state = ServiceState(configuration)
    _remove_stale_endpoint(configuration.endpoint)
    listener = try
        Sockets.listen(configuration.endpoint)
    catch
        throw(ServiceError("INTERNAL_ERROR", "The local service endpoint could not be opened."))
    end

    println(
        ready_io,
        "AIMORA_SERVICE_READY\t",
        PROTOCOL_VERSION,
        "\t",
        configuration.endpoint,
    )
    flush(ready_io)

    try
        while !state.shutting_down
            socket = try
                accept(listener)
            catch
                state.shutting_down && break
                rethrow()
            end
            _handle_client!(socket, state)
        end
    finally
        stop_all_workers!(state.workers)
        try
            close(listener)
        catch
        end
        _remove_stale_endpoint(configuration.endpoint)
    end
    return nothing
end
