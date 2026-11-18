# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
function _encode_u32(value::Integer)
    0 <= value <= typemax(UInt32) ||
        throw(ServiceError("FRAME_TOO_LARGE", "Frame length exceeds the protocol limit."))
    unsigned_value = UInt32(value)
    return UInt8[
        UInt8((unsigned_value >> 24) & 0xff),
        UInt8((unsigned_value >> 16) & 0xff),
        UInt8((unsigned_value >> 8) & 0xff),
        UInt8(unsigned_value & 0xff),
    ]
end

function _decode_u32(bytes::AbstractVector{UInt8})
    length(bytes) == 4 ||
        throw(ServiceError("FRAME_INVALID", "A four-byte integer was expected."))
    value = (UInt32(bytes[1]) << 24) |
            (UInt32(bytes[2]) << 16) |
            (UInt32(bytes[3]) << 8) |
            UInt32(bytes[4])
    return Int(value)
end

function _frame_limit(kind::FrameKind, limits::ServiceLimits)
    return kind == CONTROL_FRAME ? limits.max_control_frame_bytes :
           limits.max_binary_frame_bytes
end

function encode_frame(frame::Frame, limits::ServiceLimits = ServiceLimits())
    length(frame.payload) <= _frame_limit(frame.kind, limits) ||
        throw(ServiceError("FRAME_TOO_LARGE", "Frame payload exceeds the configured limit."))

    header = UInt8[]
    append!(header, FRAME_MAGIC)
    push!(header, UInt8(frame.kind))
    append!(header, UInt8[0x00, 0x00, 0x00])
    append!(header, _encode_u32(length(frame.payload)))
    return vcat(header, frame.payload)
end

function write_frame(io::IO, frame::Frame, limits::ServiceLimits = ServiceLimits())
    write(io, encode_frame(frame, limits))
    flush(io)
    return nothing
end

function read_frame(io::IO, limits::ServiceLimits = ServiceLimits())
    header = read(io, FRAME_HEADER_BYTES)
    isempty(header) && return nothing
    length(header) == FRAME_HEADER_BYTES ||
        throw(ServiceError("FRAME_INVALID", "The frame header is incomplete."))
    header[1:4] == FRAME_MAGIC ||
        throw(ServiceError("FRAME_INVALID", "The frame magic is invalid."))
    all(iszero, header[6:8]) ||
        throw(ServiceError("FRAME_INVALID", "Reserved frame bytes must be zero."))

    kind_value = header[5]
    kind_value in (UInt8(CONTROL_FRAME), UInt8(BINARY_FRAME)) ||
        throw(ServiceError("FRAME_INVALID", "The frame kind is unsupported."))
    kind = FrameKind(kind_value)

    payload_length = _decode_u32(header[9:12])
    payload_length <= _frame_limit(kind, limits) ||
        throw(ServiceError("FRAME_TOO_LARGE", "Frame payload exceeds the configured limit."))
    payload = read(io, payload_length)
    length(payload) == payload_length ||
        throw(ServiceError("FRAME_INVALID", "The frame payload is incomplete."))
    return Frame(kind, payload)
end

function encode_control_message(message, limits::ServiceLimits = ServiceLimits())
    payload = collect(codeunits(JSON3.write(message)))
    return encode_frame(Frame(CONTROL_FRAME, payload), limits)
end

function decode_control_message(frame::Frame)
    frame.kind == CONTROL_FRAME ||
        throw(ServiceError("FRAME_INVALID", "A control frame was expected."))
    value = try
        JSON3.read(String(frame.payload))
    catch
        throw(ServiceError("INVALID_REQUEST", "The control payload is not valid JSON."))
    end
    materialized = _materialize_json(value)
    materialized isa Dict{String,Any} ||
        throw(ServiceError("INVALID_REQUEST", "The control payload must be a JSON object."))
    return materialized
end

function encode_binary_payload(metadata::AbstractDict, data::AbstractVector{UInt8})
    metadata_bytes = collect(codeunits(JSON3.write(metadata)))
    return vcat(_encode_u32(length(metadata_bytes)), metadata_bytes, Vector{UInt8}(data))
end

function decode_binary_payload(frame::Frame)
    frame.kind == BINARY_FRAME ||
        throw(ServiceError("FRAME_INVALID", "A binary frame was expected."))
    length(frame.payload) >= 4 ||
        throw(ServiceError("FRAME_INVALID", "Binary metadata length is missing."))
    metadata_length = _decode_u32(frame.payload[1:4])
    metadata_end = 4 + metadata_length
    metadata_end <= length(frame.payload) ||
        throw(ServiceError("FRAME_INVALID", "Binary metadata is incomplete."))
    metadata_value = try
        JSON3.read(String(frame.payload[5:metadata_end]))
    catch
        throw(ServiceError("FRAME_INVALID", "Binary metadata is not valid JSON."))
    end
    metadata = _materialize_json(metadata_value)
    metadata isa Dict{String,Any} ||
        throw(ServiceError("FRAME_INVALID", "Binary metadata must be a JSON object."))
    data = frame.payload[(metadata_end + 1):end]
    return metadata, data
end

function _materialize_json(value)
    if value isa JSON3.Object
        return Dict{String,Any}(String(key) => _materialize_json(item) for (key, item) in pairs(value))
    elseif value isa JSON3.Array
        return Any[_materialize_json(item) for item in value]
    end
    return value
end
