using AIMORAProject
using Dates

primitive = Base.include(@__MODULE__, joinpath(@__DIR__, "canonical_primitives.jl"))
provenance = primitive.voltage.provenance
record = CanonicalRecord(
    ObjectIdentity(ProjectId("bus.demo")),
    primitive.schema.identity,
    [
        CanonicalField("id", "bus.demo"),
        CanonicalField("nominal_voltage", primitive.voltage),
    ],
    provenance,
)
metadata = ProjectMetadata(
    ObjectIdentity(ProjectId("project.event_scenario_demo")),
    "Event and Scenario Demo",
    NamespaceId("aimora"),
    v"1.0.0",
    DateTime(2026, 8, 9, 12, 0, 0),
    provenance,
)
event_time = PhysicalValue(
    ScalarQuantity(parse_exact_decimal("0.1"), UnitId("s"), OrientationScalar),
    provenance,
)
fault = EventDeclaration(
    ObjectIdentity(ProjectId("event.bus_fault")),
    SemanticTypeId(NamespaceId("aimora"), ProjectId("event.electrical_fault"), v"1.0.0"),
    RelativeEventTrigger(event_time),
    100,
    ProjectReference(ReferenceAsset, record.identity.id),
    [CanonicalField("kind", "three_phase_ground")],
    EventResetDeclaration[],
    EventRollbackRestoreAccepted,
    provenance,
)
peak_voltage = PhysicalValue(
    ScalarQuantity(parse_exact_decimal("138.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
    provenance,
)
peak = ScenarioDefinition(
    ObjectIdentity(ProjectId("scenario.peak")),
    nothing,
    [ScenarioPatchDeclaration(
        ObjectIdentity(ProjectId("patch.peak_voltage")),
        ScenarioSet,
        SetRecordFieldPatch(record.identity.id, CanonicalField("nominal_voltage", peak_voltage)),
        10,
        provenance,
    )],
    provenance,
)
project = CanonicalProject(
    metadata,
    primitive.registry,
    primitive.units,
    [record],
    SemanticGraphs(),
    AssetLibrary(),
    HierarchyModel(),
    ControlSystem(),
    EventScenarioModel(events = [fault], scenarios = [peak]),
)
resolved = resolve_scenario(project, peak.identity.id)
println("resolved scenario ", peak.identity.id.value, " at ", resolved.content_hash.sha256)
(; project, fault, peak, resolved)
