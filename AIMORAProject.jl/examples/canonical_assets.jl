using AIMORAProject
using Dates

primitive = Base.include(@__MODULE__, joinpath(@__DIR__, "canonical_primitives.jl"))
provenance = primitive.voltage.provenance
schema = primitive.schema
namespace = NamespaceId("aimora")
semantic_type(name) = SemanticTypeId(namespace, ProjectId(name), v"1.0.0")

record = CanonicalRecord(
    ObjectIdentity(ProjectId("bus.demo")),
    schema.identity,
    [
        CanonicalField("id", "bus.demo"),
        CanonicalField("nominal_voltage", primitive.voltage),
    ],
    provenance,
)
metadata = ProjectMetadata(
    ObjectIdentity(ProjectId("project.asset_demo")),
    "Canonical Multi-Realization Asset Demo",
    namespace,
    v"1.0.0",
    DateTime(2026, 8, 9, 12, 0, 0),
    provenance,
)
asset_type = SemanticTypeId(
    schema.identity.namespace,
    schema.identity.name,
    schema.identity.version,
)
rating = AssetProperty(
    FieldPath("nameplate.rating"),
    PhysicalValue(
        ScalarQuantity(parse_exact_decimal("100.0"), UnitId("MVA"), OrientationScalar),
        provenance,
    ),
    provenance,
)
static = StudyRealization(
    ProjectId("realization.static"),
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
emt = StudyRealization(
    ProjectId("realization.emt"),
    semantic_type("model.bus.instantaneous_emt"),
    InstantaneousEMT,
    SwitchingDetailed,
    ModelExecutable,
    ModelQualified,
    AssetProperty[],
    DerivedAssetProperty[],
    ValidityLimit[],
    provenance,
)
asset = CanonicalAsset(
    record.identity,
    asset_type,
    [rating],
    [static, emt],
    provenance,
)
project = CanonicalProject(
    metadata,
    primitive.registry,
    primitive.units,
    [record],
    SemanticGraphs(),
    AssetLibrary(assets = [asset]),
)

println(
    "asset ",
    asset.identity.id.value,
    " reuses one physical identity across ",
    length(asset.realizations),
    " exact study realizations",
)

(; project, asset)
