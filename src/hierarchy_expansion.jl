struct InstanceExpansion
    instance::ProjectId
    records::CanonicalList{CanonicalRecord}
    assets::CanonicalList{CanonicalAsset}
    graphs::SemanticGraphs
    identities::CanonicalList{ExpansionIdentity}
end

Base.:(==)(left::InstanceExpansion, right::InstanceExpansion) =
    left.instance == right.instance && left.records == right.records &&
    left.assets == right.assets && left.graphs == right.graphs &&
    left.identities == right.identities

_scoped_id(prefix::ProjectId, local_id::ProjectId) = ProjectId(prefix.value * "." * local_id.value)

function _scoped_identity(prefix::ProjectId, identity::ObjectIdentity)
    return ObjectIdentity(_scoped_id(prefix, identity.id))
end

function _instance_parameter_value(
    definition::ReusableDefinition,
    instance::DefinitionInstance,
    name::String,
)
    index = findfirst(value -> value.name == name, instance.parameters)
    !isnothing(index) && return instance.parameters[index].value, instance.parameters[index].provenance
    parameter = _definition_parameter(definition, name)
    isnothing(parameter.default) && _semantic_fail(:missing_instance_parameter, "instance parameter has no value or default")
    return parameter.default, definition.provenance
end

function _replace_definition_field(
    fields::Vector{CanonicalField},
    name::String,
    value::CanonicalFieldData,
)
    index = findfirst(field -> field.name == name, fields)
    isnothing(index) && _semantic_fail(:dangling_record_binding, "expanded record field does not exist")
    fields[index] = CanonicalField(name, value)
    return fields
end

function _expanded_records(
    definition::ReusableDefinition,
    instance::DefinitionInstance,
    prefix::ProjectId,
)
    records = CanonicalRecord[]
    for template in definition.records
        fields = collect(template.fields)
        id_index = findfirst(field -> field.name == "id", fields)
        !isnothing(id_index) && (fields[id_index] = CanonicalField("id", _scoped_id(prefix, template.identity.id).value))
        for binding in definition.parameter_bindings
            binding.target == DefinitionRecordField && binding.owner == template.identity.id || continue
            value, _ = _instance_parameter_value(definition, instance, binding.parameter)
            _replace_definition_field(fields, binding.path.segments[1].value, value)
        end
        push!(records, CanonicalRecord(
            _scoped_identity(prefix, template.identity),
            template.schema,
            fields,
            template.provenance,
        ))
    end
    return records
end

function _expanded_assets(
    definition::ReusableDefinition,
    instance::DefinitionInstance,
    prefix::ProjectId,
)
    assets = CanonicalAsset[]
    for template in definition.assets
        common = collect(template.common)
        for binding in definition.parameter_bindings
            binding.target == DefinitionAssetCommonProperty && binding.owner == template.identity.id || continue
            value, provenance = _instance_parameter_value(definition, instance, binding.parameter)
            property = AssetProperty(binding.path, value, provenance)
            index = findfirst(existing -> existing.path == binding.path, common)
            isnothing(index) ? push!(common, property) : (common[index] = property)
        end
        push!(assets, CanonicalAsset(
            _scoped_identity(prefix, template.identity),
            template.asset_type,
            common,
            collect(template.realizations),
            template.provenance;
            catalog = template.catalog,
            overrides = collect(template.overrides),
            access = template.access,
        ))
    end
    return assets
end

function _expanded_internal_graphs(definition::ReusableDefinition, prefix::ProjectId)
    graphs = definition.internals
    nodes = GraphNode[
        GraphNode(
            _scoped_identity(prefix, node.identity),
            node.domain,
            collect(node.carriers),
            node.provenance;
            nominal_level = node.nominal_level,
        ) for node in graphs.nodes
    ]
    ports = SemanticPort[
        SemanticPort(
            _scoped_identity(prefix, port.identity),
            _scoped_id(prefix, port.owner),
            port.domain,
            port.direction,
            collect(port.carriers),
            port.provenance;
            nominal_level = port.nominal_level,
            signal_contract = port.signal_contract,
        ) for port in graphs.ports
    ]
    physical_connections = PhysicalConnection[
        PhysicalConnection(
            _scoped_identity(prefix, connection.identity),
            _scoped_id(prefix, connection.port),
            _scoped_id(prefix, connection.node),
            collect(connection.mappings),
            connection.provenance,
        ) for connection in graphs.physical_connections
    ]
    signal_connections = SignalConnection[
        SignalConnection(
            _scoped_identity(prefix, connection.identity),
            _scoped_id(prefix, connection.source_port),
            _scoped_id(prefix, connection.target_port),
            connection.delayed,
            connection.provenance,
        ) for connection in graphs.signal_connections
    ]
    workflow_dependencies = WorkflowDependency[
        WorkflowDependency(
            _scoped_identity(prefix, dependency.identity),
            _scoped_id(prefix, dependency.upstream),
            _scoped_id(prefix, dependency.downstream),
            dependency.provenance,
        ) for dependency in graphs.workflow_dependencies
    ]
    return SemanticGraphs(; nodes, ports, physical_connections, signal_connections, workflow_dependencies)
end

function _binding_connections(
    definition::ReusableDefinition,
    instance::DefinitionInstance,
    prefix::ProjectId,
    target_prefix::Union{Nothing,ProjectId},
)
    physical = PhysicalConnection[]
    signals = SignalConnection[]
    for binding in instance.port_bindings
        external = _definition_external_port(definition, binding.external_port)
        internal = _scoped_id(prefix, external.internal_port)
        target = isnothing(target_prefix) ? binding.target : _scoped_id(target_prefix, binding.target)
        identity = ObjectIdentity(_scoped_id(prefix, ProjectId("binding." * external.id.value)))
        if external.domain.family == PhysicalGraph
            push!(physical, PhysicalConnection(
                identity,
                internal,
                target,
                collect(binding.carrier_mappings),
                instance.provenance,
            ))
        elseif external.direction == PortInput
            push!(signals, SignalConnection(identity, target, internal, binding.delayed, instance.provenance))
        else
            push!(signals, SignalConnection(identity, internal, target, binding.delayed, instance.provenance))
        end
    end
    return physical, signals
end

function _merge_expansion_graphs(parts::AbstractVector{SemanticGraphs})
    return SemanticGraphs(;
        nodes = reduce(vcat, (collect(part.nodes) for part in parts); init = GraphNode[]),
        ports = reduce(vcat, (collect(part.ports) for part in parts); init = SemanticPort[]),
        physical_connections = reduce(vcat, (collect(part.physical_connections) for part in parts); init = PhysicalConnection[]),
        signal_connections = reduce(vcat, (collect(part.signal_connections) for part in parts); init = SignalConnection[]),
        workflow_dependencies = reduce(vcat, (collect(part.workflow_dependencies) for part in parts); init = WorkflowDependency[]),
    )
end

function _expand_instance(
    project::CanonicalProject,
    instance::DefinitionInstance,
    prefix::ProjectId,
    target_prefix::Union{Nothing,ProjectId},
)
    definition = reusable_definition(project.hierarchy, instance.definition.target.id, instance.definition_version)
    records = _expanded_records(definition, instance, prefix)
    assets = _expanded_assets(definition, instance, prefix)
    graphs = _expanded_internal_graphs(definition, prefix)
    physical, signals = _binding_connections(definition, instance, prefix, target_prefix)
    graphs = _merge_expansion_graphs([
        graphs,
        SemanticGraphs(physical_connections = physical, signal_connections = signals),
    ])
    identities = ExpansionIdentity[]
    for owner in vcat(
        [record.identity.id for record in definition.records],
        _graph_element_ids(definition.internals),
    )
        push!(identities, ExpansionIdentity(prefix, owner, _scoped_id(prefix, owner)))
    end
    for nested in definition.nested_instances
        nested_prefix = _scoped_id(prefix, nested.identity.id)
        expanded = _expand_instance(project, nested, nested_prefix, prefix)
        append!(records, collect(expanded.records))
        append!(assets, collect(expanded.assets))
        graphs = _merge_expansion_graphs([graphs, expanded.graphs])
        append!(identities, collect(expanded.identities))
    end
    sort!(identities; by = item -> item.expanded_owner.value)
    return InstanceExpansion(
        prefix,
        CanonicalList{CanonicalRecord}(sort!(records; by = item -> item.identity.id.value)),
        CanonicalList{CanonicalAsset}(sort!(assets; by = item -> item.identity.id.value)),
        graphs,
        CanonicalList{ExpansionIdentity}(identities),
    )
end

"""Deterministically expand one immutable instance to primitive canonical owners."""
function expand_instance(project::CanonicalProject, instance::DefinitionInstance)
    _validate_definition_instance(project, instance, project.graphs)
    expanded = _expand_instance(project, instance, instance.identity.id, nothing)
    combined_graphs = _merge_expansion_graphs([project.graphs, expanded.graphs])
    temporary = unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        vcat(collect(project.records), collect(expanded.records)),
        combined_graphs,
        AssetLibrary(;
            assets = vcat(collect(project.asset_library.assets), collect(expanded.assets)),
            profiles = collect(project.asset_library.profiles),
            curves = collect(project.asset_library.curves),
            matrices = collect(project.asset_library.matrices),
            measurements = collect(project.asset_library.measurements),
        ),
    )
    foreach(record -> _validate_record(temporary, record), expanded.records)
    validate_graphs(temporary)
    validate_asset_library(temporary)
    return expanded
end

expand_instance(project::CanonicalProject, id::ProjectId) =
    expand_instance(project, definition_instance(project.hierarchy, id))
