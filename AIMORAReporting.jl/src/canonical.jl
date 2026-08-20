function _json_escape(value::AbstractString)
    io = IOBuffer()
    for character in value
        if character == '"'
            print(io, "\\\"")
        elseif character == '\\'
            print(io, "\\\\")
        elseif character == '\n'
            print(io, "\\n")
        elseif character == '\r'
            print(io, "\\r")
        elseif character == '\t'
            print(io, "\\t")
        elseif Int(character) < 0x20
            @printf(io, "\\u%04x", Int(character))
        else
            print(io, character)
        end
    end
    return String(take!(io))
end

function _canonical_number(value::Real)
    if value isa AbstractFloat
        isnan(value) && return "\"NaN\""
        value == Inf && return "\"Infinity\""
        value == -Inf && return "\"-Infinity\""
        value == 0 && signbit(value) && return "-0.0"
        return @sprintf("%.17g", value)
    end
    return string(value)
end

function canonical_json(value)
    if value === nothing || value === missing
        return "null"
    elseif value isa Bool
        return value ? "true" : "false"
    elseif value isa Real
        return _canonical_number(value)
    elseif value isa AbstractString
        return "\"" * _json_escape(value) * "\""
    elseif value isa Symbol || value isa VersionNumber || value isa UUID || value isa Date || value isa DateTime
        return canonical_json(string(value))
    elseif value isa Pair
        return "[" * canonical_json(first(value)) * "," * canonical_json(last(value)) * "]"
    elseif value isa NamedTuple
        return canonical_json(Dict(String(key) => getfield(value, key) for key in keys(value)))
    elseif value isa AbstractDict
        keys_sorted = sort!(String.(collect(keys(value))))
        entries = String[]
        for key in keys_sorted
            original_key = findfirst(candidate -> String(candidate) == key, collect(keys(value)))
            key_object = collect(keys(value))[original_key]
            push!(entries, canonical_json(key) * ":" * canonical_json(value[key_object]))
        end
        return "{" * join(entries, ",") * "}"
    elseif value isa AbstractVector || value isa Tuple || value isa Set
        values = value isa Set ? sort!(collect(value); by = string) : collect(value)
        return "[" * join(canonical_json.(values), ",") * "]"
    elseif isstructtype(typeof(value))
        data = Dict{String,Any}()
        for field in fieldnames(typeof(value))
            data[String(field)] = getfield(value, field)
        end
        data["__type__"] = String(nameof(typeof(value)))
        return canonical_json(data)
    else
        return canonical_json(string(value))
    end
end

hash_payload(value) = bytes2hex(sha256(codeunits(canonical_json(value))))

function report_semantic_data(report::ReportDocument)
    return Dict(
        "id" => report.id,
        "revision" => report.revision,
        "schema_version" => string(report.schema_version),
        "metadata" => report.metadata,
        "bindings" => report.bindings,
        "dependencies" => report.dependencies,
        "sections" => report.sections,
        "supersedes" => report.supersedes,
    )
end

content_hash(report::ReportDocument) = hash_payload(report_semantic_data(report))

function _artifact_hash(path::AbstractString)
    open(path, "r") do io
        return bytes2hex(sha256(io))
    end
end

_is_sha256(value::AbstractString) = occursin(r"^[0-9a-f]{64}$", lowercase(value))
