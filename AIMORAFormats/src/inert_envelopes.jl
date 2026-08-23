const _PORTABLE_LOCAL_ID_PATTERN = r"^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)*$"
const _PORTABLE_REFERENCE_KIND_PATTERN = r"^[a-z][a-z0-9_-]*$"
const _PORTABLE_ARTIFACT_FORMAT_PATTERN = r"^[a-z][a-z0-9._+@-]*$"
const _PORTABLE_MEDIA_TYPE_PATTERN = r"^[a-z][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$"
const _PORTABLE_SYMBOL_PATTERN = r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*$"
const _SEMANTIC_VERSION_PATTERN = r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"

struct _InertEnvelopeFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _inert_fail(code::Symbol, message::AbstractString, span::SourceSpan)
    throw(_InertEnvelopeFailure(
        FormatDiagnostic(DiagnosticError, code, String(message), span),
    ))
end

function _inert_result(::Type{T}, failure::_InertEnvelopeFailure) where {T}
    return FormatResult{T}(nothing, [failure.diagnostic])
end

function _inert_mapping_entries(
    node::FormatNode,
    label::String,
    allowed::Set{String},
)
    node.value isa FormatMapping || _inert_fail(
        :inert_envelope_kind_mismatch,
        "$(label) must be a mapping",
        node.span,
    )
    entries = Dict{String,FormatMappingEntry}(
        entry.key.value.value => entry for entry in node.value.entries
    )
    unknown = sort!(collect(setdiff(Set(keys(entries)), allowed)))
    isempty(unknown) || begin
        entry = entries[first(unknown)]
        _inert_fail(
            :unknown_inert_envelope_field,
            "$(label) contains unknown field $(first(unknown))",
            entry.key.span,
        )
    end
    return entries
end

function _inert_required_entry(
    entries::Dict{String,FormatMappingEntry},
    key::String,
    container::FormatNode,
    label::String,
)
    haskey(entries, key) || _inert_fail(
        :missing_inert_envelope_field,
        "$(label) requires field $(key)",
        container.span,
    )
    return entries[key]
end

function _inert_string(
    entries::Dict{String,FormatMappingEntry},
    key::String,
    container::FormatNode,
    label::String;
    required::Bool = true,
)
    if !haskey(entries, key)
        required && _inert_required_entry(entries, key, container, label)
        return nothing
    end
    node = entries[key].value
    node.value isa FormatString || _inert_fail(
        :inert_envelope_field_kind_mismatch,
        "$(label) field $(key) must be a string",
        node.span,
    )
    return node.value.value
end

function _inert_nonempty_text(value::String, label::String, span::SourceSpan)
    isempty(value) && _inert_fail(
        :empty_inert_envelope_field,
        "$(label) must not be empty",
        span,
    )
    occursin(r"[\x00-\x1f\x7f]", value) && _inert_fail(
        :invalid_inert_envelope_text,
        "$(label) contains a prohibited control character",
        span,
    )
    return value
end

function _inert_semantic_version(value::String, span::SourceSpan)
    occursin(_SEMANTIC_VERSION_PATTERN, value) || _inert_fail(
        :invalid_semantic_version,
        "semantic version must be an exact portable major.minor.patch value",
        span,
    )
    try
        return VersionNumber(value)
    catch
        _inert_fail(
            :invalid_semantic_version,
            "semantic version cannot be represented by Julia VersionNumber",
            span,
        )
    end
end

"""A decoded RFC 6901 JSON Pointer retained without resolving a document."""
struct InertJsonPointer
    tokens::FormatItemList{String}

    function InertJsonPointer(tokens::AbstractVector{<:AbstractString})
        copied = String[String(token) for token in tokens]
        all(isvalid, copied) || throw(ArgumentError("JSON Pointer token is not valid Unicode"))
        return new(FormatItemList(copied))
    end
end

Base.:(==)(left::InertJsonPointer, right::InertJsonPointer) =
    left.tokens == right.tokens

function _inert_parse_json_pointer(value::String, span::SourceSpan)
    isempty(value) && return InertJsonPointer(String[])
    startswith(value, '/') || _inert_fail(
        :invalid_json_pointer,
        "JSON Pointer must be empty or begin with slash",
        span,
    )
    encoded_tokens = split(value[2:end], '/'; keepempty = true)
    decoded = String[]
    for encoded in encoded_tokens
        output = IOBuffer()
        index = firstindex(encoded)
        while index <= lastindex(encoded)
            character = encoded[index]
            if character == '~'
                next_index = nextind(encoded, index)
                next_index <= lastindex(encoded) || _inert_fail(
                    :invalid_json_pointer_escape,
                    "JSON Pointer contains a trailing tilde escape",
                    span,
                )
                escaped = encoded[next_index]
                escaped == '0' ? print(output, '~') :
                    escaped == '1' ? print(output, '/') :
                    _inert_fail(
                        :invalid_json_pointer_escape,
                        "JSON Pointer admits only ~0 and ~1 escapes",
                        span,
                    )
                index = nextind(encoded, next_index)
            else
                print(output, character)
                index = nextind(encoded, index)
            end
        end
        push!(decoded, String(take!(output)))
    end
    return InertJsonPointer(decoded)
end

function _inert_encode_json_pointer(pointer::InertJsonPointer)
    isempty(pointer.tokens) && return ""
    return "/" * join((replace(token, "~" => "~0", "/" => "~1") for token in pointer.tokens), "/")
end

function _inert_external_reference_valid(target::String)
    startswith(target, "aimora://") || return false
    body = target[(firstindex(target) + ncodeunits("aimora://")):end]
    segments = split(body, '/'; keepempty = true)
    length(segments) >= 2 || return false
    return all(segments) do segment
        !isempty(segment) &&
            segment != "." &&
            segment != ".." &&
            occursin(r"^[A-Za-z0-9][A-Za-z0-9._~@+-]*$", segment)
    end
end

function _inert_local_reference_valid(target::String)
    separator = findfirst(==(':'), target)
    isnothing(separator) && return false
    kind = target[firstindex(target):prevind(target, separator)]
    identifier = target[nextind(target, separator):end]
    return occursin(_PORTABLE_REFERENCE_KIND_PATTERN, kind) &&
           occursin(_PORTABLE_LOCAL_ID_PATTERN, identifier)
end

"""A portable local or `aimora://` reference plus an optional inert JSON Pointer."""
struct PortableReference
    target::String
    external::Bool
    pointer::Union{Nothing,InertJsonPointer}
    span::SourceSpan

    function PortableReference(
        target::String,
        external::Bool,
        pointer::Union{Nothing,InertJsonPointer},
        span::SourceSpan,
        ::Val{:parsed_portable_reference},
    )
        return new(target, external, pointer, span)
    end
end

Base.:(==)(left::PortableReference, right::PortableReference) =
    left.target == right.target &&
    left.external == right.external &&
    left.pointer == right.pointer &&
    left.span == right.span

function _inert_parse_reference(value::String, span::SourceSpan)
    hashes = findall(==('#'), value)
    length(hashes) <= 1 || _inert_fail(
        :invalid_portable_reference,
        "portable reference contains more than one fragment separator",
        span,
    )
    if isempty(hashes)
        target = value
        pointer = nothing
    else
        separator = only(hashes)
        target = separator == firstindex(value) ? "" : value[firstindex(value):prevind(value, separator)]
        pointer_text = separator == lastindex(value) ? "" : value[nextind(value, separator):end]
        pointer = _inert_parse_json_pointer(pointer_text, span)
    end
    external = startswith(target, "aimora://")
    valid = external ? _inert_external_reference_valid(target) :
        _inert_local_reference_valid(target)
    valid || _inert_fail(
        :invalid_portable_reference,
        "reference target must be a portable kind:local.id or aimora:// identity",
        span,
    )
    return PortableReference(
        target,
        external,
        pointer,
        span,
        Val(:parsed_portable_reference),
    )
end

function _inert_reference_text(reference::PortableReference)
    isnothing(reference.pointer) && return reference.target
    return reference.target * "#" * _inert_encode_json_pointer(reference.pointer)
end

"""Parse a portable reference scalar without resolving its target."""
function parse_portable_reference(
    source::SourceDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_scalar_bytes || begin
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :reference_too_large,
            "portable reference exceeds the configured scalar limit",
            source_span(source, 1, 1),
        )
        return FormatResult{PortableReference}(nothing, [diagnostic])
    end
    span = source_span(source, 1, ncodeunits(source.text) + 1)
    try
        return FormatResult(_inert_parse_reference(source.text, span))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(PortableReference, error)
    end
end

function parse_portable_reference(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<reference>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return FormatResult{PortableReference}(nothing, collect(admitted.diagnostics))
    return parse_portable_reference(admitted.value; policy)
end

parse_portable_reference(
    text::AbstractString;
    source_name::AbstractString = "<reference>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_portable_reference(
    Vector{UInt8}(codeunits(text));
    source_name,
    policy,
)

"""A strict `{"\$ref": ...}` syntax envelope."""
struct ReferenceEnvelope
    reference::PortableReference
    span::SourceSpan
end

Base.:(==)(left::ReferenceEnvelope, right::ReferenceEnvelope) =
    left.reference == right.reference && left.span == right.span

function parse_reference_envelope(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) || return FormatResult{ReferenceEnvelope}(nothing, diagnostics)
    try
        entries = _inert_mapping_entries(node, "reference envelope", Set(["\$ref"]))
        value_entry = _inert_required_entry(entries, "\$ref", node, "reference envelope")
        value_entry.value.value isa FormatString || _inert_fail(
            :inert_envelope_field_kind_mismatch,
            "reference envelope \$ref must be a string",
            value_entry.value.span,
        )
        reference = _inert_parse_reference(
            value_entry.value.value.value,
            value_entry.value.span,
        )
        return FormatResult(ReferenceEnvelope(reference, node.span))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(ReferenceEnvelope, error)
    end
end

parse_reference_envelope(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_reference_envelope(document.root; policy)

function _inert_portable_artifact_path(value::String, span::SourceSpan)
    _inert_nonempty_text(value, "artifact path", span)
    startswith(value, '/') && _inert_fail(
        :absolute_artifact_path,
        "artifact path must be relative",
        span,
    )
    occursin('\\', value) && _inert_fail(
        :nonportable_artifact_path,
        "artifact path must use forward slashes",
        span,
    )
    occursin(':', value) && _inert_fail(
        :absolute_artifact_path,
        "artifact path must not contain a drive or URI scheme",
        span,
    )
    segments = split(value, '/'; keepempty = true)
    any(segment -> isempty(segment) || segment == "." || segment == "..", segments) &&
        _inert_fail(
            :artifact_path_traversal,
            "artifact path contains an empty, current, or parent segment",
            span,
        )
    all(segment -> occursin(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", segment), segments) ||
        _inert_fail(
            :nonportable_artifact_path,
            "artifact path contains a nonportable segment",
            span,
        )
    return value
end

function _inert_optional_string_list(
    entries::Dict{String,FormatMappingEntry},
    key::String,
    label::String,
)
    haskey(entries, key) || return nothing
    node = entries[key].value
    node.value isa FormatSequence || _inert_fail(
        :inert_envelope_field_kind_mismatch,
        "$(label) must be an array of strings",
        node.span,
    )
    values = String[]
    for child in node.value.elements
        child.value isa FormatString || _inert_fail(
            :inert_envelope_field_kind_mismatch,
            "$(label) must contain only strings",
            child.span,
        )
        value = _inert_nonempty_text(child.value.value, label, child.span)
        push!(values, value)
    end
    length(values) == length(unique(values)) || _inert_fail(
        :duplicate_inert_envelope_value,
        "$(label) contains duplicate values",
        node.span,
    )
    return FormatItemList(values)
end

"""Inert metadata for one project-contained artifact; parsing never opens its path."""
struct ArtifactEnvelope
    path::String
    format::String
    sha256::String
    size_bytes::Union{Nothing,Int}
    schema::Union{Nothing,String}
    table::Union{Nothing,String}
    unit::Union{Nothing,String}
    ordering::Union{Nothing,FormatItemList{String}}
    media_type::Union{Nothing,String}
    span::SourceSpan

    function ArtifactEnvelope(
        path::String,
        format::String,
        sha256::String,
        size_bytes::Union{Nothing,Int},
        schema::Union{Nothing,String},
        table::Union{Nothing,String},
        unit::Union{Nothing,String},
        ordering::Union{Nothing,FormatItemList{String}},
        media_type::Union{Nothing,String},
        span::SourceSpan,
        ::Val{:parsed_artifact_envelope},
    )
        return new(
            path,
            format,
            sha256,
            size_bytes,
            schema,
            table,
            unit,
            ordering,
            media_type,
            span,
        )
    end
end

Base.:(==)(left::ArtifactEnvelope, right::ArtifactEnvelope) =
    left.path == right.path &&
    left.format == right.format &&
    left.sha256 == right.sha256 &&
    left.size_bytes == right.size_bytes &&
    left.schema == right.schema &&
    left.table == right.table &&
    left.unit == right.unit &&
    left.ordering == right.ordering &&
    left.media_type == right.media_type &&
    left.span == right.span

function parse_artifact_envelope(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) || return FormatResult{ArtifactEnvelope}(nothing, diagnostics)
    try
        outer = _inert_mapping_entries(node, "artifact envelope", Set(["\$artifact"]))
        descriptor = _inert_required_entry(outer, "\$artifact", node, "artifact envelope").value
        allowed = Set([
            "path",
            "format",
            "sha256",
            "size_bytes",
            "schema",
            "table",
            "unit",
            "ordering",
            "media_type",
        ])
        entries = _inert_mapping_entries(descriptor, "artifact descriptor", allowed)
        path_entry = _inert_required_entry(entries, "path", descriptor, "artifact descriptor")
        path = _inert_string(entries, "path", descriptor, "artifact descriptor")
        _inert_portable_artifact_path(path, path_entry.value.span)
        format_entry = _inert_required_entry(entries, "format", descriptor, "artifact descriptor")
        format = _inert_string(entries, "format", descriptor, "artifact descriptor")
        occursin(_PORTABLE_ARTIFACT_FORMAT_PATTERN, format) || _inert_fail(
            :invalid_artifact_format,
            "artifact format is not a portable format identifier",
            format_entry.value.span,
        )
        digest_entry = _inert_required_entry(entries, "sha256", descriptor, "artifact descriptor")
        digest = _inert_string(entries, "sha256", descriptor, "artifact descriptor")
        occursin(r"^[0-9a-f]{64}$", digest) || _inert_fail(
            :invalid_artifact_sha256,
            "artifact SHA-256 must contain 64 lowercase hexadecimal digits",
            digest_entry.value.span,
        )
        size = if haskey(entries, "size_bytes")
            size_node = entries["size_bytes"].value
            size_node.value isa FormatInteger || _inert_fail(
                :inert_envelope_field_kind_mismatch,
                "artifact size_bytes must be an integer",
                size_node.span,
            )
            value = size_node.value.value
            0 <= value <= typemax(Int) || _inert_fail(
                :invalid_artifact_size,
                "artifact size_bytes must be a nonnegative bounded integer",
                size_node.span,
            )
            Int(value)
        else
            nothing
        end
        schema = _inert_string(entries, "schema", descriptor, "artifact descriptor"; required = false)
        if !isnothing(schema)
            schema_entry = entries["schema"].value
            _inert_nonempty_text(schema, "artifact schema", schema_entry.span)
            occursin(r"^[A-Za-z][A-Za-z0-9._@+-]*$", schema) || _inert_fail(
                :invalid_artifact_schema,
                "artifact schema is not a portable identifier",
                schema_entry.span,
            )
        end
        table = _inert_string(entries, "table", descriptor, "artifact descriptor"; required = false)
        !isnothing(table) && _inert_nonempty_text(table, "artifact table", entries["table"].value.span)
        unit = _inert_string(entries, "unit", descriptor, "artifact descriptor"; required = false)
        !isnothing(unit) && _inert_nonempty_text(unit, "artifact unit", entries["unit"].value.span)
        ordering = _inert_optional_string_list(entries, "ordering", "artifact ordering")
        !isnothing(ordering) && isempty(ordering) && _inert_fail(
            :empty_artifact_ordering,
            "artifact ordering must contain at least one named element when present",
            entries["ordering"].value.span,
        )
        media_type = _inert_string(
            entries,
            "media_type",
            descriptor,
            "artifact descriptor";
            required = false,
        )
        if !isnothing(media_type)
            occursin(_PORTABLE_MEDIA_TYPE_PATTERN, media_type) || _inert_fail(
                :invalid_artifact_media_type,
                "artifact media_type is not a portable registered type",
                entries["media_type"].value.span,
            )
        end
        return FormatResult(ArtifactEnvelope(
            path,
            format,
            digest,
            size,
            schema,
            table,
            unit,
            ordering,
            media_type,
            node.span,
            Val(:parsed_artifact_envelope),
        ))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(ArtifactEnvelope, error)
    end
end

parse_artifact_envelope(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_artifact_envelope(document.root; policy)

"""One explicit catalog inheritance declaration without applying inheritance."""
struct ExtendsEnvelope
    catalog::String
    version::VersionNumber
    sha256::Union{Nothing,String}
    facets::Union{Nothing,FormatItemList{String}}
    span::SourceSpan

    function ExtendsEnvelope(
        catalog::String,
        version::VersionNumber,
        sha256::Union{Nothing,String},
        facets::Union{Nothing,FormatItemList{String}},
        span::SourceSpan,
        ::Val{:parsed_extends_envelope},
    )
        return new(catalog, version, sha256, facets, span)
    end
end

Base.:(==)(left::ExtendsEnvelope, right::ExtendsEnvelope) =
    left.catalog == right.catalog &&
    left.version == right.version &&
    left.sha256 == right.sha256 &&
    left.facets == right.facets &&
    left.span == right.span

function parse_extends_envelope(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) || return FormatResult{ExtendsEnvelope}(nothing, diagnostics)
    try
        outer = _inert_mapping_entries(node, "extends envelope", Set(["extends"]))
        declaration = _inert_required_entry(outer, "extends", node, "extends envelope").value
        entries = _inert_mapping_entries(
            declaration,
            "extends declaration",
            Set(["catalog", "version", "sha256", "facets"]),
        )
        catalog_entry = _inert_required_entry(entries, "catalog", declaration, "extends declaration")
        catalog = _inert_string(entries, "catalog", declaration, "extends declaration")
        occursin(_PORTABLE_LOCAL_ID_PATTERN, catalog) || _inert_fail(
            :invalid_extends_catalog,
            "extends catalog must be a portable project-independent ID",
            catalog_entry.value.span,
        )
        version_entry = _inert_required_entry(entries, "version", declaration, "extends declaration")
        version_text = _inert_string(entries, "version", declaration, "extends declaration")
        version = _inert_semantic_version(version_text, version_entry.value.span)
        digest = _inert_string(entries, "sha256", declaration, "extends declaration"; required = false)
        if !isnothing(digest)
            occursin(r"^[0-9a-f]{64}$", digest) || _inert_fail(
                :invalid_extends_sha256,
                "extends SHA-256 must contain 64 lowercase hexadecimal digits",
                entries["sha256"].value.span,
            )
        end
        facets = _inert_optional_string_list(entries, "facets", "extends facets")
        if !isnothing(facets)
            for (index, facet) in enumerate(facets)
                occursin(_PORTABLE_LOCAL_ID_PATTERN, facet) || _inert_fail(
                    :invalid_extends_facet,
                    "extends facet is not a portable identifier",
                    entries["facets"].value.value.elements[index].span,
                )
            end
        end
        return FormatResult(ExtendsEnvelope(
            catalog,
            version,
            digest,
            facets,
            node.span,
            Val(:parsed_extends_envelope),
        ))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(ExtendsEnvelope, error)
    end
end

parse_extends_envelope(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_extends_envelope(document.root; policy)

@enum PatchOperationKind::UInt8 begin
    PatchSet = 0x01
    PatchUnset = 0x02
    PatchAdd = 0x03
    PatchRemove = 0x04
    PatchEnable = 0x05
    PatchDisable = 0x06
    PatchConnect = 0x07
    PatchDisconnect = 0x08
    PatchReplaceProfile = 0x09
    PatchReplaceRealization = 0x0a
end

const _PATCH_OPERATION_NAMES = Dict(
    "set" => PatchSet,
    "unset" => PatchUnset,
    "add" => PatchAdd,
    "remove" => PatchRemove,
    "enable" => PatchEnable,
    "disable" => PatchDisable,
    "connect" => PatchConnect,
    "disconnect" => PatchDisconnect,
    "replace_profile" => PatchReplaceProfile,
    "replace_realization" => PatchReplaceRealization,
)
const _PATCH_VALUE_OPERATIONS = Set([
    PatchSet,
    PatchAdd,
    PatchConnect,
    PatchReplaceProfile,
    PatchReplaceRealization,
])

function _inert_patch_path(value::String, span::SourceSpan)
    occursin(_PORTABLE_LOCAL_ID_PATTERN, value) || _inert_fail(
        :invalid_patch_path,
        "patch path must contain portable stable field segments",
        span,
    )
    return FormatPath(split(value, '.')...)
end

function _inert_patch_path_text(path::FormatPath)
    all(segment -> segment isa FormatMappingKeySegment, path.segments) ||
        throw(ArgumentError("patch path contains a sequence index"))
    return join((segment.key for segment in path.segments), ".")
end

"""One bounded declarative patch operation; applying it belongs to project semantics."""
struct PatchEnvelope
    operation::PatchOperationKind
    target::PortableReference
    path::FormatPath
    value::Union{Nothing,FormatNode}
    span::SourceSpan

    function PatchEnvelope(
        operation::PatchOperationKind,
        target::PortableReference,
        path::FormatPath,
        value::Union{Nothing,FormatNode},
        span::SourceSpan,
        ::Val{:parsed_patch_envelope},
    )
        return new(operation, target, path, value, span)
    end
end

Base.:(==)(left::PatchEnvelope, right::PatchEnvelope) =
    left.operation == right.operation &&
    left.target == right.target &&
    left.path == right.path &&
    left.value == right.value &&
    left.span == right.span

function parse_patch_envelope(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) || return FormatResult{PatchEnvelope}(nothing, diagnostics)
    try
        entries = _inert_mapping_entries(
            node,
            "patch envelope",
            Set(["op", "target", "path", "value"]),
        )
        operation_entry = _inert_required_entry(entries, "op", node, "patch envelope")
        operation_name = _inert_string(entries, "op", node, "patch envelope")
        haskey(_PATCH_OPERATION_NAMES, operation_name) || _inert_fail(
            :unknown_patch_operation,
            "patch operation $(operation_name) is not admitted",
            operation_entry.value.span,
        )
        operation = _PATCH_OPERATION_NAMES[operation_name]
        target_entry = _inert_required_entry(entries, "target", node, "patch envelope")
        target_result = parse_reference_envelope(target_entry.value; policy)
        format_succeeded(target_result) || throw(_InertEnvelopeFailure(first(target_result.diagnostics)))
        path_entry = _inert_required_entry(entries, "path", node, "patch envelope")
        path_text = _inert_string(entries, "path", node, "patch envelope")
        path = _inert_patch_path(path_text, path_entry.value.span)
        requires_value = operation in _PATCH_VALUE_OPERATIONS
        if requires_value && !haskey(entries, "value")
            _inert_fail(
                :missing_patch_value,
                "patch operation $(operation_name) requires a value",
                node.span,
            )
        elseif !requires_value && haskey(entries, "value")
            _inert_fail(
                :unexpected_patch_value,
                "patch operation $(operation_name) prohibits a value",
                entries["value"].value.span,
            )
        end
        value = haskey(entries, "value") ? entries["value"].value : nothing
        return FormatResult(PatchEnvelope(
            operation,
            target_result.value.reference,
            path,
            value,
            node.span,
            Val(:parsed_patch_envelope),
        ))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(PatchEnvelope, error)
    end
end

parse_patch_envelope(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_patch_envelope(document.root; policy)

"""A hash-pinnable package function identity; parsing never loads its package or symbol."""
struct RegisteredFunctionIdentity
    plugin::String
    package_uuid::UUID
    version::VersionNumber
    symbol::String
    git_tree_sha1::Union{Nothing,String}
    span::SourceSpan

    function RegisteredFunctionIdentity(
        plugin::String,
        package_uuid::UUID,
        version::VersionNumber,
        symbol::String,
        git_tree_sha1::Union{Nothing,String},
        span::SourceSpan,
        ::Val{:parsed_registered_function_identity},
    )
        return new(plugin, package_uuid, version, symbol, git_tree_sha1, span)
    end
end

Base.:(==)(left::RegisteredFunctionIdentity, right::RegisteredFunctionIdentity) =
    left.plugin == right.plugin &&
    left.package_uuid == right.package_uuid &&
    left.version == right.version &&
    left.symbol == right.symbol &&
    left.git_tree_sha1 == right.git_tree_sha1 &&
    left.span == right.span

function parse_registered_function_identity(
    node::FormatNode;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = validate_format_tree(node, policy)
    isempty(diagnostics) ||
        return FormatResult{RegisteredFunctionIdentity}(nothing, diagnostics)
    try
        entries = _inert_mapping_entries(
            node,
            "registered function identity",
            Set(["plugin", "package_uuid", "version", "symbol", "git_tree_sha1"]),
        )
        plugin_entry = _inert_required_entry(entries, "plugin", node, "registered function identity")
        plugin = _inert_string(entries, "plugin", node, "registered function identity")
        occursin(_PORTABLE_LOCAL_ID_PATTERN, plugin) || _inert_fail(
            :invalid_registered_function_plugin,
            "registered function plugin is not a portable ID",
            plugin_entry.value.span,
        )
        uuid_entry = _inert_required_entry(entries, "package_uuid", node, "registered function identity")
        uuid_text = _inert_string(entries, "package_uuid", node, "registered function identity")
        package_uuid = try
            UUID(uuid_text)
        catch
            _inert_fail(
                :invalid_registered_function_uuid,
                "registered function package_uuid is not a UUID",
                uuid_entry.value.span,
            )
        end
        string(package_uuid) == uuid_text || _inert_fail(
            :invalid_registered_function_uuid,
            "registered function package_uuid must use canonical lowercase form",
            uuid_entry.value.span,
        )
        version_entry = _inert_required_entry(entries, "version", node, "registered function identity")
        version_text = _inert_string(entries, "version", node, "registered function identity")
        version = _inert_semantic_version(version_text, version_entry.value.span)
        symbol_entry = _inert_required_entry(entries, "symbol", node, "registered function identity")
        symbol = _inert_string(entries, "symbol", node, "registered function identity")
        occursin(_PORTABLE_SYMBOL_PATTERN, symbol) || _inert_fail(
            :invalid_registered_function_symbol,
            "registered function symbol must use portable qualified identifiers",
            symbol_entry.value.span,
        )
        tree_hash = _inert_string(
            entries,
            "git_tree_sha1",
            node,
            "registered function identity";
            required = false,
        )
        if !isnothing(tree_hash)
            occursin(r"^[0-9a-f]{40}$", tree_hash) || _inert_fail(
                :invalid_registered_function_tree_hash,
                "registered function git_tree_sha1 must contain 40 lowercase hexadecimal digits",
                entries["git_tree_sha1"].value.span,
            )
        end
        return FormatResult(RegisteredFunctionIdentity(
            plugin,
            package_uuid,
            version,
            symbol,
            tree_hash,
            node.span,
            Val(:parsed_registered_function_identity),
        ))
    catch error
        error isa _InertEnvelopeFailure || rethrow()
        return _inert_result(RegisteredFunctionIdentity, error)
    end
end

parse_registered_function_identity(
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_registered_function_identity(document.root; policy)

function _inert_generated_span()
    position = SourcePosition(1, 1, 1)
    return SourceSpan("<generated-inert-envelope>", position, position)
end

_inert_generated_node(value::FormatValue) = FormatNode(value, _inert_generated_span())

function _inert_generated_mapping(pairs::AbstractVector{<:Pair{String,FormatNode}})
    entries = FormatMappingEntry[]
    for (key, value) in pairs
        push!(entries, FormatMappingEntry(
            _inert_generated_node(FormatString(key)),
            value,
        ))
    end
    return _inert_generated_node(FormatMapping(entries))
end

_inert_generated_string(value::String) = _inert_generated_node(FormatString(value))

function _inert_generated_reference(reference::PortableReference)
    return _inert_generated_mapping([
        "\$ref" => _inert_generated_string(_inert_reference_text(reference)),
    ])
end

"""Write a reference envelope as deterministic canonical JSON without resolution."""
serialize_reference_envelope(
    envelope::ReferenceEnvelope;
    policy::FormatInputPolicy = FormatInputPolicy(),
) = serialize_canonical_json(_inert_generated_reference(envelope.reference); policy)

"""Write an artifact descriptor as deterministic canonical JSON without opening it."""
function serialize_artifact_envelope(
    envelope::ArtifactEnvelope;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    pairs = Pair{String,FormatNode}[
        "path" => _inert_generated_string(envelope.path),
        "format" => _inert_generated_string(envelope.format),
        "sha256" => _inert_generated_string(envelope.sha256),
    ]
    isnothing(envelope.size_bytes) || push!(
        pairs,
        "size_bytes" => _inert_generated_node(FormatInteger(envelope.size_bytes)),
    )
    isnothing(envelope.schema) || push!(pairs, "schema" => _inert_generated_string(envelope.schema))
    isnothing(envelope.table) || push!(pairs, "table" => _inert_generated_string(envelope.table))
    isnothing(envelope.unit) || push!(pairs, "unit" => _inert_generated_string(envelope.unit))
    if !isnothing(envelope.ordering)
        ordering = _inert_generated_node(FormatSequence(
            [_inert_generated_string(value) for value in envelope.ordering],
        ))
        push!(pairs, "ordering" => ordering)
    end
    isnothing(envelope.media_type) || push!(
        pairs,
        "media_type" => _inert_generated_string(envelope.media_type),
    )
    root = _inert_generated_mapping([
        "\$artifact" => _inert_generated_mapping(pairs),
    ])
    return serialize_canonical_json(root; policy)
end

"""Write an explicit inheritance envelope as deterministic canonical JSON."""
function serialize_extends_envelope(
    envelope::ExtendsEnvelope;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    pairs = Pair{String,FormatNode}[
        "catalog" => _inert_generated_string(envelope.catalog),
        "version" => _inert_generated_string(string(envelope.version)),
    ]
    isnothing(envelope.sha256) || push!(pairs, "sha256" => _inert_generated_string(envelope.sha256))
    if !isnothing(envelope.facets)
        facets = _inert_generated_node(FormatSequence(
            [_inert_generated_string(value) for value in envelope.facets],
        ))
        push!(pairs, "facets" => facets)
    end
    root = _inert_generated_mapping([
        "extends" => _inert_generated_mapping(pairs),
    ])
    return serialize_canonical_json(root; policy)
end

function _patch_operation_name(operation::PatchOperationKind)
    for (name, candidate) in _PATCH_OPERATION_NAMES
        candidate == operation && return name
    end
    error("unsupported patch operation")
end

"""Write a patch envelope as deterministic canonical JSON without applying it."""
function serialize_patch_envelope(
    envelope::PatchEnvelope;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    pairs = Pair{String,FormatNode}[
        "op" => _inert_generated_string(_patch_operation_name(envelope.operation)),
        "target" => _inert_generated_reference(envelope.target),
        "path" => _inert_generated_string(_inert_patch_path_text(envelope.path)),
    ]
    isnothing(envelope.value) || push!(pairs, "value" => envelope.value)
    return serialize_canonical_json(_inert_generated_mapping(pairs); policy)
end

"""Write a registered package-function identity without loading its module."""
function serialize_registered_function_identity(
    identity::RegisteredFunctionIdentity;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    pairs = Pair{String,FormatNode}[
        "plugin" => _inert_generated_string(identity.plugin),
        "package_uuid" => _inert_generated_string(string(identity.package_uuid)),
        "version" => _inert_generated_string(string(identity.version)),
        "symbol" => _inert_generated_string(identity.symbol),
    ]
    isnothing(identity.git_tree_sha1) || push!(
        pairs,
        "git_tree_sha1" => _inert_generated_string(identity.git_tree_sha1),
    )
    return serialize_canonical_json(_inert_generated_mapping(pairs); policy)
end
