@enum AssetDataKind::UInt8 begin
    ProfileData = 0x01
    CurveData = 0x02
    MatrixData = 0x03
    MeasurementData = 0x04
end

const CanonicalAssetData = Union{
    ProfileDescriptor,
    CurveDescriptor,
    MatrixDescriptor,
    MeasurementDefinition,
}

struct AddAssetPatch <: ProjectPatch
    asset::CanonicalAsset
end

Base.:(==)(left::AddAssetPatch, right::AddAssetPatch) = left.asset == right.asset

struct RemoveAssetPatch <: ProjectPatch
    owner::ProjectId
end


Base.:(==)(left::RemoveAssetPatch, right::RemoveAssetPatch) = left.owner == right.owner

struct SetAssetCommonPropertyPatch <: ProjectPatch
    owner::ProjectId
    property::AssetProperty
end

Base.:(==)(left::SetAssetCommonPropertyPatch, right::SetAssetCommonPropertyPatch) =
    left.owner == right.owner && left.property == right.property

struct UnsetAssetCommonPropertyPatch <: ProjectPatch
    owner::ProjectId
    path::FieldPath
end

Base.:(==)(left::UnsetAssetCommonPropertyPatch, right::UnsetAssetCommonPropertyPatch) =
    left.owner == right.owner && left.path == right.path

struct AddStudyRealizationPatch <: ProjectPatch
    owner::ProjectId
    realization::StudyRealization
end

Base.:(==)(left::AddStudyRealizationPatch, right::AddStudyRealizationPatch) =
    left.owner == right.owner && left.realization == right.realization

struct RemoveStudyRealizationPatch <: ProjectPatch
    owner::ProjectId
    realization::ProjectId
end

Base.:(==)(left::RemoveStudyRealizationPatch, right::RemoveStudyRealizationPatch) =
    left.owner == right.owner && left.realization == right.realization

struct ReplaceStudyRealizationPatch <: ProjectPatch
    owner::ProjectId
    realization::StudyRealization
end

Base.:(==)(left::ReplaceStudyRealizationPatch, right::ReplaceStudyRealizationPatch) =
    left.owner == right.owner && left.realization == right.realization

struct AddAssetDataPatch <: ProjectPatch
    element::CanonicalAssetData
end

Base.:(==)(left::AddAssetDataPatch, right::AddAssetDataPatch) = left.element == right.element

struct RemoveAssetDataPatch <: ProjectPatch
    kind::AssetDataKind
    id::ProjectId
end

Base.:(==)(left::RemoveAssetDataPatch, right::RemoveAssetDataPatch) =
    left.kind == right.kind && left.id == right.id

function _library_with(
    library::AssetLibrary;
    assets = collect(library.assets),
    profiles = collect(library.profiles),
    curves = collect(library.curves),
    matrices = collect(library.matrices),
    measurements = collect(library.measurements),
)
    return AssetLibrary(; assets, profiles, curves, matrices, measurements)
end

function _asset_effect(owner::ProjectId)
    scopes = [InvalidateStudyResults, InvalidateWorkflowResults]
    return CommandEffect(owner, DependencyInvalidation(owner, scopes))
end

function _replace_asset(project::CanonicalProject, replacement::CanonicalAsset)
    assets = collect(project.asset_library.assets)
    index = findfirst(asset -> asset.identity.id == replacement.identity.id, assets)
    isnothing(index) && _semantic_fail(:unknown_asset_id, "asset patch target does not exist")
    assets[index] = replacement
    return _replace_asset_library(project, _library_with(project.asset_library; assets))
end

_local_reference_id(reference::ProjectReference) =
    reference.target isa LocalReferenceTarget ? reference.target.id : nothing

_property_references(property::AssetProperty, id::ProjectId) =
    property.value isa ProjectReference && _local_reference_id(property.value) == id

function _asset_references(asset::CanonicalAsset, id::ProjectId)
    any(property -> _property_references(property, id), asset.common) && return true
    any(override -> _property_references(override.property, id), asset.overrides) && return true
    for realization in asset.realizations
        any(property -> _property_references(property, id), realization.parameters) && return true
        any(property -> _property_references(property.property, id), realization.derived_parameters) && return true
    end
    return false
end

function _ensure_asset_removable(project::CanonicalProject, owner::ProjectId)
    any(port -> port.owner == owner, project.graphs.ports) &&
        _semantic_fail(:asset_has_graph_dependents, "asset owns graph ports and cannot be removed")
    any(reference -> _local_reference_id(reference.target) == owner, project.graphs.cross_references) &&
        _semantic_fail(:asset_has_graph_dependents, "asset is targeted by a cross-graph reference")
    any(measurement -> _local_reference_id(measurement.target) == owner, project.asset_library.measurements) &&
        _semantic_fail(:asset_has_measurement_dependents, "asset is targeted by a measurement")
    return true
end

function _ensure_asset_data_removable(project::CanonicalProject, id::ProjectId)
    any(asset -> _asset_references(asset, id), project.asset_library.assets) &&
        _semantic_fail(:asset_data_has_dependents, "asset data is referenced by a physical asset")
    any(
        measurement -> !isnothing(measurement.profile) && _local_reference_id(measurement.profile) == id,
        project.asset_library.measurements,
    ) && _semantic_fail(:asset_data_has_dependents, "profile is referenced by a measurement")
    return true
end

function _apply_patch(project::CanonicalProject, patch::AddAssetPatch)
    any(asset -> asset.identity.id == patch.asset.identity.id, project.asset_library.assets) &&
        _semantic_fail(:duplicate_asset_id, "add-asset patch targets an existing asset")
    _validate_asset(project, patch.asset)
    assets = vcat(collect(project.asset_library.assets), [patch.asset])
    return _replace_asset_library(project, _library_with(project.asset_library; assets)),
        _asset_effect(patch.asset.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveAssetPatch)
    assets, _ = _remove_by_id(
        project.asset_library.assets,
        patch.owner,
        :unknown_asset_id,
        "remove-asset patch target does not exist",
    )
    _ensure_asset_removable(project, patch.owner)
    return _replace_asset_library(project, _library_with(project.asset_library; assets)),
        _asset_effect(patch.owner)
end

function _asset_with(
    asset::CanonicalAsset;
    common = collect(asset.common),
    realizations = collect(asset.realizations),
)
    return CanonicalAsset(
        asset.identity,
        asset.asset_type,
        common,
        realizations,
        asset.provenance;
        catalog = asset.catalog,
        overrides = collect(asset.overrides),
        access = asset.access,
    )
end

function _apply_patch(project::CanonicalProject, patch::SetAssetCommonPropertyPatch)
    asset = canonical_asset(project, patch.owner)
    properties = collect(asset.common)
    index = findfirst(property -> property.path == patch.property.path, properties)
    !isnothing(index) && properties[index] == patch.property &&
        _semantic_fail(:no_effect_command, "set asset property does not change the asset")
    isnothing(index) ? push!(properties, patch.property) : (properties[index] = patch.property)
    return _replace_asset(project, _asset_with(asset; common = properties)), _asset_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::UnsetAssetCommonPropertyPatch)
    asset = canonical_asset(project, patch.owner)
    properties = collect(asset.common)
    index = findfirst(property -> property.path == patch.path, properties)
    isnothing(index) && _semantic_fail(:unknown_asset_property, "unset asset property target does not exist")
    deleteat!(properties, index)
    return _replace_asset(project, _asset_with(asset; common = properties)), _asset_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::AddStudyRealizationPatch)
    asset = canonical_asset(project, patch.owner)
    any(realization -> realization.id == patch.realization.id, asset.realizations) &&
        _semantic_fail(:duplicate_realization_id, "add-realization patch targets an existing realization")
    realizations = vcat(collect(asset.realizations), [patch.realization])
    return _replace_asset(project, _asset_with(asset; realizations)), _asset_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::RemoveStudyRealizationPatch)
    asset = canonical_asset(project, patch.owner)
    realizations = collect(asset.realizations)
    index = findfirst(realization -> realization.id == patch.realization, realizations)
    isnothing(index) && _semantic_fail(:unknown_realization_id, "remove-realization patch target does not exist")
    deleteat!(realizations, index)
    return _replace_asset(project, _asset_with(asset; realizations)), _asset_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::ReplaceStudyRealizationPatch)
    asset = canonical_asset(project, patch.owner)
    realizations = collect(asset.realizations)
    index = findfirst(realization -> realization.id == patch.realization.id, realizations)
    isnothing(index) && _semantic_fail(:unknown_realization_id, "replace-realization patch target does not exist")
    realizations[index] == patch.realization &&
        _semantic_fail(:no_effect_command, "replacement realization does not change the asset")
    realizations[index] = patch.realization
    return _replace_asset(project, _asset_with(asset; realizations)), _asset_effect(patch.owner)
end

function _asset_data_kind(element::CanonicalAssetData)
    element isa ProfileDescriptor && return ProfileData
    element isa CurveDescriptor && return CurveData
    element isa MatrixDescriptor && return MatrixData
    return MeasurementData
end

function _asset_data_collection(library::AssetLibrary, kind::AssetDataKind)
    kind == ProfileData && return library.profiles
    kind == CurveData && return library.curves
    kind == MatrixData && return library.matrices
    return library.measurements
end

function _asset_data(project::CanonicalProject, kind::AssetDataKind, id::ProjectId)
    collection = _asset_data_collection(project.asset_library, kind)
    index = findfirst(element -> element.identity.id == id, collection)
    isnothing(index) && _semantic_fail(:unknown_asset_data_id, "asset data element does not exist")
    return collection[index]
end

function _apply_patch(project::CanonicalProject, patch::AddAssetDataPatch)
    element = patch.element
    id = element.identity.id
    all_ids = ProjectId[]
    for collection in (
        project.asset_library.profiles,
        project.asset_library.curves,
        project.asset_library.matrices,
        project.asset_library.measurements,
    ), item in collection
        push!(all_ids, item.identity.id)
    end
    id in all_ids && _semantic_fail(:duplicate_asset_data_id, "add-data patch targets an existing data ID")
    library = if element isa ProfileDescriptor
        _library_with(project.asset_library; profiles = vcat(collect(project.asset_library.profiles), [element]))
    elseif element isa CurveDescriptor
        _library_with(project.asset_library; curves = vcat(collect(project.asset_library.curves), [element]))
    elseif element isa MatrixDescriptor
        _library_with(project.asset_library; matrices = vcat(collect(project.asset_library.matrices), [element]))
    else
        _library_with(project.asset_library; measurements = vcat(collect(project.asset_library.measurements), [element]))
    end
    return _replace_asset_library(project, library), _asset_effect(id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveAssetDataPatch)
    _ensure_asset_data_removable(project, patch.id)
    items, _ = _remove_by_id(
        _asset_data_collection(project.asset_library, patch.kind),
        patch.id,
        :unknown_asset_data_id,
        "remove-data patch target does not exist",
    )
    library = patch.kind == ProfileData ? _library_with(project.asset_library; profiles = items) :
        patch.kind == CurveData ? _library_with(project.asset_library; curves = items) :
        patch.kind == MatrixData ? _library_with(project.asset_library; matrices = items) :
        _library_with(project.asset_library; measurements = items)
    return _replace_asset_library(project, library), _asset_effect(patch.id)
end

function _asset_common_property(asset::CanonicalAsset, path::FieldPath)
    index = findfirst(property -> property.path == path, asset.common)
    return isnothing(index) ? nothing : asset.common[index]
end

function _study_realization(asset::CanonicalAsset, id::ProjectId)
    index = findfirst(realization -> realization.id == id, asset.realizations)
    isnothing(index) && _semantic_fail(:invalid_command_inverse, "study realization is absent before mutation")
    return asset.realizations[index]
end

_inverse_patch(patch::AddAssetPatch, ::CanonicalProject) = RemoveAssetPatch(patch.asset.identity.id)
_inverse_patch(patch::RemoveAssetPatch, project::CanonicalProject) = AddAssetPatch(canonical_asset(project, patch.owner))

function _inverse_patch(patch::SetAssetCommonPropertyPatch, project::CanonicalProject)
    previous = _asset_common_property(canonical_asset(project, patch.owner), patch.property.path)
    return isnothing(previous) ?
        UnsetAssetCommonPropertyPatch(patch.owner, patch.property.path) :
        SetAssetCommonPropertyPatch(patch.owner, previous)
end

function _inverse_patch(patch::UnsetAssetCommonPropertyPatch, project::CanonicalProject)
    previous = _asset_common_property(canonical_asset(project, patch.owner), patch.path)
    isnothing(previous) && _semantic_fail(:invalid_command_inverse, "asset property is absent before removal")
    return SetAssetCommonPropertyPatch(patch.owner, previous)
end

_inverse_patch(patch::AddStudyRealizationPatch, ::CanonicalProject) =
    RemoveStudyRealizationPatch(patch.owner, patch.realization.id)
_inverse_patch(patch::RemoveStudyRealizationPatch, project::CanonicalProject) =
    AddStudyRealizationPatch(patch.owner, _study_realization(canonical_asset(project, patch.owner), patch.realization))
_inverse_patch(patch::ReplaceStudyRealizationPatch, project::CanonicalProject) =
    ReplaceStudyRealizationPatch(patch.owner, _study_realization(canonical_asset(project, patch.owner), patch.realization.id))
_inverse_patch(patch::AddAssetDataPatch, ::CanonicalProject) =
    RemoveAssetDataPatch(_asset_data_kind(patch.element), patch.element.identity.id)
_inverse_patch(patch::RemoveAssetDataPatch, project::CanonicalProject) =
    AddAssetDataPatch(_asset_data(project, patch.kind, patch.id))

_patch_signature(patch::AddAssetPatch) = "add-asset:" * patch.asset.identity.id.value
_patch_signature(patch::RemoveAssetPatch) = "remove-asset:" * patch.owner.value
_patch_signature(patch::SetAssetCommonPropertyPatch) =
    "set-asset-property:" * patch.owner.value * ":" * string(patch.property.path)
_patch_signature(patch::UnsetAssetCommonPropertyPatch) =
    "unset-asset-property:" * patch.owner.value * ":" * string(patch.path)
_patch_signature(patch::AddStudyRealizationPatch) =
    "add-realization:" * patch.owner.value * ":" * patch.realization.id.value
_patch_signature(patch::RemoveStudyRealizationPatch) =
    "remove-realization:" * patch.owner.value * ":" * patch.realization.value
_patch_signature(patch::ReplaceStudyRealizationPatch) =
    "replace-realization:" * patch.owner.value * ":" * patch.realization.id.value
_patch_signature(patch::AddAssetDataPatch) =
    "add-asset-data:" * string(UInt8(_asset_data_kind(patch.element))) * ":" * patch.element.identity.id.value
_patch_signature(patch::RemoveAssetDataPatch) =
    "remove-asset-data:" * string(UInt8(patch.kind)) * ":" * patch.id.value

_declared_patch_effect(::CanonicalProject, patch::AddAssetPatch) = _asset_effect(patch.asset.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveAssetPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::SetAssetCommonPropertyPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::UnsetAssetCommonPropertyPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::AddStudyRealizationPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::RemoveStudyRealizationPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::ReplaceStudyRealizationPatch) = _asset_effect(patch.owner)
_declared_patch_effect(::CanonicalProject, patch::AddAssetDataPatch) = _asset_effect(patch.element.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveAssetDataPatch) = _asset_effect(patch.id)
