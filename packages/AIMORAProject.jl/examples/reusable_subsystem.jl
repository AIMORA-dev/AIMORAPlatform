using AIMORAProject
using Dates

primitive = Base.include(@__MODULE__, joinpath(@__DIR__, "canonical_primitives.jl"))
provenance = primitive.voltage.provenance
schema = primitive.schema
namespace = NamespaceId("aimora")

record = DefinitionRecord(
    ObjectIdentity(ProjectId("branch.owner")),
    schema.identity,
    [
        CanonicalField("id", "branch.owner"),
        CanonicalField("nominal_voltage", primitive.voltage),
    ],
    provenance,
)
asset = CanonicalAsset(
    record.identity,
    SemanticTypeId(schema.identity.namespace, schema.identity.name, schema.identity.version),
    AssetProperty[],
    StudyRealization[],
    provenance,
)
rating_parameter = DefinitionParameterSpec(SchemaField(
    "rating",
    SchemaQuantity;
    required = true,
    constraints = [QuantityConstraint(
        lookup_unit(primitive.units, UnitId("MVA")).dimension,
        [OrientationScalar],
    )],
))
definition = ReusableDefinition(
    ObjectIdentity(ProjectId("definition.rated_branch")),
    SemanticTypeId(namespace, ProjectId("definition.rated_branch"), v"1.0.0"),
    [rating_parameter],
    DefinitionExternalPort[],
    [record],
    [asset],
    SemanticGraphs(),
    [DefinitionParameterBinding(
        "rating",
        asset.identity.id,
        DefinitionAssetCommonProperty,
        FieldPath("nameplate.rating"),
    )],
    DefinitionInstance[],
    provenance,
)

function branch_instance(id, rating)
    return DefinitionInstance(
        ObjectIdentity(ProjectId(id)),
        ProjectReference(ReferenceDefinition, definition.identity.id),
        v"1.0.0",
        [InstanceParameterValue(
            "rating",
            PhysicalValue(
                ScalarQuantity(parse_exact_decimal(rating), UnitId("MVA"), OrientationScalar),
                provenance,
            ),
            provenance,
        )],
        InstancePortBinding[],
        provenance,
    )
end

feed_one = branch_instance("subsystem.feed_one", "100.0")
feed_two = branch_instance("subsystem.feed_two", "125.0")
metadata = ProjectMetadata(
    ObjectIdentity(ProjectId("project.reusable_subsystem_demo")),
    "Reusable Subsystem Demo",
    namespace,
    v"1.0.0",
    DateTime(2026, 8, 9, 12, 0, 0),
    provenance,
)
project = CanonicalProject(
    metadata,
    primitive.registry,
    primitive.units,
    CanonicalRecord[],
    SemanticGraphs(),
    AssetLibrary(),
    HierarchyModel(definitions = [definition], instances = [feed_one, feed_two]),
)
first = expand_instance(project, feed_one)
second = expand_instance(project, feed_two)

println("expanded two independent instances from ", definition.identity.id.value)
(; project, first, second)
