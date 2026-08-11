struct AddReusableDefinitionPatch <: ProjectPatch
    definition::ReusableDefinition
end

Base.:(==)(left::AddReusableDefinitionPatch, right::AddReusableDefinitionPatch) =
    left.definition == right.definition

struct RemoveReusableDefinitionPatch <: ProjectPatch
    id::ProjectId
    version::VersionNumber
end

Base.:(==)(left::RemoveReusableDefinitionPatch, right::RemoveReusableDefinitionPatch) =
    left.id == right.id && left.version == right.version

struct AddDefinitionInstancePatch <: ProjectPatch
    instance::DefinitionInstance
end

Base.:(==)(left::AddDefinitionInstancePatch, right::AddDefinitionInstancePatch) =
    left.instance == right.instance

struct RemoveDefinitionInstancePatch <: ProjectPatch
    id::ProjectId
end

Base.:(==)(left::RemoveDefinitionInstancePatch, right::RemoveDefinitionInstancePatch) = left.id == right.id

struct SetInstanceParameterPatch <: ProjectPatch
    instance::ProjectId
    value::InstanceParameterValue
end

Base.:(==)(left::SetInstanceParameterPatch, right::SetInstanceParameterPatch) =
    left.instance == right.instance && left.value == right.value

struct UnsetInstanceParameterPatch <: ProjectPatch
    instance::ProjectId
    parameter::String

    function UnsetInstanceParameterPatch(instance::ProjectId, parameter::AbstractString)
        normalized = String(parameter)
        occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
            _semantic_fail(:invalid_instance_parameter, "instance parameter name is not portable")
        return new(instance, normalized)
    end
end

Base.:(==)(left::UnsetInstanceParameterPatch, right::UnsetInstanceParameterPatch) =
    left.instance == right.instance && left.parameter == right.parameter

struct AddDefinitionMigrationPatch <: ProjectPatch
    migration::DefinitionMigration
end

Base.:(==)(left::AddDefinitionMigrationPatch, right::AddDefinitionMigrationPatch) =
    left.migration == right.migration

struct RemoveDefinitionMigrationPatch <: ProjectPatch
    definition::ProjectId
    from_version::VersionNumber
    to_version::VersionNumber
end

Base.:(==)(left::RemoveDefinitionMigrationPatch, right::RemoveDefinitionMigrationPatch) =
    left.definition == right.definition && left.from_version == right.from_version &&
    left.to_version == right.to_version

function _hierarchy_with(
    hierarchy::HierarchyModel;
    definitions = collect(hierarchy.definitions),
    instances = collect(hierarchy.instances),
    migrations = collect(hierarchy.migrations),
)
    return HierarchyModel(; definitions, instances, migrations)
end

_hierarchy_effect(owner::ProjectId) = CommandEffect(
    owner,
    DependencyInvalidation(owner, [InvalidateStudyResults, InvalidateWorkflowResults, InvalidateViews]),
)

function _apply_patch(project::CanonicalProject, patch::AddReusableDefinitionPatch)
    key = (patch.definition.identity.id, patch.definition.definition_type.version)
    any(definition -> (definition.identity.id, definition.definition_type.version) == key,
        project.hierarchy.definitions) &&
        _semantic_fail(:duplicate_definition_version, "add-definition patch targets an existing version")
    hierarchy = _hierarchy_with(
        project.hierarchy;
        definitions = vcat(collect(project.hierarchy.definitions), [patch.definition]),
    )
    return _replace_hierarchy(project, hierarchy), _hierarchy_effect(patch.definition.identity.id)
end

function _definition_has_dependents(
    hierarchy::HierarchyModel,
    id::ProjectId,
    version::VersionNumber,
)
    any(instance -> instance.definition.target.id == id && instance.definition_version == version,
        hierarchy.instances) && return true
    for definition in hierarchy.definitions
        any(instance -> instance.definition.target.id == id && instance.definition_version == version,
            definition.nested_instances) && return true
    end
    return any(migration -> migration.definition == id &&
        (migration.from_version == version || migration.to_version == version), hierarchy.migrations)
end

function _apply_patch(project::CanonicalProject, patch::RemoveReusableDefinitionPatch)
    definitions = collect(project.hierarchy.definitions)
    index = findfirst(definition -> definition.identity.id == patch.id &&
        definition.definition_type.version == patch.version, definitions)
    isnothing(index) && _semantic_fail(:unknown_definition_version, "remove-definition target does not exist")
    _definition_has_dependents(project.hierarchy, patch.id, patch.version) &&
        _semantic_fail(:definition_has_dependents, "definition version has instances or migrations")
    deleteat!(definitions, index)
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; definitions)),
        _hierarchy_effect(patch.id)
end

function _apply_patch(project::CanonicalProject, patch::AddDefinitionInstancePatch)
    any(instance -> instance.identity.id == patch.instance.identity.id, project.hierarchy.instances) &&
        _semantic_fail(:duplicate_definition_instance, "add-instance patch targets an existing ID")
    instances = vcat(collect(project.hierarchy.instances), [patch.instance])
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; instances)),
        _hierarchy_effect(patch.instance.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveDefinitionInstancePatch)
    instances, _ = _remove_by_id(
        project.hierarchy.instances,
        patch.id,
        :unknown_definition_instance,
        "remove-instance target does not exist",
    )
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; instances)),
        _hierarchy_effect(patch.id)
end

function _instance_with_parameters(instance::DefinitionInstance, parameters)
    return DefinitionInstance(
        instance.identity,
        instance.definition,
        instance.definition_version,
        parameters,
        collect(instance.port_bindings),
        instance.provenance,
    )
end

function _replace_top_level_instance(project::CanonicalProject, replacement::DefinitionInstance)
    instances = collect(project.hierarchy.instances)
    index = findfirst(instance -> instance.identity.id == replacement.identity.id, instances)
    isnothing(index) && _semantic_fail(:unknown_definition_instance, "instance patch target does not exist")
    instances[index] = replacement
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; instances))
end

function _apply_patch(project::CanonicalProject, patch::SetInstanceParameterPatch)
    instance = definition_instance(project.hierarchy, patch.instance)
    parameters = collect(instance.parameters)
    index = findfirst(value -> value.name == patch.value.name, parameters)
    !isnothing(index) && parameters[index] == patch.value &&
        _semantic_fail(:no_effect_command, "set-instance-parameter does not change the instance")
    isnothing(index) ? push!(parameters, patch.value) : (parameters[index] = patch.value)
    return _replace_top_level_instance(project, _instance_with_parameters(instance, parameters)),
        _hierarchy_effect(patch.instance)
end

function _apply_patch(project::CanonicalProject, patch::UnsetInstanceParameterPatch)
    instance = definition_instance(project.hierarchy, patch.instance)
    parameters = collect(instance.parameters)
    index = findfirst(value -> value.name == patch.parameter, parameters)
    isnothing(index) && _semantic_fail(:unknown_instance_parameter, "unset-instance-parameter target does not exist")
    deleteat!(parameters, index)
    return _replace_top_level_instance(project, _instance_with_parameters(instance, parameters)),
        _hierarchy_effect(patch.instance)
end

function _apply_patch(project::CanonicalProject, patch::AddDefinitionMigrationPatch)
    key = (patch.migration.definition, patch.migration.from_version, patch.migration.to_version)
    any(migration -> (migration.definition, migration.from_version, migration.to_version) == key,
        project.hierarchy.migrations) &&
        _semantic_fail(:duplicate_definition_migration, "add-migration patch targets an existing route")
    migrations = vcat(collect(project.hierarchy.migrations), [patch.migration])
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; migrations)),
        _hierarchy_effect(patch.migration.definition)
end

function _apply_patch(project::CanonicalProject, patch::RemoveDefinitionMigrationPatch)
    migrations = collect(project.hierarchy.migrations)
    index = findfirst(migration -> migration.definition == patch.definition &&
        migration.from_version == patch.from_version && migration.to_version == patch.to_version,
        migrations)
    isnothing(index) && _semantic_fail(:unknown_definition_migration, "remove-migration target does not exist")
    deleteat!(migrations, index)
    return _replace_hierarchy(project, _hierarchy_with(project.hierarchy; migrations)),
        _hierarchy_effect(patch.definition)
end

_inverse_patch(patch::AddReusableDefinitionPatch, ::CanonicalProject) =
    RemoveReusableDefinitionPatch(patch.definition.identity.id, patch.definition.definition_type.version)
_inverse_patch(patch::RemoveReusableDefinitionPatch, project::CanonicalProject) =
    AddReusableDefinitionPatch(reusable_definition(project.hierarchy, patch.id, patch.version))
_inverse_patch(patch::AddDefinitionInstancePatch, ::CanonicalProject) =
    RemoveDefinitionInstancePatch(patch.instance.identity.id)
_inverse_patch(patch::RemoveDefinitionInstancePatch, project::CanonicalProject) =
    AddDefinitionInstancePatch(definition_instance(project.hierarchy, patch.id))

function _instance_parameter(instance::DefinitionInstance, name::String)
    index = findfirst(value -> value.name == name, instance.parameters)
    return isnothing(index) ? nothing : instance.parameters[index]
end

function _inverse_patch(patch::SetInstanceParameterPatch, project::CanonicalProject)
    previous = _instance_parameter(definition_instance(project.hierarchy, patch.instance), patch.value.name)
    return isnothing(previous) ?
        UnsetInstanceParameterPatch(patch.instance, patch.value.name) :
        SetInstanceParameterPatch(patch.instance, previous)
end

function _inverse_patch(patch::UnsetInstanceParameterPatch, project::CanonicalProject)
    previous = _instance_parameter(definition_instance(project.hierarchy, patch.instance), patch.parameter)
    isnothing(previous) && _semantic_fail(:invalid_command_inverse, "instance parameter is absent before removal")
    return SetInstanceParameterPatch(patch.instance, previous)
end

_inverse_patch(patch::AddDefinitionMigrationPatch, ::CanonicalProject) = RemoveDefinitionMigrationPatch(
    patch.migration.definition,
    patch.migration.from_version,
    patch.migration.to_version,
)
_inverse_patch(patch::RemoveDefinitionMigrationPatch, project::CanonicalProject) = AddDefinitionMigrationPatch(
    definition_migration(project.hierarchy, patch.definition, patch.from_version, patch.to_version),
)

_patch_signature(patch::AddReusableDefinitionPatch) =
    "add-definition:" * patch.definition.identity.id.value * ":" * string(patch.definition.definition_type.version)
_patch_signature(patch::RemoveReusableDefinitionPatch) =
    "remove-definition:" * patch.id.value * ":" * string(patch.version)
_patch_signature(patch::AddDefinitionInstancePatch) = "add-instance:" * patch.instance.identity.id.value
_patch_signature(patch::RemoveDefinitionInstancePatch) = "remove-instance:" * patch.id.value
_patch_signature(patch::SetInstanceParameterPatch) =
    "set-instance-parameter:" * patch.instance.value * ":" * patch.value.name
_patch_signature(patch::UnsetInstanceParameterPatch) =
    "unset-instance-parameter:" * patch.instance.value * ":" * patch.parameter
_patch_signature(patch::AddDefinitionMigrationPatch) =
    "add-definition-migration:" * patch.migration.definition.value * ":" *
    string(patch.migration.from_version) * ":" * string(patch.migration.to_version)
_patch_signature(patch::RemoveDefinitionMigrationPatch) =
    "remove-definition-migration:" * patch.definition.value * ":" *
    string(patch.from_version) * ":" * string(patch.to_version)

_declared_patch_effect(::CanonicalProject, patch::AddReusableDefinitionPatch) =
    _hierarchy_effect(patch.definition.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveReusableDefinitionPatch) = _hierarchy_effect(patch.id)
_declared_patch_effect(::CanonicalProject, patch::AddDefinitionInstancePatch) =
    _hierarchy_effect(patch.instance.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveDefinitionInstancePatch) = _hierarchy_effect(patch.id)
_declared_patch_effect(::CanonicalProject, patch::SetInstanceParameterPatch) = _hierarchy_effect(patch.instance)
_declared_patch_effect(::CanonicalProject, patch::UnsetInstanceParameterPatch) = _hierarchy_effect(patch.instance)
_declared_patch_effect(::CanonicalProject, patch::AddDefinitionMigrationPatch) =
    _hierarchy_effect(patch.migration.definition)
_declared_patch_effect(::CanonicalProject, patch::RemoveDefinitionMigrationPatch) =
    _hierarchy_effect(patch.definition)
