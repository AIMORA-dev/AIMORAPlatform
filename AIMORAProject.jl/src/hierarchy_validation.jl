function reusable_definition(
    hierarchy::HierarchyModel,
    id::ProjectId,
    version::VersionNumber,
)
    index = findfirst(
        definition -> definition.identity.id == id && definition.definition_type.version == version,
        hierarchy.definitions,
    )
    isnothing(index) && _semantic_fail(:unknown_definition_version, "reusable definition version does not exist")
    return hierarchy.definitions[index]
end

function definition_instance(hierarchy::HierarchyModel, id::ProjectId)
    index = findfirst(instance -> instance.identity.id == id, hierarchy.instances)
    isnothing(index) && _semantic_fail(:unknown_definition_instance, "definition instance does not exist")
    return hierarchy.instances[index]
end

function definition_migration(
    hierarchy::HierarchyModel,
    id::ProjectId,
    from_version::VersionNumber,
    to_version::VersionNumber,
)
    index = findfirst(
        migration -> migration.definition == id && migration.from_version == from_version &&
            migration.to_version == to_version,
        hierarchy.migrations,
    )
    isnothing(index) && _semantic_fail(:unknown_definition_migration, "definition migration is not declared")
    return hierarchy.migrations[index]
end

function _definition_record(definition::ReusableDefinition, id::ProjectId)
    index = findfirst(record -> record.identity.id == id, definition.records)
    isnothing(index) && _semantic_fail(:unknown_definition_record, "definition record does not exist")
    return definition.records[index]
end

function _definition_asset(definition::ReusableDefinition, id::ProjectId)
    index = findfirst(asset -> asset.identity.id == id, definition.assets)
    isnothing(index) && _semantic_fail(:unknown_definition_asset, "definition asset does not exist")
    return definition.assets[index]
end

function _definition_external_port(definition::ReusableDefinition, id::ProjectId)
    index = findfirst(port -> port.id == id, definition.external_ports)
    isnothing(index) && _semantic_fail(:unknown_definition_port, "definition external port does not exist")
    return definition.external_ports[index]
end

function _definition_parameter(definition::ReusableDefinition, name::String)
    index = findfirst(parameter -> parameter.field.name == name, definition.parameters)
    isnothing(index) && _semantic_fail(:unknown_definition_parameter, "instance supplies an unknown definition parameter")
    return definition.parameters[index]
end

function _validate_definition_parameter(project::CanonicalProject, parameter::DefinitionParameterSpec)
    !isnothing(parameter.default) && validate_field_value(parameter.field, parameter.default, project.units)
    return true
end

function _validate_definition_external_port(
    definition::ReusableDefinition,
    external::DefinitionExternalPort,
)
    index = findfirst(port -> port.identity.id == external.internal_port, definition.internals.ports)
    isnothing(index) && _semantic_fail(:dangling_definition_port, "external port has no internal port")
    internal = definition.internals.ports[index]
    internal.domain == external.domain && internal.direction == external.direction &&
        internal.carriers == external.carriers && internal.signal_contract == external.signal_contract ||
        _semantic_fail(:definition_port_contract_mismatch, "external and internal port contracts differ")
    return true
end

function _validate_definition_binding(
    project::CanonicalProject,
    definition::ReusableDefinition,
    binding::DefinitionParameterBinding,
)
    parameter = _definition_parameter(definition, binding.parameter)
    if binding.target == DefinitionRecordField
        length(binding.path.segments) == 1 ||
            _semantic_fail(:invalid_record_binding_path, "record parameter binding requires one field segment")
        record = _definition_record(definition, binding.owner)
        field_name = binding.path.segments[1].value
        any(field -> field.name == field_name, record.fields) ||
            _semantic_fail(:dangling_record_binding, "parameter binding record field does not exist")
        target_field = schema_field(resolve_schema(project.registry, record.schema), field_name)
        parameter.field.kind == target_field.kind && parameter.field.constraints == target_field.constraints ||
            _semantic_fail(:parameter_binding_type_mismatch, "parameter and bound record field contracts differ")
    else
        _definition_asset(definition, binding.owner)
    end
    return true
end

function _validate_instance_parameter(
    project::CanonicalProject,
    definition::ReusableDefinition,
    value::InstanceParameterValue,
)
    specification = _definition_parameter(definition, value.name)
    validate_field_value(specification.field, value.value, project.units)
    return true
end

function _validate_instance_ports(
    definition::ReusableDefinition,
    instance::DefinitionInstance,
    target_graphs::SemanticGraphs,
)
    bound = Set(binding.external_port for binding in instance.port_bindings)
    required = Set(port.id for port in definition.external_ports)
    bound == required || _semantic_fail(:missing_instance_port_binding, "instance port bindings are incomplete")
    for binding in instance.port_bindings
        external = _definition_external_port(definition, binding.external_port)
        if external.domain.family == PhysicalGraph
            binding.target_kind == InstanceTargetNode ||
                _semantic_fail(:invalid_physical_instance_target, "physical definition port must bind to a node")
            index = findfirst(node -> node.identity.id == binding.target, target_graphs.nodes)
            isnothing(index) && _semantic_fail(:dangling_instance_target, "instance target node does not exist")
            node = target_graphs.nodes[index]
            node.domain == external.domain ||
                _semantic_fail(:instance_port_domain_mismatch, "instance physical port and node domains differ")
            mapped = Set(mapping.port_carrier for mapping in binding.carrier_mappings)
            mapped == Set(external.carriers) ||
                _semantic_fail(:incomplete_instance_carrier_map, "instance physical carrier map is incomplete")
            all(mapping -> mapping.node_carrier in node.carriers, binding.carrier_mappings) ||
                _semantic_fail(:unknown_instance_node_carrier, "instance binding targets an unknown node carrier")
            binding.delayed && _semantic_fail(:delay_on_physical_binding, "physical instance binding cannot be delayed")
        else
            binding.target_kind == InstanceTargetPort ||
                _semantic_fail(:invalid_signal_instance_target, "signal definition port must bind to a signal port")
            index = findfirst(port -> port.identity.id == binding.target, target_graphs.ports)
            isnothing(index) && _semantic_fail(:dangling_instance_target, "instance target signal port does not exist")
            target = target_graphs.ports[index]
            target.domain == external.domain && target.signal_contract == external.signal_contract ||
                _semantic_fail(:instance_signal_contract_mismatch, "instance signal contracts differ")
            target.direction != external.direction ||
                _semantic_fail(:instance_signal_direction_mismatch, "connected instance signal ports require opposite directions")
            isempty(binding.carrier_mappings) ||
                _semantic_fail(:carrier_on_signal_binding, "signal instance binding cannot map physical carriers")
        end
    end
    return true
end

function _validate_definition_instance(
    project::CanonicalProject,
    instance::DefinitionInstance,
    target_graphs::SemanticGraphs,
)
    definition = reusable_definition(
        project.hierarchy,
        instance.definition.target.id,
        instance.definition_version,
    )
    foreach(value -> _validate_instance_parameter(project, definition, value), instance.parameters)
    supplied = Set(value.name for value in instance.parameters)
    for parameter in definition.parameters
        parameter.field.required && parameter.field.name ∉ supplied &&
            _semantic_fail(:missing_instance_parameter, "instance omits a required parameter")
    end
    _validate_instance_ports(definition, instance, target_graphs)
    return true
end

function _definition_temporary_project(project::CanonicalProject, definition::ReusableDefinition)
    records = CanonicalRecord[
        CanonicalRecord(record.identity, record.schema, collect(record.fields), record.provenance)
        for record in definition.records
    ]
    return unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        records,
        definition.internals,
        AssetLibrary(assets = collect(definition.assets)),
        HierarchyModel(),
        definition.controls,
    )
end

function _validate_reusable_definition(project::CanonicalProject, definition::ReusableDefinition)
    definition.definition_type.namespace in Set(item.namespace for item in project.registry.namespaces) ||
        _semantic_fail(:unknown_definition_namespace, "definition type namespace is not registered")
    parameter_names = [parameter.field.name for parameter in definition.parameters]
    length(parameter_names) == length(unique(parameter_names)) ||
        _semantic_fail(:duplicate_definition_parameter, "definition repeats a parameter")
    external_ids = [port.id for port in definition.external_ports]
    length(external_ids) == length(unique(external_ids)) ||
        _semantic_fail(:duplicate_definition_port, "definition repeats an external port")
    record_ids = [record.identity.id for record in definition.records]
    length(record_ids) == length(unique(record_ids)) ||
        _semantic_fail(:duplicate_definition_record, "definition repeats an internal record")
    nested_ids = [instance.identity.id for instance in definition.nested_instances]
    length(nested_ids) == length(unique(nested_ids)) ||
        _semantic_fail(:duplicate_nested_instance, "definition repeats a nested instance")
    foreach(parameter -> _validate_definition_parameter(project, parameter), definition.parameters)
    foreach(port -> _validate_definition_external_port(definition, port), definition.external_ports)
    foreach(binding -> _validate_definition_binding(project, definition, binding), definition.parameter_bindings)
    binding_targets = [(binding.target, binding.owner, binding.path) for binding in definition.parameter_bindings]
    length(binding_targets) == length(unique(binding_targets)) ||
        _semantic_fail(:duplicate_parameter_binding_target, "definition binds multiple parameters to one target")
    metadata_parameters = [metadata.parameter for metadata in definition.property_metadata]
    length(metadata_parameters) == length(unique(metadata_parameters)) ||
        _semantic_fail(:duplicate_property_metadata, "definition repeats property metadata")
    foreach(metadata -> _definition_parameter(definition, metadata.parameter), definition.property_metadata)
    temporary = _definition_temporary_project(project, definition)
    foreach(record -> _validate_record(temporary, record), temporary.records)
    validate_graphs(temporary)
    validate_asset_library(temporary)
    validate_control_system(temporary)
    isempty(definition.internals.cross_references) ||
        _semantic_fail(:definition_cross_reference_unsupported, "definition cross references require explicit external bindings")
    isempty(definition.internals.view_projections) ||
        _semantic_fail(:definition_view_physics_mixing, "definition internals cannot store view projections")
    !isnothing(definition.documentation) && definition.documentation.media_type != "text/markdown" &&
        _semantic_fail(:invalid_definition_documentation, "definition documentation artifact must be Markdown")
    if !isnothing(definition.default_view)
        definition.default_view.kind == ReferenceView ||
            _semantic_fail(:invalid_definition_default_view, "definition default view requires a view reference")
    end
    for provider in definition.report_providers
        provider.namespace in Set(item.namespace for item in project.registry.namespaces) ||
            _semantic_fail(:unknown_report_provider_namespace, "definition report provider namespace is not registered")
    end
    for nested in definition.nested_instances
        _validate_definition_instance(project, nested, definition.internals)
    end
    return true
end

function _definition_cycle(hierarchy::HierarchyModel)
    keys = [(definition.identity.id, definition.definition_type.version) for definition in hierarchy.definitions]
    adjacency = [Tuple{ProjectId,VersionNumber}[] for _ in keys]
    for (index, definition) in pairs(hierarchy.definitions), nested in definition.nested_instances
        push!(adjacency[index], (nested.definition.target.id, nested.definition_version))
    end
    state = fill(UInt8(0), length(keys))
    function visit(index)
        state[index] == 0x01 && return true
        state[index] == 0x02 && return false
        state[index] = 0x01
        for target in adjacency[index]
            target_index = findfirst(==(target), keys)
            isnothing(target_index) || !visit(target_index) || return true
        end
        state[index] = 0x02
        return false
    end
    return any(visit, eachindex(keys))
end

"""Validate definition versions, independent instances, bindings, nesting, and migrations."""
function validate_hierarchy(project::CanonicalProject)
    hierarchy = project.hierarchy
    definition_keys = [(item.identity.id, item.definition_type.version) for item in hierarchy.definitions]
    length(definition_keys) == length(unique(definition_keys)) ||
        _semantic_fail(:duplicate_definition_version, "hierarchy repeats a definition version")
    instance_ids = [instance.identity.id for instance in hierarchy.instances]
    length(instance_ids) == length(unique(instance_ids)) ||
        _semantic_fail(:duplicate_definition_instance, "hierarchy repeats an instance ID")
    semantic_ids = Set(vcat(
        [record.identity.id for record in project.records],
        _graph_element_ids(project.graphs),
        [item.identity.id for item in project.asset_library.profiles],
        [item.identity.id for item in project.asset_library.curves],
        [item.identity.id for item in project.asset_library.matrices],
        [item.identity.id for item in project.asset_library.measurements],
        _control_owner_ids(project.control_system),
    ))
    isempty(intersect(semantic_ids, Set(instance_ids))) ||
        _semantic_fail(:instance_identity_collision, "instance ID collides with project semantics")
    foreach(definition -> _validate_reusable_definition(project, definition), hierarchy.definitions)
    _definition_cycle(hierarchy) && _semantic_fail(:recursive_definition_cycle, "definition nesting contains a cycle")
    foreach(instance -> _validate_definition_instance(project, instance, project.graphs), hierarchy.instances)
    migration_keys = [(item.definition, item.from_version, item.to_version) for item in hierarchy.migrations]
    length(migration_keys) == length(unique(migration_keys)) ||
        _semantic_fail(:duplicate_definition_migration, "hierarchy repeats a migration")
    for migration in hierarchy.migrations
        reusable_definition(hierarchy, migration.definition, migration.from_version)
        reusable_definition(hierarchy, migration.definition, migration.to_version)
        migration.operation.namespace in Set(item.namespace for item in project.registry.namespaces) ||
            _semantic_fail(:unknown_migration_namespace, "definition migration operation namespace is not registered")
    end
    return true
end
