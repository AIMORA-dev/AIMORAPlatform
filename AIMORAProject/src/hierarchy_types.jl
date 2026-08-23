struct DefinitionParameterSpec
    field::SchemaField
    default::Union{Nothing,CanonicalFieldData}

    function DefinitionParameterSpec(
        field::SchemaField;
        default::Union{Nothing,CanonicalFieldData} = nothing,
    )
        field.required && !isnothing(default) &&
            _semantic_fail(:required_parameter_default, "required definition parameter cannot have a default")
        return new(field, default)
    end
end

Base.:(==)(left::DefinitionParameterSpec, right::DefinitionParameterSpec) =
    left.field == right.field && left.default == right.default

@enum ParameterBindingTarget::UInt8 begin
    DefinitionRecordField = 0x01
    DefinitionAssetCommonProperty = 0x02
end

struct DefinitionParameterBinding
    parameter::String
    owner::ProjectId
    target::ParameterBindingTarget
    path::FieldPath

    function DefinitionParameterBinding(
        parameter::AbstractString,
        owner::ProjectId,
        target::ParameterBindingTarget,
        path::FieldPath,
    )
        normalized = String(parameter)
        occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
            _semantic_fail(:invalid_definition_parameter, "definition parameter name is not portable")
        return new(normalized, owner, target, path)
    end
end

Base.:(==)(left::DefinitionParameterBinding, right::DefinitionParameterBinding) =
    left.parameter == right.parameter && left.owner == right.owner &&
    left.target == right.target && left.path == right.path

struct DefinitionRecord
    identity::ObjectIdentity
    schema::SemanticSchemaIdentity
    fields::CanonicalList{CanonicalField}
    provenance::ProvenanceSource

    function DefinitionRecord(
        identity::ObjectIdentity,
        schema::SemanticSchemaIdentity,
        fields::AbstractVector{CanonicalField},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(fields); by = field -> field.name)
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_definition_field, "definition record repeats a field")
        return new(identity, schema, CanonicalList{CanonicalField}(copied), provenance)
    end
end

Base.:(==)(left::DefinitionRecord, right::DefinitionRecord) =
    left.identity == right.identity && left.schema == right.schema &&
    left.fields == right.fields && left.provenance == right.provenance

struct DefinitionExternalPort
    id::ProjectId
    internal_port::ProjectId
    domain::GraphDomainIdentity
    direction::PortDirection
    carriers::CanonicalList{CarrierIdentity}
    signal_contract::Union{Nothing,SignalContract}

    function DefinitionExternalPort(
        id::ProjectId,
        internal_port::ProjectId,
        domain::GraphDomainIdentity,
        direction::PortDirection,
        carriers::AbstractVector{CarrierIdentity};
        signal_contract::Union{Nothing,SignalContract} = nothing,
    )
        copied = sort!(collect(carriers); by = carrier -> carrier.name.value)
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_definition_port_carrier, "definition port repeats a carrier")
        return new(id, internal_port, domain, direction, CanonicalList{CarrierIdentity}(copied), signal_contract)
    end
end

Base.:(==)(left::DefinitionExternalPort, right::DefinitionExternalPort) =
    left.id == right.id && left.internal_port == right.internal_port &&
    left.domain == right.domain && left.direction == right.direction &&
    left.carriers == right.carriers && left.signal_contract == right.signal_contract

struct InstanceParameterValue
    name::String
    value::CanonicalFieldData
    provenance::ProvenanceSource

    function InstanceParameterValue(
        name::AbstractString,
        value::CanonicalFieldData,
        provenance::ProvenanceSource,
    )
        normalized = String(name)
        occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
            _semantic_fail(:invalid_instance_parameter, "instance parameter name is not portable")
        return new(normalized, value isa String ? String(value) : value, provenance)
    end
end

Base.:(==)(left::InstanceParameterValue, right::InstanceParameterValue) =
    left.name == right.name && left.value == right.value && left.provenance == right.provenance

@enum InstancePortTarget::UInt8 begin
    InstanceTargetNode = 0x01
    InstanceTargetPort = 0x02
end

struct InstancePortBinding
    external_port::ProjectId
    target_kind::InstancePortTarget
    target::ProjectId
    carrier_mappings::CanonicalList{CarrierMapping}
    delayed::Bool

    function InstancePortBinding(
        external_port::ProjectId,
        target_kind::InstancePortTarget,
        target::ProjectId;
        carrier_mappings::AbstractVector{CarrierMapping} = CarrierMapping[],
        delayed::Bool = false,
    )
        copied = sort!(collect(carrier_mappings); by = mapping -> mapping.port_carrier.name.value)
        port_carriers = getfield.(copied, :port_carrier)
        node_carriers = getfield.(copied, :node_carrier)
        length(port_carriers) == length(unique(port_carriers)) ||
            _semantic_fail(:duplicate_instance_port_carrier, "instance binding repeats a port carrier")
        length(node_carriers) == length(unique(node_carriers)) ||
            _semantic_fail(:duplicate_instance_target_carrier, "instance binding repeats a target carrier")
        return new(external_port, target_kind, target, CanonicalList{CarrierMapping}(copied), delayed)
    end
end

Base.:(==)(left::InstancePortBinding, right::InstancePortBinding) =
    left.external_port == right.external_port && left.target_kind == right.target_kind &&
    left.target == right.target && left.carrier_mappings == right.carrier_mappings &&
    left.delayed == right.delayed

struct DefinitionInstance
    identity::ObjectIdentity
    definition::ProjectReference
    definition_version::VersionNumber
    parameters::CanonicalList{InstanceParameterValue}
    port_bindings::CanonicalList{InstancePortBinding}
    provenance::ProvenanceSource

    function DefinitionInstance(
        identity::ObjectIdentity,
        definition::ProjectReference,
        definition_version::VersionNumber,
        parameters::AbstractVector{InstanceParameterValue},
        port_bindings::AbstractVector{InstancePortBinding},
        provenance::ProvenanceSource,
    )
        definition.kind == ReferenceDefinition ||
            _semantic_fail(:invalid_definition_reference, "instance requires a definition reference")
        definition.target isa LocalReferenceTarget ||
            _semantic_fail(:external_definition_instance, "project instances require locked local definitions")
        definition_version.major > 0 ||
            _semantic_fail(:invalid_definition_version, "instance definition major version must be positive")
        parameter_copy = sort!(collect(parameters); by = parameter -> parameter.name)
        names = getfield.(parameter_copy, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_instance_parameter, "instance repeats a parameter value")
        binding_copy = sort!(collect(port_bindings); by = binding -> binding.external_port.value)
        ports = getfield.(binding_copy, :external_port)
        length(ports) == length(unique(ports)) ||
            _semantic_fail(:duplicate_instance_port_binding, "instance repeats an external port binding")
        return new(
            identity,
            definition,
            definition_version,
            CanonicalList{InstanceParameterValue}(parameter_copy),
            CanonicalList{InstancePortBinding}(binding_copy),
            provenance,
        )
    end
end

Base.:(==)(left::DefinitionInstance, right::DefinitionInstance) =
    left.identity == right.identity && left.definition == right.definition &&
    left.definition_version == right.definition_version && left.parameters == right.parameters &&
    left.port_bindings == right.port_bindings && left.provenance == right.provenance

struct DefinitionPropertyMetadata
    parameter::String
    category::String
    display_order::Int
    visible::Bool
    provenance::ProvenanceSource

    function DefinitionPropertyMetadata(
        parameter::AbstractString,
        category::AbstractString,
        display_order::Integer,
        visible::Bool,
        provenance::ProvenanceSource,
    )
        normalized_parameter = String(parameter)
        occursin(r"^[a-z][a-z0-9_]*$", normalized_parameter) ||
            _semantic_fail(:invalid_property_metadata_parameter, "property metadata parameter is not portable")
        normalized_category = String(category)
        isempty(strip(normalized_category)) &&
            _semantic_fail(:invalid_property_metadata_category, "property metadata category must not be empty")
        occursin('\0', normalized_category) &&
            _semantic_fail(:invalid_property_metadata_category, "property metadata category contains NUL")
        order = Int(display_order)
        order >= 0 || _semantic_fail(:invalid_property_display_order, "property display order must be nonnegative")
        return new(normalized_parameter, normalized_category, order, visible, provenance)
    end
end

Base.:(==)(left::DefinitionPropertyMetadata, right::DefinitionPropertyMetadata) =
    left.parameter == right.parameter && left.category == right.category &&
    left.display_order == right.display_order && left.visible == right.visible &&
    left.provenance == right.provenance

struct ReusableDefinition
    identity::ObjectIdentity
    definition_type::SemanticTypeId
    parameters::CanonicalList{DefinitionParameterSpec}
    external_ports::CanonicalList{DefinitionExternalPort}
    records::CanonicalList{DefinitionRecord}
    assets::CanonicalList{CanonicalAsset}
    internals::SemanticGraphs
    controls::ControlSystem
    parameter_bindings::CanonicalList{DefinitionParameterBinding}
    nested_instances::CanonicalList{DefinitionInstance}
    property_metadata::CanonicalList{DefinitionPropertyMetadata}
    documentation::Union{Nothing,ArtifactIdentity}
    default_view::Union{Nothing,ProjectReference}
    report_providers::CanonicalList{SemanticTypeId}
    provenance::ProvenanceSource

    function ReusableDefinition(
        identity::ObjectIdentity,
        definition_type::SemanticTypeId,
        parameters::AbstractVector{DefinitionParameterSpec},
        external_ports::AbstractVector{DefinitionExternalPort},
        records::AbstractVector{DefinitionRecord},
        assets::AbstractVector{CanonicalAsset},
        internals::SemanticGraphs,
        parameter_bindings::AbstractVector{DefinitionParameterBinding},
        nested_instances::AbstractVector{DefinitionInstance},
        provenance::ProvenanceSource;
        property_metadata::AbstractVector{DefinitionPropertyMetadata} = DefinitionPropertyMetadata[],
        controls::ControlSystem = ControlSystem(),
        documentation::Union{Nothing,ArtifactIdentity} = nothing,
        default_view::Union{Nothing,ProjectReference} = nothing,
        report_providers::AbstractVector{SemanticTypeId} = SemanticTypeId[],
    )
        ordered(items; by) = sort!(collect(items); by)
        parameter_copy = ordered(parameters, by = item -> item.field.name)
        external_copy = ordered(external_ports, by = item -> item.id.value)
        record_copy = ordered(records, by = item -> item.identity.id.value)
        asset_copy = ordered(assets, by = item -> item.identity.id.value)
        binding_copy = ordered(parameter_bindings, by = item -> (item.parameter, item.owner.value, string(item.path)))
        nested_copy = ordered(nested_instances, by = item -> item.identity.id.value)
        metadata_copy = ordered(property_metadata, by = item -> (item.display_order, item.parameter))
        providers = ordered(report_providers, by = item -> (item.namespace.value, item.name.value, item.version))
        return new(
            identity,
            definition_type,
            CanonicalList{DefinitionParameterSpec}(parameter_copy),
            CanonicalList{DefinitionExternalPort}(external_copy),
            CanonicalList{DefinitionRecord}(record_copy),
            CanonicalList{CanonicalAsset}(asset_copy),
            internals,
            controls,
            CanonicalList{DefinitionParameterBinding}(binding_copy),
            CanonicalList{DefinitionInstance}(nested_copy),
            CanonicalList{DefinitionPropertyMetadata}(metadata_copy),
            documentation,
            default_view,
            CanonicalList{SemanticTypeId}(providers),
            provenance,
        )
    end
end

Base.:(==)(left::ReusableDefinition, right::ReusableDefinition) =
    left.identity == right.identity && left.definition_type == right.definition_type &&
    left.parameters == right.parameters && left.external_ports == right.external_ports &&
    left.records == right.records && left.assets == right.assets &&
    left.internals == right.internals && left.controls == right.controls &&
    left.parameter_bindings == right.parameter_bindings &&
    left.nested_instances == right.nested_instances && left.property_metadata == right.property_metadata &&
    left.documentation == right.documentation &&
    left.default_view == right.default_view && left.report_providers == right.report_providers &&
    left.provenance == right.provenance

struct DefinitionMigration
    definition::ProjectId
    from_version::VersionNumber
    to_version::VersionNumber
    operation::SemanticTypeId
    implementation_hash::ContentDigest
    provenance::ProvenanceSource

    function DefinitionMigration(
        definition::ProjectId,
        from_version::VersionNumber,
        to_version::VersionNumber,
        operation::SemanticTypeId,
        implementation_hash::ContentDigest,
        provenance::ProvenanceSource,
    )
        from_version != to_version ||
            _semantic_fail(:empty_definition_migration, "definition migration must change version")
        return new(definition, from_version, to_version, operation, implementation_hash, provenance)
    end
end

Base.:(==)(left::DefinitionMigration, right::DefinitionMigration) =
    left.definition == right.definition && left.from_version == right.from_version &&
    left.to_version == right.to_version && left.operation == right.operation &&
    left.implementation_hash == right.implementation_hash && left.provenance == right.provenance

struct HierarchyModel
    definitions::CanonicalList{ReusableDefinition}
    instances::CanonicalList{DefinitionInstance}
    migrations::CanonicalList{DefinitionMigration}

    function HierarchyModel(;
        definitions::AbstractVector{ReusableDefinition} = ReusableDefinition[],
        instances::AbstractVector{DefinitionInstance} = DefinitionInstance[],
        migrations::AbstractVector{DefinitionMigration} = DefinitionMigration[],
    )
        definition_copy = sort!(collect(definitions); by = item -> (item.identity.id.value, item.definition_type.version))
        instance_copy = sort!(collect(instances); by = item -> item.identity.id.value)
        migration_copy = sort!(collect(migrations); by = item -> (item.definition.value, item.from_version, item.to_version))
        return new(
            CanonicalList{ReusableDefinition}(definition_copy),
            CanonicalList{DefinitionInstance}(instance_copy),
            CanonicalList{DefinitionMigration}(migration_copy),
        )
    end
end

Base.:(==)(left::HierarchyModel, right::HierarchyModel) =
    left.definitions == right.definitions && left.instances == right.instances &&
    left.migrations == right.migrations

struct ExpansionIdentity
    instance::ProjectId
    local_owner::ProjectId
    expanded_owner::ProjectId
end

Base.:(==)(left::ExpansionIdentity, right::ExpansionIdentity) =
    left.instance == right.instance && left.local_owner == right.local_owner &&
    left.expanded_owner == right.expanded_owner
