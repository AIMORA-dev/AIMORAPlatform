export NativeDrawingCacheReference,
    NativeDrawingDocument,
    NativeDrawingMigrationReport,
    NativeDrawingRead,
    NativeDrawingReadResult,
    NativeSymbolReference,
    native_drawing_payload,
    native_drawing_sha256,
    parse_native_drawing,
    serialize_native_drawing

const _NATIVE_DRAWING_FORMAT = "aimora-drawing"
const _NATIVE_DRAWING_VERSION = v"2.0.0"
const _NATIVE_DRAWING_PREVIOUS_VERSION = v"1.0.0"
const _NATIVE_DRAWING_IDENTIFIER = r"^[A-Za-z][A-Za-z0-9_.:-]{0,127}$"
const _NATIVE_DRAWING_HASH = r"^[0-9a-f]{64}$"
const _NATIVE_DRAWING_SPAN = SourceSpan(
    "<generated-drawing>",
    SourcePosition(1, 1, 1),
    SourcePosition(1, 1, 1),
)

function _native_drawing_node(value, span::SourceSpan = _NATIVE_DRAWING_SPAN)
    value isa FormatNode && return value
    value isa FormatValue && return FormatNode(value, span)
    isnothing(value) && return FormatNode(FormatNull(), span)
    value isa Bool && return FormatNode(FormatBoolean(value), span)
    value isa Integer && return FormatNode(FormatInteger(value), span)
    value isa AbstractString && return FormatNode(FormatString(value), span)
    if value isa AbstractVector
        return FormatNode(FormatSequence(FormatNode[_native_drawing_node(item, span) for item in value]), span)
    end
    if value isa AbstractDict
        entries = FormatMappingEntry[]
        for key in sort!(String.(collect(keys(value))))
            push!(entries, FormatMappingEntry(
                FormatNode(FormatString(key), span),
                _native_drawing_node(value[key], span),
            ))
        end
        return FormatNode(FormatMapping(entries), span)
    end
    throw(ArgumentError("drawing payload contains unsupported value $(typeof(value))"))
end

function _native_drawing_identifier(value::AbstractString, role::AbstractString)
    text = String(value)
    occursin(_NATIVE_DRAWING_IDENTIFIER, text) ||
        throw(ArgumentError("$(role) is not a portable identifier"))
    return text
end

function _native_drawing_hash(value::AbstractString, role::AbstractString)
    text = lowercase(String(value))
    occursin(_NATIVE_DRAWING_HASH, text) ||
        throw(ArgumentError("$(role) must be a lowercase SHA-256 digest"))
    return text
end

function _native_drawing_relative_path(value::AbstractString)
    path = String(value)
    isempty(path) && throw(ArgumentError("cache path cannot be empty"))
    ncodeunits(path) <= 512 || throw(ArgumentError("cache path exceeds 512 bytes"))
    occursin('\\', path) && throw(ArgumentError("cache paths must use portable '/' separators"))
    startswith(path, '/') && throw(ArgumentError("cache path cannot be absolute"))
    occursin(r"^[A-Za-z]:", path) && throw(ArgumentError("cache path cannot contain a drive root"))
    segments = split(path, '/'; keepempty = true)
    any(segment -> isempty(segment) || segment in (".", ".."), segments) &&
        throw(ArgumentError("cache path contains an empty or traversal segment"))
    return path
end

struct NativeSymbolReference
    owner_id::String
    symbol_id::String
    library_id::String
    content_sha256::String
    state::String
    level_of_detail::String

    function NativeSymbolReference(
        owner_id::AbstractString,
        symbol_id::AbstractString,
        library_id::AbstractString,
        content_sha256::AbstractString;
        state::AbstractString = "normal",
        level_of_detail::AbstractString = "detail",
    )
        return new(
            _native_drawing_identifier(owner_id, "symbol owner"),
            _native_drawing_identifier(symbol_id, "symbol id"),
            _native_drawing_identifier(library_id, "symbol library"),
            _native_drawing_hash(content_sha256, "symbol content hash"),
            _native_drawing_identifier(state, "symbol state"),
            _native_drawing_identifier(level_of_detail, "symbol level of detail"),
        )
    end
end

Base.:(==)(left::NativeSymbolReference, right::NativeSymbolReference) =
    left.owner_id == right.owner_id &&
    left.symbol_id == right.symbol_id &&
    left.library_id == right.library_id &&
    left.content_sha256 == right.content_sha256 &&
    left.state == right.state &&
    left.level_of_detail == right.level_of_detail

struct NativeDrawingCacheReference
    path::String
    content_sha256::String

    function NativeDrawingCacheReference(path::AbstractString, content_sha256::AbstractString)
        return new(
            _native_drawing_relative_path(path),
            _native_drawing_hash(content_sha256, "cache content hash"),
        )
    end
end

Base.:(==)(left::NativeDrawingCacheReference, right::NativeDrawingCacheReference) =
    left.path == right.path && left.content_sha256 == right.content_sha256

struct NativeDrawingDocument
    schema_version::VersionNumber
    project_id::String
    drawing::FormatNode
    symbols::FormatItemList{NativeSymbolReference}
    caches::FormatItemList{NativeDrawingCacheReference}

    function NativeDrawingDocument(
        project_id::AbstractString,
        drawing,
        symbols::AbstractVector{NativeSymbolReference} = NativeSymbolReference[],
        caches::AbstractVector{NativeDrawingCacheReference} = NativeDrawingCacheReference[];
        schema_version::VersionNumber = _NATIVE_DRAWING_VERSION,
    )
        schema_version == _NATIVE_DRAWING_VERSION ||
            throw(ArgumentError("new drawing documents must use schema 2.0.0"))
        drawing_node = _native_drawing_node(drawing)
        drawing_node.value isa FormatMapping || throw(ArgumentError("drawing payload must be an object"))
        ordered_symbols = sort!(collect(symbols); by = item -> (item.owner_id, item.symbol_id))
        owners = getfield.(ordered_symbols, :owner_id)
        length(owners) == length(unique(owners)) || throw(ArgumentError("one drawing owner cannot bind multiple symbols"))
        ordered_caches = sort!(collect(caches); by = item -> item.path)
        paths = getfield.(ordered_caches, :path)
        length(paths) == length(unique(paths)) || throw(ArgumentError("cache paths must be unique"))
        return new(
            schema_version,
            _native_drawing_identifier(project_id, "project id"),
            drawing_node,
            FormatItemList(ordered_symbols),
            FormatItemList(ordered_caches),
        )
    end
end

struct NativeDrawingMigrationReport
    source_version::VersionNumber
    target_version::VersionNumber
    changes::FormatItemList{String}
    lossless::Bool
end

NativeDrawingMigrationReport(
    source_version::VersionNumber,
    target_version::VersionNumber,
    changes::AbstractVector{<:AbstractString},
    lossless::Bool,
) = NativeDrawingMigrationReport(
    source_version,
    target_version,
    FormatItemList(String.(changes)),
    lossless,
)

struct NativeDrawingRead
    document::NativeDrawingDocument
    migration::NativeDrawingMigrationReport
    missing_cache_paths::FormatItemList{String}
end

NativeDrawingRead(
    document::NativeDrawingDocument,
    migration::NativeDrawingMigrationReport,
    missing_cache_paths::AbstractVector{<:AbstractString},
) = NativeDrawingRead(document, migration, FormatItemList(String.(missing_cache_paths)))

const NativeDrawingReadResult = FormatResult{NativeDrawingRead}

struct _NativeDrawingFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _native_drawing_fail(code::Symbol, message::AbstractString, node::Union{Nothing,FormatNode} = nothing)
    throw(_NativeDrawingFailure(FormatDiagnostic(
        DiagnosticError,
        code,
        String(message),
        isnothing(node) ? nothing : node.span,
    )))
end

function _native_drawing_entries(node::FormatNode, role::AbstractString)
    node.value isa FormatMapping || _native_drawing_fail(:invalid_native_drawing_type, "$(role) must be an object", node)
    return Dict(entry.key.value.value => entry.value for entry in node.value.entries)
end

function _native_drawing_sequence(node::FormatNode, role::AbstractString)
    node.value isa FormatSequence || _native_drawing_fail(:invalid_native_drawing_type, "$(role) must be an array", node)
    return collect(node.value.elements)
end

function _native_drawing_string(node::FormatNode, role::AbstractString)
    node.value isa FormatString || _native_drawing_fail(:invalid_native_drawing_type, "$(role) must be a string", node)
    return node.value.value
end

function _native_drawing_strict(entries::AbstractDict, required, allowed, node::FormatNode, role::AbstractString)
    names = Set(keys(entries))
    missing = setdiff(Set(required), names)
    extra = setdiff(names, Set(allowed))
    isempty(missing) || _native_drawing_fail(:missing_native_drawing_field, "$(role) is missing $(join(sort!(collect(missing)), ", "))", node)
    isempty(extra) || _native_drawing_fail(:unknown_native_drawing_field, "$(role) contains unsupported $(join(sort!(collect(extra)), ", "))", node)
end

function _native_drawing_plain(node::FormatNode)
    value = node.value
    value isa FormatNull && return nothing
    value isa FormatBoolean && return value.value
    value isa FormatInteger && return value.value
    value isa FormatDecimal && return value
    value isa FormatString && return value.value
    value isa FormatSequence && return [_native_drawing_plain(item) for item in value.elements]
    value isa FormatMapping && return Dict(entry.key.value.value => _native_drawing_plain(entry.value) for entry in value.entries)
    throw(ArgumentError("unsupported drawing format value $(typeof(value))"))
end

native_drawing_payload(document::NativeDrawingDocument) = _native_drawing_plain(document.drawing)

function _native_symbol_data(reference::NativeSymbolReference)
    return Dict(
        "owner_id" => reference.owner_id,
        "symbol_id" => reference.symbol_id,
        "library_id" => reference.library_id,
        "content_sha256" => reference.content_sha256,
        "state" => reference.state,
        "level_of_detail" => reference.level_of_detail,
    )
end

_native_cache_data(reference::NativeDrawingCacheReference) = Dict(
    "path" => reference.path,
    "content_sha256" => reference.content_sha256,
)

function serialize_native_drawing(
    document::NativeDrawingDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    payload = Dict(
        "format" => _NATIVE_DRAWING_FORMAT,
        "schema_version" => string(_NATIVE_DRAWING_VERSION),
        "project_id" => document.project_id,
        "drawing" => native_drawing_payload(document),
        "symbols" => [_native_symbol_data(item) for item in document.symbols],
        "caches" => [_native_cache_data(item) for item in document.caches],
    )
    return serialize_canonical_json(_native_drawing_node(payload); policy)
end

function native_drawing_sha256(
    document::NativeDrawingDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    serialized = serialize_native_drawing(document; policy)
    format_succeeded(serialized) || return FormatResult{String}(nothing, collect(serialized.diagnostics))
    return FormatResult{String}(bytes2hex(sha256(collect(serialized.value.bytes))))
end

function _parse_native_symbol(node::FormatNode)
    entries = _native_drawing_entries(node, "symbol binding")
    fields = ["owner_id", "symbol_id", "library_id", "content_sha256", "state", "level_of_detail"]
    _native_drawing_strict(entries, fields, fields, node, "symbol binding")
    try
        return NativeSymbolReference(
            _native_drawing_string(entries["owner_id"], "symbol owner"),
            _native_drawing_string(entries["symbol_id"], "symbol id"),
            _native_drawing_string(entries["library_id"], "symbol library"),
            _native_drawing_string(entries["content_sha256"], "symbol content hash");
            state = _native_drawing_string(entries["state"], "symbol state"),
            level_of_detail = _native_drawing_string(entries["level_of_detail"], "symbol level of detail"),
        )
    catch error
        error isa ArgumentError || rethrow()
        _native_drawing_fail(:invalid_native_symbol_reference, sprint(showerror, error), node)
    end
end

function _parse_native_cache(node::FormatNode)
    entries = _native_drawing_entries(node, "cache reference")
    fields = ["path", "content_sha256"]
    _native_drawing_strict(entries, fields, fields, node, "cache reference")
    try
        return NativeDrawingCacheReference(
            _native_drawing_string(entries["path"], "cache path"),
            _native_drawing_string(entries["content_sha256"], "cache content hash"),
        )
    catch error
        error isa ArgumentError || rethrow()
        _native_drawing_fail(:invalid_native_cache_reference, sprint(showerror, error), node)
    end
end

function _parse_native_drawing_root(root::FormatNode, available_cache_hashes::AbstractDict)
    entries = _native_drawing_entries(root, "drawing document")
    common = ["format", "schema_version", "project_id"]
    _native_drawing_strict(entries, common, vcat(common, ["drawing", "symbols", "caches", "workspace", "symbol_bindings"]), root, "drawing document")
    _native_drawing_string(entries["format"], "format") == _NATIVE_DRAWING_FORMAT ||
        _native_drawing_fail(:unknown_native_drawing_format, "unsupported drawing document format", entries["format"])
    version_text = _native_drawing_string(entries["schema_version"], "schema version")
    version = try
        VersionNumber(version_text)
    catch
        _native_drawing_fail(:invalid_native_drawing_version, "schema version is not semantic versioning", entries["schema_version"])
    end
    drawing_node = nothing
    symbol_node = nothing
    cache_nodes = FormatNode[]
    changes = String[]
    if version == _NATIVE_DRAWING_VERSION
        fields = vcat(common, ["drawing", "symbols", "caches"])
        _native_drawing_strict(entries, fields, fields, root, "drawing document v2")
        drawing_node = entries["drawing"]
        symbol_node = entries["symbols"]
        cache_nodes = _native_drawing_sequence(entries["caches"], "caches")
    elseif version == _NATIVE_DRAWING_PREVIOUS_VERSION
        fields = vcat(common, ["workspace", "symbol_bindings"])
        _native_drawing_strict(entries, fields, fields, root, "drawing document v1")
        drawing_node = entries["workspace"]
        symbol_node = entries["symbol_bindings"]
        push!(changes, "workspace renamed to drawing", "symbol_bindings renamed to symbols", "empty derived cache index added")
    else
        _native_drawing_fail(:unsupported_native_drawing_version, "drawing schema $(version_text) is unsupported", entries["schema_version"])
    end
    drawing_node.value isa FormatMapping || _native_drawing_fail(:invalid_native_drawing_type, "drawing payload must be an object", drawing_node)
    symbols = NativeSymbolReference[_parse_native_symbol(node) for node in _native_drawing_sequence(symbol_node, "symbols")]
    caches = NativeDrawingCacheReference[_parse_native_cache(node) for node in cache_nodes]
    project_id = _native_drawing_string(entries["project_id"], "project id")
    document = try
        NativeDrawingDocument(project_id, drawing_node, symbols, caches)
    catch error
        error isa ArgumentError || rethrow()
        _native_drawing_fail(:native_drawing_conflict, sprint(showerror, error), root)
    end
    missing = sort!([
        cache.path for cache in document.caches
        if lowercase(String(get(available_cache_hashes, cache.path, ""))) != cache.content_sha256
    ])
    migration = NativeDrawingMigrationReport(version, _NATIVE_DRAWING_VERSION, changes, true)
    return NativeDrawingRead(document, migration, missing)
end

function parse_native_drawing(
    input::Union{AbstractString,AbstractVector{UInt8}};
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
    available_cache_hashes::AbstractDict = Dict{String,String}(),
)
    parsed = parse_json(input; source_name, policy)
    format_succeeded(parsed) || return NativeDrawingReadResult(nothing, collect(parsed.diagnostics))
    try
        return NativeDrawingReadResult(_parse_native_drawing_root(parsed.value.root, available_cache_hashes))
    catch error
        error isa _NativeDrawingFailure || rethrow()
        return NativeDrawingReadResult(nothing, [error.diagnostic])
    end
end
