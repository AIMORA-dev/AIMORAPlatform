"""A validated dotted field path used by asset parameters and overrides."""
struct FieldPath
    segments::CanonicalList{ProjectId}

    function FieldPath(segments::AbstractVector{ProjectId})
        isempty(segments) && _semantic_fail(:empty_field_path, "field path requires at least one segment")
        return new(CanonicalList{ProjectId}(segments))
    end
end

FieldPath(path::AbstractString) = FieldPath(ProjectId[ProjectId(segment) for segment in split(String(path), '.')])
Base.string(path::FieldPath) = join((segment.value for segment in path.segments), '.')
Base.:(==)(left::FieldPath, right::FieldPath) = left.segments == right.segments
Base.hash(path::FieldPath, seed::UInt) = hash(Tuple(path.segments), seed)

"""One provenance-owned canonical asset property without dictionary storage."""
struct AssetProperty
    path::FieldPath
    value::CanonicalFieldData
    provenance::ProvenanceSource
end

AssetProperty(path::FieldPath, value::Integer, provenance::ProvenanceSource) =
    AssetProperty(path, BigInt(value), provenance)
AssetProperty(path::FieldPath, value::AbstractString, provenance::ProvenanceSource) =
    AssetProperty(path, String(value), provenance)
Base.:(==)(left::AssetProperty, right::AssetProperty) =
    left.path == right.path && left.value == right.value && left.provenance == right.provenance

@enum ModelRepresentation::UInt8 begin
    ComponentPrototype = 0x01
    StaticPhasor = 0x02
    DynamicPhasorDAE = 0x03
    InstantaneousEMT = 0x04
    HarmonicFrequencyDomain = 0x05
    ShortCircuit = 0x06
    ThermalField = 0x07
    ProtectionMeasurement = 0x08
    ReliabilityAsset = 0x09
    EconomicOptimization = 0x0a
end

@enum ModelFidelity::UInt8 begin
    LegacyDetailed = 0x01
    SwitchingDetailed = 0x02
    SwitchingStateEquivalent = 0x03
    AverageValue = 0x04
    FieldCoupledDetailed = 0x05
end

@enum ModelAvailability::UInt8 begin
    ModelPlanned = 0x01
    ModelExecutable = 0x02
    ModelUnavailable = 0x03
    ModelLegacyReference = 0x04
end

@enum ModelQualification::UInt8 begin
    ModelUnqualified = 0x01
    ModelPrototypeEvidence = 0x02
    ModelQualified = 0x03
    ModelProduction = 0x04
end

@enum DataAccessClass::UInt8 begin
    AccessPublic = 0x01
    AccessProjectRestricted = 0x02
    AccessConfidential = 0x03
end

"""One bounded validity condition with compatible exact physical limits."""
struct ValidityLimit
    quantity::SemanticTypeId
    lower::Union{Nothing,PhysicalValue{ScalarQuantity}}
    upper::Union{Nothing,PhysicalValue{ScalarQuantity}}
    lower_inclusive::Bool
    upper_inclusive::Bool

    function ValidityLimit(
        quantity::SemanticTypeId;
        lower::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
        upper::Union{Nothing,PhysicalValue{ScalarQuantity}} = nothing,
        lower_inclusive::Bool = true,
        upper_inclusive::Bool = true,
    )
        isnothing(lower) && isnothing(upper) &&
            _semantic_fail(:empty_validity_limit, "validity limit requires a lower or upper bound")
        return new(quantity, lower, upper, lower_inclusive, upper_inclusive)
    end
end

Base.:(==)(left::ValidityLimit, right::ValidityLimit) =
    left.quantity == right.quantity &&
    left.lower == right.lower && left.upper == right.upper &&
    left.lower_inclusive == right.lower_inclusive &&
    left.upper_inclusive == right.upper_inclusive

"""A derived property with exact upstream content and algorithm identities."""
struct DerivedAssetProperty
    property::AssetProperty
    operation::SemanticTypeId
    upstream_hashes::CanonicalList{ContentDigest}

    function DerivedAssetProperty(
        property::AssetProperty,
        operation::SemanticTypeId,
        upstream_hashes::AbstractVector{ContentDigest},
    )
        copied = sort!(collect(upstream_hashes); by = digest -> digest.sha256)
        isempty(copied) && _semantic_fail(:missing_derivation_input, "derived property requires upstream content hashes")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_derivation_input, "derived property repeats an upstream hash")
        return new(property, operation, CanonicalList{ContentDigest}(copied))
    end
end

Base.:(==)(left::DerivedAssetProperty, right::DerivedAssetProperty) =
    left.property == right.property &&
    left.operation == right.operation &&
    left.upstream_hashes == right.upstream_hashes

"""One exact study realization of a shared physical asset."""
struct StudyRealization
    id::ProjectId
    model::SemanticTypeId
    representation::ModelRepresentation
    fidelity::ModelFidelity
    availability::ModelAvailability
    qualification::ModelQualification
    parameters::CanonicalList{AssetProperty}
    derived_parameters::CanonicalList{DerivedAssetProperty}
    validity::CanonicalList{ValidityLimit}
    provenance::ProvenanceSource

    function StudyRealization(
        id::ProjectId,
        model::SemanticTypeId,
        representation::ModelRepresentation,
        fidelity::ModelFidelity,
        availability::ModelAvailability,
        qualification::ModelQualification,
        parameters::AbstractVector{AssetProperty},
        derived_parameters::AbstractVector{DerivedAssetProperty},
        validity::AbstractVector{ValidityLimit},
        provenance::ProvenanceSource,
    )
        property_copy = sort!(collect(parameters); by = property -> string(property.path))
        paths = getfield.(property_copy, :path)
        length(paths) == length(unique(paths)) ||
            _semantic_fail(:duplicate_realization_parameter, "study realization repeats a parameter path")
        derived_copy = sort!(collect(derived_parameters); by = property -> string(property.property.path))
        derived_paths = [property.property.path for property in derived_copy]
        length(derived_paths) == length(unique(derived_paths)) ||
            _semantic_fail(:duplicate_derived_parameter, "study realization repeats a derived parameter path")
        isempty(intersect(Set(paths), Set(derived_paths))) ||
            _semantic_fail(:conflicting_derived_parameter, "direct and derived realization parameters overlap")
        validity_copy = sort!(collect(validity); by = limit -> (limit.quantity.namespace.value, limit.quantity.name.value))
        validity_keys = [(limit.quantity.namespace, limit.quantity.name, limit.quantity.version) for limit in validity_copy]
        length(validity_keys) == length(unique(validity_keys)) ||
            _semantic_fail(:duplicate_validity_limit, "study realization repeats a validity quantity")
        return new(
            id,
            model,
            representation,
            fidelity,
            availability,
            qualification,
            CanonicalList{AssetProperty}(property_copy),
            CanonicalList{DerivedAssetProperty}(derived_copy),
            CanonicalList{ValidityLimit}(validity_copy),
            provenance,
        )
    end
end

Base.:(==)(left::StudyRealization, right::StudyRealization) =
    left.id == right.id && left.model == right.model &&
    left.representation == right.representation && left.fidelity == right.fidelity &&
    left.availability == right.availability && left.qualification == right.qualification &&
    left.parameters == right.parameters && left.derived_parameters == right.derived_parameters &&
    left.validity == right.validity && left.provenance == right.provenance

struct CatalogBinding
    catalog::ProjectReference
    version::VersionNumber
    content_hash::ContentDigest
    provenance::ProvenanceSource

    function CatalogBinding(
        catalog::ProjectReference,
        version::VersionNumber,
        content_hash::ContentDigest,
        provenance::ProvenanceSource,
    )
        catalog.kind == ReferenceCatalog ||
            _semantic_fail(:invalid_catalog_binding, "catalog binding requires a catalog reference")
        version.major > 0 || _semantic_fail(:invalid_catalog_version, "catalog major version must be positive")
        return new(catalog, version, content_hash, provenance)
    end
end

Base.:(==)(left::CatalogBinding, right::CatalogBinding) =
    left.catalog == right.catalog && left.version == right.version &&
    left.content_hash == right.content_hash && left.provenance == right.provenance

struct AssetOverride
    property::AssetProperty
end

Base.:(==)(left::AssetOverride, right::AssetOverride) = left.property == right.property

abstract type AssetLibraryElement end

"""One physical asset identity with common data and explicit study realizations."""
struct CanonicalAsset <: AssetLibraryElement
    identity::ObjectIdentity
    asset_type::SemanticTypeId
    common::CanonicalList{AssetProperty}
    realizations::CanonicalList{StudyRealization}
    catalog::Union{Nothing,CatalogBinding}
    overrides::CanonicalList{AssetOverride}
    access::DataAccessClass
    provenance::ProvenanceSource

    function CanonicalAsset(
        identity::ObjectIdentity,
        asset_type::SemanticTypeId,
        common::AbstractVector{AssetProperty},
        realizations::AbstractVector{StudyRealization},
        provenance::ProvenanceSource;
        catalog::Union{Nothing,CatalogBinding} = nothing,
        overrides::AbstractVector{AssetOverride} = AssetOverride[],
        access::DataAccessClass = AccessPublic,
    )
        common_copy = sort!(collect(common); by = property -> string(property.path))
        common_paths = getfield.(common_copy, :path)
        length(common_paths) == length(unique(common_paths)) ||
            _semantic_fail(:duplicate_common_parameter, "asset repeats a common parameter path")
        realization_copy = sort!(collect(realizations); by = realization -> realization.id.value)
        ids = getfield.(realization_copy, :id)
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_realization_id, "asset repeats a realization ID")
        selection_keys = [(item.representation, item.fidelity) for item in realization_copy]
        length(selection_keys) == length(unique(selection_keys)) ||
            _semantic_fail(:ambiguous_realization_selection, "asset repeats a representation and fidelity pair")
        override_copy = sort!(collect(overrides); by = override -> string(override.property.path))
        override_paths = [override.property.path for override in override_copy]
        length(override_paths) == length(unique(override_paths)) ||
            _semantic_fail(:duplicate_asset_override, "asset repeats an override path")
        isnothing(catalog) && !isempty(override_copy) &&
            _semantic_fail(:override_without_catalog, "asset overrides require a catalog base")
        return new(
            identity,
            asset_type,
            CanonicalList{AssetProperty}(common_copy),
            CanonicalList{StudyRealization}(realization_copy),
            catalog,
            CanonicalList{AssetOverride}(override_copy),
            access,
            provenance,
        )
    end
end

Base.:(==)(left::CanonicalAsset, right::CanonicalAsset) =
    left.identity == right.identity && left.asset_type == right.asset_type &&
    left.common == right.common && left.realizations == right.realizations &&
    left.catalog == right.catalog && left.overrides == right.overrides &&
    left.access == right.access && left.provenance == right.provenance

@enum AxisKind::UInt8 begin
    TimeAxis = 0x01
    FrequencyAxis = 0x02
    OperatingPointAxis = 0x03
    ProbabilityAxis = 0x04
    SpatialAxis = 0x05
end

@enum InterpolationPolicy::UInt8 begin
    InterpolationProhibited = 0x01
    InterpolationStep = 0x02
    InterpolationLinear = 0x03
    InterpolationLogLinear = 0x04
    InterpolationLogLogLinear = 0x05
end

@enum ExtrapolationPolicy::UInt8 begin
    ExtrapolationError = 0x01
    ExtrapolationHold = 0x02
    ExtrapolationLinear = 0x03
end

@enum MissingDataPolicy::UInt8 begin
    MissingDataError = 0x01
    MissingDataSkip = 0x02
    MissingDataInterpolate = 0x03
end

struct DataAxis
    name::ProjectId
    kind::AxisKind
    unit::UnitId
    orientation::QuantityOrientation
end

Base.:(==)(left::DataAxis, right::DataAxis) =
    left.name == right.name && left.kind == right.kind &&
    left.unit == right.unit && left.orientation == right.orientation

struct ProfileDescriptor <: AssetLibraryElement
    identity::ObjectIdentity
    quantity::SemanticTypeId
    value_unit::UnitId
    value_orientation::QuantityOrientation
    axis::DataAxis
    artifact::ArtifactIdentity
    interpolation::InterpolationPolicy
    extrapolation::ExtrapolationPolicy
    missing_data::MissingDataPolicy
    access::DataAccessClass
    provenance::ProvenanceSource
end

Base.:(==)(left::ProfileDescriptor, right::ProfileDescriptor) =
    left.identity == right.identity && left.quantity == right.quantity &&
    left.value_unit == right.value_unit && left.value_orientation == right.value_orientation &&
    left.axis == right.axis && left.artifact == right.artifact &&
    left.interpolation == right.interpolation && left.extrapolation == right.extrapolation &&
    left.missing_data == right.missing_data && left.access == right.access &&
    left.provenance == right.provenance

struct CurvePoint
    x::PhysicalValue{ScalarQuantity}
    y::PhysicalValue{ScalarQuantity}
end

Base.:(==)(left::CurvePoint, right::CurvePoint) = left.x == right.x && left.y == right.y

struct CurveDescriptor <: AssetLibraryElement
    identity::ObjectIdentity
    x_axis::DataAxis
    y_axis::DataAxis
    points::CanonicalList{CurvePoint}
    artifact::Union{Nothing,ArtifactIdentity}
    interpolation::InterpolationPolicy
    extrapolation::ExtrapolationPolicy
    provenance::ProvenanceSource

    function CurveDescriptor(
        identity::ObjectIdentity,
        x_axis::DataAxis,
        y_axis::DataAxis,
        points::AbstractVector{CurvePoint},
        interpolation::InterpolationPolicy,
        extrapolation::ExtrapolationPolicy,
        provenance::ProvenanceSource;
        artifact::Union{Nothing,ArtifactIdentity} = nothing,
    )
        isempty(points) == isnothing(artifact) &&
            _semantic_fail(:invalid_curve_source, "curve requires exactly one inline or artifact source")
        return new(
            identity,
            x_axis,
            y_axis,
            CanonicalList{CurvePoint}(collect(points)),
            artifact,
            interpolation,
            extrapolation,
            provenance,
        )
    end
end

Base.:(==)(left::CurveDescriptor, right::CurveDescriptor) =
    left.identity == right.identity && left.x_axis == right.x_axis &&
    left.y_axis == right.y_axis && left.points == right.points &&
    left.artifact == right.artifact && left.interpolation == right.interpolation &&
    left.extrapolation == right.extrapolation && left.provenance == right.provenance

@enum MatrixSymmetry::UInt8 begin
    MatrixGeneral = 0x01
    MatrixSymmetric = 0x02
    MatrixHermitian = 0x03
end

struct MatrixDescriptor <: AssetLibraryElement
    identity::ObjectIdentity
    artifact::ArtifactIdentity
    unit::UnitId
    row_order::CanonicalList{String}
    column_order::CanonicalList{String}
    symmetry::MatrixSymmetry
    provenance::ProvenanceSource

    function MatrixDescriptor(
        identity::ObjectIdentity,
        artifact::ArtifactIdentity,
        unit::UnitId,
        row_order::AbstractVector{<:AbstractString},
        column_order::AbstractVector{<:AbstractString},
        symmetry::MatrixSymmetry,
        provenance::ProvenanceSource,
    )
        rows = String[String(item) for item in row_order]
        columns = String[String(item) for item in column_order]
        (isempty(rows) || isempty(columns)) &&
            _semantic_fail(:empty_matrix_order, "matrix row and column ordering must be nonempty")
        length(rows) == length(unique(rows)) || _semantic_fail(:duplicate_matrix_row, "matrix repeats a row label")
        length(columns) == length(unique(columns)) || _semantic_fail(:duplicate_matrix_column, "matrix repeats a column label")
        symmetry != MatrixGeneral && rows != columns &&
            _semantic_fail(:invalid_matrix_symmetry, "symmetric matrix requires identical row and column ordering")
        return new(
            identity,
            artifact,
            unit,
            CanonicalList{String}(rows),
            CanonicalList{String}(columns),
            symmetry,
            provenance,
        )
    end
end

Base.:(==)(left::MatrixDescriptor, right::MatrixDescriptor) =
    left.identity == right.identity && left.artifact == right.artifact &&
    left.unit == right.unit && left.row_order == right.row_order &&
    left.column_order == right.column_order && left.symmetry == right.symmetry &&
    left.provenance == right.provenance

@enum MeasurementProductKind::UInt8 begin
    LinearCurrentTransformerProduct = 0x01
    MagneticCurrentTransformerProduct = 0x02
    InductiveVoltageTransformerProduct = 0x03
    CouplingCapacitorVoltageTransformerProduct = 0x04
    ElectronicCurrentSensorProduct = 0x05
    ElectronicVoltageSensorProduct = 0x06
    ThreePhaseSampledMeasurementProduct = 0x07
end

@enum MeasurementQuantizerKind::UInt8 begin
    MeasurementUnquantized = 0x01
    MeasurementUniformQuantizer = 0x02
end

@enum MeasurementQuantizerTieRule::UInt8 begin
    MeasurementTiesToEven = 0x01
    MeasurementTiesAwayFromZero = 0x02
    MeasurementTiesTowardZero = 0x03
end

@enum MeasurementEstimatorKind::UInt8 begin
    MeasurementInstantaneousEstimator = 0x01
    MeasurementSlidingRmsEstimator = 0x02
    MeasurementFundamentalPhasorEstimator = 0x03
    MeasurementSequenceEstimator = 0x04
    MeasurementFrequencyEstimator = 0x05
end

struct MeasurementAcquisitionDefinition
    tick_s::ExactRational
    sample_period_ticks::Int
    first_sample_tick::Int
    aperture_ticks::Int
    delay_ticks::Int
    window_sample_count::Int
    nominal_frequency_hz::ExactRational

    function MeasurementAcquisitionDefinition(
        tick_s::ExactRational,
        sample_period_ticks::Integer,
        first_sample_tick::Integer,
        aperture_ticks::Integer,
        delay_ticks::Integer,
        window_sample_count::Integer,
        nominal_frequency_hz::ExactRational,
    )
        tick_s > ExactRational(0) || _semantic_fail(
            :invalid_measurement_tick,
            "measurement acquisition tick must be positive",
        )
        sample_period_ticks > 0 || _semantic_fail(
            :invalid_measurement_period,
            "measurement sample period must be a positive tick count",
        )
        first_sample_tick >= 0 || _semantic_fail(
            :invalid_measurement_phase,
            "measurement first sample tick must be nonnegative",
        )
        0 <= aperture_ticks <= sample_period_ticks || _semantic_fail(
            :invalid_measurement_aperture,
            "measurement aperture must fit inside one sample period",
        )
        delay_ticks >= 0 || _semantic_fail(
            :invalid_measurement_delay,
            "measurement delay must be nonnegative",
        )
        4 <= window_sample_count <= 4096 || _semantic_fail(
            :invalid_measurement_window,
            "measurement estimator window must contain 4 through 4096 samples",
        )
        nominal_frequency_hz > ExactRational(0) || _semantic_fail(
            :invalid_measurement_frequency,
            "measurement nominal frequency must be positive",
        )
        return new(
            tick_s,
            Int(sample_period_ticks),
            Int(first_sample_tick),
            Int(aperture_ticks),
            Int(delay_ticks),
            Int(window_sample_count),
            nominal_frequency_hz,
        )
    end
end

Base.:(==)(left::MeasurementAcquisitionDefinition, right::MeasurementAcquisitionDefinition) =
    left.tick_s == right.tick_s &&
    left.sample_period_ticks == right.sample_period_ticks &&
    left.first_sample_tick == right.first_sample_tick &&
    left.aperture_ticks == right.aperture_ticks &&
    left.delay_ticks == right.delay_ticks &&
    left.window_sample_count == right.window_sample_count &&
    left.nominal_frequency_hz == right.nominal_frequency_hz

struct MeasurementQuantizerDefinition
    kind::MeasurementQuantizerKind
    lower_clip::ExactRational
    upper_clip::ExactRational
    engineering_offset::Union{Nothing,ExactRational}
    engineering_step::Union{Nothing,ExactRational}
    minimum_code::Union{Nothing,BigInt}
    maximum_code::Union{Nothing,BigInt}
    tie_rule::MeasurementQuantizerTieRule

    function MeasurementQuantizerDefinition(
        kind::MeasurementQuantizerKind,
        lower_clip::ExactRational,
        upper_clip::ExactRational;
        engineering_offset::Union{Nothing,ExactRational}=nothing,
        engineering_step::Union{Nothing,ExactRational}=nothing,
        minimum_code::Union{Nothing,Integer}=nothing,
        maximum_code::Union{Nothing,Integer}=nothing,
        tie_rule::MeasurementQuantizerTieRule=MeasurementTiesToEven,
    )
        lower_clip < upper_clip || _semantic_fail(
            :invalid_measurement_clip_limits,
            "measurement clipping limits must increase strictly",
        )
        minimum = isnothing(minimum_code) ? nothing : BigInt(minimum_code)
        maximum = isnothing(maximum_code) ? nothing : BigInt(maximum_code)
        if kind == MeasurementUnquantized
            all(isnothing, (engineering_offset, engineering_step, minimum, maximum)) ||
                _semantic_fail(
                    :hidden_measurement_quantizer,
                    "unquantized measurement cannot retain hidden code parameters",
                )
        else
            all(value -> !isnothing(value), (
                engineering_offset,
                engineering_step,
                minimum,
                maximum,
            )) ||
                _semantic_fail(
                    :incomplete_measurement_quantizer,
                    "uniform measurement quantizer requires offset, step, and code limits",
                )
            something(engineering_step) > ExactRational(0) || _semantic_fail(
                :invalid_measurement_quantizer_step,
                "uniform measurement quantizer step must be positive",
            )
            something(minimum) < something(maximum) || _semantic_fail(
                :invalid_measurement_code_limits,
                "uniform measurement code limits must increase strictly",
            )
        end
        return new(
            kind,
            lower_clip,
            upper_clip,
            engineering_offset,
            engineering_step,
            minimum,
            maximum,
            tie_rule,
        )
    end
end


Base.:(==)(left::MeasurementQuantizerDefinition, right::MeasurementQuantizerDefinition) =
    left.kind == right.kind && left.lower_clip == right.lower_clip &&
    left.upper_clip == right.upper_clip &&
    left.engineering_offset == right.engineering_offset &&
    left.engineering_step == right.engineering_step &&
    left.minimum_code == right.minimum_code && left.maximum_code == right.maximum_code &&
    left.tie_rule == right.tie_rule

struct MeasurementChainIdentity
    schema_version::VersionNumber
    product::MeasurementProductKind
    topology::String
    terminal_order::CanonicalList{String}
    channel_order::CanonicalList{String}
    phase_order::CanonicalList{String}
    acquisition::MeasurementAcquisitionDefinition
    quantizer::MeasurementQuantizerDefinition
    estimators::CanonicalList{MeasurementEstimatorKind}
    algorithm_version::VersionNumber
    source::ContentDigest
    record::Union{Nothing,ArtifactIdentity}

    function MeasurementChainIdentity(
        schema_version::VersionNumber,
        product::MeasurementProductKind,
        topology::AbstractString,
        terminal_order::AbstractVector{<:AbstractString},
        channel_order::AbstractVector{<:AbstractString},
        phase_order::AbstractVector{<:AbstractString},
        acquisition::MeasurementAcquisitionDefinition,
        quantizer::MeasurementQuantizerDefinition,
        estimators::AbstractVector{MeasurementEstimatorKind},
        algorithm_version::VersionNumber,
        source::ContentDigest;
        record::Union{Nothing,ArtifactIdentity}=nothing,
    )
        schema_version.major == 1 || _semantic_fail(
            :unsupported_measurement_schema,
            "measurement-chain schema major version must be one",
        )
        algorithm_version.major == 1 || _semantic_fail(
            :unsupported_measurement_algorithm,
            "measurement-chain algorithm major version must be one",
        )
        topology_text = String(topology)
        occursin(r"^[a-z][a-z0-9_]*$", topology_text) || _semantic_fail(
            :invalid_measurement_topology,
            "measurement topology must be a lowercase portable identifier",
        )
        terminals = String.(terminal_order)
        channels = String.(channel_order)
        phases = String.(phase_order)
        isempty(terminals) && _semantic_fail(
            :empty_measurement_terminals,
            "measurement chain requires explicit terminal or observation ownership",
        )
        isempty(channels) && _semantic_fail(
            :empty_measurement_channels,
            "measurement chain requires at least one channel",
        )
        length(terminals) == length(unique(terminals)) || _semantic_fail(
            :duplicate_measurement_terminal,
            "measurement chain repeats a terminal identity",
        )
        length(channels) == length(unique(channels)) || _semantic_fail(
            :duplicate_measurement_channel,
            "measurement chain repeats a channel identity",
        )
        if product == ThreePhaseSampledMeasurementProduct
            phases == ["a", "b", "c"] && length(channels) == 3 || _semantic_fail(
                :invalid_three_phase_measurement_identity,
                "three-phase sampled measurement requires three explicit abc channels",
            )
        elseif !isempty(phases)
            phases == ["a", "b", "c"] && length(channels) == 3 || _semantic_fail(
                :invalid_measurement_phase_order,
                "phase-owned measurement channels require three explicit abc identities",
            )
        end
        estimator_rows = sort!(unique(collect(estimators)); by=UInt8)
        isempty(estimator_rows) && _semantic_fail(
            :empty_measurement_estimators,
            "measurement chain requires at least one estimator/output identity",
        )
        return new(
            schema_version,
            product,
            topology_text,
            CanonicalList{String}(terminals),
            CanonicalList{String}(channels),
            CanonicalList{String}(phases),
            acquisition,
            quantizer,
            CanonicalList{MeasurementEstimatorKind}(estimator_rows),
            algorithm_version,
            source,
            record,
        )
    end
end


Base.:(==)(left::MeasurementChainIdentity, right::MeasurementChainIdentity) =
    left.schema_version == right.schema_version && left.product == right.product &&
    left.topology == right.topology && left.terminal_order == right.terminal_order &&
    left.channel_order == right.channel_order && left.phase_order == right.phase_order &&
    left.acquisition == right.acquisition && left.quantizer == right.quantizer &&
    left.estimators == right.estimators &&
    left.algorithm_version == right.algorithm_version && left.source == right.source &&
    left.record == right.record

struct MeasurementDefinition <: AssetLibraryElement
    identity::ObjectIdentity
    target::ProjectReference
    quantity::SemanticTypeId
    unit::UnitId
    orientation::QuantityOrientation
    profile::Union{Nothing,ProjectReference}
    provenance::ProvenanceSource
    chain::Union{Nothing,MeasurementChainIdentity}
end

MeasurementDefinition(
    identity::ObjectIdentity,
    target::ProjectReference,
    quantity::SemanticTypeId,
    unit::UnitId,
    orientation::QuantityOrientation,
    profile::Union{Nothing,ProjectReference},
    provenance::ProvenanceSource,
) = MeasurementDefinition(
    identity,
    target,
    quantity,
    unit,
    orientation,
    profile,
    provenance,
    nothing,
)

Base.:(==)(left::MeasurementDefinition, right::MeasurementDefinition) =
    left.identity == right.identity && left.target == right.target &&
    left.quantity == right.quantity && left.unit == right.unit &&
    left.orientation == right.orientation && left.profile == right.profile &&
    left.provenance == right.provenance && left.chain == right.chain

struct AssetLibrary
    assets::CanonicalList{CanonicalAsset}
    profiles::CanonicalList{ProfileDescriptor}
    curves::CanonicalList{CurveDescriptor}
    matrices::CanonicalList{MatrixDescriptor}
    measurements::CanonicalList{MeasurementDefinition}

    function AssetLibrary(;
        assets::AbstractVector{CanonicalAsset} = CanonicalAsset[],
        profiles::AbstractVector{ProfileDescriptor} = ProfileDescriptor[],
        curves::AbstractVector{CurveDescriptor} = CurveDescriptor[],
        matrices::AbstractVector{MatrixDescriptor} = MatrixDescriptor[],
        measurements::AbstractVector{MeasurementDefinition} = MeasurementDefinition[],
    )
        ordered(items) = sort!(collect(items); by = item -> item.identity.id.value)
        return new(
            CanonicalList{CanonicalAsset}(ordered(assets)),
            CanonicalList{ProfileDescriptor}(ordered(profiles)),
            CanonicalList{CurveDescriptor}(ordered(curves)),
            CanonicalList{MatrixDescriptor}(ordered(matrices)),
            CanonicalList{MeasurementDefinition}(ordered(measurements)),
        )
    end
end

Base.:(==)(left::AssetLibrary, right::AssetLibrary) =
    left.assets == right.assets && left.profiles == right.profiles &&
    left.curves == right.curves && left.matrices == right.matrices &&
    left.measurements == right.measurements
