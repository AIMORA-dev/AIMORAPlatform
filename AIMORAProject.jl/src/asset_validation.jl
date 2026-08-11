function _validate_registered_type(project::CanonicalProject, type::SemanticTypeId, code::Symbol, message::String)
    type.namespace in Set(item.namespace for item in project.registry.namespaces) || _semantic_fail(code, message)
    return true
end

function _validate_asset_reference(project::CanonicalProject, reference::ProjectReference)
    reference.target isa GlobalReferenceTarget && return true
    id = reference.target.id
    if reference.kind == ReferenceProfile
        any(profile -> profile.identity.id == id, project.asset_library.profiles) ||
            _semantic_fail(:dangling_asset_profile_reference, "asset property profile does not exist")
    elseif reference.kind == ReferenceCurve
        any(curve -> curve.identity.id == id, project.asset_library.curves) ||
            _semantic_fail(:dangling_asset_curve_reference, "asset property curve does not exist")
    elseif reference.kind == ReferenceCatalog
        _semantic_fail(:local_catalog_reference, "catalog references require a locked global identity")
    else
        _validate_local_reference(project, reference)
    end
    return true
end

function _validate_asset_property(project::CanonicalProject, property::AssetProperty)
    value = property.value
    value isa PhysicalValue && validate_quantity(project.units, value)
    value isa ProjectReference && _validate_asset_reference(project, value)
    value isa ArtifactIdentity && isnothing(value.schema) &&
        _semantic_fail(:missing_artifact_schema, "asset artifact property requires an exact schema identity")
    return true
end

function _validate_validity_limit(project::CanonicalProject, limit::ValidityLimit)
    _validate_registered_type(
        project,
        limit.quantity,
        :unknown_validity_quantity_namespace,
        "validity quantity namespace is not registered",
    )
    lower = limit.lower
    upper = limit.upper
    !isnothing(lower) && validate_quantity(project.units, lower)
    !isnothing(upper) && validate_quantity(project.units, upper)
    if !isnothing(lower) && !isnothing(upper)
        lower_quantity = lower.quantity
        upper_quantity = upper.quantity
        lower_quantity.orientation == upper_quantity.orientation ||
            _semantic_fail(:validity_orientation_mismatch, "validity bounds use different orientations")
        lower_quantity.base == upper_quantity.base ||
            _semantic_fail(:validity_base_mismatch, "validity bounds use different per-unit bases")
        if lower_quantity.unit == UnitId("pu") || upper_quantity.unit == UnitId("pu")
            lower_quantity.unit == upper_quantity.unit ||
                _semantic_fail(:validity_unit_mismatch, "validity per-unit bounds use different units")
            lower_value = exact_rational(lower_quantity.value)
        else
            lower_value = exact_rational(convert_quantity(
                project.units,
                lower_quantity,
                upper_quantity.unit,
            ).value)
        end
        upper_value = exact_rational(upper_quantity.value)
        lower_value <= upper_value ||
            _semantic_fail(:invalid_validity_bounds, "validity lower bound exceeds upper bound")
        lower_value == upper_value && (!limit.lower_inclusive || !limit.upper_inclusive) &&
            _semantic_fail(:empty_validity_domain, "exclusive equal validity bounds admit no value")
    end
    return true
end

function _validate_realization(project::CanonicalProject, asset::CanonicalAsset, realization::StudyRealization)
    _validate_registered_type(
        project,
        realization.model,
        :unknown_model_namespace,
        "study realization model namespace is not registered",
    )
    common_paths = Set(property.path for property in asset.common)
    parameter_paths = Set(property.path for property in realization.parameters)
    derived_paths = Set(property.property.path for property in realization.derived_parameters)
    isempty(intersect(common_paths, union(parameter_paths, derived_paths))) ||
        _semantic_fail(:common_realization_parameter_conflict, "realization restates shared common physical data")
    foreach(property -> _validate_asset_property(project, property), realization.parameters)
    foreach(property -> _validate_asset_property(project, property.property), realization.derived_parameters)
    foreach(limit -> _validate_validity_limit(project, limit), realization.validity)
    realization.availability == ModelExecutable && realization.qualification == ModelUnqualified &&
        _semantic_fail(:unqualified_executable_realization, "executable realization requires qualification evidence state")
    return true
end

function _validate_asset(project::CanonicalProject, asset::CanonicalAsset)
    record = project_record(project, asset.identity.id)
    record.identity == asset.identity ||
        _semantic_fail(:asset_identity_mismatch, "asset facet global identity differs from its canonical record")
    record.schema.namespace == asset.asset_type.namespace &&
        record.schema.name == asset.asset_type.name &&
        record.schema.version == asset.asset_type.version ||
        _semantic_fail(:asset_type_mismatch, "asset facet type differs from its canonical record schema")
    registered_namespaces = Set(item.namespace for item in project.registry.namespaces)
    asset.asset_type.namespace in registered_namespaces ||
        _semantic_fail(:unknown_asset_namespace, "asset type namespace is not registered")
    foreach(property -> _validate_asset_property(project, property), asset.common)
    common_paths = Set(property.path for property in asset.common)
    override_paths = Set(override.property.path for override in asset.overrides)
    isempty(intersect(common_paths, override_paths)) ||
        _semantic_fail(:ambiguous_asset_override, "asset common data duplicates a catalog override path")
    foreach(override -> _validate_asset_property(project, override.property), asset.overrides)
    foreach(realization -> _validate_realization(project, asset, realization), asset.realizations)
    return true
end

function _validate_data_axis(project::CanonicalProject, axis::DataAxis)
    unit = lookup_unit(project.units, axis.unit)
    unit.per_unit && _semantic_fail(:per_unit_data_axis, "data axis requires a physical unit")
    if axis.kind == TimeAxis
        unit.dimension == lookup_unit(project.units, UnitId("s")).dimension ||
            _semantic_fail(:time_axis_unit_mismatch, "time axis requires a time unit")
    elseif axis.kind == FrequencyAxis
        unit.dimension == lookup_unit(project.units, UnitId("Hz")).dimension ||
            _semantic_fail(:frequency_axis_unit_mismatch, "frequency axis requires a frequency unit")
    elseif axis.kind == ProbabilityAxis
        unit.dimension == dimensionless() ||
            _semantic_fail(:probability_axis_unit_mismatch, "probability axis must be dimensionless")
    end
    return true
end

function _validate_profile(project::CanonicalProject, profile::ProfileDescriptor)
    _validate_registered_type(
        project,
        profile.quantity,
        :unknown_profile_quantity_namespace,
        "profile quantity namespace is not registered",
    )
    _validate_data_axis(project, profile.axis)
    value_unit = lookup_unit(project.units, profile.value_unit)
    value_unit.per_unit && _semantic_fail(:per_unit_profile_value, "profile value requires explicit physical units")
    isnothing(profile.artifact.schema) &&
        _semantic_fail(:missing_artifact_schema, "profile artifact requires an exact schema identity")
    profile.missing_data == MissingDataInterpolate && profile.interpolation == InterpolationProhibited &&
        _semantic_fail(:invalid_missing_data_policy, "interpolated missing data requires an interpolation policy")
    return true
end

function _validate_curve(project::CanonicalProject, curve::CurveDescriptor)
    _validate_data_axis(project, curve.x_axis)
    _validate_data_axis(project, curve.y_axis)
    !isnothing(curve.artifact) && isnothing(curve.artifact.schema) &&
        _semantic_fail(:missing_artifact_schema, "curve artifact requires an exact schema identity")
    previous_x = nothing
    for point in curve.points
        validate_quantity(project.units, point.x)
        validate_quantity(project.units, point.y)
        point.x.quantity.unit == curve.x_axis.unit && point.x.quantity.orientation == curve.x_axis.orientation ||
            _semantic_fail(:curve_x_contract_mismatch, "curve point x metadata differs from its axis")
        point.y.quantity.unit == curve.y_axis.unit && point.y.quantity.orientation == curve.y_axis.orientation ||
            _semantic_fail(:curve_y_contract_mismatch, "curve point y metadata differs from its axis")
        x_value = exact_rational(point.x.quantity.value)
        !isnothing(previous_x) && x_value <= previous_x &&
            _semantic_fail(:nonmonotonic_curve_axis, "inline curve x values must increase strictly")
        previous_x = x_value
    end
    return true
end

function _validate_matrix(project::CanonicalProject, matrix::MatrixDescriptor)
    lookup_unit(project.units, matrix.unit)
    isnothing(matrix.artifact.schema) &&
        _semantic_fail(:missing_artifact_schema, "matrix artifact requires an exact schema identity")
    return true
end

function _validate_measurement(project::CanonicalProject, measurement::MeasurementDefinition)
    measurement.target.kind in (ReferenceAsset, ReferenceNode, ReferenceControlBlock) ||
        _semantic_fail(:invalid_measurement_target, "measurement target must be physical or control semantics")
    _validate_local_reference(project, measurement.target)
    _validate_registered_type(
        project,
        measurement.quantity,
        :unknown_measurement_quantity_namespace,
        "measurement quantity namespace is not registered",
    )
    unit = lookup_unit(project.units, measurement.unit)
    unit.per_unit && _semantic_fail(:per_unit_measurement, "measurement requires explicit physical unit/base metadata")
    if !isnothing(measurement.profile)
        measurement.profile.kind == ReferenceProfile ||
            _semantic_fail(:invalid_measurement_profile, "measurement profile reference has the wrong kind")
        measurement.profile.target isa LocalReferenceTarget ||
            _semantic_fail(:external_measurement_profile, "measurement profile must resolve inside the project")
        any(profile -> profile.identity.id == measurement.profile.target.id, project.asset_library.profiles) ||
            _semantic_fail(:dangling_measurement_profile, "measurement profile does not exist")
    end
    return true
end

"""Validate asset ownership, realization fidelity, data contracts, and artifact locks."""
function validate_asset_library(project::CanonicalProject)
    library = project.asset_library
    asset_ids = [asset.identity.id for asset in library.assets]
    length(asset_ids) == length(unique(asset_ids)) ||
        _semantic_fail(:duplicate_asset_id, "asset library repeats a physical asset identity")
    auxiliary_ids = ProjectId[]
    for collection in (library.profiles, library.curves, library.matrices, library.measurements), item in collection
        push!(auxiliary_ids, item.identity.id)
    end
    length(auxiliary_ids) == length(unique(auxiliary_ids)) ||
        _semantic_fail(:duplicate_asset_data_id, "asset library data elements repeat an ID")
    occupied = Set(vcat(
        [record.identity.id for record in project.records],
        _graph_element_ids(project.graphs),
        asset_ids,
    ))
    isempty(intersect(occupied, Set(auxiliary_ids))) ||
        _semantic_fail(:asset_data_identity_collision, "asset data ID collides with project semantics")
    foreach(asset -> _validate_asset(project, asset), library.assets)
    foreach(profile -> _validate_profile(project, profile), library.profiles)
    foreach(curve -> _validate_curve(project, curve), library.curves)
    foreach(matrix -> _validate_matrix(project, matrix), library.matrices)
    foreach(measurement -> _validate_measurement(project, measurement), library.measurements)
    return true
end

function canonical_asset(project::CanonicalProject, id::ProjectId)
    index = findfirst(asset -> asset.identity.id == id, project.asset_library.assets)
    isnothing(index) && _semantic_fail(:unknown_asset_id, "canonical asset facet does not exist")
    return project.asset_library.assets[index]
end

"""Select only an exact representation/fidelity realization; no fallback is permitted."""
function select_realization(
    asset::CanonicalAsset,
    representation::ModelRepresentation,
    fidelity::ModelFidelity,
)
    index = findfirst(realization -> (
        realization.representation == representation && realization.fidelity == fidelity
    ), asset.realizations)
    isnothing(index) && _semantic_fail(:missing_exact_realization, "asset has no exact representation and fidelity realization")
    realization = asset.realizations[index]
    realization.availability == ModelExecutable ||
        _semantic_fail(:realization_not_executable, "selected exact realization is not executable")
    return realization
end
