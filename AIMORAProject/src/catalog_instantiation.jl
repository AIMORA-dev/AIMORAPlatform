const _CATALOG_INSTANCE_NAMESPACE = UUID("ef2884b9-2ca4-5cf2-b2ce-d5ac64686666")
const _CATALOG_DESIGNATOR = r"^[A-Z][A-Z0-9]{0,7}[1-9][0-9]*$"

struct CatalogPartLine
    number::String
    description::String
    unit::String
    quantity::Int

    function CatalogPartLine(
        number::AbstractString,
        description::AbstractString,
        unit::AbstractString,
        quantity::Integer,
    )
        normalized_number = strip(String(number))
        normalized_description = strip(String(description))
        normalized_unit = strip(String(unit))
        isempty(normalized_number) &&
            _semantic_fail(:invalid_catalog_part_number, "catalog part number must not be empty")
        isempty(normalized_description) &&
            _semantic_fail(:invalid_catalog_part_description, "catalog part description must not be empty")
        isempty(normalized_unit) &&
            _semantic_fail(:invalid_catalog_part_unit, "catalog part unit must not be empty")
        0 < quantity <= 1_000_000 ||
            _semantic_fail(:invalid_catalog_part_quantity, "catalog part quantity is outside its bound")
        return new(normalized_number, normalized_description, normalized_unit, Int(quantity))
    end
end

Base.:(==)(left::CatalogPartLine, right::CatalogPartLine) =
    left.number == right.number && left.description == right.description &&
    left.unit == right.unit && left.quantity == right.quantity

struct CatalogCrossReferenceSpec
    field::String
    target_local_id::ProjectId

    function CatalogCrossReferenceSpec(field::AbstractString, target_local_id::ProjectId)
        normalized = strip(String(field))
        occursin(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*$", normalized) ||
            _semantic_fail(
                :invalid_catalog_cross_reference_field,
                "catalog cross-reference field must use portable dotted segments",
            )
        return new(normalized, target_local_id)
    end
end

Base.:(==)(left::CatalogCrossReferenceSpec, right::CatalogCrossReferenceSpec) =
    left.field == right.field && left.target_local_id == right.target_local_id

struct CatalogAssemblyMemberSpec
    local_id::ProjectId
    catalog_id::GlobalId
    equipment_class::String
    designator_prefix::String
    parent_local_id::Union{Nothing,ProjectId}
    cross_references::CanonicalList{CatalogCrossReferenceSpec}
    parts::CanonicalList{CatalogPartLine}

    function CatalogAssemblyMemberSpec(
        local_id::ProjectId,
        catalog_id::GlobalId,
        equipment_class::AbstractString,
        designator_prefix::AbstractString,
        parts::AbstractVector{CatalogPartLine};
        parent_local_id::Union{Nothing,ProjectId} = nothing,
        cross_references::AbstractVector{CatalogCrossReferenceSpec} =
            CatalogCrossReferenceSpec[],
    )
        normalized_class = strip(String(equipment_class))
        isempty(normalized_class) &&
            _semantic_fail(:invalid_catalog_equipment_class, "equipment class must not be empty")
        prefix = strip(String(designator_prefix))
        occursin(r"^[A-Z][A-Z0-9]{0,7}$", prefix) ||
            _semantic_fail(:invalid_designator_prefix, "designator prefix is invalid")
        references = sort!(collect(cross_references); by = item -> item.field)
        fields = getfield.(references, :field)
        length(fields) == length(unique(fields)) ||
            _semantic_fail(
                :duplicate_catalog_cross_reference,
                "catalog member repeats a cross-reference field",
            )
        part_copy = sort!(collect(parts); by = item -> (item.number, item.unit))
        isempty(part_copy) &&
            _semantic_fail(:missing_catalog_parts, "catalog member must provide parts-list data")
        return new(
            local_id,
            catalog_id,
            normalized_class,
            prefix,
            parent_local_id,
            CanonicalList{CatalogCrossReferenceSpec}(references),
            CanonicalList{CatalogPartLine}(part_copy),
        )
    end
end

struct CatalogAssemblySpec
    id::GlobalId
    members::CanonicalList{CatalogAssemblyMemberSpec}

    function CatalogAssemblySpec(
        id::GlobalId,
        members::AbstractVector{CatalogAssemblyMemberSpec},
    )
        copied = sort!(collect(members); by = item -> item.local_id.value)
        0 < length(copied) <= 1_000 ||
            _semantic_fail(:invalid_catalog_member_count, "catalog assembly member count is invalid")
        local_ids = getfield.(copied, :local_id)
        length(local_ids) == length(unique(local_ids)) ||
            _semantic_fail(:duplicate_catalog_member, "catalog assembly repeats a member ID")
        known = Set(local_ids)
        for member in copied
            member.parent_local_id === nothing || member.parent_local_id in known ||
                _semantic_fail(:unknown_catalog_parent, "catalog member parent does not exist")
            all(reference -> reference.target_local_id in known, member.cross_references) ||
                _semantic_fail(
                    :unknown_catalog_cross_reference,
                    "catalog cross-reference target does not exist",
                )
            visited = Set{ProjectId}([member.local_id])
            parent = member.parent_local_id
            while parent !== nothing
                parent in visited &&
                    _semantic_fail(:catalog_parent_cycle, "catalog assembly parent relation is cyclic")
                push!(visited, parent)
                parent_index = findfirst(item -> item.local_id == parent, copied)
                parent = copied[parent_index].parent_local_id
            end
        end
        return new(id, CanonicalList{CatalogAssemblyMemberSpec}(copied))
    end
end

struct CatalogInstanceCrossReference
    field::String
    target_instance_id::ProjectId
end

struct CatalogMaterializedInstance
    identity::ObjectIdentity
    source_local_id::ProjectId
    catalog_id::GlobalId
    equipment_class::String
    designator::String
    parent_instance_id::ProjectId
    cross_references::CanonicalList{CatalogInstanceCrossReference}
    parts::CanonicalList{CatalogPartLine}
end

struct CatalogAssemblyMaterialization
    identity::ObjectIdentity
    catalog_id::GlobalId
    members::CanonicalList{CatalogMaterializedInstance}
end

struct CatalogPartsRow
    number::String
    description::String
    unit::String
    quantity::Int
    instance_ids::CanonicalList{ProjectId}
end

_catalog_instance_id(root::ProjectId, local_id::ProjectId) =
    ProjectId("$(root.value).$(local_id.value)")

_catalog_uid(catalog_id::GlobalId, instance_id::ProjectId) = GlobalId(uuid5(
    _CATALOG_INSTANCE_NAMESPACE,
    "$(catalog_id.uri)|$(instance_id.value)",
))

function _next_designator(prefix::String, occupied::Set{String})
    sequence = 1
    while string(prefix, sequence) in occupied
        sequence += 1
        sequence <= 10_000_000 ||
            _semantic_fail(:designator_space_exhausted, "automatic designator space is exhausted")
    end
    designator = string(prefix, sequence)
    push!(occupied, designator)
    return designator
end

function materialize_catalog_assembly(
    assembly::CatalogAssemblySpec,
    root_id::ProjectId;
    occupied_project_ids::AbstractVector{ProjectId} = ProjectId[],
    occupied_designators::AbstractVector{<:AbstractString} = String[],
)
    root_id in occupied_project_ids &&
        _semantic_fail(:catalog_instance_id_conflict, "catalog assembly root ID already exists")
    occupied_ids = Set(occupied_project_ids)
    materialized_ids = Dict(
        member.local_id => _catalog_instance_id(root_id, member.local_id)
        for member in assembly.members
    )
    generated_ids = collect(values(materialized_ids))
    isempty(intersect(occupied_ids, Set(generated_ids))) ||
        _semantic_fail(:catalog_instance_id_conflict, "catalog member ID already exists")
    designators = Set(String(value) for value in occupied_designators)
    all(value -> occursin(_CATALOG_DESIGNATOR, value), designators) ||
        _semantic_fail(:invalid_existing_designator, "existing designator is invalid")
    instances = CatalogMaterializedInstance[]
    for member in assembly.members
        instance_id = materialized_ids[member.local_id]
        parent_id = member.parent_local_id === nothing ?
                    root_id : materialized_ids[member.parent_local_id]
        references = CatalogInstanceCrossReference[
            CatalogInstanceCrossReference(
                reference.field,
                materialized_ids[reference.target_local_id],
            ) for reference in member.cross_references
        ]
        push!(
            instances,
            CatalogMaterializedInstance(
                ObjectIdentity(
                    instance_id;
                    uid = _catalog_uid(member.catalog_id, instance_id),
                ),
                member.local_id,
                member.catalog_id,
                member.equipment_class,
                _next_designator(member.designator_prefix, designators),
                parent_id,
                CanonicalList{CatalogInstanceCrossReference}(references),
                member.parts,
            ),
        )
    end
    return CatalogAssemblyMaterialization(
        ObjectIdentity(root_id; uid = _catalog_uid(assembly.id, root_id)),
        assembly.id,
        CanonicalList{CatalogMaterializedInstance}(instances),
    )
end

function catalog_parts_schedule(materialization::CatalogAssemblyMaterialization)
    totals = Dict{Tuple{String,String,String},Tuple{Int,Vector{ProjectId}}}()
    for instance in materialization.members, part in instance.parts
        key = (part.number, part.description, part.unit)
        quantity, instance_ids = get(totals, key, (0, ProjectId[]))
        push!(instance_ids, instance.identity.id)
        totals[key] = (quantity + part.quantity, instance_ids)
    end
    return CatalogPartsRow[
        CatalogPartsRow(
            number,
            description,
            unit,
            quantity,
            CanonicalList{ProjectId}(sort!(unique!(instance_ids); by = item -> item.value)),
        )
        for ((number, description, unit), (quantity, instance_ids)) in
            sort!(collect(totals); by = first)
    ]
end
