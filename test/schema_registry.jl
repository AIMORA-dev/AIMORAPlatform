function canonical_schema_fixture()
    units = si_unit_registry()
    provenance = canonical_test_provenance()
    licence = canonical_test_licence()
    namespace = NamespaceId("aimora")
    namespace_registration = NamespaceRegistration(
        namespace,
        UUID("1867e578-e373-4a38-a813-9703fe6c30ba"),
        licence,
        provenance,
    )
    voltage_dimension = lookup_unit(units, UnitId("V")).dimension
    fields = [
        SchemaField(
            "id",
            SchemaString;
            required = true,
            description = "Stable project-local ID",
        ),
        SchemaField(
            "mode",
            SchemaString;
            required = true,
            constraints = [AllowedStringConstraint(["PQ", "PV", "slack"])],
        ),
        SchemaField(
            "nominal_voltage",
            SchemaQuantity;
            required = true,
            constraints = [QuantityConstraint(
                voltage_dimension,
                [OrientationPhaseToGroundRms, OrientationPhaseToPhaseRms];
                allow_per_unit = true,
            )],
        ),
        SchemaField(
            "source",
            SchemaReference;
            constraints = [ReferenceConstraint([ReferenceAsset, ReferenceCatalog])],
        ),
        SchemaField(
            "priority",
            SchemaInteger;
            constraints = [NumericBoundsConstraint(lower = ExactRational(0), upper = ExactRational(100))],
        ),
        SchemaField("artifact", SchemaArtifact),
    ]
    identity = SemanticSchemaIdentity(
        UUID("9475cb4e-713d-4691-9c65-a81374d51d96"),
        namespace,
        ProjectId("asset.bus"),
        v"1.0.0",
    )
    schema = SemanticSchema(identity, fields, provenance)
    registry = register_namespace(SemanticSchemaRegistry(), namespace_registration)
    registry = register_schema(registry, schema)
    return units, provenance, namespace_registration, schema, registry
end

@testset "public canonical primitive example" begin
    example = include(joinpath(@__DIR__, "..", "examples", "canonical_primitives.jl"))
    @test length(example.registry.namespaces) == 1
    @test length(example.registry.schemas) == 1
    @test validate_quantity(example.units, example.voltage)
end

@testset "immutable namespace and semantic schema registry" begin
    units, provenance, namespace_registration, schema, registry = canonical_schema_fixture()
    @test length(registry.namespaces) == 1
    @test length(registry.schemas) == 1
    @test resolve_schema(registry, schema.identity) == schema
    @test resolve_schema(registry, NamespaceId("aimora"), ProjectId("asset.bus"), v"1.0.0") == schema
    @test [field.name for field in schema.fields] == sort([field.name for field in schema.fields])
    @test schema_field(schema, "nominal_voltage").kind == SchemaQuantity
    @test register_namespace(registry, namespace_registration) === registry
    @test register_schema(registry, schema) === registry

    empty = SemanticSchemaRegistry()
    @test isempty(empty.namespaces)
    @test isempty(empty.schemas)
    @test length(registry.schemas) == 1
    @test_throws MethodError push!(registry.schemas, schema)

    conflicting_namespace = NamespaceRegistration(
        NamespaceId("aimora"),
        UUID("d86c0bb9-e121-4cd5-ae47-817c5497683f"),
        canonical_test_licence(),
        provenance,
    )
    @test semantic_error_code(() -> register_namespace(registry, conflicting_namespace)) == :namespace_owner_collision

    identity_collision = SemanticSchema(
        SemanticSchemaIdentity(
            UUID("817f8725-67f2-4ebc-b615-85f57cd77129"),
            NamespaceId("aimora"),
            ProjectId("asset.bus"),
            v"1.0.0",
        ),
        collect(schema.fields),
        provenance,
    )
    @test semantic_error_code(() -> register_schema(registry, identity_collision)) == :schema_identity_collision

    uuid_collision = SemanticSchema(
        SemanticSchemaIdentity(
            schema.identity.uuid,
            NamespaceId("aimora"),
            ProjectId("asset.other"),
            v"1.0.0",
        ),
        collect(schema.fields),
        provenance,
    )
    @test semantic_error_code(() -> register_schema(registry, uuid_collision)) == :schema_uuid_collision

    unknown_namespace_schema = SemanticSchema(
        SemanticSchemaIdentity(
            UUID("2b513873-cfa0-4a59-8619-1af45ce9eebf"),
            NamespaceId("vendor"),
            ProjectId("asset.custom"),
            v"1.0.0",
        ),
        [SchemaField("id", SchemaString; required = true)],
        provenance,
    )
    @test semantic_error_code(() -> register_schema(registry, unknown_namespace_schema)) == :unknown_schema_namespace
    @test semantic_error_code(() -> SemanticSchemaRegistry(NamespaceRegistration[], [unknown_namespace_schema])) == :unknown_schema_namespace
    @test semantic_error_code(() -> resolve_schema(registry, NamespaceId("aimora"), ProjectId("asset.bus"), v"2.0.0")) == :unknown_schema_version
    @test semantic_error_code(() -> schema_field(schema, "missing")) == :unknown_schema_field
end

@testset "schema constraints validate canonical typed values" begin
    units, provenance, _, schema, _ = canonical_schema_fixture()
    @test validate_field_value(schema_field(schema, "id"), "bus.HV", units)
    @test validate_field_value(schema_field(schema, "mode"), "PV", units)
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "mode"), "unknown", units)) == :value_not_allowed
    @test validate_field_value(schema_field(schema, "priority"), 50, units)
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "priority"), 101, units)) == :value_above_schema_bound
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "priority"), true, units)) == :schema_value_type_mismatch

    voltage = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
        provenance,
    )
    @test validate_field_value(schema_field(schema, "nominal_voltage"), voltage, units)
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "nominal_voltage"), voltage.quantity, units)) == :schema_value_type_mismatch
    current = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("100.0"), UnitId("A"), OrientationIntoAsset),
        provenance,
    )
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "nominal_voltage"), current, units)) == :dimension_mismatch

    base_reference = BaseReference(BaseVoltage, ProjectReference(ReferenceAsset, ProjectId("bus.HV")))
    per_unit = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("1.0"), UnitId("pu"), OrientationPhaseToPhaseRms; base = base_reference),
        provenance,
    )
    @test validate_field_value(schema_field(schema, "nominal_voltage"), per_unit, units)
    no_per_unit = SchemaField(
        "voltage",
        SchemaQuantity;
        constraints = [QuantityConstraint(
            lookup_unit(units, UnitId("V")).dimension,
            [OrientationPhaseToPhaseRms],
        )],
    )
    @test semantic_error_code(() -> validate_field_value(no_per_unit, per_unit, units)) == :per_unit_not_allowed

    source = ProjectReference(ReferenceCatalog, GlobalId("aimora://catalog/generic/source@1.0.0"))
    @test validate_field_value(schema_field(schema, "source"), source, units)
    wrong_reference = ProjectReference(ReferenceStudy, ProjectId("study.base"))
    @test semantic_error_code(() -> validate_field_value(schema_field(schema, "source"), wrong_reference, units)) == :reference_kind_mismatch

    artifact = ArtifactIdentity(
        ProjectId("artifact.profile"),
        "data/profile.csv",
        repeat("c", 64),
        "text/csv",
        provenance,
    )
    @test validate_field_value(schema_field(schema, "artifact"), artifact, units)
end

@testset "schema declarations reject hidden defaults and executable ambiguity" begin
    units, provenance, _, schema, _ = canonical_schema_fixture()
    @test semantic_error_code(() -> SchemaField("BadName", SchemaString)) == :invalid_schema_field_name
    @test semantic_error_code(() -> SchemaField("voltage", SchemaQuantity)) == :missing_quantity_constraint
    @test semantic_error_code(() -> SchemaField("source", SchemaReference)) == :missing_reference_constraint
    @test semantic_error_code(() -> SchemaField("name", SchemaString; constraints = [NumericBoundsConstraint(lower = ExactRational(0))])) == :incompatible_schema_constraint
    @test semantic_error_code(() -> NumericBoundsConstraint(lower = ExactRational(2), upper = ExactRational(1))) == :invalid_numeric_bounds
    @test semantic_error_code(() -> AllowedStringConstraint(["PV", "PV"])) == :duplicate_allowed_value
    @test semantic_error_code(() -> SemanticSchema(schema.identity, [schema.fields[1], schema.fields[1]], provenance)) == :duplicate_schema_field
    @test semantic_error_code(() -> SemanticSchemaIdentity(UUID(UInt128(0)), NamespaceId("aimora"), ProjectId("asset.bad"), v"1.0.0")) == :invalid_schema_uuid
    @test semantic_error_code(() -> SemanticSchemaIdentity(uuid4(), NamespaceId("aimora"), ProjectId("asset.bad"), v"0.1.0")) == :invalid_schema_version

    canonical_types = [
        ProjectId,
        NamespaceId,
        GlobalId,
        ObjectIdentity,
        IdentifiedName,
        SemanticTypeId,
        ReferenceToken,
        ReferencePath,
        ProjectReference,
        ExactDecimal,
        ExactRational,
        DimensionVector,
        UnitId,
        UnitDefinition,
        UnitRegistry,
        BaseReference,
        ScalarQuantity,
        ComplexQuantity,
        LicenceIdentity,
        ProvenanceSource,
        ArtifactIdentity,
        QuantityUncertainty,
        SchemaField,
        SemanticSchemaIdentity,
        SemanticSchema,
        NamespaceRegistration,
        SemanticSchemaRegistry,
        ContentDigest,
        CanonicalField,
        CanonicalRecord,
        ProjectMetadata,
        CanonicalProject,
        RevisionProvenance,
        DependencyInvalidation,
        CommandEffect,
        AddRecordPatch,
        RemoveRecordPatch,
        SetRecordFieldPatch,
        UnsetRecordFieldPatch,
        SetProjectNamePatch,
        UnsafeReplaceRecordsPatch,
        ProjectCommand,
        ProjectRevision,
        RevisionConflict,
        ProjectSnapshot,
        GraphDomainIdentity,
        CarrierIdentity,
        SignalContract,
        GraphNode,
        SemanticPort,
        CarrierMapping,
        PhysicalConnection,
        SignalConnection,
        WorkflowDependency,
        CrossGraphReference,
        ViewProjection,
        SemanticGraphs,
        AddGraphElementPatch,
        RemoveGraphElementPatch,
        ConnectGraphPatch,
        DisconnectGraphPatch,
        ControlPortSpec,
        ControlStateSpec,
        ControlBlockSchema,
        ControlPortBinding,
        ControlStateDeclaration,
        ControlBlock,
        ControlSchedule,
        ControlExternalPort,
        ControlBoundaryBinding,
        ControlLinkDelay,
        ControlImportProvenance,
        AlgebraicLoopDeclaration,
        ControlNetwork,
        ControlSystem,
        AddControlBlockSchemaPatch,
        RemoveControlBlockSchemaPatch,
        AddControlNetworkPatch,
        RemoveControlNetworkPatch,
        ReplaceControlNetworkPatch,
        RelativeEventTrigger,
        AbsoluteEventTrigger,
        SampledEventTrigger,
        ConditionEventTrigger,
        EventResetDeclaration,
        EventDeclaration,
        ScenarioPatchDeclaration,
        ScenarioDefinition,
        EventScenarioModel,
        AddEventDeclarationPatch,
        RemoveEventDeclarationPatch,
        ReplaceEventDeclarationPatch,
        SetEventEnabledPatch,
        AddScenarioDefinitionPatch,
        RemoveScenarioDefinitionPatch,
        ReplaceScenarioDefinitionPatch,
        ResolvedScenario,
        RegisteredFunctionIdentity,
        StudyValidityPolicy,
        StudyRequestSchema,
        StudyMethodDeclaration,
        StudyOutputRequest,
        StudyPrerequisite,
        StudyRequest,
        ResultContract,
        ResultDeclaration,
        ExistingResultSource,
        StepResultSource,
        WorkflowInputBinding,
        WorkflowStep,
        WorkflowDefinition,
        DecisionVariable,
        ResultSelector,
        ObjectiveDeclaration,
        ConstraintDeclaration,
        ExperimentSolverDeclaration,
        ExperimentStoppingCriteria,
        ExperimentExecution,
        ExperimentCheckpoint,
        ExperimentPolicies,
        ParameterSweepExperiment,
        BoundedIterationExperiment,
        CalibrationExperiment,
        UncertainInput,
        UncertaintyExperiment,
        OptimizationExperiment,
        OrchestrationModel,
        AddStudyRequestSchemaPatch,
        RemoveStudyRequestSchemaPatch,
        ReplaceStudyRequestSchemaPatch,
        AddStudyRequestPatch,
        RemoveStudyRequestPatch,
        ReplaceStudyRequestPatch,
        AddResultContractPatch,
        RemoveResultContractPatch,
        ReplaceResultContractPatch,
        AddResultDeclarationPatch,
        RemoveResultDeclarationPatch,
        ReplaceResultDeclarationPatch,
        AddWorkflowDefinitionPatch,
        RemoveWorkflowDefinitionPatch,
        ReplaceWorkflowDefinitionPatch,
        AddExperimentDeclarationPatch,
        RemoveExperimentDeclarationPatch,
        ReplaceExperimentDeclarationPatch,
    ]
    for canonical_type in canonical_types
        @test all(field_type -> field_type != Any, fieldtypes(canonical_type))
        @test all(field_type -> !(field_type isa DataType && field_type <: Function), fieldtypes(canonical_type))
        @test !ismutabletype(canonical_type)
    end
    @test :default ∉ fieldnames(SchemaField)
    @test all(constraint -> !(constraint isa Function), schema.fields[1].constraints)
    @test validate_quantity(units, PhysicalValue(
        ScalarQuantity(ExactRational(1), UnitId("1"), OrientationScalar),
        provenance,
    ))
end
