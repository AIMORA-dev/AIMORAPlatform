# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
const WORKER_PROTOCOL_VERSION = "1.0.0"
const _WORKER_READY_PREFIX = "AIMORA_STUDY_WORKER_READY"
const _WORKER_READY_MAX_BYTES = 1024
const _WORKER_SHA256_PATTERN = r"^[0-9a-f]{64}$"

mutable struct WorkerRecord
    id::String
    process::Base.Process
    started_at_ns::UInt64
    manifest_sha256::String
    generation::Int
    recoveries::Int
end

mutable struct WorkerSupervisor
    command::Vector{String}
    maximum_workers::Int
    maximum_recoveries::Int
    start_timeout_seconds::Float64
    stop_timeout_seconds::Float64
    workers::Dict{String,WorkerRecord}
end

function WorkerSupervisor(
    command::Vector{String},
    maximum_workers::Integer;
    maximum_recoveries::Integer = 3,
    start_timeout_seconds::Real = 10.0,
    stop_timeout_seconds::Real = 2.0,
)
    maximum_workers > 0 ||
        throw(ServiceError("INVALID_REQUEST", "Worker limit must be positive."))
    0 <= maximum_recoveries <= 16 || throw(ServiceError(
        "INVALID_REQUEST",
        "Worker recovery limit must be between zero and sixteen.",
    ))
    0.1 <= start_timeout_seconds <= 120.0 || throw(ServiceError(
        "INVALID_REQUEST",
        "Worker startup timeout is outside the supported range.",
    ))
    0.1 <= stop_timeout_seconds <= 30.0 || throw(ServiceError(
        "INVALID_REQUEST",
        "Worker shutdown timeout is outside the supported range.",
    ))
    return WorkerSupervisor(
        copy(command),
        Int(maximum_workers),
        Int(maximum_recoveries),
        Float64(start_timeout_seconds),
        Float64(stop_timeout_seconds),
        Dict{String,WorkerRecord}(),
    )
end

function _process_exited(process::Base.Process)
    return try
        Base.process_exited(process)
    catch
        true
    end
end

_worker_running(record::WorkerRecord) = !_process_exited(record.process)

function _reap_exited_process!(process::Base.Process)
    _process_exited(process) || return false
    try
        wait(process)
    catch
    end
    return true
end

function _terminate_process!(process::Base.Process; timeout_seconds::Real = 2.0)
    if !_process_exited(process)
        try
            kill(process)
        catch
        end
    end

    status = timedwait(
        () -> _process_exited(process),
        timeout_seconds;
        pollint = 0.02,
    )
    if status == :timed_out
        try
            if Sys.iswindows()
                kill(process)
            else
                kill(process, Base.SIGKILL)
            end
        catch
        end
        timedwait(
            () -> _process_exited(process),
            timeout_seconds;
            pollint = 0.02,
        )
    end

    return _reap_exited_process!(process)
end

function _new_worker_session_token()
    material = string(uuid4(), ':', uuid4(), ':', time_ns())
    return bytes2hex(SHA.sha256(collect(codeunits(material))))
end

function _worker_token_digest(token::AbstractString)
    return bytes2hex(SHA.sha256(collect(codeunits(token))))
end

function _parse_worker_ready_record(
    ready_path::AbstractString,
    expected_token::AbstractString,
)
    isfile(ready_path) || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker exited before publishing readiness.",
    ))
    size = Int(stat(ready_path).size)
    0 < size <= _WORKER_READY_MAX_BYTES || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker readiness record is invalid.",
    ))
    text = read(ready_path, String)
    line = chomp(text)
    any(character -> character in ('\0', '\n', '\r'), line) && throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker readiness record is invalid.",
    ))
    fields = split(line, '\t'; keepempty = true)
    length(fields) == 4 || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker readiness record is invalid.",
    ))
    fields[1] == _WORKER_READY_PREFIX || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker readiness record is invalid.",
    ))
    fields[2] == WORKER_PROTOCOL_VERSION || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker protocol version is unsupported.",
    ))
    manifest_sha256 = String(fields[3])
    occursin(_WORKER_SHA256_PATTERN, manifest_sha256) || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker manifest identity is invalid.",
    ))
    token_digest = String(fields[4])
    occursin(_WORKER_SHA256_PATTERN, token_digest) || throw(ServiceError(
        "WORKER_UNAVAILABLE",
        "The study worker authentication record is invalid.",
    ))
    constant_time_equal(token_digest, _worker_token_digest(expected_token)) ||
        throw(ServiceError(
            "WORKER_UNAVAILABLE",
            "The study worker failed launch authentication.",
        ))
    return manifest_sha256
end

function _launch_worker_process(supervisor::WorkerSupervisor)
    isempty(supervisor.command) &&
        throw(ServiceError("WORKER_UNAVAILABLE", "No study-worker command is configured."))

    ready_root = mktempdir()
    if !Sys.iswindows()
        try
            chmod(ready_root, 0o700)
        catch
            rm(ready_root; force = true, recursive = true)
            throw(ServiceError(
                "WORKER_UNAVAILABLE",
                "A private study-worker launch directory could not be prepared.",
            ))
        end
    end
    ready_path = joinpath(ready_root, "ready")
    session_token = _new_worker_session_token()
    command = addenv(
        Cmd(supervisor.command),
        "AIMORA_WORKER_READY_FILE" => ready_path,
        "AIMORA_WORKER_SESSION_TOKEN" => session_token,
        "AIMORA_WORKER_PROTOCOL_VERSION" => WORKER_PROTOCOL_VERSION,
    )

    process = nothing
    try
        isolated_command = pipeline(
            command;
            stdin = devnull,
            stdout = devnull,
            stderr = devnull,
        )
        process = run(isolated_command; wait = false)
        status = timedwait(
            () -> isfile(ready_path) || _process_exited(process),
            supervisor.start_timeout_seconds;
            pollint = 0.02,
        )
        status == :timed_out && throw(ServiceError(
            "WORKER_UNAVAILABLE",
            "The study worker did not become ready before the bounded timeout.",
        ))
        manifest_sha256 = _parse_worker_ready_record(ready_path, session_token)
        _process_exited(process) && throw(ServiceError(
            "WORKER_UNAVAILABLE",
            "The study worker exited during launch authentication.",
        ))
        return process, manifest_sha256
    catch error
        if process isa Base.Process
            _terminate_process!(
                process;
                timeout_seconds = supervisor.stop_timeout_seconds,
            )
        end
        error isa ServiceError && rethrow()
        throw(ServiceError("WORKER_UNAVAILABLE", "The study worker could not be started."))
    finally
        rm(ready_root; force = true, recursive = true)
    end
end

function _worker_descriptor(
    supervisor::WorkerSupervisor,
    record::WorkerRecord;
    recovered::Bool = false,
)
    running = _worker_running(record)
    exhausted = !running && record.recoveries >= supervisor.maximum_recoveries
    return Dict{String,Any}(
        "worker_id" => record.id,
        "state" => running ? "running" : exhausted ? "failed" : "exited",
        "started_at_ns" => record.started_at_ns,
        "worker_protocol_version" => WORKER_PROTOCOL_VERSION,
        "manifest_sha256" => record.manifest_sha256,
        "generation" => record.generation,
        "recoveries" => record.recoveries,
        "maximum_recoveries" => supervisor.maximum_recoveries,
        "recovered" => recovered,
        "recovery_exhausted" => exhausted,
    )
end

function _recover_worker!(supervisor::WorkerSupervisor, record::WorkerRecord)
    _worker_running(record) && return false
    _reap_exited_process!(record.process)
    record.recoveries < supervisor.maximum_recoveries || return false

    record.recoveries += 1
    record.generation += 1
    process, manifest_sha256 = _launch_worker_process(supervisor)
    record.process = process
    record.started_at_ns = time_ns()
    record.manifest_sha256 = manifest_sha256
    return true
end

function prune_workers!(supervisor::WorkerSupervisor)
    stale_ids = String[
        worker_id for (worker_id, record) in supervisor.workers if
        !_worker_running(record) && record.recoveries >= supervisor.maximum_recoveries
    ]
    for worker_id in stale_ids
        record = pop!(supervisor.workers, worker_id)
        _reap_exited_process!(record.process)
    end
    return nothing
end

function start_worker!(supervisor::WorkerSupervisor)
    isempty(supervisor.command) &&
        throw(ServiceError("WORKER_UNAVAILABLE", "No study-worker command is configured."))
    prune_workers!(supervisor)
    length(supervisor.workers) < supervisor.maximum_workers ||
        throw(ServiceError("WORKER_LIMIT_REACHED", "The configured worker limit was reached."))

    process, manifest_sha256 = _launch_worker_process(supervisor)
    worker_id = "worker-" * string(uuid4())
    record = WorkerRecord(
        worker_id,
        process,
        time_ns(),
        manifest_sha256,
        1,
        0,
    )
    supervisor.workers[worker_id] = record
    return _worker_descriptor(supervisor, record)
end

function worker_status(supervisor::WorkerSupervisor, worker_id::AbstractString)
    record = get(supervisor.workers, String(worker_id), nothing)
    record === nothing &&
        throw(ServiceError("WORKER_NOT_FOUND", "The requested worker does not exist."))
    recovered = _recover_worker!(supervisor, record)
    return _worker_descriptor(supervisor, record; recovered = recovered)
end

function stop_worker!(supervisor::WorkerSupervisor, worker_id::AbstractString)
    key = String(worker_id)
    record = pop!(supervisor.workers, key, nothing)
    record === nothing &&
        throw(ServiceError("WORKER_NOT_FOUND", "The requested worker does not exist."))
    terminated = _terminate_process!(
        record.process;
        timeout_seconds = supervisor.stop_timeout_seconds,
    )
    if !terminated
        supervisor.workers[key] = record
        throw(ServiceError(
            "WORKER_UNAVAILABLE",
            "The study worker did not stop within the bounded shutdown window.",
        ))
    end
    return Dict{String,Any}(
        "worker_id" => record.id,
        "state" => "stopped",
        "worker_protocol_version" => WORKER_PROTOCOL_VERSION,
        "generation" => record.generation,
        "recoveries" => record.recoveries,
    )
end

function stop_all_workers!(supervisor::WorkerSupervisor)
    for worker_id in collect(keys(supervisor.workers))
        record = pop!(supervisor.workers, worker_id)
        _terminate_process!(
            record.process;
            timeout_seconds = supervisor.stop_timeout_seconds,
        )
    end
    return nothing
end
