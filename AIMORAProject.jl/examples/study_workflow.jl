using AIMORAProject
using Dates
using UUIDs

primitive = Base.include(@__MODULE__, joinpath(@__DIR__, "canonical_primitives.jl"))
provenance = primitive.voltage.provenance
namespace = NamespaceId("aimora")
semantic_type(name) = SemanticTypeId(namespace, ProjectId(name), v"1.0.0")

record = CanonicalRecord(
    ObjectIdentity(ProjectId("bus.study_demo")),
    primitive.schema.identity,
    [
        CanonicalField("id", "bus.study_demo"),
        CanonicalField("nominal_voltage", primitive.voltage),
    ],
    provenance,
)
rating = PhysicalValue(
    ScalarQuantity(parse_exact_decimal("100.0"), UnitId("MVA"), OrientationScalar),
    provenance,
)
realization = StudyRealization(
    ProjectId("realization.bus_static"),
    semantic_type("model.bus.static_phasor"),
    StaticPhasor,
    AverageValue,
    ModelExecutable,
    ModelQualified,
    AssetProperty[],
    DerivedAssetProperty[],
    ValidityLimit[],
    provenance,
)
asset = CanonicalAsset(
    record.identity,
    semantic_type("asset.bus"),
    [AssetProperty(FieldPath("nameplate.rating"), rating, provenance)],
    [realization],
    provenance,
)
metadata = ProjectMetadata(
    ObjectIdentity(ProjectId("project.study_workflow_demo")),
    "Study Workflow Demo",
    namespace,
    v"1.0.0",
    DateTime(2026, 8, 9, 12, 0, 0),
    provenance,
)
study_schema = StudyRequestSchema(
    SemanticSchemaIdentity(
        UUID("bd78f321-ddd5-4ce7-96ac-2efc808e8bd4"),
        namespace,
        ProjectId("study.power_flow"),
        v"1.0.0",
    ),
    [StaticPhasor],
    [AverageValue],
    [SchemaField(
        "tolerance",
        SchemaDecimal;
        required = true,
        constraints = [NumericBoundsConstraint(lower = ExactRational(0))],
    )],
    SchemaField[],
    provenance,
)
voltage_contract = ResultContract(
    SemanticSchemaIdentity(
        UUID("b707d73d-e74d-4f3c-8040-c4202e1095a6"),
        namespace,
        ProjectId("result.bus_voltage"),
        v"1.0.0",
    ),
    [SchemaField(
        "voltage",
        SchemaQuantity;
        required = true,
        constraints = [QuantityConstraint(
            lookup_unit(primitive.units, UnitId("kV")).dimension,
            [OrientationPhaseToPhaseRms],
        )],
    )],
    provenance,
)
function_identity = RegisteredFunctionIdentity(
    UUID("01448609-f7e7-45e6-bcc2-ae220f9c239d"),
    semantic_type("package.study_demo"),
    ProjectId("solve_power_flow"),
    ContentDigest(repeat("1", 64)),
)
study = StudyRequest(
    ObjectIdentity(ProjectId("study.base_power_flow")),
    study_schema.identity,
    ContentDigest(repeat("2", 64)),
    nothing,
    StaticPhasor,
    AverageValue,
    StudyMethodDeclaration(semantic_type("method.newton_raphson"), function_identity, CanonicalField[]),
    [CanonicalField("tolerance", parse_exact_decimal("1.0e-8"))],
    CanonicalField[],
    ProjectReference[],
    [StudyOutputRequest(
        ObjectIdentity(ProjectId("output.bus_voltage")),
        voltage_contract.identity,
        ProjectReference(ReferenceAsset, asset.identity.id),
        semantic_type("quantity.voltage"),
        UnitId("kV"),
        OrientationPhaseToPhaseRms,
        provenance,
    )],
    StudyPrerequisite[],
    StudyValidityPolicy(StudyOutsideDomainError, StudyOptionalDataWarning),
    provenance,
)
step = WorkflowStep(
    ObjectIdentity(ProjectId("step.power_flow")),
    ProjectReference(ReferenceStudy, study.identity.id),
    ProjectId[],
    WorkflowInputBinding[],
    provenance,
)
workflow = WorkflowDefinition(
    ObjectIdentity(ProjectId("workflow.base_review")),
    [step],
    WorkflowStopOnFailure,
    WorkflowUseValidCache,
    provenance,
)
lower = PhysicalValue(
    ScalarQuantity(parse_exact_decimal("80.0"), UnitId("MVA"), OrientationScalar),
    provenance,
)
upper = PhysicalValue(
    ScalarQuantity(parse_exact_decimal("120.0"), UnitId("MVA"), OrientationScalar),
    provenance,
)
sweep = ParameterSweepExperiment(
    ObjectIdentity(ProjectId("experiment.rating_sweep")),
    [DecisionVariable(
        ObjectIdentity(ProjectId("variable.bus_rating")),
        ProjectReference(ReferenceAsset, asset.identity.id),
        FieldPath("nameplate.rating"),
        UnitId("MVA"),
        OrientationScalar,
        DecisionContinuous,
        lower,
        upper,
        [lower, rating, upper],
        provenance,
    )],
    ProjectReference(ReferenceWorkflow, workflow.identity.id),
    ExperimentExecution(ExperimentSerial, 1, 20260809, semantic_type("rng.stable")),
    ExperimentCheckpoint(semantic_type("checkpoint.parameter_sweep"), 1, 3, true),
    ExperimentPolicies(ExperimentStopOnFailure, ExperimentUseValidCache),
    provenance,
)
project = CanonicalProject(
    metadata,
    primitive.registry,
    primitive.units,
    [record],
    SemanticGraphs(),
    AssetLibrary(assets = [asset]),
    HierarchyModel(),
    ControlSystem(),
    EventScenarioModel(),
    OrchestrationModel(
        study_schemas = [study_schema],
        studies = [study],
        result_contracts = [voltage_contract],
        workflows = [workflow],
        experiments = [sweep],
    ),
)
println("validated workflow ", workflow.identity.id.value, " with bounded sweep ", sweep.identity.id.value)
hashes = project_semantic_hashes(
    project,
    ContentDigest(repeat("3", 64)),
    ExecutionDependencySignatures(
        ContentDigest(repeat("4", 64)),
        ContentDigest(repeat("5", 64)),
        ContentDigest(repeat("6", 64)),
    ),
)
readiness = study_readiness(project, study.identity.id)
println("physics hash ", hashes.physics.sha256, " readiness ", readiness.state)
(; project, study, workflow, sweep, hashes, readiness)
