function asset_quantity(value, unit, orientation, provenance; uncertainty = nothing, base = nothing)
    quantity = ScalarQuantity(
        parse_exact_decimal(value),
        UnitId(unit),
        orientation;
        base,
    )
    return PhysicalValue(quantity, provenance; uncertainty)
end

function asset_fixture()
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    namespace = NamespaceId("aimora")
    type(name) = SemanticTypeId(namespace, ProjectId(name), v"1.0.0")
    asset_type = SemanticTypeId(
        fixture.schema.identity.namespace,
        fixture.schema.identity.name,
        fixture.schema.identity.version,
    )
    content_schema = type("data.parquet_table")
    profile_artifact = ArtifactIdentity(
        ProjectId("artifact.load_profile"),
        "data/load_profile.parquet",
        repeat("3", 64),
        "application/vnd.apache.parquet",
        provenance;
        schema = content_schema,
        byte_count = 4096,
    )
    curve_artifact = ArtifactIdentity(
        ProjectId("artifact.relay_curve"),
        "data/relay_curve.parquet",
        repeat("4", 64),
        "application/vnd.apache.parquet",
        provenance;
        schema = content_schema,
    )
    matrix_artifact = ArtifactIdentity(
        ProjectId("artifact.impedance_matrix"),
        "data/impedance_matrix.h5",
        repeat("5", 64),
        "application/x-hdf5",
        provenance;
        schema = type("data.complex_matrix"),
    )
    rating_uncertainty = QuantityUncertainty(
        UncertaintyNormal,
        parse_exact_decimal("0.95");
        standard_deviation = ScalarQuantity(
            parse_exact_decimal("2.0"),
            UnitId("MVA"),
            OrientationScalar,
        ),
    )
    common = [
        AssetProperty(
            FieldPath("nameplate.rating"),
            asset_quantity("100.0", "MVA", OrientationScalar, provenance; uncertainty = rating_uncertainty),
            provenance,
        ),
        AssetProperty(FieldPath("physical.in_service"), true, provenance),
    ]
    validity = [
        ValidityLimit(
            type("quantity.frequency");
            lower = asset_quantity("45.0", "Hz", OrientationScalar, provenance),
            upper = asset_quantity("65.0", "Hz", OrientationScalar, provenance),
        ),
    ]
    static = StudyRealization(
        ProjectId("realization.static"),
        type("model.bus.static_phasor"),
        StaticPhasor,
        AverageValue,
        ModelExecutable,
        ModelQualified,
        [AssetProperty(FieldPath("solver.voltage_control"), "slack", provenance)],
        DerivedAssetProperty[],
        validity,
        provenance,
    )
    emt = StudyRealization(
        ProjectId("realization.emt"),
        type("model.bus.instantaneous_emt"),
        InstantaneousEMT,
        SwitchingDetailed,
        ModelExecutable,
        ModelProduction,
        [
            AssetProperty(
                FieldPath("solver.timestep_limit"),
                asset_quantity("20.0e-6", "s", OrientationScalar, provenance),
                provenance,
            ),
        ],
        [
            DerivedAssetProperty(
                AssetProperty(
                    FieldPath("solver.initial_voltage"),
                    asset_quantity("132.0", "kV", OrientationPhaseToPhaseRms, provenance),
                    provenance,
                ),
                type("derive.power_flow_to_emt"),
                [ContentDigest(repeat("6", 64))],
            ),
        ],
        validity,
        provenance,
    )
    thermal = StudyRealization(
        ProjectId("realization.thermal"),
        type("model.bus.thermal"),
        ThermalField,
        FieldCoupledDetailed,
        ModelPlanned,
        ModelUnqualified,
        AssetProperty[],
        DerivedAssetProperty[],
        ValidityLimit[],
        provenance,
    )
    reliability = StudyRealization(
        ProjectId("realization.reliability"),
        type("model.bus.reliability"),
        ReliabilityAsset,
        AverageValue,
        ModelExecutable,
        ModelPrototypeEvidence,
        [AssetProperty(FieldPath("failure.annual_rate"), parse_exact_decimal("0.08"), provenance)],
        DerivedAssetProperty[],
        ValidityLimit[],
        provenance,
    )
    catalog = CatalogBinding(
        ProjectReference(ReferenceCatalog, GlobalId("aimora://catalog/generic/bus@3.2.1")),
        v"3.2.1",
        ContentDigest(repeat("7", 64)),
        provenance,
    )
    asset = CanonicalAsset(
        project_record(fixture.project, ProjectId("bus.HV")).identity,
        asset_type,
        common,
        [static, emt, thermal, reliability],
        provenance;
        catalog,
        overrides = [AssetOverride(AssetProperty(FieldPath("catalog.rated_current"), 1200, provenance))],
        access = AccessProjectRestricted,
    )
    time_axis = DataAxis(ProjectId("timestamp"), TimeAxis, UnitId("s"), OrientationScalar)
    load_axis = DataAxis(ProjectId("active_power"), OperatingPointAxis, UnitId("MW"), OrientationScalar)
    profile = ProfileDescriptor(
        ObjectIdentity(ProjectId("profile.load_weekday")),
        type("quantity.active_power"),
        UnitId("MW"),
        OrientationScalar,
        time_axis,
        profile_artifact,
        InterpolationLinear,
        ExtrapolationError,
        MissingDataError,
        AccessProjectRestricted,
        provenance,
    )
    curve = CurveDescriptor(
        ObjectIdentity(ProjectId("curve.load_schedule")),
        time_axis,
        load_axis,
        [
            CurvePoint(
                asset_quantity("0.0", "s", OrientationScalar, provenance),
                asset_quantity("50.0", "MW", OrientationScalar, provenance),
            ),
            CurvePoint(
                asset_quantity("60.0", "s", OrientationScalar, provenance),
                asset_quantity("55.0", "MW", OrientationScalar, provenance),
            ),
        ],
        InterpolationLinear,
        ExtrapolationHold,
        provenance,
    )
    artifact_curve = CurveDescriptor(
        ObjectIdentity(ProjectId("curve.relay_tcc")),
        DataAxis(ProjectId("current"), OperatingPointAxis, UnitId("A"), OrientationIntoAsset),
        DataAxis(ProjectId("time"), TimeAxis, UnitId("s"), OrientationScalar),
        CurvePoint[],
        InterpolationLogLogLinear,
        ExtrapolationError,
        provenance;
        artifact = curve_artifact,
    )
    matrix = MatrixDescriptor(
        ObjectIdentity(ProjectId("matrix.bus_impedance")),
        matrix_artifact,
        UnitId("ohm"),
        ["A", "B", "C"],
        ["A", "B", "C"],
        MatrixSymmetric,
        provenance,
    )
    measurement = MeasurementDefinition(
        ObjectIdentity(ProjectId("measurement.bus_voltage")),
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        type("quantity.voltage"),
        UnitId("kV"),
        OrientationPhaseToPhaseRms,
        ProjectReference(ReferenceProfile, profile.identity.id),
        provenance,
    )
    library = AssetLibrary(;
        assets = [asset],
        profiles = [profile],
        curves = [curve, artifact_curve],
        matrices = [matrix],
        measurements = [measurement],
    )
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        library,
    )
    revision = initial_revision(
        project,
        ContentDigest(repeat("8", 64)),
        ContentDigest(repeat("9", 64)),
        transaction_provenance(fixture, "action.asset_import", 10),
    )
    return (;
        fixture...,
        project,
        revision,
        asset,
        static,
        emt,
        thermal,
        reliability,
        profile,
        curve,
        artifact_curve,
        matrix,
        measurement,
        type,
        content_schema,
    )
end

@testset "public multi-realization asset example" begin
    example_module = Module(:CanonicalAssetExample, true, true)
    example = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "canonical_assets.jl"))
    @test example.project.verification == ProjectVerified
    @test length(example.project.asset_library.assets) == 1
    @test select_realization(example.asset, InstantaneousEMT, SwitchingDetailed).id == ProjectId("realization.emt")
end

@testset "shared assets expose exact independent study realizations" begin
    fixture = asset_fixture()
    @test validate_asset_library(fixture.project)
    @test fixture.project.verification == ProjectVerified
    @test canonical_asset(fixture.project, ProjectId("bus.HV")) == fixture.asset
    @test select_realization(fixture.asset, StaticPhasor, AverageValue) == fixture.static
    @test select_realization(fixture.asset, InstantaneousEMT, SwitchingDetailed) == fixture.emt
    @test select_realization(fixture.asset, ReliabilityAsset, AverageValue) == fixture.reliability
    @test semantic_error_code(() -> select_realization(fixture.asset, InstantaneousEMT, AverageValue)) == :missing_exact_realization
    @test semantic_error_code(() -> select_realization(fixture.asset, ThermalField, FieldCoupledDetailed)) == :realization_not_executable
    @test fixture.asset.catalog.version == v"3.2.1"
    @test fixture.asset.catalog.content_hash == ContentDigest(repeat("7", 64))
    @test fixture.asset.access == AccessProjectRestricted
    @test fixture.asset.common[1].value.uncertainty.kind == UncertaintyNormal
    @test fixture.emt.derived_parameters[1].upstream_hashes[1] == ContentDigest(repeat("6", 64))
end

@testset "asset declarations reject fidelity provenance and validity ambiguity" begin
    fixture = asset_fixture()
    provenance = fixture.provenance
    duplicate_selection = StudyRealization(
        ProjectId("realization.static_duplicate"),
        fixture.static.model,
        fixture.static.representation,
        fixture.static.fidelity,
        ModelExecutable,
        ModelQualified,
        AssetProperty[],
        DerivedAssetProperty[],
        ValidityLimit[],
        provenance,
    )
    @test semantic_error_code(() -> CanonicalAsset(
        fixture.asset.identity,
        fixture.asset.asset_type,
        collect(fixture.asset.common),
        [fixture.static, duplicate_selection],
        provenance,
    )) == :ambiguous_realization_selection
    @test semantic_error_code(() -> StudyRealization(
        ProjectId("realization.unqualified"),
        fixture.static.model,
        StaticPhasor,
        SwitchingStateEquivalent,
        ModelExecutable,
        ModelUnqualified,
        AssetProperty[],
        DerivedAssetProperty[],
        ValidityLimit[],
        provenance,
    ) |> realization -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(assets = [CanonicalAsset(
            fixture.asset.identity,
            fixture.asset.asset_type,
            AssetProperty[],
            [realization],
            provenance,
        )]),
    ))) == :unqualified_executable_realization
    @test semantic_error_code(() -> DerivedAssetProperty(
        AssetProperty(FieldPath("derived.value"), 1, provenance),
        fixture.type("derive.test"),
        ContentDigest[],
    )) == :missing_derivation_input
    common_conflict = StudyRealization(
        ProjectId("realization.conflict"),
        fixture.static.model,
        StaticPhasor,
        SwitchingStateEquivalent,
        ModelPlanned,
        ModelUnqualified,
        [fixture.asset.common[1]],
        DerivedAssetProperty[],
        ValidityLimit[],
        provenance,
    )
    conflicting_asset = CanonicalAsset(
        fixture.asset.identity,
        fixture.asset.asset_type,
        collect(fixture.asset.common),
        [common_conflict],
        provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(assets = [conflicting_asset]),
    ))) == :common_realization_parameter_conflict
    @test semantic_error_code(() -> CanonicalAsset(
        fixture.asset.identity,
        fixture.asset.asset_type,
        AssetProperty[],
        StudyRealization[],
        provenance;
        overrides = [fixture.asset.overrides[1]],
    )) == :override_without_catalog
    @test semantic_error_code(() -> CatalogBinding(
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        v"1.0.0",
        ContentDigest(repeat("a", 64)),
        provenance,
    )) == :invalid_catalog_binding

    wrong_upper = asset_quantity("65.0", "s", OrientationScalar, provenance)
    invalid_limit = ValidityLimit(
        fixture.type("quantity.frequency");
        lower = asset_quantity("45.0", "Hz", OrientationScalar, provenance),
        upper = wrong_upper,
    )
    invalid_realization = StudyRealization(
        ProjectId("realization.invalid_validity"),
        fixture.static.model,
        StaticPhasor,
        SwitchingStateEquivalent,
        ModelPlanned,
        ModelUnqualified,
        AssetProperty[],
        DerivedAssetProperty[],
        [invalid_limit],
        provenance,
    )
    invalid_asset = CanonicalAsset(
        fixture.asset.identity,
        fixture.asset.asset_type,
        AssetProperty[],
        [invalid_realization],
        provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(assets = [invalid_asset]),
    ))) == :dimension_mismatch

    orientation_limit = ValidityLimit(
        fixture.type("quantity.voltage");
        lower = asset_quantity("10.0", "kV", OrientationPhaseToGroundRms, provenance),
        upper = asset_quantity("20.0", "kV", OrientationPhaseToPhaseRms, provenance),
    )
    @test semantic_error_code(() -> AIMORAProject._validate_validity_limit(fixture.project, orientation_limit)) == :validity_orientation_mismatch
    descending_limit = ValidityLimit(
        fixture.type("quantity.frequency");
        lower = asset_quantity("65.0", "Hz", OrientationScalar, provenance),
        upper = asset_quantity("45.0", "Hz", OrientationScalar, provenance),
    )
    @test semantic_error_code(() -> AIMORAProject._validate_validity_limit(fixture.project, descending_limit)) == :invalid_validity_bounds
    base_hv = BaseReference(BaseAsset, ProjectReference(ReferenceAsset, ProjectId("bus.HV")))
    base_mv = BaseReference(BaseAsset, ProjectReference(ReferenceAsset, ProjectId("bus.MV")))
    base_limit = ValidityLimit(
        fixture.type("quantity.voltage");
        lower = asset_quantity("0.9", "pu", OrientationScalar, provenance; base = base_hv),
        upper = asset_quantity("1.1", "pu", OrientationScalar, provenance; base = base_mv),
    )
    @test semantic_error_code(() -> AIMORAProject._validate_validity_limit(fixture.project, base_limit)) == :validity_base_mismatch
end

@testset "profiles curves matrices and measurements enforce data contracts" begin
    fixture = asset_fixture()
    @test fixture.profile.interpolation == InterpolationLinear
    @test fixture.profile.extrapolation == ExtrapolationError
    @test fixture.profile.missing_data == MissingDataError
    @test fixture.artifact_curve.artifact.schema == fixture.content_schema
    @test fixture.matrix.row_order == fixture.matrix.column_order
    @test fixture.measurement.profile.target.id == fixture.profile.identity.id

    @test semantic_error_code(() -> CurveDescriptor(
        ObjectIdentity(ProjectId("curve.empty")),
        fixture.curve.x_axis,
        fixture.curve.y_axis,
        CurvePoint[],
        InterpolationLinear,
        ExtrapolationError,
        fixture.provenance,
    )) == :invalid_curve_source
    @test semantic_error_code(() -> CurveDescriptor(
        ObjectIdentity(ProjectId("curve.two_sources")),
        fixture.curve.x_axis,
        fixture.curve.y_axis,
        collect(fixture.curve.points),
        InterpolationLinear,
        ExtrapolationError,
        fixture.provenance;
        artifact = fixture.artifact_curve.artifact,
    )) == :invalid_curve_source
    reversed_curve = CurveDescriptor(
        ObjectIdentity(ProjectId("curve.reversed")),
        fixture.curve.x_axis,
        fixture.curve.y_axis,
        reverse(collect(fixture.curve.points)),
        InterpolationLinear,
        ExtrapolationError,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(curves = [reversed_curve]),
    ))) == :nonmonotonic_curve_axis
    @test semantic_error_code(() -> MatrixDescriptor(
        ObjectIdentity(ProjectId("matrix.bad_symmetry")),
        fixture.matrix.artifact,
        UnitId("ohm"),
        ["A", "B"],
        ["B", "A"],
        MatrixSymmetric,
        fixture.provenance,
    )) == :invalid_matrix_symmetry
    invalid_axis_profile = ProfileDescriptor(
        ObjectIdentity(ProjectId("profile.bad_time_axis")),
        fixture.profile.quantity,
        UnitId("MW"),
        OrientationScalar,
        DataAxis(ProjectId("timestamp"), TimeAxis, UnitId("MW"), OrientationScalar),
        fixture.profile.artifact,
        InterpolationLinear,
        ExtrapolationError,
        MissingDataError,
        AccessPublic,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(profiles = [invalid_axis_profile]),
    ))) == :time_axis_unit_mismatch
    invalid_missing_profile = ProfileDescriptor(
        ObjectIdentity(ProjectId("profile.bad_missing_policy")),
        fixture.profile.quantity,
        UnitId("MW"),
        OrientationScalar,
        fixture.profile.axis,
        fixture.profile.artifact,
        InterpolationProhibited,
        ExtrapolationError,
        MissingDataInterpolate,
        AccessPublic,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(profiles = [invalid_missing_profile]),
    ))) == :invalid_missing_data_policy
    no_schema = ArtifactIdentity(
        ProjectId("artifact.no_schema"),
        "data/no_schema.csv",
        repeat("b", 64),
        "text/csv",
        fixture.provenance,
    )
    invalid_profile = ProfileDescriptor(
        ObjectIdentity(ProjectId("profile.invalid")),
        fixture.profile.quantity,
        UnitId("MW"),
        OrientationScalar,
        fixture.profile.axis,
        no_schema,
        InterpolationLinear,
        ExtrapolationError,
        MissingDataError,
        AccessPublic,
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(profiles = [invalid_profile]),
    ))) == :missing_artifact_schema
    bad_measurement = MeasurementDefinition(
        ObjectIdentity(ProjectId("measurement.bad_profile")),
        ProjectReference(ReferenceAsset, ProjectId("bus.HV")),
        fixture.measurement.quantity,
        UnitId("kV"),
        OrientationPhaseToPhaseRms,
        ProjectReference(ReferenceProfile, ProjectId("profile.missing")),
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(assets = [fixture.asset], measurements = [bad_measurement]),
    ))) == :dangling_measurement_profile
end

@testset "asset transactions replay undo and protect dependents" begin
    fixture = asset_fixture()
    revised_rating = AssetProperty(
        FieldPath("nameplate.rating"),
        asset_quantity("110.0", "MVA", OrientationScalar, fixture.provenance),
        fixture.provenance,
    )
    harmonic = StudyRealization(
        ProjectId("realization.harmonic"),
        fixture.type("model.bus.harmonic"),
        HarmonicFrequencyDomain,
        AverageValue,
        ModelExecutable,
        ModelQualified,
        AssetProperty[],
        DerivedAssetProperty[],
        ValidityLimit[],
        fixture.provenance,
    )
    commands = [
        ProjectCommand(
            ProjectId("command.set_rating"),
            SetAssetCommonPropertyPatch(ProjectId("bus.HV"), revised_rating),
        ),
        ProjectCommand(
            ProjectId("command.add_harmonic"),
            AddStudyRealizationPatch(ProjectId("bus.HV"), harmonic),
        ),
    ]
    transaction = begin_project_transaction(fixture.revision)
    foreach(command -> apply!(transaction, command), commands)
    committed = commit!(
        transaction,
        fixture.revision,
        ContentDigest(repeat("c", 64)),
        ContentDigest(repeat("d", 64)),
        transaction_provenance(fixture, "action.asset_update", 11),
    )
    @test select_realization(canonical_asset(committed.project, ProjectId("bus.HV")), HarmonicFrequencyDomain, AverageValue) == harmonic
    @test collect(committed.changed_owners) == [ProjectId("bus.HV")]
    @test collect(committed.invalidations[1].scopes) == [InvalidateStudyResults, InvalidateWorkflowResults]
    @test replay_commands(fixture.project, commands) == committed.project
    undo = inverse_commands(fixture.project, commands)
    @test replay_commands(committed.project, undo) == fixture.project

    blocked_asset = begin_project_transaction(fixture.revision)
    @test semantic_error_code(() -> apply!(
        blocked_asset,
        ProjectCommand(ProjectId("command.remove_asset"), RemoveAssetPatch(ProjectId("bus.HV"))),
    )) == :asset_has_measurement_dependents
    blocked_profile = begin_project_transaction(fixture.revision)
    @test semantic_error_code(() -> apply!(
        blocked_profile,
        ProjectCommand(
            ProjectId("command.remove_profile"),
            RemoveAssetDataPatch(ProfileData, fixture.profile.identity.id),
        ),
    )) == :asset_data_has_dependents

    removable = begin_project_transaction(fixture.revision)
    apply!(
        removable,
        ProjectCommand(
            ProjectId("command.remove_measurement"),
            RemoveAssetDataPatch(MeasurementData, fixture.measurement.identity.id),
        ),
    )
    apply!(
        removable,
        ProjectCommand(ProjectId("command.remove_asset"), RemoveAssetPatch(ProjectId("bus.HV"))),
    )
    validate!(removable)
    @test isempty(removable.working.asset_library.assets)
    @test isempty(removable.working.asset_library.measurements)
    removal_commands = copy(removable.commands)
    removal_undo = inverse_commands(fixture.project, removal_commands)
    @test replay_commands(removable.working, removal_undo) == fixture.project

    replacement = StudyRealization(
        fixture.static.id,
        fixture.static.model,
        fixture.static.representation,
        fixture.static.fidelity,
        fixture.static.availability,
        ModelProduction,
        collect(fixture.static.parameters),
        collect(fixture.static.derived_parameters),
        collect(fixture.static.validity),
        fixture.provenance,
    )
    realization_commands = [
        ProjectCommand(
            ProjectId("command.replace_static"),
            ReplaceStudyRealizationPatch(ProjectId("bus.HV"), replacement),
        ),
        ProjectCommand(
            ProjectId("command.remove_reliability"),
            RemoveStudyRealizationPatch(ProjectId("bus.HV"), fixture.reliability.id),
        ),
        ProjectCommand(
            ProjectId("command.unset_in_service"),
            UnsetAssetCommonPropertyPatch(ProjectId("bus.HV"), FieldPath("physical.in_service")),
        ),
    ]
    realized = replay_commands(fixture.project, realization_commands)
    @test select_realization(canonical_asset(realized, ProjectId("bus.HV")), StaticPhasor, AverageValue).qualification == ModelProduction
    @test semantic_error_code(() -> select_realization(canonical_asset(realized, ProjectId("bus.HV")), ReliabilityAsset, AverageValue)) == :missing_exact_realization
    @test replay_commands(realized, inverse_commands(fixture.project, realization_commands)) == fixture.project

    second_asset = CanonicalAsset(
        project_record(fixture.project, ProjectId("bus.MV")).identity,
        fixture.asset.asset_type,
        AssetProperty[],
        StudyRealization[],
        fixture.provenance,
    )
    added_curve = CurveDescriptor(
        ObjectIdentity(ProjectId("curve.added")),
        fixture.curve.x_axis,
        fixture.curve.y_axis,
        collect(fixture.curve.points),
        fixture.curve.interpolation,
        fixture.curve.extrapolation,
        fixture.provenance,
    )
    added_matrix = MatrixDescriptor(
        ObjectIdentity(ProjectId("matrix.added")),
        fixture.matrix.artifact,
        fixture.matrix.unit,
        collect(fixture.matrix.row_order),
        collect(fixture.matrix.column_order),
        fixture.matrix.symmetry,
        fixture.provenance,
    )
    added_profile = ProfileDescriptor(
        ObjectIdentity(ProjectId("profile.added")),
        fixture.profile.quantity,
        fixture.profile.value_unit,
        fixture.profile.value_orientation,
        fixture.profile.axis,
        fixture.profile.artifact,
        fixture.profile.interpolation,
        fixture.profile.extrapolation,
        fixture.profile.missing_data,
        fixture.profile.access,
        fixture.provenance,
    )
    added_measurement = MeasurementDefinition(
        ObjectIdentity(ProjectId("measurement.added")),
        ProjectReference(ReferenceAsset, ProjectId("bus.MV")),
        fixture.measurement.quantity,
        fixture.measurement.unit,
        fixture.measurement.orientation,
        ProjectReference(ReferenceProfile, added_profile.identity.id),
        fixture.provenance,
    )
    add_commands = [
        ProjectCommand(ProjectId("command.add_asset"), AddAssetPatch(second_asset)),
        ProjectCommand(ProjectId("command.add_profile"), AddAssetDataPatch(added_profile)),
        ProjectCommand(ProjectId("command.add_curve"), AddAssetDataPatch(added_curve)),
        ProjectCommand(ProjectId("command.add_matrix"), AddAssetDataPatch(added_matrix)),
        ProjectCommand(ProjectId("command.add_measurement"), AddAssetDataPatch(added_measurement)),
    ]
    expanded = replay_commands(fixture.project, add_commands)
    @test canonical_asset(expanded, ProjectId("bus.MV")) == second_asset
    @test added_profile in expanded.asset_library.profiles
    @test added_curve in expanded.asset_library.curves
    @test added_matrix in expanded.asset_library.matrices
    @test added_measurement in expanded.asset_library.measurements
    @test replay_commands(expanded, inverse_commands(fixture.project, add_commands)) == fixture.project
end

@testset "canonical asset data excludes runtime and generic mutable storage" begin
    canonical_types = [
        FieldPath,
        AssetProperty,
        ValidityLimit,
        DerivedAssetProperty,
        StudyRealization,
        CatalogBinding,
        AssetOverride,
        CanonicalAsset,
        DataAxis,
        ProfileDescriptor,
        CurvePoint,
        CurveDescriptor,
        MatrixDescriptor,
        MeasurementDefinition,
        AssetLibrary,
    ]
    @test all(!ismutabletype(type) for type in canonical_types)
    @test all(type -> all(field -> field !== Any && field !== Function && !(field <: AbstractDict), fieldtypes(type)), canonical_types)
end
