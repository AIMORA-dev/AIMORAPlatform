# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
const PROTOCOL_VERSION = "1.1"
const SERVICE_VERSION = "0.2.0"
const FRAME_MAGIC = UInt8[0x41, 0x4d, 0x52, 0x31]
const FRAME_HEADER_BYTES = 12

const CAPABILITIES = String[
    "service.handshake",
    "service.capabilities",
    "service.ping",
    "service.shutdown",
    "project.reference",
    "inspector.schema",
    "inspector.transaction",
    "artifact.reference",
    "result.binary-window",
    "request.cancel",
    "worker.lifecycle",
]

@enum FrameKind::UInt8 begin
    CONTROL_FRAME = 0x01
    BINARY_FRAME = 0x02
end

Base.@kwdef struct ServiceLimits
    max_control_frame_bytes::Int = 1024 * 1024
    max_binary_frame_bytes::Int = 64 * 1024 * 1024
    max_pending_requests::Int = 128
    max_path_bytes::Int = 4096
    max_project_bytes::Int = 64 * 1024 * 1024
    max_artifact_bytes::Int = 256 * 1024 * 1024
    max_window_bytes::Int = 16 * 1024 * 1024
    max_workers::Int = 2
    max_inspector_sections::Int = 64
    max_inspector_fields::Int = 4096
    max_inspector_edits::Int = 4096
    max_inspector_table_rows::Int = 100_000
end

function isvalid(limits::ServiceLimits)
    return FRAME_HEADER_BYTES < limits.max_control_frame_bytes <= 16 * 1024 * 1024 &&
           limits.max_control_frame_bytes <= limits.max_binary_frame_bytes <= 512 * 1024 * 1024 &&
           0 < limits.max_pending_requests <= 4096 &&
           256 <= limits.max_path_bytes <= 32 * 1024 &&
           0 < limits.max_project_bytes <= 4 * 1024 * 1024 * 1024 &&
           limits.max_project_bytes <= limits.max_artifact_bytes <= 4 * 1024 * 1024 * 1024 &&
           0 < limits.max_window_bytes <= min(limits.max_binary_frame_bytes, 64 * 1024 * 1024) &&
           0 < limits.max_workers <= 64 &&
           0 < limits.max_inspector_sections <= 256 &&
           0 < limits.max_inspector_fields <= 65_536 &&
           0 < limits.max_inspector_edits <= limits.max_inspector_fields &&
           0 < limits.max_inspector_table_rows <= 1_000_000
end

struct ServiceError <: Exception
    code::String
    message::String
    details::Dict{String,Any}
end

ServiceError(code::AbstractString, message::AbstractString) =
    ServiceError(String(code), String(message), Dict{String,Any}())

function Base.showerror(io::IO, error::ServiceError)
    print(io, error.code, ": ", error.message)
end

struct Frame
    kind::FrameKind
    payload::Vector{UInt8}
end

Base.@kwdef struct ServiceReply
    result::Dict{String,Any} = Dict{String,Any}()
    binary_metadata::Union{Nothing,Dict{String,Any}} = nothing
    binary_data::Union{Nothing,Vector{UInt8}} = nothing
    shutdown_after_response::Bool = false
end

Base.@kwdef struct ServiceConfiguration
    endpoint::String
    session_token::String
    allowed_roots::Vector{String}
    limits::ServiceLimits = ServiceLimits()
    worker_command::Vector{String} = String[]
end

function isvalid(configuration::ServiceConfiguration)
    return !isempty(strip(configuration.endpoint)) &&
           ncodeunits(configuration.endpoint) <= configuration.limits.max_path_bytes &&
           64 <= ncodeunits(configuration.session_token) <= 256 &&
           0 < length(configuration.allowed_roots) <= 64 &&
           all(root -> !isempty(strip(root)), configuration.allowed_roots) &&
           length(configuration.worker_command) <= 128 &&
           all(argument -> ncodeunits(argument) <= configuration.limits.max_path_bytes,
               configuration.worker_command) &&
           isvalid(configuration.limits)
end
