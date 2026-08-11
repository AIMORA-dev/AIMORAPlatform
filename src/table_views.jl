"""A read-only Tables.jl-compatible projection of one canonical record schema."""
struct RecordTable
    revision::ContentDigest
    schema::SemanticSchema
    records::CanonicalList{CanonicalRecord}
end

function RecordTable(snapshot::ProjectSnapshot, identity::SemanticSchemaIdentity)
    schema = resolve_schema(snapshot.project.registry, identity)
    records = CanonicalRecord[record for record in snapshot.project.records if record.schema == identity]
    return RecordTable(snapshot.revision_id, schema, CanonicalList{CanonicalRecord}(records))
end

record_table(snapshot::ProjectSnapshot, identity::SemanticSchemaIdentity) = RecordTable(snapshot, identity)

Tables.istable(::Type{RecordTable}) = true
Tables.rowaccess(::Type{RecordTable}) = true

function _record_table_names(table::RecordTable)
    return Tuple(Symbol.(vcat(["owner_id"], [field.name for field in table.schema.fields])))
end

function _record_table_row(table::RecordTable, record::CanonicalRecord)
    values = Any[record.identity.id.value]
    for declared in table.schema.fields
        index = findfirst(field -> field.name == declared.name, record.fields)
        push!(values, isnothing(index) ? missing : record.fields[index].value)
    end
    return NamedTuple{_record_table_names(table)}(Tuple(values))
end

Tables.rows(table::RecordTable) = (_record_table_row(table, record) for record in table.records)

function Tables.schema(table::RecordTable)
    names = _record_table_names(table)
    types = Tuple(vcat([String], fill(Union{Missing,CanonicalFieldData}, length(table.schema.fields))))
    return Tables.Schema(names, types)
end

struct RecordTableEdit
    owner::ProjectId
    field::CanonicalField
end

Base.:(==)(left::RecordTableEdit, right::RecordTableEdit) =
    left.owner == right.owner && left.field == right.field

"""A typed transactional record-table edit buffer; it never aliases accepted canonical storage."""
mutable struct RecordTableEditBuffer
    base::ProjectRevision
    schema::SemanticSchemaIdentity
    edits::Vector{RecordTableEdit}
end

begin_record_table_edit(base::ProjectRevision, schema::SemanticSchemaIdentity) =
    RecordTableEditBuffer(base, schema, RecordTableEdit[])

function set_table_cell!(
    buffer::RecordTableEditBuffer,
    owner::ProjectId,
    field::CanonicalField,
)
    record = project_record(buffer.base.project, owner)
    record.schema == buffer.schema ||
        _semantic_fail(:table_schema_mismatch, "record table edit owner uses a different schema")
    any(edit -> edit.owner == owner && edit.field.name == field.name, buffer.edits) &&
        _semantic_fail(:duplicate_table_edit, "record table buffer repeats one owner and field")
    validate_field_value(schema_field(resolve_schema(buffer.base.project.registry, buffer.schema), field.name), field.value, buffer.base.project.units)
    push!(buffer.edits, RecordTableEdit(owner, field))
    return buffer
end

function commit_table!(
    buffer::RecordTableEditBuffer;
    source_hash::Union{Nothing,ContentDigest} = nothing,
    provenance::RevisionProvenance,
)
    isempty(buffer.edits) && _semantic_fail(:empty_table_edit, "record table buffer contains no edits")
    builder = project_builder(buffer.base)
    ordered = sort!(copy(buffer.edits); by = edit -> (edit.owner.value, edit.field.name))
    for edit in ordered
        set_record_field!(builder, edit.owner, edit.field)
    end
    digest = isnothing(source_hash) ? project_resolved_hash(builder.transaction.working) : source_hash
    return commit_builder!(builder; source_hash = digest, provenance)
end

"""A Tables.jl-compatible projection of common asset properties that preserves all other asset facets."""
struct AssetTable
    revision::ContentDigest
    assets::CanonicalList{CanonicalAsset}
    paths::CanonicalList{FieldPath}
end

function asset_table(snapshot::ProjectSnapshot)
    paths = sort!(unique(AssetProperty[property for asset in snapshot.project.asset_library.assets for property in asset.common]); by = property -> string(property.path))
    unique_paths = FieldPath[]
    for property in paths
        property.path in unique_paths || push!(unique_paths, property.path)
    end
    return AssetTable(snapshot.revision_id, snapshot.project.asset_library.assets, CanonicalList{FieldPath}(unique_paths))
end

Tables.istable(::Type{AssetTable}) = true
Tables.rowaccess(::Type{AssetTable}) = true

function _asset_table_names(table::AssetTable)
    property_names = Symbol[Symbol(replace(string(path), '.' => "__")) for path in table.paths]
    return Tuple(vcat([:id, :asset_type], property_names))
end

function _asset_table_row(table::AssetTable, asset::CanonicalAsset)
    values = Any[asset.identity.id.value, string(asset.asset_type.namespace.value, ':', asset.asset_type.name.value, '@', asset.asset_type.version)]
    for path in table.paths
        index = findfirst(property -> property.path == path, asset.common)
        push!(values, isnothing(index) ? missing : asset.common[index].value)
    end
    return NamedTuple{_asset_table_names(table)}(Tuple(values))
end

Tables.rows(table::AssetTable) = (_asset_table_row(table, asset) for asset in table.assets)

function Tables.schema(table::AssetTable)
    names = _asset_table_names(table)
    types = Tuple(vcat([String, String], fill(Union{Missing,CanonicalFieldData}, length(table.paths))))
    return Tables.Schema(names, types)
end

struct AssetTableEdit
    owner::ProjectId
    path::FieldPath
    value::Union{Nothing,CanonicalFieldData}
    provenance::ProvenanceSource
end

"""A typed asset-table edit buffer whose commit changes only declared common-property paths."""
mutable struct AssetTableEditBuffer
    base::ProjectRevision
    edits::Vector{AssetTableEdit}
end

begin_asset_table_edit(base::ProjectRevision) = AssetTableEditBuffer(base, AssetTableEdit[])

function _check_asset_table_edit(buffer::AssetTableEditBuffer, owner::ProjectId, path::FieldPath)
    canonical_asset(buffer.base.project, owner)
    any(edit -> edit.owner == owner && edit.path == path, buffer.edits) &&
        _semantic_fail(:duplicate_table_edit, "asset table buffer repeats one owner and property path")
    return true
end

function set_table_cell!(
    buffer::AssetTableEditBuffer,
    owner::ProjectId,
    path::FieldPath,
    value::CanonicalFieldData,
    provenance::ProvenanceSource,
)
    _check_asset_table_edit(buffer, owner, path)
    push!(buffer.edits, AssetTableEdit(owner, path, value, provenance))
    return buffer
end

function unset_asset_property!(
    buffer::AssetTableEditBuffer,
    owner::ProjectId,
    path::FieldPath,
    provenance::ProvenanceSource,
)
    _check_asset_table_edit(buffer, owner, path)
    push!(buffer.edits, AssetTableEdit(owner, path, nothing, provenance))
    return buffer
end

function commit_table!(
    buffer::AssetTableEditBuffer;
    source_hash::Union{Nothing,ContentDigest} = nothing,
    provenance::RevisionProvenance,
)
    isempty(buffer.edits) && _semantic_fail(:empty_table_edit, "asset table buffer contains no edits")
    builder = project_builder(buffer.base)
    ordered = sort!(copy(buffer.edits); by = edit -> (edit.owner.value, string(edit.path)))
    for edit in ordered
        if isnothing(edit.value)
            unset_asset_property!(builder, edit.owner, edit.path)
        else
            set_asset_property!(builder, edit.owner, AssetProperty(edit.path, edit.value, edit.provenance))
        end
    end
    digest = isnothing(source_hash) ? project_resolved_hash(builder.transaction.working) : source_hash
    return commit_builder!(builder; source_hash = digest, provenance)
end
