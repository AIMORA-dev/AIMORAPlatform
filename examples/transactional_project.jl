using AIMORAProject
using Dates

primitive = Base.include(@__MODULE__, joinpath(@__DIR__, "canonical_primitives.jl"))
provenance = primitive.voltage.provenance
schema = primitive.schema

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
    ObjectIdentity(ProjectId("project.transaction_demo")),
    "Transactional Project Demo",
    NamespaceId("aimora"),
    v"1.0.0",
    DateTime(2026, 8, 9, 12, 0, 0),
    provenance,
)
project = CanonicalProject(metadata, primitive.registry, primitive.units, [record])
base = initial_revision(
    project,
    ContentDigest(repeat("1", 64)),
    ContentDigest(repeat("2", 64)),
    RevisionProvenance(
        ProjectId("action.create_demo"),
        DateTime(2026, 8, 9, 12, 1, 0),
        provenance,
    ),
)

transaction = begin_project_transaction(base)
apply!(
    transaction,
    ProjectCommand(
        ProjectId("command.rename_demo"),
        SetProjectNamePatch("Transactional Project Demo Revised"),
    ),
)
revision = commit!(
    transaction,
    base,
    ContentDigest(repeat("3", 64)),
    ContentDigest(repeat("4", 64)),
    RevisionProvenance(
        ProjectId("action.rename_demo"),
        DateTime(2026, 8, 9, 12, 2, 0),
        provenance,
    ),
)

println("committed revision ", revision.id.sha256, " with ", length(revision.changed_owners), " changed owner")
revision
