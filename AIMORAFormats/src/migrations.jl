"""One typed segment in a source/result format-tree path."""
abstract type FormatPathSegment end

"""A Unicode mapping-key segment in a format-tree path."""
struct FormatMappingKeySegment <: FormatPathSegment
    key::String

    function FormatMappingKeySegment(key::AbstractString)
        normalized_key = String(key)
        isempty(normalized_key) && throw(ArgumentError("format path key must not be empty"))
        isvalid(normalized_key) || throw(ArgumentError("format path key is not valid Unicode"))
        occursin('\0', normalized_key) &&
            throw(ArgumentError("format path key must not contain NUL"))
        return new(normalized_key)
    end
end

Base.:(==)(left::FormatMappingKeySegment, right::FormatMappingKeySegment) =
    left.key == right.key
Base.hash(segment::FormatMappingKeySegment, seed::UInt) = hash(segment.key, seed)

"""A one-based sequence-index segment in a format-tree path."""
struct FormatSequenceIndexSegment <: FormatPathSegment
    index::Int

    function FormatSequenceIndexSegment(index::Integer)
        index > 0 || throw(ArgumentError("format path index must be positive"))
        index <= typemax(Int) || throw(OverflowError("format path index exceeds Int"))
        return new(Int(index))
    end
end

Base.:(==)(left::FormatSequenceIndexSegment, right::FormatSequenceIndexSegment) =
    left.index == right.index
Base.hash(segment::FormatSequenceIndexSegment, seed::UInt) = hash(segment.index, seed)

"""An immutable root-relative path through mapping values and sequence elements."""
struct FormatPath
    segments::FormatItemList{FormatPathSegment}

    function FormatPath(
        segments::AbstractVector{<:FormatPathSegment},
        ::Val{:validated_format_path},
    )
        all(
            segment -> segment isa FormatMappingKeySegment ||
                       segment isa FormatSequenceIndexSegment,
            segments,
        ) || throw(ArgumentError("format path contains an unsupported segment type"))
        return new(FormatItemList{FormatPathSegment}(collect(segments)))
    end
end

function FormatPath(segments...)
    converted = FormatPathSegment[]
    for segment in segments
        if segment isa FormatPathSegment
            if segment isa FormatMappingKeySegment ||
               segment isa FormatSequenceIndexSegment
                push!(converted, segment)
            else
                throw(ArgumentError("format path contains an unsupported segment type"))
            end
        elseif segment isa AbstractString
            push!(converted, FormatMappingKeySegment(segment))
        elseif segment isa Integer
            push!(converted, FormatSequenceIndexSegment(segment))
        else
            throw(ArgumentError("format path segments must be strings, integers, or typed segments"))
        end
    end
    return FormatPath(converted, Val(:validated_format_path))
end

Base.:(==)(left::FormatPath, right::FormatPath) = left.segments == right.segments
Base.hash(path::FormatPath, seed::UInt) =
    foldl((current_seed, segment) -> hash(segment, current_seed), path.segments; init = seed)

function Base.show(io::IO, path::FormatPath)
    print(io, '\$')
    for segment in path.segments
        if segment isa FormatMappingKeySegment
            if occursin(r"^[A-Za-z_][A-Za-z0-9_-]*$", segment.key)
                print(io, '.', segment.key)
            else
                print(io, '[')
                show(io, segment.key)
                print(io, ']')
            end
        else
            print(io, '[', segment.index, ']')
        end
    end
end

function _migration_path_text(path::FormatPath)
    return sprint(show, path)
end

function _migration_path_tuple(path::FormatPath)
    return Tuple(
        segment isa FormatMappingKeySegment ? segment.key : segment.index
        for segment in path.segments
    )
end

function _migration_path_from_tuple(path::Tuple)
    return FormatPath(path...)
end

function _migration_path_prefix(prefix::FormatPath, path::FormatPath)
    length(prefix.segments) <= length(path.segments) || return false
    return all(prefix.segments[index] == path.segments[index] for index in eachindex(prefix.segments))
end

"""Closed declarative operation family admitted in a format migration step."""
abstract type MigrationOperation end

"""Require an exact semantic value before later migration operations run."""
struct MigrationAssertValue <: MigrationOperation
    path::FormatPath
    expected::FormatValue
end

Base.:(==)(left::MigrationAssertValue, right::MigrationAssertValue) =
    left.path == right.path && left.expected == right.expected

"""Rename one mapping key while preserving its value and source span."""
struct MigrationRenameKey <: MigrationOperation
    parent::FormatPath
    from_key::String
    to_key::String

    function MigrationRenameKey(
        parent::FormatPath,
        from_key::AbstractString,
        to_key::AbstractString,
    )
        source = FormatMappingKeySegment(from_key).key
        target = FormatMappingKeySegment(to_key).key
        source == target && throw(ArgumentError("migration rename must change the key"))
        return new(parent, source, target)
    end
end


Base.:(==)(left::MigrationRenameKey, right::MigrationRenameKey) =
    left.parent == right.parent &&
    left.from_key == right.from_key &&
    left.to_key == right.to_key

"""Move one existing value to an absent mapping-key destination."""
struct MigrationMoveValue <: MigrationOperation
    source::FormatPath
    destination::FormatPath

    function MigrationMoveValue(source::FormatPath, destination::FormatPath)
        isempty(source.segments) && throw(ArgumentError("migration cannot move the root"))
        isempty(destination.segments) &&
            throw(ArgumentError("migration move destination cannot be the root"))
        last(destination.segments) isa FormatMappingKeySegment ||
            throw(ArgumentError("migration move destination must end in a mapping key"))
        _migration_path_prefix(source, destination) &&
            throw(ArgumentError("migration cannot move a value into its own subtree"))
        source == destination && throw(ArgumentError("migration move must change the path"))
        return new(source, destination)
    end
end


Base.:(==)(left::MigrationMoveValue, right::MigrationMoveValue) =
    left.source == right.source && left.destination == right.destination

"""Update one exact string schema-version field using its migration-step endpoints."""
struct MigrationSetSchemaVersion <: MigrationOperation
    path::FormatPath

    function MigrationSetSchemaVersion(path::FormatPath)
        isempty(path.segments) &&
            throw(ArgumentError("schema version path cannot be the document root"))
        last(path.segments) isa FormatMappingKeySegment ||
            throw(ArgumentError("schema version path must end in a mapping key"))
        return new(path)
    end
end

Base.:(==)(left::MigrationSetSchemaVersion, right::MigrationSetSchemaVersion) =
    left.path == right.path

"""Mandatory, inspectable accounting for one deliberately removed value."""
struct MigrationLoss
    id::String
    path::FormatPath
    description::String
    consequence::String

    function MigrationLoss(
        id::AbstractString,
        path::FormatPath,
        description::AbstractString,
        consequence::AbstractString,
    )
        normalized_id = String(id)
        occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", normalized_id) ||
            throw(ArgumentError("migration loss ID is not portable"))
        normalized_description = String(description)
        normalized_consequence = String(consequence)
        for (label, value) in (
            ("description", normalized_description),
            ("consequence", normalized_consequence),
        )
            isempty(value) && throw(ArgumentError("migration loss $(label) must not be empty"))
            occursin(r"[\r\n\0]", value) &&
                throw(ArgumentError("migration loss $(label) contains a prohibited character"))
        end
        isempty(path.segments) && throw(ArgumentError("migration cannot account for removing the root"))
        return new(normalized_id, path, normalized_description, normalized_consequence)
    end
end


Base.:(==)(left::MigrationLoss, right::MigrationLoss) =
    left.id == right.id &&
    left.path == right.path &&
    left.description == right.description &&
    left.consequence == right.consequence

"""Remove one existing value only with exact loss accounting."""
struct MigrationRemoveValue <: MigrationOperation
    path::FormatPath
    loss::MigrationLoss

    function MigrationRemoveValue(path::FormatPath, loss::MigrationLoss)
        path == loss.path || throw(ArgumentError("migration removal path differs from its loss record"))
        return new(path, loss)
    end
end

Base.:(==)(left::MigrationRemoveValue, right::MigrationRemoveValue) =
    left.path == right.path && left.loss == right.loss

@enum MigrationDirection::UInt8 begin
    MigrationUpgrade = 0x01
    MigrationDowngrade = 0x02
end

function _migration_operations(
    operations::AbstractVector{<:MigrationOperation},
    label::String,
)
    copied = MigrationOperation[operations...]
    isempty(copied) && throw(ArgumentError("migration $(label) operations must not be empty"))
    all(
        operation -> operation isa MigrationAssertValue ||
                     operation isa MigrationRenameKey ||
                     operation isa MigrationMoveValue ||
                     operation isa MigrationSetSchemaVersion ||
                     operation isa MigrationRemoveValue,
        copied,
    ) || throw(ArgumentError("migration $(label) contains an unsupported operation type"))
    count(operation -> operation isa MigrationSetSchemaVersion, copied) == 1 ||
        throw(ArgumentError("migration $(label) requires exactly one schema-version operation"))
    return copied
end

"""One immutable, provenance-bearing upgrade and its optional explicit inverse."""
struct MigrationStep
    id::String
    schema_id::String
    from_version::VersionNumber
    to_version::VersionNumber
    operations::FormatItemList{MigrationOperation}
    inverse_operations::Union{Nothing,FormatItemList{MigrationOperation}}
    provenance::String

    function MigrationStep(
        id::AbstractString,
        schema_id::AbstractString,
        from_version::VersionNumber,
        to_version::VersionNumber,
        operations::AbstractVector{<:MigrationOperation};
        inverse_operations::Union{Nothing,AbstractVector{<:MigrationOperation}} = nothing,
        provenance::AbstractString,
    )
        normalized_id = String(id)
        occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", normalized_id) ||
            throw(ArgumentError("migration step ID is not portable"))
        normalized_schema_id = String(schema_id)
        _structural_schema_name_valid(normalized_schema_id) ||
            throw(ArgumentError("migration schema ID is not portable"))
        from_version < to_version ||
            throw(ArgumentError("migration steps must advance semantic version order"))
        forward = _migration_operations(operations, "forward")
        inverse = isnothing(inverse_operations) ? nothing :
            _migration_operations(inverse_operations, "inverse")
        if !isnothing(inverse) && any(
            operation -> operation isa MigrationRemoveValue,
            vcat(forward, inverse),
        )
            throw(ArgumentError("a migration with an explicit inverse must be lossless"))
        end
        loss_ids = String[
            operation.loss.id for operation in forward if operation isa MigrationRemoveValue
        ]
        length(loss_ids) == length(unique(loss_ids)) ||
            throw(ArgumentError("migration step contains duplicate loss IDs"))
        normalized_provenance = String(provenance)
        isempty(normalized_provenance) &&
            throw(ArgumentError("migration provenance must not be empty"))
        occursin(r"[\r\n\0]", normalized_provenance) &&
            throw(ArgumentError("migration provenance contains a prohibited character"))
        return new(
            normalized_id,
            normalized_schema_id,
            from_version,
            to_version,
            FormatItemList{MigrationOperation}(forward),
            isnothing(inverse) ? nothing : FormatItemList{MigrationOperation}(inverse),
            normalized_provenance,
        )
    end
end

Base.:(==)(left::MigrationStep, right::MigrationStep) =
    left.id == right.id &&
    left.schema_id == right.schema_id &&
    left.from_version == right.from_version &&
    left.to_version == right.to_version &&
    left.operations == right.operations &&
    left.inverse_operations == right.inverse_operations &&
    left.provenance == right.provenance

function _migration_adjacency(steps::AbstractVector{MigrationStep})
    adjacency = Dict{VersionNumber,Vector{MigrationStep}}()
    for step in steps
        push!(get!(adjacency, step.from_version, MigrationStep[]), step)
    end
    for outgoing in values(adjacency)
        sort!(outgoing; by = step -> (step.to_version, step.id))
    end
    return adjacency
end

function _migration_count_paths(
    adjacency::Dict{VersionNumber,Vector{MigrationStep}},
    source::VersionNumber,
)
    counts = Dict{VersionNumber,Int}(source => 1)
    versions = sort!(collect(Set(vcat(
        VersionNumber[source],
        collect(keys(adjacency)),
        [step.to_version for outgoing in values(adjacency) for step in outgoing],
    ))))
    for version in versions
        count = get(counts, version, 0)
        iszero(count) && continue
        for step in get(adjacency, version, MigrationStep[])
            counts[step.to_version] = min(2, get(counts, step.to_version, 0) + count)
        end
    end
    return counts
end

"""A deterministic acyclic migration graph with at most one path per version pair."""
struct MigrationGraph
    schema_id::String
    steps::FormatItemList{MigrationStep}

    function MigrationGraph(
        schema_id::AbstractString,
        steps::AbstractVector{MigrationStep},
    )
        normalized_schema_id = String(schema_id)
        _structural_schema_name_valid(normalized_schema_id) ||
            throw(ArgumentError("migration graph schema ID is not portable"))
        copied_steps = sort!(collect(steps); by = step -> (
            step.from_version,
            step.to_version,
            step.id,
        ))
        all(step -> step.schema_id == normalized_schema_id, copied_steps) ||
            throw(ArgumentError("migration step schema differs from its graph"))
        ids = getfield.(copied_steps, :id)
        length(ids) == length(unique(ids)) ||
            throw(ArgumentError("migration graph contains duplicate step IDs"))
        edges = [(step.from_version, step.to_version) for step in copied_steps]
        length(edges) == length(unique(edges)) ||
            throw(ArgumentError("migration graph contains duplicate version edges"))
        loss_ids = String[
            operation.loss.id
            for step in copied_steps
            for operation in step.operations
            if operation isa MigrationRemoveValue
        ]
        length(loss_ids) == length(unique(loss_ids)) ||
            throw(ArgumentError("migration graph contains duplicate loss IDs"))
        adjacency = _migration_adjacency(copied_steps)
        versions = sort!(collect(Set(vcat(
            collect(keys(adjacency)),
            [step.to_version for step in copied_steps],
        ))))
        for source in versions
            counts = _migration_count_paths(adjacency, source)
            any(count -> count > 1, values(counts)) &&
                throw(ArgumentError("migration graph contains ambiguous paths"))
        end
        return new(normalized_schema_id, FormatItemList(copied_steps))
    end
end

Base.:(==)(left::MigrationGraph, right::MigrationGraph) =
    left.schema_id == right.schema_id && left.steps == right.steps

"""One directed use of a migration step in an exact plan."""
struct MigrationPlanStep
    step::MigrationStep
    direction::MigrationDirection
end

Base.:(==)(left::MigrationPlanStep, right::MigrationPlanStep) =
    left.step == right.step && left.direction == right.direction

"""One exact deterministic path between two schema versions."""
struct MigrationPlan
    schema_id::String
    from_version::VersionNumber
    to_version::VersionNumber
    steps::FormatItemList{MigrationPlanStep}
end

MigrationPlan(
    schema_id::AbstractString,
    from_version::VersionNumber,
    to_version::VersionNumber,
    steps::AbstractVector{MigrationPlanStep},
) = MigrationPlan(
    String(schema_id),
    from_version,
    to_version,
    FormatItemList(collect(steps)),
)

Base.:(==)(left::MigrationPlan, right::MigrationPlan) =
    left.schema_id == right.schema_id &&
    left.from_version == right.from_version &&
    left.to_version == right.to_version &&
    left.steps == right.steps

"""Typed result returned by deterministic migration planning."""
const MigrationPlanResult = FormatResult{MigrationPlan}

function _migration_failure_result(
    graph::MigrationGraph,
    from_version::VersionNumber,
    to_version::VersionNumber,
    code::Symbol,
    message::String,
)
    diagnostic = FormatDiagnostic(DiagnosticError, code, message)
    return MigrationPlanResult(nothing, [diagnostic])
end

function _migration_upgrade_steps(
    graph::MigrationGraph,
    from_version::VersionNumber,
    to_version::VersionNumber,
)
    adjacency = _migration_adjacency(collect(graph.steps))
    current = from_version
    planned = MigrationStep[]
    visited = Set{VersionNumber}()
    while current != to_version
        current in visited && return nothing
        push!(visited, current)
        candidates = MigrationStep[]
        for step in get(adjacency, current, MigrationStep[])
            step.to_version <= to_version || continue
            counts = _migration_count_paths(adjacency, step.to_version)
            get(counts, to_version, 0) == 1 && push!(candidates, step)
        end
        length(candidates) == 1 || return nothing
        selected = only(candidates)
        push!(planned, selected)
        current = selected.to_version
    end
    return planned
end

"""Plan an upgrade or only an explicitly invertible downgrade; gaps never fallback."""
function plan_migration(
    graph::MigrationGraph,
    from_version::VersionNumber,
    to_version::VersionNumber,
)
    if from_version == to_version
        return MigrationPlanResult(MigrationPlan(
            graph.schema_id,
            from_version,
            to_version,
            MigrationPlanStep[],
        ))
    elseif from_version < to_version
        steps = _migration_upgrade_steps(graph, from_version, to_version)
        isnothing(steps) && return _migration_failure_result(
            graph,
            from_version,
            to_version,
            :migration_path_missing,
            "no deterministic migration path connects the requested versions",
        )
        return MigrationPlanResult(MigrationPlan(
            graph.schema_id,
            from_version,
            to_version,
            [MigrationPlanStep(step, MigrationUpgrade) for step in steps],
        ))
    end
    forward = _migration_upgrade_steps(graph, to_version, from_version)
    isnothing(forward) && return _migration_failure_result(
        graph,
        from_version,
        to_version,
        :migration_path_missing,
        "no deterministic migration path connects the requested versions",
    )
    missing_inverse = findfirst(step -> isnothing(step.inverse_operations), forward)
    !isnothing(missing_inverse) && return _migration_failure_result(
        graph,
        from_version,
        to_version,
        :migration_inverse_missing,
        "downgrade requires an explicit inverse for step $(forward[missing_inverse].id)",
    )
    return MigrationPlanResult(MigrationPlan(
        graph.schema_id,
        from_version,
        to_version,
        [MigrationPlanStep(step, MigrationDowngrade) for step in reverse(forward)],
    ))
end

"""Exact compiled schemas, version policy, and migration graph for one schema ID."""
struct StructuralSchemaRegistry
    version_policy::SchemaVersionPolicy
    schemas::FormatItemList{StructuralSchema}
    migrations::MigrationGraph

    function StructuralSchemaRegistry(
        version_policy::SchemaVersionPolicy,
        schemas::AbstractVector{StructuralSchema},
        migrations::MigrationGraph,
    )
        copied_schemas = sort!(collect(schemas); by = schema -> schema.identity.version)
        isempty(copied_schemas) && throw(ArgumentError("structural schema registry must not be empty"))
        all(schema -> schema.identity.id == version_policy.schema_id, copied_schemas) ||
            throw(ArgumentError("registered structural schema ID differs from its policy"))
        migrations.schema_id == version_policy.schema_id ||
            throw(ArgumentError("migration graph ID differs from its schema policy"))
        versions = [schema.identity.version for schema in copied_schemas]
        length(versions) == length(unique(versions)) ||
            throw(ArgumentError("structural schema registry contains duplicate versions"))
        uris = [schema.identity.uri for schema in copied_schemas]
        length(uris) == length(unique(uris)) ||
            throw(ArgumentError("structural schema registry contains duplicate URIs"))
        version_policy.current_version in versions ||
            throw(ArgumentError("current structural schema version is not registered"))
        all(version -> version in versions, version_policy.backward_readers) ||
            throw(ArgumentError("promised backward reader schema is not registered"))
        all(
            step -> step.from_version in versions && step.to_version in versions,
            migrations.steps,
        ) || throw(ArgumentError("migration graph references an unregistered schema version"))
        return new(version_policy, FormatItemList(copied_schemas), migrations)
    end
end

Base.:(==)(left::StructuralSchemaRegistry, right::StructuralSchemaRegistry) =
    left.version_policy == right.version_policy &&
    left.schemas == right.schemas &&
    left.migrations == right.migrations

"""Resolve only an exactly registered schema version, with explicit future/past diagnostics."""
function resolve_structural_schema(
    registry::StructuralSchemaRegistry,
    version::VersionNumber,
)
    index = findfirst(schema -> schema.identity.version == version, registry.schemas)
    if !isnothing(index)
        return FormatResult(registry.schemas[index])
    end
    code = version > registry.version_policy.current_version ?
        :structural_schema_future_version : :structural_schema_version_missing
    message = version > registry.version_policy.current_version ?
        "future structural schema version is unsupported" :
        "structural schema version is not registered"
    return FormatResult{StructuralSchema}(
        nothing,
        [FormatDiagnostic(DiagnosticError, code, message)],
    )
end

function schema_compatibility(
    registry::StructuralSchemaRegistry,
    requested_version::VersionNumber,
)
    plan = requested_version < registry.version_policy.current_version ?
        plan_migration(
            registry.migrations,
            requested_version,
            registry.version_policy.current_version,
        ) : nothing
    return schema_compatibility(
        registry.version_policy,
        requested_version;
        migration_available = !isnothing(plan) && format_succeeded(plan),
    )
end

struct _MigrationFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _migration_fail(
    code::Symbol,
    message::String,
    span::SourceSpan,
)
    throw(_MigrationFailure(FormatDiagnostic(DiagnosticError, code, message, span)))
end

function _migration_node_at(root::FormatNode, path::FormatPath)
    node = root
    for segment in path.segments
        if segment isa FormatMappingKeySegment
            node.value isa FormatMapping || return nothing
            entry = findfirst(
                candidate -> candidate.key.value.value == segment.key,
                node.value.entries,
            )
            isnothing(entry) && return nothing
            node = node.value.entries[entry].value
        else
            node.value isa FormatSequence || return nothing
            1 <= segment.index <= length(node.value.elements) || return nothing
            node = node.value.elements[segment.index]
        end
    end
    return node
end

function _migration_replace_node(
    root::FormatNode,
    path::FormatPath,
    replacement::FormatNode,
)
    isempty(path.segments) && return replacement
    function replace_at(node::FormatNode, depth::Int)
        segment = path.segments[depth]
        last_segment = depth == length(path.segments)
        if segment isa FormatMappingKeySegment
            node.value isa FormatMapping || return nothing
            entries = collect(node.value.entries)
            index = findfirst(entry -> entry.key.value.value == segment.key, entries)
            isnothing(index) && return nothing
            child = last_segment ? replacement : replace_at(entries[index].value, depth + 1)
            isnothing(child) && return nothing
            entries[index] = FormatMappingEntry(entries[index].key, child)
            return FormatNode(FormatMapping(entries), node.span)
        end
        node.value isa FormatSequence || return nothing
        1 <= segment.index <= length(node.value.elements) || return nothing
        elements = collect(node.value.elements)
        child = last_segment ? replacement : replace_at(elements[segment.index], depth + 1)
        isnothing(child) && return nothing
        elements[segment.index] = child
        return FormatNode(FormatSequence(elements), node.span)
    end
    return replace_at(root, 1)
end

function _migration_remove_node(root::FormatNode, path::FormatPath)
    isempty(path.segments) && return nothing
    parent = FormatPath(collect(path.segments[1:(end - 1)]), Val(:validated_format_path))
    parent_node = _migration_node_at(root, parent)
    isnothing(parent_node) && return nothing
    last_segment = last(path.segments)
    replacement = if last_segment isa FormatMappingKeySegment
        parent_node.value isa FormatMapping || return nothing
        entries = collect(parent_node.value.entries)
        index = findfirst(entry -> entry.key.value.value == last_segment.key, entries)
        isnothing(index) && return nothing
        deleteat!(entries, index)
        FormatNode(FormatMapping(entries), parent_node.span)
    else
        parent_node.value isa FormatSequence || return nothing
        1 <= last_segment.index <= length(parent_node.value.elements) || return nothing
        elements = collect(parent_node.value.elements)
        deleteat!(elements, last_segment.index)
        FormatNode(FormatSequence(elements), parent_node.span)
    end
    return _migration_replace_node(root, parent, replacement)
end

function _migration_insert_mapping_value(
    root::FormatNode,
    path::FormatPath,
    value::FormatNode,
)
    parent = FormatPath(collect(path.segments[1:(end - 1)]), Val(:validated_format_path))
    parent_node = _migration_node_at(root, parent)
    isnothing(parent_node) && return nothing
    parent_node.value isa FormatMapping || return nothing
    key = last(path.segments)
    key isa FormatMappingKeySegment || return nothing
    any(entry -> entry.key.value.value == key.key, parent_node.value.entries) && return nothing
    entries = collect(parent_node.value.entries)
    push!(entries, FormatMappingEntry(
        FormatNode(FormatString(key.key), value.span),
        value,
    ))
    replacement = FormatNode(FormatMapping(entries), parent_node.span)
    return _migration_replace_node(root, parent, replacement)
end

function _migration_rename_key(
    root::FormatNode,
    operation::MigrationRenameKey,
)
    parent = _migration_node_at(root, operation.parent)
    isnothing(parent) && _migration_fail(
        :migration_path_missing,
        "migration rename parent $(_migration_path_text(operation.parent)) does not exist",
        root.span,
    )
    parent.value isa FormatMapping || _migration_fail(
        :migration_path_kind_mismatch,
        "migration rename parent is not a mapping",
        parent.span,
    )
    entries = collect(parent.value.entries)
    source_index = findfirst(entry -> entry.key.value.value == operation.from_key, entries)
    isnothing(source_index) && _migration_fail(
        :migration_path_missing,
        "migration rename source key $(operation.from_key) does not exist",
        parent.span,
    )
    any(entry -> entry.key.value.value == operation.to_key, entries) && _migration_fail(
        :migration_destination_exists,
        "migration rename destination key $(operation.to_key) already exists",
        parent.span,
    )
    source_entry = entries[source_index]
    entries[source_index] = FormatMappingEntry(
        FormatNode(FormatString(operation.to_key), source_entry.key.span),
        source_entry.value,
    )
    replacement = FormatNode(FormatMapping(entries), parent.span)
    updated = _migration_replace_node(root, operation.parent, replacement)
    isnothing(updated) && _migration_fail(
        :migration_path_missing,
        "migration rename parent disappeared",
        parent.span,
    )
    return updated
end

function _migration_step_versions(plan_step::MigrationPlanStep)
    step = plan_step.step
    return plan_step.direction == MigrationUpgrade ?
        (step.from_version, step.to_version) :
        (step.to_version, step.from_version)
end

@enum MigrationChangeKind::UInt8 begin
    MigrationAssertion = 0x01
    MigrationRename = 0x02
    MigrationMove = 0x03
    MigrationVersionChange = 0x04
    MigrationRemoval = 0x05
end

"""One deterministic operation effect recorded in migration order."""
struct MigrationChange
    step_id::String
    operation_index::Int
    kind::MigrationChangeKind
    source_path::FormatPath
    result_path::Union{Nothing,FormatPath}
end

Base.:(==)(left::MigrationChange, right::MigrationChange) =
    left.step_id == right.step_id &&
    left.operation_index == right.operation_index &&
    left.kind == right.kind &&
    left.source_path == right.source_path &&
    left.result_path == right.result_path

function _migration_apply_operation(
    root::FormatNode,
    operation::MigrationOperation,
    plan_step::MigrationPlanStep,
    operation_index::Int,
)
    step = plan_step.step
    if operation isa MigrationAssertValue
        node = _migration_node_at(root, operation.path)
        isnothing(node) && _migration_fail(
            :migration_path_missing,
            "migration assertion path $(_migration_path_text(operation.path)) does not exist",
            root.span,
        )
        _structural_semantic_equal(node.value, operation.expected) || _migration_fail(
            :migration_assertion_failed,
            "migration assertion value differs at $(_migration_path_text(operation.path))",
            node.span,
        )
        change = MigrationChange(
            step.id,
            operation_index,
            MigrationAssertion,
            operation.path,
            operation.path,
        )
        return (root, change, nothing)
    elseif operation isa MigrationRenameKey
        source = FormatPath(
            collect(operation.parent.segments)...,
            operation.from_key,
        )
        target = FormatPath(
            collect(operation.parent.segments)...,
            operation.to_key,
        )
        updated = _migration_rename_key(root, operation)
        change = MigrationChange(step.id, operation_index, MigrationRename, source, target)
        return (updated, change, nothing)
    elseif operation isa MigrationMoveValue
        node = _migration_node_at(root, operation.source)
        isnothing(node) && _migration_fail(
            :migration_path_missing,
            "migration move source $(_migration_path_text(operation.source)) does not exist",
            root.span,
        )
        removed = _migration_remove_node(root, operation.source)
        isnothing(removed) && _migration_fail(
            :migration_path_missing,
            "migration move source cannot be removed",
            node.span,
        )
        inserted = _migration_insert_mapping_value(removed, operation.destination, node)
        isnothing(inserted) && _migration_fail(
            :migration_destination_invalid,
            "migration move destination $(_migration_path_text(operation.destination)) is absent, occupied, or not a mapping key",
            node.span,
        )
        change = MigrationChange(
            step.id,
            operation_index,
            MigrationMove,
            operation.source,
            operation.destination,
        )
        return (inserted, change, nothing)
    elseif operation isa MigrationSetSchemaVersion
        node = _migration_node_at(root, operation.path)
        isnothing(node) && _migration_fail(
            :migration_path_missing,
            "schema version path $(_migration_path_text(operation.path)) does not exist",
            root.span,
        )
        from_version, to_version = _migration_step_versions(plan_step)
        expected = string(from_version)
        node.value == FormatString(expected) || _migration_fail(
            :migration_version_mismatch,
            "schema version field contains $(repr(node.value)) instead of $(expected)",
            node.span,
        )
        replacement = FormatNode(FormatString(string(to_version)), node.span)
        updated = _migration_replace_node(root, operation.path, replacement)
        isnothing(updated) && _migration_fail(
            :migration_path_missing,
            "schema version field cannot be replaced",
            node.span,
        )
        change = MigrationChange(
            step.id,
            operation_index,
            MigrationVersionChange,
            operation.path,
            operation.path,
        )
        return (updated, change, nothing)
    elseif operation isa MigrationRemoveValue
        node = _migration_node_at(root, operation.path)
        isnothing(node) && _migration_fail(
            :migration_path_missing,
            "migration removal path $(_migration_path_text(operation.path)) does not exist",
            root.span,
        )
        updated = _migration_remove_node(root, operation.path)
        isnothing(updated) && _migration_fail(
            :migration_path_missing,
            "migration removal cannot be applied",
            node.span,
        )
        change = MigrationChange(
            step.id,
            operation_index,
            MigrationRemoval,
            operation.path,
            nothing,
        )
        return (updated, change, operation.loss)
    end
    error("unsupported migration operation")
end

"""One source path/span retained for every value node in the migrated result."""
struct MigrationSourceMapping
    result_path::FormatPath
    source_path::FormatPath
    source_span::SourceSpan
end

Base.:(==)(left::MigrationSourceMapping, right::MigrationSourceMapping) =
    left.result_path == right.result_path &&
    left.source_path == right.source_path &&
    left.source_span == right.source_span

function _migration_collect_nodes!(
    output::Vector{Tuple{FormatPath,SourceSpan}},
    node::FormatNode,
    path::FormatPath = FormatPath(),
)
    push!(output, (path, node.span))
    if node.value isa FormatMapping
        for entry in node.value.entries
            child_path = FormatPath(
                collect(path.segments)...,
                entry.key.value.value,
            )
            _migration_collect_nodes!(output, entry.value, child_path)
        end
    elseif node.value isa FormatSequence
        for (index, child) in enumerate(node.value.elements)
            child_path = FormatPath(collect(path.segments)..., index)
            _migration_collect_nodes!(output, child, child_path)
        end
    end
    return output
end

function _migration_source_mappings(source::FormatNode, result::FormatNode)
    source_nodes = _migration_collect_nodes!(Tuple{FormatPath,SourceSpan}[], source)
    result_nodes = _migration_collect_nodes!(Tuple{FormatPath,SourceSpan}[], result)
    by_span = Dict{SourceSpan,Vector{FormatPath}}()
    for (path, span) in source_nodes
        push!(get!(by_span, span, FormatPath[]), path)
    end
    mappings = MigrationSourceMapping[]
    for (result_path, span) in result_nodes
        candidates = get(by_span, span, FormatPath[])
        isempty(candidates) && error("migrated node lost its source span")
        matching = findfirst(==(result_path), candidates)
        source_path = isnothing(matching) ?
            first(sort!(candidates; by = _migration_path_text)) : candidates[matching]
        push!(mappings, MigrationSourceMapping(result_path, source_path, span))
    end
    sort!(mappings; by = mapping -> _migration_path_text(mapping.result_path))
    return mappings
end

"""Provenance for one directed migration-step execution."""
struct MigrationStepRecord
    id::String
    direction::MigrationDirection
    from_version::VersionNumber
    to_version::VersionNumber
    provenance::String
end

Base.:(==)(left::MigrationStepRecord, right::MigrationStepRecord) =
    left.id == right.id &&
    left.direction == right.direction &&
    left.from_version == right.from_version &&
    left.to_version == right.to_version &&
    left.provenance == right.provenance

"""Complete deterministic migration plan, changes, losses, hashes, and source mappings."""
struct MigrationReport
    schema_id::String
    from_version::VersionNumber
    to_version::VersionNumber
    dry_run::Bool
    source_sha256::String
    result_sha256::String
    steps::FormatItemList{MigrationStepRecord}
    changes::FormatItemList{MigrationChange}
    losses::FormatItemList{MigrationLoss}
    source_mappings::FormatItemList{MigrationSourceMapping}
end

Base.:(==)(left::MigrationReport, right::MigrationReport) =
    left.schema_id == right.schema_id &&
    left.from_version == right.from_version &&
    left.to_version == right.to_version &&
    left.dry_run == right.dry_run &&
    left.source_sha256 == right.source_sha256 &&
    left.result_sha256 == right.result_sha256 &&
    left.steps == right.steps &&
    left.changes == right.changes &&
    left.losses == right.losses &&
    left.source_mappings == right.source_mappings

"""A migrated root retaining the immutable original source and exact source spans."""
struct MigratedFormatDocument
    source::SourceDocument
    root::FormatNode
end

Base.:(==)(left::MigratedFormatDocument, right::MigratedFormatDocument) =
    left.source == right.source && left.root == right.root

"""Atomic migration output; `document` is absent for a dry run."""
struct MigrationOutcome
    document::Union{Nothing,MigratedFormatDocument}
    report::MigrationReport
end

"""Typed result returned by an atomic format migration."""
const MigrationResult = FormatResult{MigrationOutcome}

Base.:(==)(left::MigrationOutcome, right::MigrationOutcome) =
    left.document == right.document && left.report == right.report

function _migration_result(
    ::Type{MigrationOutcome},
    diagnostics::Vector{FormatDiagnostic},
)
    return MigrationResult(nothing, diagnostics)
end

"""Validate, migrate atomically, validate the target, and report every transformation."""
function migrate_format_document(
    registry::StructuralSchemaRegistry,
    document::ParsedFormatDocument,
    from_version::VersionNumber;
    to_version::VersionNumber = registry.version_policy.current_version,
    dry_run::Bool = false,
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source_schema_result = resolve_structural_schema(registry, from_version)
    format_succeeded(source_schema_result) || return _migration_result(
        MigrationOutcome,
        collect(source_schema_result.diagnostics),
    )
    target_schema_result = resolve_structural_schema(registry, to_version)
    format_succeeded(target_schema_result) || return _migration_result(
        MigrationOutcome,
        collect(target_schema_result.diagnostics),
    )
    source_validation = validate_structural_document(
        source_schema_result.value,
        document;
        policy,
    )
    format_succeeded(source_validation) || return _migration_result(
        MigrationOutcome,
        vcat(
            [FormatDiagnostic(
                DiagnosticError,
                :migration_source_validation_failed,
                "source document does not satisfy its declared structural schema",
                document.root.span,
            )],
            collect(source_validation.diagnostics),
        ),
    )
    plan_result = plan_migration(registry.migrations, from_version, to_version)
    format_succeeded(plan_result) || return _migration_result(
        MigrationOutcome,
        collect(plan_result.diagnostics),
    )
    source_hash = canonical_json_sha256(document.root; policy)
    format_succeeded(source_hash) || return _migration_result(
        MigrationOutcome,
        collect(source_hash.diagnostics),
    )
    root = document.root
    changes = MigrationChange[]
    losses = MigrationLoss[]
    step_records = MigrationStepRecord[]
    try
        for plan_step in plan_result.value.steps
            from_step_version, to_step_version = _migration_step_versions(plan_step)
            operations = plan_step.direction == MigrationUpgrade ?
                plan_step.step.operations : plan_step.step.inverse_operations
            for (operation_index, operation) in enumerate(operations)
                root, change, loss = _migration_apply_operation(
                    root,
                    operation,
                    plan_step,
                    operation_index,
                )
                push!(changes, change)
                isnothing(loss) || push!(losses, loss)
            end
            push!(step_records, MigrationStepRecord(
                plan_step.step.id,
                plan_step.direction,
                from_step_version,
                to_step_version,
                plan_step.step.provenance,
            ))
        end
    catch error
        error isa _MigrationFailure || rethrow()
        return _migration_result(MigrationOutcome, [error.diagnostic])
    end
    migrated = ParsedFormatDocument(document.source, root)
    target_validation = validate_structural_document(
        target_schema_result.value,
        migrated;
        policy,
    )
    format_succeeded(target_validation) || return _migration_result(
        MigrationOutcome,
        vcat(
            [FormatDiagnostic(
                DiagnosticError,
                :migration_target_validation_failed,
                "migrated document does not satisfy the target structural schema",
                root.span,
            )],
            collect(target_validation.diagnostics),
        ),
    )
    result_hash = canonical_json_sha256(root; policy)
    format_succeeded(result_hash) || return _migration_result(
        MigrationOutcome,
        collect(result_hash.diagnostics),
    )
    report = MigrationReport(
        registry.version_policy.schema_id,
        from_version,
        to_version,
        dry_run,
        source_hash.value,
        result_hash.value,
        FormatItemList(step_records),
        FormatItemList(changes),
        FormatItemList(losses),
        FormatItemList(_migration_source_mappings(document.root, root)),
    )
    output_document = dry_run ? nothing : MigratedFormatDocument(document.source, root)
    return FormatResult(MigrationOutcome(output_document, report))
end
