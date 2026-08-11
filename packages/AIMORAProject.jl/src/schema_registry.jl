@enum SemanticValueKind::UInt8 begin
    SchemaBoolean = 0x01
    SchemaInteger = 0x02
    SchemaDecimal = 0x03
    SchemaString = 0x04
    SchemaQuantity = 0x05
    SchemaComplexQuantity = 0x06
    SchemaReference = 0x07
    SchemaArtifact = 0x08
end

struct NumericBoundsConstraint
    lower::Union{Nothing,ExactScalar}
    upper::Union{Nothing,ExactScalar}
    lower_inclusive::Bool
    upper_inclusive::Bool

    function NumericBoundsConstraint(;
        lower::Union{Nothing,ExactScalar} = nothing,
        upper::Union{Nothing,ExactScalar} = nothing,
        lower_inclusive::Bool = true,
        upper_inclusive::Bool = true,
    )
        isnothing(lower) && isnothing(upper) &&
            _semantic_fail(:empty_numeric_constraint, "numeric bounds require a lower or upper value")
        if !isnothing(lower) && !isnothing(upper)
            lower_value = exact_rational(lower)
            upper_value = exact_rational(upper)
            lower_value <= upper_value || _semantic_fail(:invalid_numeric_bounds, "numeric lower bound exceeds upper bound")
            lower_value == upper_value && (!lower_inclusive || !upper_inclusive) &&
                _semantic_fail(:empty_numeric_interval, "exclusive equal numeric bounds admit no value")
        end
        return new(lower, upper, lower_inclusive, upper_inclusive)
    end
end

Base.:(==)(left::NumericBoundsConstraint, right::NumericBoundsConstraint) =
    left.lower == right.lower &&
    left.upper == right.upper &&
    left.lower_inclusive == right.lower_inclusive &&
    left.upper_inclusive == right.upper_inclusive

struct AllowedStringConstraint
    values::CanonicalList{String}

    function AllowedStringConstraint(values::AbstractVector{<:AbstractString})
        copied = sort!(String[String(value) for value in values])
        isempty(copied) && _semantic_fail(:empty_allowed_values, "allowed string constraint must contain values")
        any(isempty, copied) && _semantic_fail(:invalid_allowed_value, "allowed string value must not be empty")
        length(copied) == length(unique(copied)) || _semantic_fail(:duplicate_allowed_value, "allowed string constraint repeats a value")
        return new(CanonicalList{String}(copied))
    end
end

Base.:(==)(left::AllowedStringConstraint, right::AllowedStringConstraint) =
    left.values == right.values

struct QuantityConstraint
    dimension::DimensionVector
    allow_per_unit::Bool
    orientations::CanonicalList{QuantityOrientation}

    function QuantityConstraint(
        dimension::DimensionVector,
        orientations::AbstractVector{QuantityOrientation};
        allow_per_unit::Bool = false,
    )
        copied = sort!(collect(orientations); by = UInt8)
        isempty(copied) && _semantic_fail(:missing_quantity_orientation, "quantity constraint requires at least one orientation")
        length(copied) == length(unique(copied)) || _semantic_fail(:duplicate_quantity_orientation, "quantity constraint repeats an orientation")
        return new(dimension, allow_per_unit, CanonicalList{QuantityOrientation}(copied))
    end
end

Base.:(==)(left::QuantityConstraint, right::QuantityConstraint) =
    left.dimension == right.dimension &&
    left.allow_per_unit == right.allow_per_unit &&
    left.orientations == right.orientations

struct ReferenceConstraint
    kinds::CanonicalList{ReferenceKind}

    function ReferenceConstraint(kinds::AbstractVector{ReferenceKind})
        copied = sort!(collect(kinds); by = UInt8)
        isempty(copied) && _semantic_fail(:missing_reference_kind, "reference constraint requires at least one kind")
        length(copied) == length(unique(copied)) || _semantic_fail(:duplicate_reference_kind, "reference constraint repeats a kind")
        return new(CanonicalList{ReferenceKind}(copied))
    end
end

Base.:(==)(left::ReferenceConstraint, right::ReferenceConstraint) = left.kinds == right.kinds

const SemanticConstraint = Union{
    NumericBoundsConstraint,
    AllowedStringConstraint,
    QuantityConstraint,
    ReferenceConstraint,
}

"""One canonical schema field with typed, callback-free constraints and no hidden default."""
struct SchemaField
    name::String
    kind::SemanticValueKind
    required::Bool
    constraints::CanonicalList{SemanticConstraint}
    description::String

    function SchemaField(
        name::AbstractString,
        kind::SemanticValueKind;
        required::Bool = false,
        constraints::AbstractVector{<:SemanticConstraint} = SemanticConstraint[],
        description::AbstractString = "",
    )
        normalized_name = String(name)
        occursin(r"^[a-z][a-z0-9_]*$", normalized_name) ||
            _semantic_fail(:invalid_schema_field_name, "schema field name is not lowercase portable text")
        normalized_description = String(description)
        occursin('\0', normalized_description) && _semantic_fail(:invalid_schema_field_description, "schema field description contains NUL")
        copied = SemanticConstraint[constraint for constraint in constraints]
        quantity_constraints = count(constraint -> constraint isa QuantityConstraint, copied)
        reference_constraints = count(constraint -> constraint isa ReferenceConstraint, copied)
        allowed_constraints = count(constraint -> constraint isa AllowedStringConstraint, copied)
        numeric_constraints = count(constraint -> constraint isa NumericBoundsConstraint, copied)
        quantity_constraints <= 1 && reference_constraints <= 1 && allowed_constraints <= 1 && numeric_constraints <= 1 ||
            _semantic_fail(:duplicate_schema_constraint, "schema field repeats a constraint family")
        if kind in (SchemaQuantity, SchemaComplexQuantity)
            quantity_constraints == 1 || _semantic_fail(:missing_quantity_constraint, "quantity schema field requires one quantity constraint")
            length(copied) == 1 || _semantic_fail(:incompatible_schema_constraint, "quantity field accepts only a quantity constraint")
        elseif kind == SchemaReference
            reference_constraints == 1 || _semantic_fail(:missing_reference_constraint, "reference schema field requires one reference constraint")
            length(copied) == 1 || _semantic_fail(:incompatible_schema_constraint, "reference field accepts only a reference constraint")
        elseif kind == SchemaString
            all(constraint -> constraint isa AllowedStringConstraint, copied) ||
                _semantic_fail(:incompatible_schema_constraint, "string field accepts only allowed-string constraints")
        elseif kind in (SchemaInteger, SchemaDecimal)
            all(constraint -> constraint isa NumericBoundsConstraint, copied) ||
                _semantic_fail(:incompatible_schema_constraint, "numeric field accepts only numeric bounds")
        elseif !isempty(copied)
            _semantic_fail(:incompatible_schema_constraint, "field kind does not accept constraints")
        end
        return new(
            normalized_name,
            kind,
            required,
            CanonicalList{SemanticConstraint}(copied),
            normalized_description,
        )
    end
end

Base.:(==)(left::SchemaField, right::SchemaField) =
    left.name == right.name &&
    left.kind == right.kind &&
    left.required == right.required &&
    left.constraints == right.constraints &&
    left.description == right.description

"""Stable UUID and exact version ownership for one semantic schema."""
struct SemanticSchemaIdentity
    uuid::UUID
    namespace::NamespaceId
    name::ProjectId
    version::VersionNumber

    function SemanticSchemaIdentity(
        uuid::UUID,
        namespace::NamespaceId,
        name::ProjectId,
        version::VersionNumber,
    )
        uuid == UUID(UInt128(0)) && _semantic_fail(:invalid_schema_uuid, "semantic schema UUID must not be nil")
        version.major > 0 || _semantic_fail(:invalid_schema_version, "semantic schema major version must be positive")
        return new(uuid, namespace, name, version)
    end
end

Base.:(==)(left::SemanticSchemaIdentity, right::SemanticSchemaIdentity) =
    left.uuid == right.uuid &&
    left.namespace == right.namespace &&
    left.name == right.name &&
    left.version == right.version
Base.hash(identity::SemanticSchemaIdentity, seed::UInt) =
    hash((identity.uuid, identity.namespace, identity.name, identity.version), seed)

"""One immutable semantic schema declaration and its engineering provenance."""
struct SemanticSchema
    identity::SemanticSchemaIdentity
    fields::CanonicalList{SchemaField}
    provenance::ProvenanceSource

    function SemanticSchema(
        identity::SemanticSchemaIdentity,
        fields::AbstractVector{SchemaField},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(fields); by = field -> field.name)
        isempty(copied) && _semantic_fail(:empty_semantic_schema, "semantic schema must contain fields")
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) || _semantic_fail(:duplicate_schema_field, "semantic schema repeats a field")
        return new(identity, CanonicalList{SchemaField}(copied), provenance)
    end
end

Base.:(==)(left::SemanticSchema, right::SemanticSchema) =
    left.identity == right.identity &&
    left.fields == right.fields &&
    left.provenance == right.provenance

"""Licence/provenance ownership of one extension namespace."""
struct NamespaceRegistration
    namespace::NamespaceId
    owner_uuid::UUID
    licence::LicenceIdentity
    provenance::ProvenanceSource

    function NamespaceRegistration(
        namespace::NamespaceId,
        owner_uuid::UUID,
        licence::LicenceIdentity,
        provenance::ProvenanceSource,
    )
        owner_uuid == UUID(UInt128(0)) && _semantic_fail(:invalid_namespace_owner, "namespace owner UUID must not be nil")
        provenance.licence == licence || _semantic_fail(:namespace_licence_mismatch, "namespace licence differs from its provenance licence")
        return new(namespace, owner_uuid, licence, provenance)
    end
end

Base.:(==)(left::NamespaceRegistration, right::NamespaceRegistration) =
    left.namespace == right.namespace &&
    left.owner_uuid == right.owner_uuid &&
    left.licence == right.licence &&
    left.provenance == right.provenance

"""The immutable owner registry for namespace and semantic schema declarations."""
struct SemanticSchemaRegistry
    namespaces::CanonicalList{NamespaceRegistration}
    schemas::CanonicalList{SemanticSchema}

    function SemanticSchemaRegistry(
        namespaces::AbstractVector{NamespaceRegistration} = NamespaceRegistration[],
        schemas::AbstractVector{SemanticSchema} = SemanticSchema[],
    )
        namespace_copy = sort!(collect(namespaces); by = item -> item.namespace.value)
        namespace_ids = getfield.(getfield.(namespace_copy, :namespace), :value)
        length(namespace_ids) == length(unique(namespace_ids)) || _semantic_fail(:duplicate_namespace, "semantic registry repeats a namespace")
        schema_copy = sort!(collect(schemas); by = schema -> (
            schema.identity.namespace.value,
            schema.identity.name.value,
            schema.identity.version,
        ))
        schema_keys = [
            (schema.identity.namespace, schema.identity.name, schema.identity.version)
            for schema in schema_copy
        ]
        length(schema_keys) == length(unique(schema_keys)) || _semantic_fail(:duplicate_schema_identity, "semantic registry repeats a schema identity")
        schema_uuids = getfield.(getfield.(schema_copy, :identity), :uuid)
        length(schema_uuids) == length(unique(schema_uuids)) || _semantic_fail(:duplicate_schema_uuid, "semantic registry repeats a schema UUID")
        registered_namespaces = Set(item.namespace for item in namespace_copy)
        all(schema -> schema.identity.namespace in registered_namespaces, schema_copy) ||
            _semantic_fail(:unknown_schema_namespace, "semantic registry contains a schema with an unregistered namespace")
        return new(
            CanonicalList{NamespaceRegistration}(namespace_copy),
            CanonicalList{SemanticSchema}(schema_copy),
        )
    end
end

Base.:(==)(left::SemanticSchemaRegistry, right::SemanticSchemaRegistry) =
    left.namespaces == right.namespaces && left.schemas == right.schemas

function register_namespace(
    registry::SemanticSchemaRegistry,
    registration::NamespaceRegistration,
)
    existing = findfirst(item -> item.namespace == registration.namespace, registry.namespaces)
    if !isnothing(existing)
        registry.namespaces[existing] == registration && return registry
        _semantic_fail(:namespace_owner_collision, "namespace $(registration.namespace.value) already has different ownership")
    end
    return SemanticSchemaRegistry(
        vcat(collect(registry.namespaces), [registration]),
        collect(registry.schemas),
    )
end

function register_schema(registry::SemanticSchemaRegistry, schema::SemanticSchema)
    any(item -> item.namespace == schema.identity.namespace, registry.namespaces) ||
        _semantic_fail(:unknown_schema_namespace, "schema namespace is not registered")
    matching_uuid = findfirst(item -> item.identity.uuid == schema.identity.uuid, registry.schemas)
    if !isnothing(matching_uuid)
        registry.schemas[matching_uuid] == schema && return registry
        _semantic_fail(:schema_uuid_collision, "schema UUID already owns a different identity or declaration")
    end
    matching_identity = findfirst(item -> (
        item.identity.namespace == schema.identity.namespace &&
        item.identity.name == schema.identity.name &&
        item.identity.version == schema.identity.version
    ), registry.schemas)
    !isnothing(matching_identity) && _semantic_fail(:schema_identity_collision, "schema identity already has a different UUID or declaration")
    return SemanticSchemaRegistry(
        collect(registry.namespaces),
        vcat(collect(registry.schemas), [schema]),
    )
end

function resolve_schema(registry::SemanticSchemaRegistry, identity::SemanticSchemaIdentity)
    index = findfirst(schema -> schema.identity == identity, registry.schemas)
    isnothing(index) && _semantic_fail(:unknown_schema_version, "exact semantic schema identity is not registered")
    return registry.schemas[index]
end

function resolve_schema(
    registry::SemanticSchemaRegistry,
    namespace::NamespaceId,
    name::ProjectId,
    version::VersionNumber,
)
    index = findfirst(schema -> (
        schema.identity.namespace == namespace &&
        schema.identity.name == name &&
        schema.identity.version == version
    ), registry.schemas)
    isnothing(index) && _semantic_fail(:unknown_schema_version, "exact semantic schema version is not registered")
    return registry.schemas[index]
end

function schema_field(schema::SemanticSchema, name::AbstractString)
    normalized = String(name)
    index = findfirst(field -> field.name == normalized, schema.fields)
    isnothing(index) && _semantic_fail(:unknown_schema_field, "semantic schema field is not declared")
    return schema.fields[index]
end

function _validate_numeric_bounds(constraint::NumericBoundsConstraint, value::ExactRational)
    if !isnothing(constraint.lower)
        lower = exact_rational(constraint.lower)
        accepted = constraint.lower_inclusive ? lower <= value : lower < value
        accepted || _semantic_fail(:value_below_schema_bound, "value is below the schema lower bound")
    end
    if !isnothing(constraint.upper)
        upper = exact_rational(constraint.upper)
        accepted = constraint.upper_inclusive ? value <= upper : value < upper
        accepted || _semantic_fail(:value_above_schema_bound, "value is above the schema upper bound")
    end
    return true
end

function _physical_quantity(value::PhysicalValue)
    return value.quantity
end

function validate_field_value(
    field::SchemaField,
    value,
    units::UnitRegistry,
)
    if field.kind == SchemaBoolean
        value isa Bool || _semantic_fail(:schema_value_type_mismatch, "schema field requires Bool")
    elseif field.kind == SchemaInteger
        value isa Integer && !(value isa Bool) || _semantic_fail(:schema_value_type_mismatch, "schema field requires Integer")
    elseif field.kind == SchemaDecimal
        value isa ExactScalar || _semantic_fail(:schema_value_type_mismatch, "schema field requires an exact scalar")
    elseif field.kind == SchemaString
        value isa AbstractString || _semantic_fail(:schema_value_type_mismatch, "schema field requires String")
    elseif field.kind == SchemaQuantity
        value isa PhysicalValue && value.quantity isa ScalarQuantity ||
            _semantic_fail(:schema_value_type_mismatch, "quantity schema field requires a scalar PhysicalValue")
        validate_quantity(units, value)
    elseif field.kind == SchemaComplexQuantity
        value isa PhysicalValue && value.quantity isa ComplexQuantity ||
            _semantic_fail(:schema_value_type_mismatch, "complex quantity schema field requires a complex PhysicalValue")
        validate_quantity(units, value)
    elseif field.kind == SchemaReference
        value isa ProjectReference || _semantic_fail(:schema_value_type_mismatch, "schema field requires ProjectReference")
    else
        value isa ArtifactIdentity || _semantic_fail(:schema_value_type_mismatch, "schema field requires ArtifactIdentity")
    end
    for constraint in field.constraints
        if constraint isa NumericBoundsConstraint
            exact_value = value isa Integer ? ExactRational(value) : exact_rational(value)
            _validate_numeric_bounds(constraint, exact_value)
        elseif constraint isa AllowedStringConstraint
            String(value) in constraint.values || _semantic_fail(:value_not_allowed, "string is outside the schema allowed set")
        elseif constraint isa ReferenceConstraint
            value.kind in constraint.kinds || _semantic_fail(:reference_kind_mismatch, "reference kind is outside the schema contract")
        else
            quantity = _physical_quantity(value)
            unit = lookup_unit(units, quantity.unit)
            unit.per_unit && !constraint.allow_per_unit &&
                _semantic_fail(:per_unit_not_allowed, "schema quantity field does not allow per-unit values")
            !unit.per_unit && unit.dimension != constraint.dimension &&
                _semantic_fail(:dimension_mismatch, "quantity dimension differs from the schema contract")
            quantity.orientation in constraint.orientations ||
                _semantic_fail(:orientation_mismatch, "quantity orientation differs from the schema contract")
        end
    end
    return true
end
