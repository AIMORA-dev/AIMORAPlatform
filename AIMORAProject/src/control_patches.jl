struct AddControlBlockSchemaPatch <: ProjectPatch
    schema::ControlBlockSchema
end

Base.:(==)(left::AddControlBlockSchemaPatch, right::AddControlBlockSchemaPatch) =
    left.schema == right.schema

struct RemoveControlBlockSchemaPatch <: ProjectPatch
    identity::SemanticSchemaIdentity
end

Base.:(==)(left::RemoveControlBlockSchemaPatch, right::RemoveControlBlockSchemaPatch) =
    left.identity == right.identity

struct AddControlNetworkPatch <: ProjectPatch
    network::ControlNetwork
end

Base.:(==)(left::AddControlNetworkPatch, right::AddControlNetworkPatch) =
    left.network == right.network

struct RemoveControlNetworkPatch <: ProjectPatch
    id::ProjectId
end

Base.:(==)(left::RemoveControlNetworkPatch, right::RemoveControlNetworkPatch) =
    left.id == right.id

struct ReplaceControlNetworkPatch <: ProjectPatch
    network::ControlNetwork
end

Base.:(==)(left::ReplaceControlNetworkPatch, right::ReplaceControlNetworkPatch) =
    left.network == right.network

function _control_system_with(
    system::ControlSystem;
    block_schemas = collect(system.block_schemas),
    networks = collect(system.networks),
)
    return ControlSystem(; block_schemas, networks)
end

function _control_effect(owner::ProjectId)
    return CommandEffect(
        owner,
        DependencyInvalidation(owner, [InvalidateStudyResults, InvalidateWorkflowResults, InvalidateViews]),
    )
end

function _apply_patch(project::CanonicalProject, patch::AddControlBlockSchemaPatch)
    any(item -> item.identity == patch.schema.identity, project.control_system.block_schemas) &&
        _semantic_fail(:duplicate_control_block_schema, "add-control-schema patch targets an existing identity")
    schemas = vcat(collect(project.control_system.block_schemas), [patch.schema])
    updated = _replace_control_system(project, _control_system_with(project.control_system; block_schemas = schemas))
    return updated, _control_effect(patch.schema.identity.name)
end

function _apply_patch(project::CanonicalProject, patch::RemoveControlBlockSchemaPatch)
    any(network -> any(block -> block.schema == patch.identity, network.blocks), project.control_system.networks) &&
        _semantic_fail(:control_schema_has_dependents, "control block schema is used by a network")
    schemas = collect(project.control_system.block_schemas)
    index = findfirst(item -> item.identity == patch.identity, schemas)
    isnothing(index) &&
        _semantic_fail(:unknown_control_block_schema, "remove-control-schema target does not exist")
    deleteat!(schemas, index)
    updated = _replace_control_system(project, _control_system_with(project.control_system; block_schemas = schemas))
    return updated, _control_effect(patch.identity.name)
end

function _apply_patch(project::CanonicalProject, patch::AddControlNetworkPatch)
    any(item -> item.identity.id == patch.network.identity.id, project.control_system.networks) &&
        _semantic_fail(:duplicate_control_network, "add-control-network patch targets an existing ID")
    networks = vcat(collect(project.control_system.networks), [patch.network])
    updated = _replace_control_system(project, _control_system_with(project.control_system; networks))
    return updated, _control_effect(patch.network.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveControlNetworkPatch)
    networks = collect(project.control_system.networks)
    index = findfirst(item -> item.identity.id == patch.id, networks)
    isnothing(index) && _semantic_fail(:unknown_control_network, "remove-control-network target does not exist")
    deleteat!(networks, index)
    updated = _replace_control_system(project, _control_system_with(project.control_system; networks))
    return updated, _control_effect(patch.id)
end

function _apply_patch(project::CanonicalProject, patch::ReplaceControlNetworkPatch)
    networks = collect(project.control_system.networks)
    index = findfirst(item -> item.identity.id == patch.network.identity.id, networks)
    isnothing(index) && _semantic_fail(:unknown_control_network, "replace-control-network target does not exist")
    networks[index] == patch.network &&
        _semantic_fail(:no_effect_command, "replace-control-network does not change the network")
    networks[index] = patch.network
    updated = _replace_control_system(project, _control_system_with(project.control_system; networks))
    return updated, _control_effect(patch.network.identity.id)
end

_inverse_patch(patch::AddControlBlockSchemaPatch, ::CanonicalProject) =
    RemoveControlBlockSchemaPatch(patch.schema.identity)

function _inverse_patch(patch::RemoveControlBlockSchemaPatch, project::CanonicalProject)
    return AddControlBlockSchemaPatch(control_block_schema(project.control_system, patch.identity))
end

_inverse_patch(patch::AddControlNetworkPatch, ::CanonicalProject) =
    RemoveControlNetworkPatch(patch.network.identity.id)

function _inverse_patch(patch::RemoveControlNetworkPatch, project::CanonicalProject)
    return AddControlNetworkPatch(control_network(project.control_system, patch.id))
end

function _inverse_patch(patch::ReplaceControlNetworkPatch, project::CanonicalProject)
    return ReplaceControlNetworkPatch(control_network(project.control_system, patch.network.identity.id))
end

_patch_signature(patch::AddControlBlockSchemaPatch) =
    "add-control-schema:" * patch.schema.identity.namespace.value * ":" *
    patch.schema.identity.name.value * ":" * string(patch.schema.identity.version)

_patch_signature(patch::RemoveControlBlockSchemaPatch) =
    "remove-control-schema:" * patch.identity.namespace.value * ":" *
    patch.identity.name.value * ":" * string(patch.identity.version)

_patch_signature(patch::AddControlNetworkPatch) =
    "add-control-network:" * patch.network.identity.id.value

_patch_signature(patch::RemoveControlNetworkPatch) =
    "remove-control-network:" * patch.id.value

_patch_signature(patch::ReplaceControlNetworkPatch) =
    "replace-control-network:" * patch.network.identity.id.value

_declared_patch_effect(::CanonicalProject, patch::AddControlBlockSchemaPatch) =
    _control_effect(patch.schema.identity.name)

_declared_patch_effect(::CanonicalProject, patch::RemoveControlBlockSchemaPatch) =
    _control_effect(patch.identity.name)

_declared_patch_effect(::CanonicalProject, patch::AddControlNetworkPatch) =
    _control_effect(patch.network.identity.id)

_declared_patch_effect(::CanonicalProject, patch::RemoveControlNetworkPatch) =
    _control_effect(patch.id)

_declared_patch_effect(::CanonicalProject, patch::ReplaceControlNetworkPatch) =
    _control_effect(patch.network.identity.id)
