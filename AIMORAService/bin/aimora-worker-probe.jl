#!/usr/bin/env julia
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

using SHA

const WORKER_PROTOCOL_VERSION = "1.0.0"
const READY_PREFIX = "AIMORA_STUDY_WORKER_READY"

function required_environment(name::AbstractString; maximum_bytes::Int = 4096)
    value = get(ENV, String(name), "")
    isempty(value) && error("missing authenticated worker launch environment")
    ncodeunits(value) <= maximum_bytes ||
        error("authenticated worker launch environment exceeds its boundary")
    any(character -> character in ('\0', '\n', '\r'), value) &&
        error("authenticated worker launch environment is malformed")
    return value
end

ready_path = required_environment("AIMORA_WORKER_READY_FILE")
session_token = required_environment(
    "AIMORA_WORKER_SESSION_TOKEN";
    maximum_bytes = 256,
)
protocol_version = required_environment(
    "AIMORA_WORKER_PROTOCOL_VERSION";
    maximum_bytes = 32,
)
protocol_version == WORKER_PROTOCOL_VERSION ||
    error("unsupported authenticated worker protocol")
isdir(dirname(ready_path)) || error("private worker launch directory is unavailable")
!ispath(ready_path) || error("private worker readiness path already exists")

manifest_sha256 = bytes2hex(SHA.sha256(codeunits("aimora-worker-probe-v1")))
token_sha256 = bytes2hex(SHA.sha256(codeunits(session_token)))
record = string(
    READY_PREFIX,
    '\t',
    WORKER_PROTOCOL_VERSION,
    '\t',
    manifest_sha256,
    '\t',
    token_sha256,
    '\n',
)
temporary_path = ready_path * ".tmp-" * string(getpid())
try
    open(temporary_path, "w") do io
        write(io, record)
        flush(io)
    end
    if !Sys.iswindows()
        chmod(temporary_path, 0o600)
    end
    mv(temporary_path, ready_path; force = false)
finally
    ispath(temporary_path) && rm(temporary_path; force = true)
end

while true
    sleep(0.25)
end
