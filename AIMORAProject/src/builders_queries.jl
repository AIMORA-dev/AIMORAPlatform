"""A typed Julia authoring surface backed by the same validated transaction used by every command client."""
mutable struct ProjectBuilder
    transaction::ProjectTransaction
    next_command::Int

    function ProjectBuilder(base::ProjectRevision)
        return new(begin_project_transaction(base), 1)
    end
end

project_builder(base::ProjectRevision) = ProjectBuilder(base)

function _builder_command_id(builder::ProjectBuilder, action::AbstractString)
    normalized = replace(lowercase(String(action)), r"[^a-z0-9_]+" => "_")
    occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
        _semantic_fail(:invalid_builder_action, "builder action name is not portable")
    id = ProjectId("command.builder.$(normalized)_c$(builder.next_command)")
    builder.next_command += 1
    return id
end

function _builder_apply!(
    builder::ProjectBuilder,
    patch::ProjectPatch,
    action::AbstractString,
    command_id::Union{Nothing,ProjectId},
)
    id = isnothing(command_id) ? _builder_command_id(builder, action) : command_id
    apply!(builder.transaction, ProjectCommand(id, patch))
    return builder
end

function add_record!(
    builder::ProjectBuilder,
    record::CanonicalRecord;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, AddRecordPatch(record), "add_record", command_id)
end

function set_record_field!(
    builder::ProjectBuilder,
    owner::ProjectId,
    field::CanonicalField;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, SetRecordFieldPatch(owner, field), "set_record_field", command_id)
end

function unset_record_field!(
    builder::ProjectBuilder,
    owner::ProjectId,
    field_name::AbstractString;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, UnsetRecordFieldPatch(owner, field_name), "unset_record_field", command_id)
end

function set_project_name!(
    builder::ProjectBuilder,
    name::AbstractString;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, SetProjectNamePatch(name), "set_project_name", command_id)
end

function set_asset_property!(
    builder::ProjectBuilder,
    owner::ProjectId,
    property::AssetProperty;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, SetAssetCommonPropertyPatch(owner, property), "set_asset_property", command_id)
end

function unset_asset_property!(
    builder::ProjectBuilder,
    owner::ProjectId,
    path::FieldPath;
    command_id::Union{Nothing,ProjectId} = nothing,
)
    return _builder_apply!(builder, UnsetAssetCommonPropertyPatch(owner, path), "unset_asset_property", command_id)
end

"""Commit all builder commands atomically with deterministic semantic normalization."""
function commit_builder!(
    builder::ProjectBuilder;
    source_hash::ContentDigest = project_resolved_hash(builder.transaction.working),
    provenance::RevisionProvenance,
)
    resolved_hash = project_resolved_hash(builder.transaction.working)
    return commit!(
        builder.transaction,
        builder.transaction.base,
        source_hash,
        resolved_hash,
        provenance,
    )
end

"""An immutable record handle pinned to the revision from which it was queried."""
struct ProjectRecordHandle
    revision::ContentDigest
    owner::ProjectId
    schema::SemanticSchemaIdentity
end

Base.:(==)(left::ProjectRecordHandle, right::ProjectRecordHandle) =
    left.revision == right.revision && left.owner == right.owner && left.schema == right.schema

function query_record_handles(snapshot::ProjectSnapshot)
    handles = ProjectRecordHandle[
        ProjectRecordHandle(snapshot.revision_id, record.identity.id, record.schema)
        for record in snapshot.project.records
    ]
    return CanonicalList{ProjectRecordHandle}(handles)
end

function query_record_handles(snapshot::ProjectSnapshot, schema::SemanticSchemaIdentity)
    handles = ProjectRecordHandle[
        ProjectRecordHandle(snapshot.revision_id, record.identity.id, record.schema)
        for record in snapshot.project.records if record.schema == schema
    ]
    return CanonicalList{ProjectRecordHandle}(handles)
end

function resolve_handle(snapshot::ProjectSnapshot, handle::ProjectRecordHandle)
    snapshot.revision_id == handle.revision ||
        _semantic_fail(:stale_project_handle, "record handle belongs to a different project revision")
    record = project_record(snapshot.project, handle.owner)
    record.schema == handle.schema ||
        _semantic_fail(:record_handle_schema_mismatch, "record handle schema differs from its owner")
    return record
end

"""Select immutable record values with an ordinary trusted Julia predicate that is never persisted."""
function select_records(snapshot::ProjectSnapshot, predicate::F) where {F<:Function}
    return CanonicalList{CanonicalRecord}(
        CanonicalRecord[record for record in snapshot.project.records if predicate(record)],
    )
end

query_assets(snapshot::ProjectSnapshot) = snapshot.project.asset_library.assets

function query_assets(snapshot::ProjectSnapshot, predicate::F) where {F<:Function}
    return CanonicalList{CanonicalAsset}(
        CanonicalAsset[asset for asset in snapshot.project.asset_library.assets if predicate(asset)],
    )
end
