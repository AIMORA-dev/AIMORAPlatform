@enum LockFamily::UInt8 begin
    LockSchema = 0x01
    LockCatalog = 0x02
    LockPlugin = 0x03
    LockImport = 0x04
    LockAutomation = 0x05
end

@enum LockTrustClass::UInt8 begin
    LockDataOnly = 0x01
    LockTrustedProjectScript = 0x02
    LockTrustedPlugin = 0x03
    LockIsolatedUntrustedScript = 0x04
    LockSignedOrganizationExtension = 0x05
end

@enum LockFilesystemScope::UInt8 begin
    LockFilesystemNone = 0x01
    LockFilesystemReadOnly = 0x02
    LockFilesystemProjectOnly = 0x03
end

const _LOCK_FORMAT_VERSION = v"1.0.0"
const _LOCK_MEDIA_TYPE = "application/toml"
const _LOCK_FAMILY_NAMES = Dict(
    LockSchema => "schema",
    LockCatalog => "catalog",
    LockPlugin => "plugin",
    LockImport => "import",
    LockAutomation => "automation",
)
const _LOCK_FAMILIES = Dict(value => key for (key, value) in _LOCK_FAMILY_NAMES)
const _LOCK_TRUST_NAMES = Dict(
    LockDataOnly => "data_only",
    LockTrustedProjectScript => "trusted_project_script",
    LockTrustedPlugin => "trusted_plugin",
    LockIsolatedUntrustedScript => "isolated_untrusted_script",
    LockSignedOrganizationExtension => "signed_organization_extension",
)
const _LOCK_TRUST_CLASSES = Dict(value => key for (key, value) in _LOCK_TRUST_NAMES)
const _LOCK_FILESYSTEM_NAMES = Dict(
    LockFilesystemNone => "none",
    LockFilesystemReadOnly => "read_only",
    LockFilesystemProjectOnly => "project_only",
)
const _LOCK_FILESYSTEM_SCOPES = Dict(
    value => key for (key, value) in _LOCK_FILESYSTEM_NAMES
)

"""Bounded process-resource declaration retained as inert lock data."""
struct LockResourcePolicy
    network::Bool
    processes::Bool
    filesystem::LockFilesystemScope
    timeout_seconds::Int
    memory_megabytes::Int

    function LockResourcePolicy(;
        network::Bool = false,
        processes::Bool = false,
        filesystem::LockFilesystemScope = LockFilesystemNone,
        timeout_seconds::Integer = 0,
        memory_megabytes::Integer = 0,
    )
        timeout_seconds >= 0 || throw(ArgumentError("timeout must not be negative"))
        memory_megabytes >= 0 || throw(ArgumentError("memory limit must not be negative"))
        timeout_seconds <= typemax(Int) || throw(OverflowError("timeout exceeds Int"))
        memory_megabytes <= typemax(Int) || throw(OverflowError("memory limit exceeds Int"))
        return new(
            network,
            processes,
            filesystem,
            Int(timeout_seconds),
            Int(memory_megabytes),
        )
    end
end

Base.:(==)(left::LockResourcePolicy, right::LockResourcePolicy) =
    left.network == right.network &&
    left.processes == right.processes &&
    left.filesystem == right.filesystem &&
    left.timeout_seconds == right.timeout_seconds &&
    left.memory_megabytes == right.memory_megabytes

function _lock_portable_relative_path(path::String)
    isempty(path) && return false
    startswith(path, '/') && return false
    startswith(path, '\\') && return false
    occursin(r"^[A-Za-z]:", path) && return false
    occursin('\\', path) && return false
    any(segment -> segment in ("", ".", ".."), split(path, '/')) && return false
    return !occursin('\0', path)
end

function _lock_source_is_portable(source::String)
    isempty(source) && return false
    occursin('\0', source) && return false
    startswith(lowercase(source), "file:") && return false
    startswith(source, '/') && return false
    startswith(source, '~') && return false
    occursin(r"^[A-Za-z]:", source) && return false
    if occursin("://", source)
        authority_start = findfirst("://", source).stop + 1
        authority_stop = something(findnext('/', source, authority_start), lastindex(source) + 1)
        authority = SubString(source, authority_start, prevind(source, authority_stop))
        occursin('@', authority) && return false
        return true
    elseif occursin(r"^[a-z][a-z0-9+.-]*:", source)
        return true
    end
    return _lock_portable_relative_path(source)
end

function _lock_compatibility_is_exact(value::String)
    isempty(value) && return false
    lowered = lowercase(value)
    any(token -> occursin(token, lowered), ("*", "latest", "main", "master", "dev")) &&
        return false
    comparator = raw"(?:=|==|>=|<=|>|<|\^|~)[0-9]+\.[0-9]+\.[0-9]+"
    return occursin(Regex("^$(comparator)(?:,$(comparator))*\$"), value)
end

function _lock_entry_family_valid(
    family::LockFamily,
    uuid::Union{Nothing,UUID},
    trust::LockTrustClass,
    permissions::Vector{String},
    entrypoint::Union{Nothing,String},
    environment::Union{Nothing,String},
    resources::LockResourcePolicy,
)
    if family in (LockSchema, LockCatalog, LockImport)
        trust == LockDataOnly || return false
        isempty(permissions) || return false
        isnothing(entrypoint) || return false
        isnothing(environment) || return false
        return resources == LockResourcePolicy()
    elseif family == LockPlugin
        isnothing(uuid) && return false
        trust in (LockTrustedPlugin, LockSignedOrganizationExtension) || return false
        isnothing(entrypoint) && return false
        isnothing(environment) && return false
        return true
    end
    isnothing(uuid) && return false
    trust in (
        LockTrustedProjectScript,
        LockIsolatedUntrustedScript,
        LockSignedOrganizationExtension,
    ) || return false
    isempty(permissions) && return false
    isnothing(entrypoint) && return false
    isnothing(environment) && return false
    return true
end

"""One immutable, exact dependency entry in an admitted AIMORA lock family."""
struct FormatLockEntry
    family::LockFamily
    id::String
    uuid::Union{Nothing,UUID}
    version::VersionNumber
    revision::String
    sha256::String
    licence::String
    compatibility::String
    source::String
    trust::LockTrustClass
    permissions::FormatItemList{String}
    entrypoint::Union{Nothing,String}
    environment::Union{Nothing,String}
    resources::LockResourcePolicy
    provenance::String

    function FormatLockEntry(
        family::LockFamily,
        id::AbstractString,
        version::VersionNumber,
        revision::AbstractString,
        sha256::AbstractString,
        licence::AbstractString,
        compatibility::AbstractString,
        source::AbstractString,
        trust::LockTrustClass;
        uuid::Union{Nothing,UUID} = nothing,
        permissions::AbstractVector{<:AbstractString} = String[],
        entrypoint::Union{Nothing,AbstractString} = nothing,
        environment::Union{Nothing,AbstractString} = nothing,
        resources::LockResourcePolicy = LockResourcePolicy(),
        provenance::AbstractString,
    )
        normalized_id = String(id)
        occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", normalized_id) ||
            throw(ArgumentError("lock entry ID is not portable"))
        normalized_revision = String(revision)
        occursin(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$", normalized_revision) ||
            throw(ArgumentError("lock revision must be an exact lowercase hash"))
        normalized_sha256 = String(sha256)
        occursin(r"^[0-9a-f]{64}$", normalized_sha256) ||
            throw(ArgumentError("lock SHA-256 must contain 64 lowercase hexadecimal digits"))
        normalized_licence = String(licence)
        isempty(normalized_licence) && throw(ArgumentError("lock licence must not be empty"))
        occursin(r"[\r\n\0]", normalized_licence) &&
            throw(ArgumentError("lock licence contains a prohibited character"))
        normalized_compatibility = String(compatibility)
        _lock_compatibility_is_exact(normalized_compatibility) ||
            throw(ArgumentError("lock compatibility must be a bounded version expression"))
        normalized_source = String(source)
        _lock_source_is_portable(normalized_source) ||
            throw(ArgumentError("lock source is local, credential-bearing, or malformed"))
        normalized_permissions = sort!(unique!(String.(permissions)))
        all(permission -> occursin(r"^[a-z][a-z0-9_.-]*$", permission), normalized_permissions) ||
            throw(ArgumentError("lock permission is malformed"))
        normalized_entrypoint = isnothing(entrypoint) ? nothing : String(entrypoint)
        if !isnothing(normalized_entrypoint)
            occursin(
                r"^[A-Za-z][A-Za-z0-9_.]*:[A-Za-z][A-Za-z0-9_!]*$",
                normalized_entrypoint,
            ) || throw(ArgumentError("lock entrypoint is malformed"))
        end
        normalized_environment = isnothing(environment) ? nothing : String(environment)
        if !isnothing(normalized_environment)
            _lock_portable_relative_path(normalized_environment) ||
                throw(ArgumentError("lock environment path is not portable"))
        end
        normalized_provenance = String(provenance)
        isempty(normalized_provenance) &&
            throw(ArgumentError("lock provenance must not be empty"))
        occursin(r"[\r\n\0]", normalized_provenance) &&
            throw(ArgumentError("lock provenance contains a prohibited character"))
        _lock_source_is_portable(normalized_provenance) ||
            throw(ArgumentError("lock provenance contains a local path or credentials"))
        _lock_entry_family_valid(
            family,
            uuid,
            trust,
            normalized_permissions,
            normalized_entrypoint,
            normalized_environment,
            resources,
        ) || throw(ArgumentError("lock fields are inconsistent with their family"))
        return new(
            family,
            normalized_id,
            uuid,
            version,
            normalized_revision,
            normalized_sha256,
            normalized_licence,
            normalized_compatibility,
            normalized_source,
            trust,
            FormatItemList(normalized_permissions),
            normalized_entrypoint,
            normalized_environment,
            resources,
            normalized_provenance,
        )
    end
end

Base.:(==)(left::FormatLockEntry, right::FormatLockEntry) =
    left.family == right.family &&
    left.id == right.id &&
    left.uuid == right.uuid &&
    left.version == right.version &&
    left.revision == right.revision &&
    left.sha256 == right.sha256 &&
    left.licence == right.licence &&
    left.compatibility == right.compatibility &&
    left.source == right.source &&
    left.trust == right.trust &&
    left.permissions == right.permissions &&
    left.entrypoint == right.entrypoint &&
    left.environment == right.environment &&
    left.resources == right.resources &&
    left.provenance == right.provenance

"""A deterministic collection of exact dependencies for one admitted lock family."""
struct FormatLockDocument
    family::LockFamily
    format_version::VersionNumber
    entries::FormatItemList{FormatLockEntry}

    function FormatLockDocument(
        family::LockFamily,
        entries::AbstractVector{FormatLockEntry};
        format_version::VersionNumber = _LOCK_FORMAT_VERSION,
    )
        format_version == _LOCK_FORMAT_VERSION ||
            throw(ArgumentError("unsupported lock format version"))
        copied_entries = sort!(collect(entries); by = entry -> entry.id)
        all(entry -> entry.family == family, copied_entries) ||
            throw(ArgumentError("lock entry family differs from its document"))
        ids = getfield.(copied_entries, :id)
        length(ids) == length(unique(ids)) ||
            throw(ArgumentError("lock document contains duplicate IDs"))
        uuids = UUID[
            entry.uuid for entry in copied_entries if !isnothing(entry.uuid)
        ]
        length(uuids) == length(unique(uuids)) ||
            throw(ArgumentError("lock document contains duplicate UUIDs"))
        return new(family, format_version, FormatItemList(copied_entries))
    end
end

Base.:(==)(left::FormatLockDocument, right::FormatLockDocument) =
    left.family == right.family &&
    left.format_version == right.format_version &&
    left.entries == right.entries

"""A typed lock document paired with the exact TOML source from which it was parsed."""
struct ParsedFormatLock
    source::SourceDocument
    lock::FormatLockDocument
end

Base.:(==)(left::ParsedFormatLock, right::ParsedFormatLock) =
    left.source == right.source && left.lock == right.lock

"""Typed result returned by an admitted format-lock parser."""
const LockParseResult = FormatResult{ParsedFormatLock}

struct _TomlLockLocations
    root::SourceSpan
    entry_headers::Vector{SourceSpan}
    entry_keys::Vector{Dict{String,SourceSpan}}
    root_keys::Dict{String,SourceSpan}
end

function _toml_policy_diagnostics(
    root,
    policy::FormatInputPolicy,
    span::SourceSpan,
)
    stack = Tuple{Any,Int}[(root, 1)]
    collection_items = 0
    while !isempty(stack)
        value, depth = pop!(stack)
        if depth > policy.max_nesting_depth
            return [FormatDiagnostic(
                DiagnosticError,
                :nesting_too_deep,
                "TOML value exceeds the configured nesting depth",
                span,
            )]
        elseif value isa AbstractDict
            collection_items += length(value)
            for (key, child) in value
                ncodeunits(String(key)) <= policy.max_scalar_bytes ||
                    return [FormatDiagnostic(
                        DiagnosticError,
                        :scalar_too_large,
                        "TOML key exceeds the configured scalar byte limit",
                        span,
                    )]
                push!(stack, (child, depth + 1))
            end
        elseif value isa AbstractVector
            collection_items += length(value)
            for child in value
                push!(stack, (child, depth + 1))
            end
        elseif value isa AbstractString
            ncodeunits(value) <= policy.max_scalar_bytes ||
                return [FormatDiagnostic(
                    DiagnosticError,
                    :scalar_too_large,
                    "TOML string exceeds the configured scalar byte limit",
                    span,
                )]
        end
        if collection_items > policy.max_collection_items
            return [FormatDiagnostic(
                DiagnosticError,
                :collection_too_large,
                "TOML value exceeds the configured collection item limit",
                span,
            )]
        end
    end
    return FormatDiagnostic[]
end

function _toml_line_stop(document::SourceDocument, line_index::Int)
    start_byte = document.line_starts[line_index]
    if line_index < length(document.line_starts)
        stop_byte = document.line_starts[line_index + 1]
        while stop_byte > start_byte &&
              codeunit(document.text, prevind(document.text, stop_byte)) in (0x0a, 0x0d)
            stop_byte = prevind(document.text, stop_byte)
        end
        return stop_byte
    end
    return ncodeunits(document.text) + 1
end

function _toml_locations(document::SourceDocument)
    root = source_span(document, 1, ncodeunits(document.text) + 1)
    headers = SourceSpan[]
    entry_keys = Dict{String,SourceSpan}[]
    root_keys = Dict{String,SourceSpan}()
    active_entry = 0
    for line_index in eachindex(document.line_starts)
        first_byte = document.line_starts[line_index]
        stop_byte = _toml_line_stop(document, line_index)
        line = first_byte < stop_byte ? String(SubString(
            document.text,
            first_byte,
            prevind(document.text, stop_byte),
        )) : ""
        header_match = match(r"^\s*\[\[entry\]\]", line)
        if !isnothing(header_match)
            offset_range = findfirst("[[entry]]", line)
            offset = isnothing(offset_range) ? firstindex(line) : first(offset_range)
            header_byte = first_byte + ncodeunits(SubString(line, 1, prevind(line, offset)))
            push!(headers, source_span(document, header_byte, header_byte + 9))
            push!(entry_keys, Dict{String,SourceSpan}())
            active_entry = length(headers)
            continue
        end
        key_match = match(r"^\s*([A-Za-z][A-Za-z0-9_-]*)\s*=", line)
        isnothing(key_match) && continue
        key = key_match.captures[1]
        key_range = findfirst(key, line)
        isnothing(key_range) && continue
        prefix = first(key_range) == firstindex(line) ? 0 :
            ncodeunits(SubString(line, firstindex(line), prevind(line, first(key_range))))
        key_byte = first_byte + prefix
        span = source_span(document, key_byte, key_byte + ncodeunits(key))
        if active_entry == 0
            root_keys[key] = span
        else
            entry_keys[active_entry][key] = span
        end
    end
    return _TomlLockLocations(root, headers, entry_keys, root_keys)
end

function _toml_position_byte(document::SourceDocument, line::Int, column::Int)
    1 <= line <= length(document.line_starts) || return 1
    byte = document.line_starts[line]
    for _ in 2:column
        byte > ncodeunits(document.text) && break
        next_byte = nextind(document.text, byte)
        next_byte > _toml_line_stop(document, line) && break
        byte = next_byte
    end
    return byte
end

function _toml_syntax_diagnostic(document::SourceDocument, error)
    byte = _toml_position_byte(document, error.line, error.column)
    span = source_span(document, byte, byte)
    return FormatDiagnostic(
        DiagnosticError,
        :invalid_lock_toml,
        "lock TOML syntax is invalid: $(sprint(showerror, error))",
        span,
    )
end

function _lock_diagnostic(
    code::Symbol,
    message::String,
    span::SourceSpan,
)
    return FormatDiagnostic(DiagnosticError, code, message, span)
end

function _lock_span(
    locations::_TomlLockLocations,
    entry_index::Int,
    key::String,
)
    if entry_index == 0
        return get(locations.root_keys, key, locations.root)
    end
    entry_index <= length(locations.entry_keys) || return locations.root
    return get(
        locations.entry_keys[entry_index],
        key,
        locations.entry_headers[entry_index],
    )
end

function _lock_expect_keys(
    table::AbstractDict,
    allowed::Set{String},
    locations::_TomlLockLocations,
    entry_index::Int,
)
    diagnostics = FormatDiagnostic[]
    for key in sort!(String.(collect(keys(table))))
        key in allowed && continue
        push!(
            diagnostics,
            _lock_diagnostic(
                :unknown_lock_field,
                "lock contains unknown field '$(key)'",
                _lock_span(locations, entry_index, key),
            ),
        )
    end
    return diagnostics
end

function _lock_required(
    table::AbstractDict,
    key::String,
    expected_type::Type,
    locations::_TomlLockLocations,
    entry_index::Int,
    diagnostics::Vector{FormatDiagnostic},
)
    if !haskey(table, key)
        push!(
            diagnostics,
            _lock_diagnostic(
                :missing_lock_field,
                "lock is missing required field '$(key)'",
                _lock_span(locations, entry_index, key),
            ),
        )
        return nothing
    end
    value = table[key]
    if !(value isa expected_type)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_field_type,
                "lock field '$(key)' has the wrong type",
                _lock_span(locations, entry_index, key),
            ),
        )
        return nothing
    end
    return value
end

function _lock_optional_string(
    table::AbstractDict,
    key::String,
    locations::_TomlLockLocations,
    entry_index::Int,
    diagnostics::Vector{FormatDiagnostic},
)
    !haskey(table, key) && return nothing
    value = table[key]
    if !(value isa String)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_field_type,
                "lock field '$(key)' has the wrong type",
                _lock_span(locations, entry_index, key),
            ),
        )
        return nothing
    end
    return value
end

function _lock_parse_version(
    value,
    key::String,
    locations::_TomlLockLocations,
    entry_index::Int,
    diagnostics::Vector{FormatDiagnostic},
)
    value isa String || return nothing
    try
        return VersionNumber(value)
    catch
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_version,
                "lock field '$(key)' is not a semantic version",
                _lock_span(locations, entry_index, key),
            ),
        )
        return nothing
    end
end

function _lock_parse_resource_policy(
    raw,
    locations::_TomlLockLocations,
    entry_index::Int,
    diagnostics::Vector{FormatDiagnostic},
)
    isnothing(raw) && return LockResourcePolicy()
    if !(raw isa AbstractDict)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_field_type,
                "lock resources must be a table",
                _lock_span(locations, entry_index, "resources"),
            ),
        )
        return nothing
    end
    allowed = Set(["network", "processes", "filesystem", "timeout_seconds", "memory_megabytes"])
    append!(diagnostics, _lock_expect_keys(raw, allowed, locations, entry_index))
    network = _lock_required(raw, "network", Bool, locations, entry_index, diagnostics)
    processes = _lock_required(raw, "processes", Bool, locations, entry_index, diagnostics)
    filesystem_text = _lock_required(raw, "filesystem", String, locations, entry_index, diagnostics)
    timeout = _lock_required(raw, "timeout_seconds", Integer, locations, entry_index, diagnostics)
    memory = _lock_required(raw, "memory_megabytes", Integer, locations, entry_index, diagnostics)
    any(isnothing, (network, processes, filesystem_text, timeout, memory)) && return nothing
    filesystem = get(_LOCK_FILESYSTEM_SCOPES, filesystem_text, nothing)
    if isnothing(filesystem)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_filesystem_scope,
                "lock filesystem scope is unknown",
                _lock_span(locations, entry_index, "filesystem"),
            ),
        )
        return nothing
    end
    try
        return LockResourcePolicy(;
            network,
            processes,
            filesystem,
            timeout_seconds = timeout,
            memory_megabytes = memory,
        )
    catch error
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_resource_limit,
                sprint(showerror, error),
                _lock_span(locations, entry_index, "resources"),
            ),
        )
        return nothing
    end
end

function _lock_parse_entry(
    raw::AbstractDict,
    family::LockFamily,
    locations::_TomlLockLocations,
    entry_index::Int,
    diagnostics::Vector{FormatDiagnostic},
)
    allowed = Set([
        "id", "uuid", "version", "revision", "sha256", "licence",
        "compatibility", "source", "trust", "permissions", "entrypoint",
        "environment", "resources", "provenance",
    ])
    append!(diagnostics, _lock_expect_keys(raw, allowed, locations, entry_index))
    id = _lock_required(raw, "id", String, locations, entry_index, diagnostics)
    version_text = _lock_required(raw, "version", String, locations, entry_index, diagnostics)
    revision = _lock_required(raw, "revision", String, locations, entry_index, diagnostics)
    sha256 = _lock_required(raw, "sha256", String, locations, entry_index, diagnostics)
    licence = _lock_required(raw, "licence", String, locations, entry_index, diagnostics)
    compatibility = _lock_required(
        raw,
        "compatibility",
        String,
        locations,
        entry_index,
        diagnostics,
    )
    source = _lock_required(raw, "source", String, locations, entry_index, diagnostics)
    trust_text = _lock_required(raw, "trust", String, locations, entry_index, diagnostics)
    provenance = _lock_required(raw, "provenance", String, locations, entry_index, diagnostics)
    uuid_text = _lock_optional_string(raw, "uuid", locations, entry_index, diagnostics)
    entrypoint = _lock_optional_string(raw, "entrypoint", locations, entry_index, diagnostics)
    environment = _lock_optional_string(raw, "environment", locations, entry_index, diagnostics)
    permissions_raw = get(raw, "permissions", Any[])
    permissions = String[]
    if !(permissions_raw isa AbstractVector) ||
       !all(permission -> permission isa String, permissions_raw)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_permissions,
                "lock permissions must be an array of strings",
                _lock_span(locations, entry_index, "permissions"),
            ),
        )
    else
        permissions = String[String(permission) for permission in permissions_raw]
    end
    version = _lock_parse_version(
        version_text,
        "version",
        locations,
        entry_index,
        diagnostics,
    )
    parsed_uuid = nothing
    if !isnothing(uuid_text)
        try
            parsed_uuid = UUID(uuid_text)
        catch
            push!(
                diagnostics,
                _lock_diagnostic(
                    :invalid_lock_uuid,
                    "lock UUID is malformed",
                    _lock_span(locations, entry_index, "uuid"),
                ),
            )
        end
    end
    trust = isnothing(trust_text) ? nothing : get(_LOCK_TRUST_CLASSES, trust_text, nothing)
    if !isnothing(trust_text) && isnothing(trust)
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_trust_class,
                "lock trust class is unknown",
                _lock_span(locations, entry_index, "trust"),
            ),
        )
    end
    resources = _lock_parse_resource_policy(
        get(raw, "resources", nothing),
        locations,
        entry_index,
        diagnostics,
    )
    required = (
        id,
        version,
        revision,
        sha256,
        licence,
        compatibility,
        source,
        trust,
        provenance,
        resources,
    )
    any(isnothing, required) && return nothing
    try
        return FormatLockEntry(
            family,
            id,
            version,
            revision,
            sha256,
            licence,
            compatibility,
            source,
            trust;
            uuid = parsed_uuid,
            permissions,
            entrypoint,
            environment,
            resources,
            provenance,
        )
    catch error
        message = sprint(showerror, error)
        error_key = if occursin("revision", message)
            "revision"
        elseif occursin("SHA-256", message)
            "sha256"
        elseif occursin("licence", message)
            "licence"
        elseif occursin("compatibility", message)
            "compatibility"
        elseif occursin("source", message)
            "source"
        elseif occursin("permission", message)
            "permissions"
        elseif occursin("entrypoint", message)
            "entrypoint"
        elseif occursin("environment", message)
            "environment"
        elseif occursin("family", message)
            "trust"
        else
            "id"
        end
        push!(
            diagnostics,
            _lock_diagnostic(
                :invalid_lock_entry,
                message,
                _lock_span(locations, entry_index, error_key),
            ),
        )
        return nothing
    end
end

function _parse_format_lock(source::SourceDocument, policy::FormatInputPolicy)
    parsed = TOML.tryparse(source.text)
    parsed isa Exception &&
        return LockParseResult(nothing, [_toml_syntax_diagnostic(source, parsed)])
    locations = _toml_locations(source)
    limit_diagnostics = _toml_policy_diagnostics(parsed, policy, locations.root)
    isempty(limit_diagnostics) || return LockParseResult(nothing, limit_diagnostics)
    diagnostics = _lock_expect_keys(
        parsed,
        Set(["format", "family", "version", "entry"]),
        locations,
        0,
    )
    format = _lock_required(parsed, "format", String, locations, 0, diagnostics)
    family_text = _lock_required(parsed, "family", String, locations, 0, diagnostics)
    version_text = _lock_required(parsed, "version", String, locations, 0, diagnostics)
    entries_raw = _lock_required(parsed, "entry", AbstractVector, locations, 0, diagnostics)
    if !isnothing(format) && format != "aimora-lock-v1"
        push!(
            diagnostics,
            _lock_diagnostic(
                :unknown_lock_format,
                "lock format identifier is unsupported",
                _lock_span(locations, 0, "format"),
            ),
        )
    end
    family = isnothing(family_text) ? nothing : get(_LOCK_FAMILIES, family_text, nothing)
    if !isnothing(family_text) && isnothing(family)
        push!(
            diagnostics,
            _lock_diagnostic(
                :unknown_lock_family,
                "lock family is unsupported",
                _lock_span(locations, 0, "family"),
            ),
        )
    end
    version = _lock_parse_version(version_text, "version", locations, 0, diagnostics)
    if !isnothing(version) && version != _LOCK_FORMAT_VERSION
        push!(
            diagnostics,
            _lock_diagnostic(
                :unknown_lock_version,
                "lock version is unsupported",
                _lock_span(locations, 0, "version"),
            ),
        )
    end
    entries = FormatLockEntry[]
    seen_ids = Set{String}()
    seen_uuids = Set{UUID}()
    if !isnothing(entries_raw) && !isnothing(family)
        for (index, raw) in enumerate(entries_raw)
            if !(raw isa AbstractDict)
                push!(
                    diagnostics,
                    _lock_diagnostic(
                        :invalid_lock_entry,
                        "lock entry must be a table",
                        _lock_span(locations, index, "id"),
                    ),
                )
                continue
            end
            entry = _lock_parse_entry(raw, family, locations, index, diagnostics)
            isnothing(entry) && continue
            if entry.id in seen_ids
                push!(
                    diagnostics,
                    _lock_diagnostic(
                        :duplicate_lock_id,
                        "lock contains duplicate ID '$(entry.id)'",
                        _lock_span(locations, index, "id"),
                    ),
                )
                continue
            end
            if !isnothing(entry.uuid) && entry.uuid in seen_uuids
                push!(
                    diagnostics,
                    _lock_diagnostic(
                        :duplicate_lock_uuid,
                        "lock contains duplicate UUID '$(entry.uuid)'",
                        _lock_span(locations, index, "uuid"),
                    ),
                )
                continue
            end
            push!(seen_ids, entry.id)
            isnothing(entry.uuid) || push!(seen_uuids, entry.uuid)
            push!(entries, entry)
        end
    end
    any(diagnostic -> diagnostic.severity == DiagnosticError, diagnostics) &&
        return LockParseResult(nothing, diagnostics)
    try
        lock = FormatLockDocument(family, entries; format_version = version)
        return LockParseResult(ParsedFormatLock(source, lock))
    catch error
        diagnostic = _lock_diagnostic(
            :conflicting_lock_entries,
            sprint(showerror, error),
            locations.root,
        )
        return LockParseResult(nothing, [diagnostic])
    end
end

"""Parse one bounded AIMORA schema, catalog, plugin, import, or automation lock."""
function parse_format_lock(
    source::SourceDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_document_bytes || begin
        diagnostic = _lock_diagnostic(
            :document_too_large,
            "lock document exceeds the configured byte limit",
            source_span(source, 1, 1),
        )
        return LockParseResult(nothing, [diagnostic])
    end
    return _parse_format_lock(source, policy)
end

function parse_format_lock(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return LockParseResult(nothing, collect(admitted.diagnostics))
    return parse_format_lock(admitted.value; policy)
end

parse_format_lock(
    text::AbstractString;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_format_lock(Vector{UInt8}(codeunits(text)); source_name, policy)

function _toml_emit_string(io::IO, value::String)
    print(io, '"')
    for character in value
        codepoint = Int(character)
        if character == '"'
            print(io, "\\\"")
        elseif character == '\\'
            print(io, "\\\\")
        elseif character == '\b'
            print(io, "\\b")
        elseif character == '\t'
            print(io, "\\t")
        elseif character == '\n'
            print(io, "\\n")
        elseif character == '\f'
            print(io, "\\f")
        elseif character == '\r'
            print(io, "\\r")
        elseif codepoint < 0x20
            print(io, "\\u", lpad(string(codepoint; base = 16), 4, '0'))
        else
            print(io, character)
        end
    end
    print(io, '"')
end

function _toml_emit_assignment(io::IO, key::String, value::String)
    print(io, key, " = ")
    _toml_emit_string(io, value)
    print(io, '\n')
end

function _toml_emit_string_array(io::IO, key::String, values::FormatItemList{String})
    print(io, key, " = [")
    for (index, value) in enumerate(values)
        index > 1 && print(io, ", ")
        _toml_emit_string(io, value)
    end
    print(io, "]\n")
end

"""Serialize an AIMORA lock in stable family, entry, field, and permission order."""
function serialize_format_lock(
    lock::FormatLockDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    output = IOBuffer()
    _toml_emit_assignment(output, "format", "aimora-lock-v1")
    _toml_emit_assignment(output, "family", _LOCK_FAMILY_NAMES[lock.family])
    _toml_emit_assignment(output, "version", string(lock.format_version))
    for entry in lock.entries
        print(output, "\n[[entry]]\n")
        _toml_emit_assignment(output, "id", entry.id)
        isnothing(entry.uuid) || _toml_emit_assignment(output, "uuid", string(entry.uuid))
        _toml_emit_assignment(output, "version", string(entry.version))
        _toml_emit_assignment(output, "revision", entry.revision)
        _toml_emit_assignment(output, "sha256", entry.sha256)
        _toml_emit_assignment(output, "licence", entry.licence)
        _toml_emit_assignment(output, "compatibility", entry.compatibility)
        _toml_emit_assignment(output, "source", entry.source)
        _toml_emit_assignment(output, "trust", _LOCK_TRUST_NAMES[entry.trust])
        _toml_emit_string_array(output, "permissions", entry.permissions)
        isnothing(entry.entrypoint) ||
            _toml_emit_assignment(output, "entrypoint", entry.entrypoint)
        isnothing(entry.environment) ||
            _toml_emit_assignment(output, "environment", entry.environment)
        _toml_emit_assignment(output, "provenance", entry.provenance)
        print(output, "\n[entry.resources]\n")
        print(output, "network = ", entry.resources.network, '\n')
        print(output, "processes = ", entry.resources.processes, '\n')
        _toml_emit_assignment(
            output,
            "filesystem",
            _LOCK_FILESYSTEM_NAMES[entry.resources.filesystem],
        )
        print(output, "timeout_seconds = ", entry.resources.timeout_seconds, '\n')
        print(output, "memory_megabytes = ", entry.resources.memory_megabytes, '\n')
    end
    bytes = take!(output)
    if length(bytes) > policy.max_document_bytes
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "serialized lock exceeds the configured byte limit",
        )
        return FormatSerializationResult(nothing, [diagnostic])
    end
    return FormatSerializationResult(SerializedFormatDocument(bytes, _LOCK_MEDIA_TYPE))
end

serialize_format_lock(
    parsed::ParsedFormatLock;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = serialize_format_lock(parsed.lock; policy)

"""One direct Julia dependency identity retained without loading its package."""
struct JuliaEnvironmentDependency
    name::String
    uuid::UUID
    version::Union{Nothing,VersionNumber}
    git_tree_sha1::Union{Nothing,String}

    function JuliaEnvironmentDependency(
        name::AbstractString,
        uuid::UUID;
        version::Union{Nothing,VersionNumber} = nothing,
        git_tree_sha1::Union{Nothing,AbstractString} = nothing,
    )
        normalized_name = String(name)
        occursin(r"^[A-Za-z][A-Za-z0-9_]*$", normalized_name) ||
            throw(ArgumentError("Julia dependency name is malformed"))
        normalized_tree = isnothing(git_tree_sha1) ? nothing : String(git_tree_sha1)
        if !isnothing(normalized_tree)
            occursin(r"^[0-9a-f]{40}$", normalized_tree) ||
                throw(ArgumentError("Julia git-tree-sha1 is malformed"))
        end
        return new(normalized_name, uuid, version, normalized_tree)
    end
end

Base.:(==)(left::JuliaEnvironmentDependency, right::JuliaEnvironmentDependency) =
    left.name == right.name &&
    left.uuid == right.uuid &&
    left.version == right.version &&
    left.git_tree_sha1 == right.git_tree_sha1

"""Hashes and version metadata inspected from inert Julia project and manifest text."""
struct JuliaEnvironmentFingerprint
    project_sha256::String
    manifest_sha256::Union{Nothing,String}
    project_uuid::Union{Nothing,UUID}
    project_version::Union{Nothing,VersionNumber}
    julia_version::Union{Nothing,VersionNumber}
    manifest_format::Union{Nothing,String}
    dependencies::FormatItemList{JuliaEnvironmentDependency}
end

Base.:(==)(left::JuliaEnvironmentFingerprint, right::JuliaEnvironmentFingerprint) =
    left.project_sha256 == right.project_sha256 &&
    left.manifest_sha256 == right.manifest_sha256 &&
    left.project_uuid == right.project_uuid &&
    left.project_version == right.project_version &&
    left.julia_version == right.julia_version &&
    left.manifest_format == right.manifest_format &&
    left.dependencies == right.dependencies

function _environment_toml(
    source::SourceDocument,
    diagnostic_code::Symbol,
    policy::FormatInputPolicy,
)
    parsed = TOML.tryparse(source.text)
    if parsed isa Exception
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            diagnostic_code,
            "Julia environment TOML is invalid: $(sprint(showerror, parsed))",
            _toml_syntax_diagnostic(source, parsed).span,
        )
        return (nothing, [diagnostic])
    end
    diagnostics = _toml_policy_diagnostics(
        parsed,
        policy,
        source_span(source, 1, ncodeunits(source.text) + 1),
    )
    isempty(diagnostics) || return (nothing, diagnostics)
    return (parsed, diagnostics)
end

function _environment_uuid(value, diagnostics, source, code, message)
    isnothing(value) && return nothing
    if !(value isa String)
        push!(
            diagnostics,
            FormatDiagnostic(DiagnosticError, code, message, source_span(source, 1, 1)),
        )
        return nothing
    end
    try
        return UUID(value)
    catch
        push!(
            diagnostics,
            FormatDiagnostic(DiagnosticError, code, message, source_span(source, 1, 1)),
        )
        return nothing
    end
end

function _environment_version(value, diagnostics, source, code, message)
    isnothing(value) && return nothing
    if !(value isa String)
        push!(
            diagnostics,
            FormatDiagnostic(DiagnosticError, code, message, source_span(source, 1, 1)),
        )
        return nothing
    end
    try
        return VersionNumber(value)
    catch
        push!(
            diagnostics,
            FormatDiagnostic(DiagnosticError, code, message, source_span(source, 1, 1)),
        )
        return nothing
    end
end

function _manifest_dependency_table(manifest, name::String, uuid::UUID)
    dependencies = get(manifest, "deps", Dict{String,Any}())
    dependencies isa AbstractDict || return nothing
    candidates = get(dependencies, name, Any[])
    candidates isa AbstractVector || (candidates = Any[candidates])
    matches = [
        candidate for candidate in candidates
        if candidate isa AbstractDict && get(candidate, "uuid", nothing) == string(uuid)
    ]
    return length(matches) == 1 ? only(matches) : nothing
end

"""Inspect inert Julia `Project.toml` and optional `Manifest.toml` text."""
function inspect_julia_environment(
    project_source::SourceDocument,
    manifest_source::Union{Nothing,SourceDocument} = nothing,
    ;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    project, diagnostics = _environment_toml(
        project_source,
        :invalid_julia_project_toml,
        policy,
    )
    isnothing(project) && return FormatResult{JuliaEnvironmentFingerprint}(nothing, diagnostics)
    manifest = nothing
    if !isnothing(manifest_source)
        manifest, manifest_diagnostics = _environment_toml(
            manifest_source,
            :invalid_julia_manifest_toml,
            policy,
        )
        append!(diagnostics, manifest_diagnostics)
    end
    any(diagnostic -> diagnostic.severity == DiagnosticError, diagnostics) &&
        return FormatResult{JuliaEnvironmentFingerprint}(nothing, diagnostics)
    project_uuid = _environment_uuid(
        get(project, "uuid", nothing),
        diagnostics,
        project_source,
        :invalid_julia_project_uuid,
        "Julia project UUID is malformed",
    )
    project_version = _environment_version(
        get(project, "version", nothing),
        diagnostics,
        project_source,
        :invalid_julia_project_version,
        "Julia project version is malformed",
    )
    julia_version = isnothing(manifest) ? nothing : _environment_version(
        get(manifest, "julia_version", nothing),
        diagnostics,
        manifest_source,
        :invalid_julia_manifest_version,
        "Julia manifest version metadata is malformed",
    )
    manifest_format = isnothing(manifest) ? nothing : get(manifest, "manifest_format", nothing)
    if !isnothing(manifest_format) && !(manifest_format isa String)
        push!(diagnostics, FormatDiagnostic(
            DiagnosticError,
            :invalid_julia_manifest_format,
            "Julia manifest format metadata must be a string",
            source_span(manifest_source, 1, 1),
        ))
        manifest_format = nothing
    end
    direct = get(project, "deps", Dict{String,Any}())
    if !(direct isa AbstractDict)
        push!(diagnostics, FormatDiagnostic(
            DiagnosticError,
            :invalid_julia_project_dependencies,
            "Julia project dependencies must be a table",
            source_span(project_source, 1, 1),
        ))
        direct = Dict{String,Any}()
    end
    dependencies = JuliaEnvironmentDependency[]
    for name in sort!(String.(collect(keys(direct))))
        uuid = _environment_uuid(
            direct[name],
            diagnostics,
            project_source,
            :invalid_julia_dependency_uuid,
            "Julia dependency UUID is malformed for $(name)",
        )
        isnothing(uuid) && continue
        version = nothing
        tree = nothing
        if !isnothing(manifest)
            table = _manifest_dependency_table(manifest, name, uuid)
            if isnothing(table)
                push!(diagnostics, FormatDiagnostic(
                    DiagnosticError,
                    :julia_manifest_dependency_missing,
                    "Julia manifest has no unique entry for direct dependency $(name)",
                    source_span(project_source, 1, 1),
                ))
                continue
            end
            if haskey(table, "path")
                push!(diagnostics, FormatDiagnostic(
                    DiagnosticError,
                    :local_julia_dependency_prohibited,
                    "Julia manifest dependency $(name) uses a local path",
                    source_span(manifest_source, 1, 1),
                ))
                continue
            end
            version = _environment_version(
                get(table, "version", nothing),
                diagnostics,
                manifest_source,
                :invalid_julia_dependency_version,
                "Julia dependency version is malformed for $(name)",
            )
            raw_tree = get(table, "git-tree-sha1", nothing)
            if !isnothing(raw_tree)
                if raw_tree isa String && occursin(r"^[0-9a-f]{40}$", raw_tree)
                    tree = raw_tree
                else
                    push!(diagnostics, FormatDiagnostic(
                        DiagnosticError,
                        :invalid_julia_dependency_tree_hash,
                        "Julia dependency git-tree-sha1 is malformed for $(name)",
                        source_span(manifest_source, 1, 1),
                    ))
                end
            elseif haskey(table, "repo-url") || haskey(table, "repo-rev")
                push!(diagnostics, FormatDiagnostic(
                    DiagnosticError,
                    :floating_julia_dependency,
                    "Julia repository dependency $(name) lacks an exact tree hash",
                    source_span(manifest_source, 1, 1),
                ))
            end
        end
        push!(dependencies, JuliaEnvironmentDependency(name, uuid; version, git_tree_sha1 = tree))
    end
    any(diagnostic -> diagnostic.severity == DiagnosticError, diagnostics) &&
        return FormatResult{JuliaEnvironmentFingerprint}(nothing, diagnostics)
    fingerprint = JuliaEnvironmentFingerprint(
        project_source.provenance.content_sha256,
        isnothing(manifest_source) ? nothing : manifest_source.provenance.content_sha256,
        project_uuid,
        project_version,
        julia_version,
        manifest_format,
        FormatItemList(dependencies),
    )
    return FormatResult(fingerprint)
end

function inspect_julia_environment(
    project_text::AbstractString,
    manifest_text::Union{Nothing,AbstractString} = nothing;
    project_source_name::AbstractString = "Project.toml",
    manifest_source_name::AbstractString = "Manifest.toml",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    project_result = source_document(project_text; source_name = project_source_name, policy)
    format_succeeded(project_result) ||
        return FormatResult{JuliaEnvironmentFingerprint}(
            nothing,
            collect(project_result.diagnostics),
        )
    manifest_source = nothing
    if !isnothing(manifest_text)
        manifest_result = source_document(
            manifest_text;
            source_name = manifest_source_name,
            policy,
        )
        format_succeeded(manifest_result) ||
            return FormatResult{JuliaEnvironmentFingerprint}(
                nothing,
                collect(manifest_result.diagnostics),
            )
        manifest_source = manifest_result.value
    end
    return inspect_julia_environment(project_result.value, manifest_source; policy)
end
