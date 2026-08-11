const _STRUCTURAL_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"
const _STRUCTURAL_SCHEMA_TYPES = Set([
    "null",
    "boolean",
    "integer",
    "number",
    "string",
    "array",
    "object",
])
const _STRUCTURAL_SCHEMA_KEYWORDS = Set([
    "\$schema",
    "\$id",
    "\$defs",
    "\$ref",
    "type",
    "properties",
    "required",
    "additionalProperties",
    "minProperties",
    "maxProperties",
    "dependentRequired",
    "items",
    "prefixItems",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "enum",
    "const",
    "allOf",
    "anyOf",
    "oneOf",
    "not",
    "if",
    "then",
    "else",
    "title",
    "description",
    "default",
    "examples",
    "deprecated",
    "readOnly",
    "writeOnly",
    "\$comment",
])
const _STRUCTURAL_SCHEMA_ANNOTATION_STRINGS = Set([
    "title",
    "description",
    "\$comment",
])
const _STRUCTURAL_SCHEMA_ANNOTATION_BOOLEANS = Set([
    "deprecated",
    "readOnly",
    "writeOnly",
])

function _structural_identifier_valid(identifier::String)
    isempty(identifier) && return false
    isvalid(identifier) || return false
    occursin(r"[\r\n\0]", identifier) && return false
    occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", identifier) && return true
    startswith(identifier, "urn:aimora:") &&
        return occursin(r"^urn:aimora:[A-Za-z0-9][A-Za-z0-9._:/-]*$", identifier)
    startswith(identifier, "https://") || return false
    authority_start = firstindex(identifier) + ncodeunits("https://")
    authority_stop = something(findnext('/', identifier, authority_start), lastindex(identifier) + 1)
    authority = String(SubString(identifier, authority_start, prevind(identifier, authority_stop)))
    isempty(authority) && return false
    occursin('@', authority) && return false
    return !occursin(r"[?#]", identifier)
end

_structural_schema_name_valid(identifier::String) =
    occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", identifier)

"""Exact identity and semantic version of one structural schema document."""
struct StructuralSchemaIdentity
    id::String
    uri::String
    version::VersionNumber

    function StructuralSchemaIdentity(
        id::AbstractString,
        version::VersionNumber;
        uri::AbstractString = id,
    )
        normalized_id = String(id)
        _structural_schema_name_valid(normalized_id) ||
            throw(ArgumentError("structural schema ID is not a portable lock name"))
        normalized_uri = String(uri)
        _structural_identifier_valid(normalized_uri) ||
            throw(ArgumentError("structural schema URI is not portable"))
        return new(normalized_id, normalized_uri, version)
    end
end

Base.:(==)(left::StructuralSchemaIdentity, right::StructuralSchemaIdentity) =
    left.id == right.id && left.uri == right.uri && left.version == right.version
Base.hash(identity::StructuralSchemaIdentity, seed::UInt) =
    hash(identity.version, hash(identity.uri, hash(identity.id, seed)))

"""A compiled, source-located JSON Schema 2020-12 structural subset."""
struct StructuralSchema
    identity::StructuralSchemaIdentity
    source::SourceDocument
    root::FormatNode
    canonical_sha256::String

    function StructuralSchema(
        identity::StructuralSchemaIdentity,
        source::SourceDocument,
        root::FormatNode,
        canonical_sha256::String,
        ::Val{:compiled_structural_schema},
    )
        return new(identity, source, root, canonical_sha256)
    end
end

Base.:(==)(left::StructuralSchema, right::StructuralSchema) =
    left.identity == right.identity &&
    left.source == right.source &&
    left.root == right.root &&
    left.canonical_sha256 == right.canonical_sha256

"""Typed result returned after schema syntax, vocabulary, identity, and lock checks."""
const StructuralSchemaCompileResult = FormatResult{StructuralSchema}

@enum SchemaCompatibilityKind::UInt8 begin
    SchemaExact = 0x01
    SchemaBackwardReadable = 0x02
    SchemaMigrationRequired = 0x03
    SchemaPastUnsupported = 0x04
    SchemaFutureUnsupported = 0x05
end

"""Declared current schema version and exact older versions promised as direct readers."""
struct SchemaVersionPolicy
    schema_id::String
    current_version::VersionNumber
    backward_readers::FormatItemList{VersionNumber}

    function SchemaVersionPolicy(
        schema_id::AbstractString,
        current_version::VersionNumber;
        backward_readers::AbstractVector{VersionNumber} = VersionNumber[],
    )
        normalized_id = String(schema_id)
        _structural_schema_name_valid(normalized_id) ||
            throw(ArgumentError("schema version policy ID is not a portable lock name"))
        readers = collect(backward_readers)
        length(readers) == length(unique(readers)) ||
            throw(ArgumentError("backward reader versions must be unique"))
        sort!(readers)
        all(version -> version < current_version, readers) ||
            throw(ArgumentError("backward reader versions must precede the current version"))
        return new(normalized_id, current_version, FormatItemList(readers))
    end
end

Base.:(==)(left::SchemaVersionPolicy, right::SchemaVersionPolicy) =
    left.schema_id == right.schema_id &&
    left.current_version == right.current_version &&
    left.backward_readers == right.backward_readers

"""Inspectable version-negotiation outcome without an implicit fallback."""
struct SchemaCompatibilityDecision
    kind::SchemaCompatibilityKind
    schema_id::String
    requested_version::VersionNumber
    current_version::VersionNumber
end

Base.:(==)(left::SchemaCompatibilityDecision, right::SchemaCompatibilityDecision) =
    left.kind == right.kind &&
    left.schema_id == right.schema_id &&
    left.requested_version == right.requested_version &&
    left.current_version == right.current_version

"""Classify an input version using exact promises and an explicitly known migration path."""
function schema_compatibility(
    policy::SchemaVersionPolicy,
    requested_version::VersionNumber;
    migration_available::Bool = false,
)
    kind = if requested_version == policy.current_version
        SchemaExact
    elseif requested_version in policy.backward_readers
        SchemaBackwardReadable
    elseif requested_version > policy.current_version
        SchemaFutureUnsupported
    elseif migration_available
        SchemaMigrationRequired
    else
        SchemaPastUnsupported
    end
    return SchemaCompatibilityDecision(
        kind,
        policy.schema_id,
        requested_version,
        policy.current_version,
    )
end

struct _StructuralSchemaFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _structural_entry(node::FormatNode, key::String)
    node.value isa FormatMapping || return nothing
    for entry in node.value.entries
        entry.key.value.value == key && return entry
    end
    return nothing
end

function _structural_mapping(node::FormatNode)
    node.value isa FormatMapping || return nothing
    return Dict{String,FormatMappingEntry}(
        entry.key.value.value => entry for entry in node.value.entries
    )
end

function _structural_diagnostic(
    code::Symbol,
    message::AbstractString,
    span::SourceSpan,
)
    return FormatDiagnostic(DiagnosticError, code, String(message), span)
end

function _structural_push!(
    diagnostics::Vector{FormatDiagnostic},
    policy::FormatInputPolicy,
    diagnostic::FormatDiagnostic,
)
    length(diagnostics) < policy.max_diagnostics && push!(diagnostics, diagnostic)
    return nothing
end

function _structural_nonnegative_integer(node::FormatNode)
    node.value isa FormatInteger || return nothing
    value = node.value.value
    value >= 0 || return nothing
    value <= typemax(Int) || return nothing
    return Int(value)
end

function _structural_numeric_components(value::FormatValue)
    if value isa FormatInteger
        coefficient = BigInt(value.value)
        exponent = 0
    elseif value isa FormatDecimal
        coefficient = BigInt(value.coefficient)
        exponent = value.exponent
    else
        return nothing
    end
    if iszero(coefficient)
        return (BigInt(0), 0)
    end
    while iszero(rem(coefficient, 10))
        coefficient = div(coefficient, 10)
        exponent == typemax(Int) && return nothing
        exponent += 1
    end
    return (coefficient, exponent)
end

function _structural_compare_magnitude(
    left_coefficient::BigInt,
    left_exponent::Int,
    right_coefficient::BigInt,
    right_exponent::Int,
)
    left_digits = string(abs(left_coefficient))
    right_digits = string(abs(right_coefficient))
    left_order = BigInt(ncodeunits(left_digits)) + BigInt(left_exponent)
    right_order = BigInt(ncodeunits(right_digits)) + BigInt(right_exponent)
    left_order < right_order && return -1
    left_order > right_order && return 1
    width = max(ncodeunits(left_digits), ncodeunits(right_digits))
    left_padded = rpad(left_digits, width, '0')
    right_padded = rpad(right_digits, width, '0')
    left_padded < right_padded && return -1
    left_padded > right_padded && return 1
    return 0
end

function _structural_compare_numbers(left::FormatValue, right::FormatValue)
    left_parts = _structural_numeric_components(left)
    right_parts = _structural_numeric_components(right)
    (isnothing(left_parts) || isnothing(right_parts)) && return nothing
    left_coefficient, left_exponent = left_parts
    right_coefficient, right_exponent = right_parts
    sign_left = sign(left_coefficient)
    sign_right = sign(right_coefficient)
    sign_left < sign_right && return -1
    sign_left > sign_right && return 1
    iszero(sign_left) && return 0
    magnitude = _structural_compare_magnitude(
        left_coefficient,
        left_exponent,
        right_coefficient,
        right_exponent,
    )
    return sign_left < 0 ? -magnitude : magnitude
end

function _structural_semantic_equal(left::FormatValue, right::FormatValue)
    numeric = _structural_compare_numbers(left, right)
    !isnothing(numeric) && return numeric == 0
    typeof(left) === typeof(right) || return false
    left isa FormatNull && return true
    left isa FormatBoolean && return left.value == right.value
    left isa FormatString && return left.value == right.value
    if left isa FormatSequence
        length(left.elements) == length(right.elements) || return false
        return all(
            _structural_semantic_equal(left_node.value, right_node.value)
            for (left_node, right_node) in zip(left.elements, right.elements)
        )
    elseif left isa FormatMapping
        length(left.entries) == length(right.entries) || return false
        right_entries = Dict(
            entry.key.value.value => entry.value.value for entry in right.entries
        )
        for entry in left.entries
            key = entry.key.value.value
            haskey(right_entries, key) || return false
            _structural_semantic_equal(entry.value.value, right_entries[key]) || return false
        end
        return true
    end
    return false
end

function _structural_semantic_key(value::FormatValue)
    numeric = _structural_numeric_components(value)
    if !isnothing(numeric)
        coefficient, exponent = numeric
        return "N$(coefficient):$(exponent)"
    end
    value isa FormatNull && return "Z"
    value isa FormatBoolean && return value.value ? "B1" : "B0"
    value isa FormatString && return "S$(ncodeunits(value.value)):$(value.value)"
    if value isa FormatSequence
        parts = String[_structural_semantic_key(node.value) for node in value.elements]
        return "A" * join(("$(ncodeunits(part))):$(part)" for part in parts), "")
    elseif value isa FormatMapping
        parts = sort!([
            begin
                key = entry.key.value.value
                encoded = _structural_semantic_key(entry.value.value)
                "$(ncodeunits(key)):$(key)$(ncodeunits(encoded)):$(encoded)"
            end for entry in value.entries
        ])
        return "O" * join(parts, "")
    end
    error("unsupported structural semantic value")
end

function _structural_schema_type_names(node::FormatNode)
    if node.value isa FormatString
        return String[node.value.value]
    elseif node.value isa FormatSequence
        names = String[]
        for child in node.value.elements
            child.value isa FormatString || return nothing
            push!(names, child.value.value)
        end
        return names
    end
    return nothing
end

function _structural_schema_list(
    node::FormatNode,
    code::Symbol,
    label::String,
    diagnostics::Vector{FormatDiagnostic},
    policy::FormatInputPolicy,
)
    if !(node.value isa FormatSequence) || isempty(node.value.elements)
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(code, "$(label) must be a nonempty array", node.span),
        )
        return nothing
    end
    return node.value.elements
end

function _structural_validate_schema_node!(
    node::FormatNode,
    identity::StructuralSchemaIdentity,
    definitions::Set{String},
    diagnostics::Vector{FormatDiagnostic},
    policy::FormatInputPolicy,
    depth::Int,
    root::Bool,
)
    length(diagnostics) >= policy.max_diagnostics && return
    if depth > policy.max_nesting_depth
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :structural_schema_too_deep,
                "structural schema exceeds the configured nesting depth",
                node.span,
            ),
        )
        return
    end
    if node.value isa FormatBoolean
        if root
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :structural_schema_root_must_be_object,
                    "root structural schema must be an object with an identity and dialect",
                    node.span,
                ),
            )
        end
        return
    end
    if !(node.value isa FormatMapping)
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :structural_schema_must_be_object,
                "structural schema must be an object or boolean",
                node.span,
            ),
        )
        return
    end
    entries = _structural_mapping(node)
    for entry in node.value.entries
        key = entry.key.value.value
        key in _STRUCTURAL_SCHEMA_KEYWORDS || _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :unsupported_structural_schema_keyword,
                "structural schema keyword $(key) is not admitted",
                entry.key.span,
            ),
        )
    end
    if root
        for required_key in ("\$schema", "\$id")
            haskey(entries, required_key) || _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :missing_structural_schema_identity,
                    "root structural schema requires $(required_key)",
                    node.span,
                ),
            )
        end
    else
        for prohibited_key in ("\$schema", "\$id")
            haskey(entries, prohibited_key) && _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :nested_structural_schema_identity,
                    "$(prohibited_key) is admitted only on the root schema",
                    entries[prohibited_key].key.span,
                ),
            )
        end
    end
    if haskey(entries, "\$schema")
        value = entries["\$schema"].value
        (!(value.value isa FormatString) || value.value.value != _STRUCTURAL_SCHEMA_DIALECT) &&
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :unsupported_structural_schema_dialect,
                    "only JSON Schema draft 2020-12 is admitted",
                    value.span,
                ),
            )
    end
    if haskey(entries, "\$id")
        value = entries["\$id"].value
        (!(value.value isa FormatString) || value.value.value != identity.uri) &&
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :structural_schema_id_mismatch,
                    "schema \$id differs from its declared identity",
                    value.span,
                ),
            )
    end
    if haskey(entries, "\$ref")
        value = entries["\$ref"].value
        if !(value.value isa FormatString) ||
           !occursin(r"^#/\$defs/[A-Za-z][A-Za-z0-9_.-]*$", value.value.value)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :unsupported_structural_schema_reference,
                    "structural schema \$ref must target one local portable \$defs entry",
                    value.span,
                ),
            )
        else
            name = split(value.value.value, '/')[3]
            name in definitions || _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :missing_structural_schema_reference,
                    "structural schema reference target $(name) does not exist",
                    value.span,
                ),
            )
        end
    end
    if haskey(entries, "type")
        value = entries["type"].value
        names = _structural_schema_type_names(value)
        if isnothing(names) || isempty(names) || length(names) != length(unique(names)) ||
           any(name -> !(name in _STRUCTURAL_SCHEMA_TYPES), names)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_type,
                    "schema type must contain unique admitted JSON type names",
                    value.span,
                ),
            )
        end
    end
    if haskey(entries, "properties")
        value = entries["properties"].value
        if !(value.value isa FormatMapping)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_properties,
                    "schema properties must be an object",
                    value.span,
                ),
            )
        else
            for property in value.value.entries
                _structural_validate_schema_node!(
                    property.value,
                    identity,
                    definitions,
                    diagnostics,
                    policy,
                    depth + 1,
                    false,
                )
            end
        end
    end
    if haskey(entries, "\$defs")
        value = entries["\$defs"].value
        if !(value.value isa FormatMapping)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_definitions,
                    "schema \$defs must be an object",
                    value.span,
                ),
            )
        else
            for definition in value.value.entries
                occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", definition.key.value.value) ||
                    _structural_push!(
                        diagnostics,
                        policy,
                        _structural_diagnostic(
                            :invalid_structural_schema_definition_name,
                            "schema definition name is not portable",
                            definition.key.span,
                        ),
                    )
                _structural_validate_schema_node!(
                    definition.value,
                    identity,
                    definitions,
                    diagnostics,
                    policy,
                    depth + 1,
                    false,
                )
            end
        end
    end
    if haskey(entries, "required")
        value = entries["required"].value
        names = value.value isa FormatSequence ? [
            child.value.value for child in value.value.elements if child.value isa FormatString
        ] : String[]
        valid = value.value isa FormatSequence &&
                length(names) == length(value.value.elements) &&
                length(names) == length(unique(names))
        valid || _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_required,
                "schema required must be an array of unique strings",
                value.span,
            ),
        )
    end
    if haskey(entries, "additionalProperties")
        value = entries["additionalProperties"].value
        if !(value.value isa FormatBoolean || value.value isa FormatMapping)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_additional_properties,
                    "additionalProperties must be a boolean or schema",
                    value.span,
                ),
            )
        elseif value.value isa FormatMapping
            _structural_validate_schema_node!(
                value,
                identity,
                definitions,
                diagnostics,
                policy,
                depth + 1,
                false,
            )
        end
    end
    for keyword in ("minProperties", "maxProperties", "minItems", "maxItems", "minLength", "maxLength")
        haskey(entries, keyword) || continue
        value = entries[keyword].value
        isnothing(_structural_nonnegative_integer(value)) && _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_limit,
                "$(keyword) must be a nonnegative bounded integer",
                value.span,
            ),
        )
    end
    for (minimum_key, maximum_key) in (
        ("minProperties", "maxProperties"),
        ("minItems", "maxItems"),
        ("minLength", "maxLength"),
    )
        haskey(entries, minimum_key) && haskey(entries, maximum_key) || continue
        minimum = _structural_nonnegative_integer(entries[minimum_key].value)
        maximum = _structural_nonnegative_integer(entries[maximum_key].value)
        (!isnothing(minimum) && !isnothing(maximum) && minimum > maximum) &&
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :contradictory_structural_schema_limits,
                    "$(minimum_key) exceeds $(maximum_key)",
                    entries[maximum_key].value.span,
                ),
            )
    end
    if haskey(entries, "dependentRequired")
        value = entries["dependentRequired"].value
        if !(value.value isa FormatMapping)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_dependencies,
                    "dependentRequired must be an object",
                    value.span,
                ),
            )
        else
            for dependency in value.value.entries
                dependency_value = dependency.value
                names = dependency_value.value isa FormatSequence ? [
                    child.value.value
                    for child in dependency_value.value.elements
                    if child.value isa FormatString
                ] : String[]
                valid = dependency_value.value isa FormatSequence &&
                        length(names) == length(dependency_value.value.elements) &&
                        length(names) == length(unique(names))
                valid || _structural_push!(
                    diagnostics,
                    policy,
                    _structural_diagnostic(
                        :invalid_structural_schema_dependencies,
                        "dependentRequired values must be arrays of unique strings",
                        dependency_value.span,
                    ),
                )
            end
        end
    end
    if haskey(entries, "items")
        value = entries["items"].value
        if !(value.value isa FormatBoolean || value.value isa FormatMapping)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_items,
                    "items must be a boolean or schema",
                    value.span,
                ),
            )
        else
            _structural_validate_schema_node!(
                value,
                identity,
                definitions,
                diagnostics,
                policy,
                depth + 1,
                false,
            )
        end
    end
    if haskey(entries, "prefixItems")
        value = entries["prefixItems"].value
        schemas = _structural_schema_list(
            value,
            :invalid_structural_schema_items,
            "prefixItems",
            diagnostics,
            policy,
        )
        if !isnothing(schemas)
            for schema in schemas
                _structural_validate_schema_node!(
                    schema,
                    identity,
                    definitions,
                    diagnostics,
                    policy,
                    depth + 1,
                    false,
                )
            end
        end
    end
    if haskey(entries, "uniqueItems") &&
       !(entries["uniqueItems"].value.value isa FormatBoolean)
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_items,
                "uniqueItems must be a boolean",
                entries["uniqueItems"].value.span,
            ),
        )
    end
    for keyword in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum")
        haskey(entries, keyword) || continue
        isnothing(_structural_numeric_components(entries[keyword].value.value)) &&
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_numeric_bound,
                    "$(keyword) must be an exact finite number",
                    entries[keyword].value.span,
                ),
            )
    end
    for (minimum_key, minimum_inclusive) in (
        ("minimum", true),
        ("exclusiveMinimum", false),
    ), (maximum_key, maximum_inclusive) in (
        ("maximum", true),
        ("exclusiveMaximum", false),
    )
        haskey(entries, minimum_key) && haskey(entries, maximum_key) || continue
        comparison = _structural_compare_numbers(
            entries[minimum_key].value.value,
            entries[maximum_key].value.value,
        )
        contradictory = !isnothing(comparison) &&
                        (comparison > 0 ||
                         (iszero(comparison) && !(minimum_inclusive && maximum_inclusive)))
        contradictory && _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :contradictory_structural_schema_limits,
                "$(minimum_key) is incompatible with $(maximum_key)",
                entries[maximum_key].value.span,
            ),
        )
    end
    if haskey(entries, "enum")
        value = entries["enum"].value
        if !(value.value isa FormatSequence) || isempty(value.value.elements)
            _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :invalid_structural_schema_enum,
                    "enum must be a nonempty array",
                    value.span,
                ),
            )
        else
            keys = [_structural_semantic_key(child.value) for child in value.value.elements]
            length(keys) == length(unique(keys)) || _structural_push!(
                diagnostics,
                policy,
                _structural_diagnostic(
                    :duplicate_structural_schema_enum,
                    "enum contains semantically duplicate values",
                    value.span,
                ),
            )
        end
    end
    for keyword in ("allOf", "anyOf", "oneOf")
        haskey(entries, keyword) || continue
        value = entries[keyword].value
        schemas = _structural_schema_list(
            value,
            :invalid_structural_schema_composition,
            keyword,
            diagnostics,
            policy,
        )
        if !isnothing(schemas)
            for schema in schemas
                _structural_validate_schema_node!(
                    schema,
                    identity,
                    definitions,
                    diagnostics,
                    policy,
                    depth + 1,
                    false,
                )
            end
        end
    end
    for keyword in ("not", "if", "then", "else")
        haskey(entries, keyword) || continue
        _structural_validate_schema_node!(
            entries[keyword].value,
            identity,
            definitions,
            diagnostics,
            policy,
            depth + 1,
            false,
        )
    end
    (haskey(entries, "then") || haskey(entries, "else")) && !haskey(entries, "if") &&
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :orphan_structural_schema_branch,
                "then or else requires if in the same schema",
                node.span,
            ),
        )
    for keyword in _STRUCTURAL_SCHEMA_ANNOTATION_STRINGS
        haskey(entries, keyword) || continue
        entries[keyword].value.value isa FormatString || _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_annotation,
                "$(keyword) annotation must be a string",
                entries[keyword].value.span,
            ),
        )
    end
    for keyword in _STRUCTURAL_SCHEMA_ANNOTATION_BOOLEANS
        haskey(entries, keyword) || continue
        entries[keyword].value.value isa FormatBoolean || _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_annotation,
                "$(keyword) annotation must be a boolean",
                entries[keyword].value.span,
            ),
        )
    end
    if haskey(entries, "examples") &&
       !(entries["examples"].value.value isa FormatSequence)
        _structural_push!(
            diagnostics,
            policy,
            _structural_diagnostic(
                :invalid_structural_schema_annotation,
                "examples annotation must be an array",
                entries["examples"].value.span,
            ),
        )
    end
    return nothing
end

function _structural_definitions(root::FormatNode)
    definitions_entry = _structural_entry(root, "\$defs")
    isnothing(definitions_entry) && return Set{String}()
    value = definitions_entry.value.value
    value isa FormatMapping || return Set{String}()
    return Set(entry.key.value.value for entry in value.entries)
end

function _structural_lock_diagnostics(
    identity::StructuralSchemaIdentity,
    digest::String,
    lock::FormatLockDocument,
    span::SourceSpan,
)
    diagnostics = FormatDiagnostic[]
    if lock.family != LockSchema
        push!(diagnostics, _structural_diagnostic(
            :structural_schema_lock_family_mismatch,
            "structural schema requires a schema-family lock",
            span,
        ))
        return diagnostics
    end
    entry_index = findfirst(entry -> entry.id == identity.id, lock.entries)
    if isnothing(entry_index)
        push!(diagnostics, _structural_diagnostic(
            :structural_schema_lock_missing,
            "structural schema identity is absent from its lock",
            span,
        ))
        return diagnostics
    end
    entry = lock.entries[entry_index]
    entry.version == identity.version || push!(diagnostics, _structural_diagnostic(
        :structural_schema_lock_version_mismatch,
        "structural schema version differs from its lock",
        span,
    ))
    entry.source == identity.uri || push!(diagnostics, _structural_diagnostic(
        :structural_schema_lock_uri_mismatch,
        "structural schema URI differs from its lock source",
        span,
    ))
    entry.sha256 == digest || push!(diagnostics, _structural_diagnostic(
        :structural_schema_lock_hash_mismatch,
        "structural schema canonical SHA-256 differs from its lock",
        span,
    ))
    return diagnostics
end

"""Compile and strictly check an admitted structural schema without resolving external data."""
function compile_structural_schema(
    document::ParsedFormatDocument,
    identity::StructuralSchemaIdentity;
    lock::Union{Nothing,FormatLockDocument} = nothing,
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    limit_diagnostics = validate_format_tree(document.root, policy)
    isempty(limit_diagnostics) ||
        return StructuralSchemaCompileResult(nothing, limit_diagnostics)
    digest_result = canonical_json_sha256(document.root; policy)
    format_succeeded(digest_result) ||
        return StructuralSchemaCompileResult(nothing, collect(digest_result.diagnostics))
    diagnostics = FormatDiagnostic[]
    definitions = _structural_definitions(document.root)
    _structural_validate_schema_node!(
        document.root,
        identity,
        definitions,
        diagnostics,
        policy,
        1,
        true,
    )
    if !isnothing(lock)
        append!(
            diagnostics,
            _structural_lock_diagnostics(
                identity,
                digest_result.value,
                lock,
                document.root.span,
            ),
        )
    end
    isempty(diagnostics) || return StructuralSchemaCompileResult(nothing, diagnostics)
    return StructuralSchemaCompileResult(StructuralSchema(
        identity,
        document.source,
        document.root,
        digest_result.value,
        Val(:compiled_structural_schema),
    ))
end

function compile_structural_schema(
    text::AbstractString,
    identity::StructuralSchemaIdentity;
    source_name::AbstractString = "<schema>",
    lock::Union{Nothing,FormatLockDocument} = nothing,
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    parsed = parse_json(text; source_name, policy)
    format_succeeded(parsed) ||
        return StructuralSchemaCompileResult(nothing, collect(parsed.diagnostics))
    return compile_structural_schema(parsed.value, identity; lock, policy)
end

mutable struct _StructuralValidationState
    schema::StructuralSchema
    policy::FormatInputPolicy
    diagnostics::Vector{FormatDiagnostic}
    evaluated_nodes::Int
    active_references::Set{Tuple{String,String}}
    remaining_evaluations::Base.RefValue{Int}
    evaluation_exhausted::Base.RefValue{Bool}
end

function _structural_instance_path(path::Vector{Union{String,Int}})
    isempty(path) && return "\$"
    output = IOBuffer()
    print(output, '\$')
    for segment in path
        if segment isa String
            print(output, '.', segment)
        else
            print(output, '[', segment, ']')
        end
    end
    return String(take!(output))
end

function _structural_validation_error!(
    state::_StructuralValidationState,
    code::Symbol,
    message::String,
    node::FormatNode,
    path::Vector{Union{String,Int}},
)
    length(state.diagnostics) < state.policy.max_diagnostics || return
    push!(state.diagnostics, _structural_diagnostic(
        code,
        "$(_structural_instance_path(path)): $(message)",
        node.span,
    ))
end

function _structural_type_matches(name::String, value::FormatValue)
    name == "null" && return value isa FormatNull
    name == "boolean" && return value isa FormatBoolean
    if name == "integer"
        value isa FormatInteger && return true
        value isa FormatDecimal || return false
        coefficient, exponent = _structural_numeric_components(value)
        return iszero(coefficient) || exponent >= 0
    end
    name == "number" && return value isa FormatInteger || value isa FormatDecimal
    name == "string" && return value isa FormatString
    name == "array" && return value isa FormatSequence
    name == "object" && return value isa FormatMapping
    return false
end

function _structural_resolve_reference(schema::StructuralSchema, reference::String)
    name = split(reference, '/')[3]
    definitions = _structural_entry(schema.root, "\$defs")
    isnothing(definitions) && return nothing
    definitions.value.value isa FormatMapping || return nothing
    for entry in definitions.value.value.entries
        entry.key.value.value == name && return entry.value
    end
    return nothing
end

function _structural_branch_diagnostics(
    state::_StructuralValidationState,
    schema_node::FormatNode,
    instance::FormatNode,
    path::Vector{Union{String,Int}},
    depth::Int,
)
    branch_state = _StructuralValidationState(
        state.schema,
        state.policy,
        FormatDiagnostic[],
        0,
        copy(state.active_references),
        state.remaining_evaluations,
        state.evaluation_exhausted,
    )
    _structural_evaluate!(branch_state, schema_node, instance, copy(path), depth)
    return branch_state
end

function _structural_evaluate_object!(
    state::_StructuralValidationState,
    entries::Dict{String,FormatMappingEntry},
    instance::FormatNode,
    path::Vector{Union{String,Int}},
    depth::Int,
)
    instance.value isa FormatMapping || return
    instance_entries = Dict{String,FormatMappingEntry}(
        entry.key.value.value => entry for entry in instance.value.entries
    )
    if haskey(entries, "minProperties")
        minimum = _structural_nonnegative_integer(entries["minProperties"].value)
        length(instance_entries) >= minimum || _structural_validation_error!(
            state,
            :structural_property_count,
            "object contains fewer than $(minimum) properties",
            instance,
            path,
        )
    end
    if haskey(entries, "maxProperties")
        maximum = _structural_nonnegative_integer(entries["maxProperties"].value)
        length(instance_entries) <= maximum || _structural_validation_error!(
            state,
            :structural_property_count,
            "object contains more than $(maximum) properties",
            instance,
            path,
        )
    end
    if haskey(entries, "required")
        for child in entries["required"].value.value.elements
            name = child.value.value
            haskey(instance_entries, name) || _structural_validation_error!(
                state,
                :structural_required_property_missing,
                "required property $(name) is missing",
                instance,
                path,
            )
        end
    end
    properties = haskey(entries, "properties") ?
        _structural_mapping(entries["properties"].value) : Dict{String,FormatMappingEntry}()
    for (name, property) in instance_entries
        if haskey(properties, name)
            push!(path, name)
            _structural_evaluate!(state, properties[name].value, property.value, path, depth + 1)
            pop!(path)
        elseif haskey(entries, "additionalProperties")
            additional = entries["additionalProperties"].value
            if additional.value isa FormatBoolean
                additional.value.value || begin
                    push!(path, name)
                    _structural_validation_error!(
                        state,
                        :structural_additional_property,
                        "additional property is prohibited",
                        property.value,
                        path,
                    )
                    pop!(path)
                end
            else
                push!(path, name)
                _structural_evaluate!(state, additional, property.value, path, depth + 1)
                pop!(path)
            end
        end
    end
    if haskey(entries, "dependentRequired")
        dependencies = _structural_mapping(entries["dependentRequired"].value)
        for (trigger, dependency) in dependencies
            haskey(instance_entries, trigger) || continue
            for child in dependency.value.value.elements
                required_name = child.value.value
                haskey(instance_entries, required_name) || _structural_validation_error!(
                    state,
                    :structural_dependent_property_missing,
                    "property $(trigger) requires property $(required_name)",
                    instance,
                    path,
                )
            end
        end
    end
end

function _structural_evaluate_array!(
    state::_StructuralValidationState,
    entries::Dict{String,FormatMappingEntry},
    instance::FormatNode,
    path::Vector{Union{String,Int}},
    depth::Int,
)
    instance.value isa FormatSequence || return
    elements = instance.value.elements
    if haskey(entries, "minItems")
        minimum = _structural_nonnegative_integer(entries["minItems"].value)
        length(elements) >= minimum || _structural_validation_error!(
            state,
            :structural_item_count,
            "array contains fewer than $(minimum) items",
            instance,
            path,
        )
    end
    if haskey(entries, "maxItems")
        maximum = _structural_nonnegative_integer(entries["maxItems"].value)
        length(elements) <= maximum || _structural_validation_error!(
            state,
            :structural_item_count,
            "array contains more than $(maximum) items",
            instance,
            path,
        )
    end
    if haskey(entries, "uniqueItems") && entries["uniqueItems"].value.value.value
        seen = Set{String}()
        for (index, element) in enumerate(elements)
            key = _structural_semantic_key(element.value)
            if key in seen
                push!(path, index)
                _structural_validation_error!(
                    state,
                    :structural_duplicate_item,
                    "array item is not unique",
                    element,
                    path,
                )
                pop!(path)
            end
            push!(seen, key)
        end
    end
    prefix = haskey(entries, "prefixItems") ?
        entries["prefixItems"].value.value.elements : FormatNode[]
    for (index, schema_node) in enumerate(prefix)
        index <= length(elements) || break
        push!(path, index)
        _structural_evaluate!(state, schema_node, elements[index], path, depth + 1)
        pop!(path)
    end
    if haskey(entries, "items")
        item_schema = entries["items"].value
        for index in (length(prefix) + 1):length(elements)
            if item_schema.value isa FormatBoolean && !item_schema.value.value
                push!(path, index)
                _structural_validation_error!(
                    state,
                    :structural_additional_item,
                    "additional array item is prohibited",
                    elements[index],
                    path,
                )
                pop!(path)
            elseif !(item_schema.value isa FormatBoolean)
                push!(path, index)
                _structural_evaluate!(state, item_schema, elements[index], path, depth + 1)
                pop!(path)
            end
        end
    end
end

function _structural_evaluate_scalar!(
    state::_StructuralValidationState,
    entries::Dict{String,FormatMappingEntry},
    instance::FormatNode,
    path::Vector{Union{String,Int}},
)
    if instance.value isa FormatString
        length_value = length(instance.value.value)
        if haskey(entries, "minLength")
            minimum = _structural_nonnegative_integer(entries["minLength"].value)
            length_value >= minimum || _structural_validation_error!(
                state,
                :structural_string_length,
                "string is shorter than $(minimum) Unicode scalars",
                instance,
                path,
            )
        end
        if haskey(entries, "maxLength")
            maximum = _structural_nonnegative_integer(entries["maxLength"].value)
            length_value <= maximum || _structural_validation_error!(
                state,
                :structural_string_length,
                "string is longer than $(maximum) Unicode scalars",
                instance,
                path,
            )
        end
    end
    isnothing(_structural_numeric_components(instance.value)) && return
    for (keyword, relation, inclusive) in (
        ("minimum", :minimum, true),
        ("exclusiveMinimum", :minimum, false),
        ("maximum", :maximum, true),
        ("exclusiveMaximum", :maximum, false),
    )
        haskey(entries, keyword) || continue
        comparison = _structural_compare_numbers(
            instance.value,
            entries[keyword].value.value,
        )
        accepted = relation == :minimum ?
            (inclusive ? comparison >= 0 : comparison > 0) :
            (inclusive ? comparison <= 0 : comparison < 0)
        accepted || _structural_validation_error!(
            state,
            :structural_numeric_bound,
            "number violates $(keyword)",
            instance,
            path,
        )
    end
end

function _structural_evaluate_composition!(
    state::_StructuralValidationState,
    entries::Dict{String,FormatMappingEntry},
    instance::FormatNode,
    path::Vector{Union{String,Int}},
    depth::Int,
)
    if haskey(entries, "allOf")
        for child in entries["allOf"].value.value.elements
            _structural_evaluate!(state, child, instance, path, depth + 1)
        end
    end
    for (keyword, required_matches) in (("anyOf", :at_least_one), ("oneOf", :exactly_one))
        haskey(entries, keyword) || continue
        matches = 0
        for child in entries[keyword].value.value.elements
            branch = _structural_branch_diagnostics(state, child, instance, path, depth + 1)
            state.evaluated_nodes += branch.evaluated_nodes
            isempty(branch.diagnostics) && (matches += 1)
        end
        accepted = required_matches == :at_least_one ? matches >= 1 : matches == 1
        accepted || _structural_validation_error!(
            state,
            :structural_composition_mismatch,
            "$(keyword) matched $(matches) branches",
            instance,
            path,
        )
    end
    if haskey(entries, "not")
        branch = _structural_branch_diagnostics(
            state,
            entries["not"].value,
            instance,
            path,
            depth + 1,
        )
        state.evaluated_nodes += branch.evaluated_nodes
        !isempty(branch.diagnostics) || _structural_validation_error!(
            state,
            :structural_not_mismatch,
            "instance matches a prohibited schema",
            instance,
            path,
        )
    end
    if haskey(entries, "if")
        condition = _structural_branch_diagnostics(
            state,
            entries["if"].value,
            instance,
            path,
            depth + 1,
        )
        state.evaluated_nodes += condition.evaluated_nodes
        selected = isempty(condition.diagnostics) ? "then" : "else"
        haskey(entries, selected) && _structural_evaluate!(
            state,
            entries[selected].value,
            instance,
            path,
            depth + 1,
        )
    end
end

function _structural_evaluate!(
    state::_StructuralValidationState,
    schema_node::FormatNode,
    instance::FormatNode,
    path::Vector{Union{String,Int}},
    depth::Int,
)
    length(state.diagnostics) >= state.policy.max_diagnostics && return
    if state.remaining_evaluations[] <= 0
        state.evaluation_exhausted[] = true
        return
    end
    state.remaining_evaluations[] -= 1
    state.evaluated_nodes += 1
    if depth > state.policy.max_nesting_depth
        _structural_validation_error!(
            state,
            :structural_validation_too_deep,
            "schema evaluation exceeds the configured nesting depth",
            instance,
            path,
        )
        return
    end
    if schema_node.value isa FormatBoolean
        schema_node.value.value || _structural_validation_error!(
            state,
            :structural_false_schema,
            "instance is rejected by a false schema",
            instance,
            path,
        )
        return
    end
    entries = _structural_mapping(schema_node)
    if haskey(entries, "\$ref")
        reference = entries["\$ref"].value.value.value
        key = (reference, _structural_instance_path(path))
        if key in state.active_references
            _structural_validation_error!(
                state,
                :structural_reference_cycle,
                "schema reference cycle does not advance the instance path",
                instance,
                path,
            )
        else
            referenced = _structural_resolve_reference(state.schema, reference)
            push!(state.active_references, key)
            _structural_evaluate!(state, referenced, instance, path, depth + 1)
            delete!(state.active_references, key)
        end
    end
    if haskey(entries, "type")
        names = _structural_schema_type_names(entries["type"].value)
        any(name -> _structural_type_matches(name, instance.value), names) || begin
            _structural_validation_error!(
                state,
                :structural_type_mismatch,
                "value does not match declared type",
                instance,
                path,
            )
            return
        end
    end
    if haskey(entries, "const") &&
       !_structural_semantic_equal(instance.value, entries["const"].value.value)
        _structural_validation_error!(
            state,
            :structural_const_mismatch,
            "value differs from const",
            instance,
            path,
        )
    end
    if haskey(entries, "enum") && !any(
        child -> _structural_semantic_equal(instance.value, child.value),
        entries["enum"].value.value.elements,
    )
        _structural_validation_error!(
            state,
            :structural_enum_mismatch,
            "value is absent from enum",
            instance,
            path,
        )
    end
    _structural_evaluate_object!(state, entries, instance, path, depth)
    _structural_evaluate_array!(state, entries, instance, path, depth)
    _structural_evaluate_scalar!(state, entries, instance, path)
    _structural_evaluate_composition!(state, entries, instance, path, depth)
    return nothing
end

"""Inspectable structural-validation counts and exact input identity."""
struct StructuralValidationReport
    schema_identity::StructuralSchemaIdentity
    document_sha256::String
    evaluated_nodes::Int
    valid::Bool
end

Base.:(==)(left::StructuralValidationReport, right::StructuralValidationReport) =
    left.schema_identity == right.schema_identity &&
    left.document_sha256 == right.document_sha256 &&
    left.evaluated_nodes == right.evaluated_nodes &&
    left.valid == right.valid

"""Typed result returned by structural schema validation."""
const StructuralValidationResult = FormatResult{StructuralValidationReport}

"""Validate one public format document against a compiled structural schema."""
function validate_structural_document(
    schema::StructuralSchema,
    document::ParsedFormatDocument;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    limit_diagnostics = validate_format_tree(document.root, policy)
    digest_result = canonical_json_sha256(document.root; policy)
    if !isempty(limit_diagnostics) || !format_succeeded(digest_result)
        diagnostics = vcat(
            limit_diagnostics,
            format_succeeded(digest_result) ? FormatDiagnostic[] :
                collect(digest_result.diagnostics),
        )
        return StructuralValidationResult(nothing, diagnostics)
    end
    state = _StructuralValidationState(
        schema,
        policy,
        FormatDiagnostic[],
        0,
        Set{Tuple{String,String}}(),
        Ref(policy.max_collection_items),
        Ref(false),
    )
    _structural_evaluate!(
        state,
        schema.root,
        document.root,
        Union{String,Int}[],
        1,
    )
    if state.evaluation_exhausted[]
        _structural_push!(
            state.diagnostics,
            policy,
            _structural_diagnostic(
                :structural_validation_too_large,
                "structural validation exceeds the configured evaluation budget",
                document.root.span,
            ),
        )
    end
    report = StructuralValidationReport(
        schema.identity,
        digest_result.value,
        policy.max_collection_items - state.remaining_evaluations[],
        isempty(state.diagnostics),
    )
    return StructuralValidationResult(report, state.diagnostics)
end
