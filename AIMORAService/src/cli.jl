# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
function _parse_integer_option(value::AbstractString, option_name::AbstractString)
    parsed = tryparse(Int, value)
    parsed === nothing &&
        throw(ServiceError("INVALID_REQUEST", "An integer service option is invalid."))
    parsed > 0 ||
        throw(ServiceError("INVALID_REQUEST", "An integer service option must be positive."))
    return parsed
end

function _parse_cli_arguments(arguments::Vector{String})
    values = Dict{String,Any}(
        "allowed_roots" => String[],
        "worker_args" => String[],
    )
    index = 1
    while index <= length(arguments)
        option = arguments[index]
        if option == "--help"
            values["help"] = true
            index += 1
            continue
        end
        option in (
            "--endpoint",
            "--token-file",
            "--allowed-root",
            "--worker-program",
            "--worker-arg",
            "--max-control-frame-bytes",
            "--max-binary-frame-bytes",
            "--max-pending-requests",
            "--max-path-bytes",
            "--max-project-bytes",
            "--max-artifact-bytes",
            "--max-window-bytes",
            "--max-workers",
        ) || throw(ServiceError("INVALID_REQUEST", "An unknown service option was supplied."))
        index < length(arguments) ||
            throw(ServiceError("INVALID_REQUEST", "A service option value is missing."))
        value = arguments[index + 1]
        if option == "--allowed-root"
            push!(values["allowed_roots"], value)
        elseif option == "--worker-arg"
            push!(values["worker_args"], value)
        else
            values[option[3:end]] = value
        end
        index += 2
    end
    return values
end

function _read_session_token(token_file::AbstractString)
    isfile(token_file) ||
        throw(ServiceError("AUTHENTICATION_FAILED", "The session token file is unavailable."))
    if !Sys.iswindows()
        mode = stat(token_file).mode
        iszero(mode & 0o077) ||
            throw(ServiceError("AUTHENTICATION_FAILED", "The session token file is not private."))
    end
    token = strip(read(token_file, String))
    rm(token_file; force = true)
    ncodeunits(token) >= 64 ||
        throw(ServiceError("AUTHENTICATION_FAILED", "The session token is too short."))
    ncodeunits(token) <= 256 ||
        throw(ServiceError("AUTHENTICATION_FAILED", "The session token is too long."))
    return token
end

function _service_usage()
    return """
Usage: aimora-service.jl --endpoint NAME --token-file PATH --allowed-root PATH [options]

Required:
  --endpoint NAME                  QLocalSocket-compatible pipe or local socket endpoint
  --token-file PATH                private one-use session token file
  --allowed-root PATH              repeatable confined project/artifact root

Optional:
  --worker-program PATH            executable used for bounded study-worker probes
  --worker-arg VALUE               repeatable worker argument
  --max-control-frame-bytes N
  --max-binary-frame-bytes N
  --max-pending-requests N
  --max-path-bytes N
  --max-project-bytes N
  --max-artifact-bytes N
  --max-window-bytes N
  --max-workers N
"""
end

function _configuration_from_cli(values::Dict{String,Any})
    haskey(values, "endpoint") ||
        throw(ServiceError("INVALID_REQUEST", "The endpoint option is required."))
    haskey(values, "token-file") ||
        throw(ServiceError("INVALID_REQUEST", "The token-file option is required."))
    allowed_roots = String.(values["allowed_roots"])
    isempty(allowed_roots) &&
        throw(ServiceError("INVALID_REQUEST", "At least one allowed root is required."))

    defaults = ServiceLimits()
    integer_option(name::String, default::Int) = haskey(values, name) ?
        _parse_integer_option(String(values[name]), name) : default
    limits = ServiceLimits(
        max_control_frame_bytes = integer_option(
            "max-control-frame-bytes",
            defaults.max_control_frame_bytes,
        ),
        max_binary_frame_bytes = integer_option(
            "max-binary-frame-bytes",
            defaults.max_binary_frame_bytes,
        ),
        max_pending_requests = integer_option(
            "max-pending-requests",
            defaults.max_pending_requests,
        ),
        max_path_bytes = integer_option("max-path-bytes", defaults.max_path_bytes),
        max_project_bytes = integer_option("max-project-bytes", defaults.max_project_bytes),
        max_artifact_bytes = integer_option(
            "max-artifact-bytes",
            defaults.max_artifact_bytes,
        ),
        max_window_bytes = integer_option("max-window-bytes", defaults.max_window_bytes),
        max_workers = integer_option("max-workers", defaults.max_workers),
    )

    worker_command = String[]
    if haskey(values, "worker-program")
        push!(worker_command, String(values["worker-program"]))
        append!(worker_command, String.(values["worker_args"]))
    elseif !isempty(values["worker_args"])
        throw(ServiceError("INVALID_REQUEST", "Worker arguments require a worker program."))
    end

    token = _read_session_token(String(values["token-file"]))
    return ServiceConfiguration(
        endpoint = String(values["endpoint"]),
        session_token = token,
        allowed_roots = allowed_roots,
        limits = limits,
        worker_command = worker_command,
    )
end

function run_cli(arguments::Vector{String} = copy(ARGS))
    try
        values = _parse_cli_arguments(arguments)
        if get(values, "help", false)
            print(stdout, _service_usage())
            return 0
        end
        configuration = _configuration_from_cli(values)
        serve(configuration)
        return 0
    catch error
        code = error isa ServiceError ? error.code : "INTERNAL_ERROR"
        println(stderr, "AIMORA_SERVICE_ERROR\t", code)
        return 2
    end
end
