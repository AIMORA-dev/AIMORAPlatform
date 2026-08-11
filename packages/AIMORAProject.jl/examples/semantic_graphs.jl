using AIMORAProject
using Dates

base = Base.include(@__MODULE__, joinpath(@__DIR__, "transactional_project.jl"))
provenance = base.provenance.source
domain = electrical_ac_domain()
carrier = CarrierIdentity(domain, ProjectId("carrier.A"))
nominal = project_record(base.project, ProjectId("bus.demo")).fields[2].value
node = GraphNode(
    ObjectIdentity(ProjectId("node.demo")),
    domain,
    [carrier],
    provenance;
    nominal_level = nominal,
)
port = SemanticPort(
    ObjectIdentity(ProjectId("port.demo")),
    ProjectId("bus.demo"),
    domain,
    PortBidirectional,
    [carrier],
    provenance;
    nominal_level = nominal,
)
connection = PhysicalConnection(
    ObjectIdentity(ProjectId("connection.demo")),
    port.identity.id,
    node.identity.id,
    [CarrierMapping(carrier, carrier)],
    provenance,
)

transaction = begin_project_transaction(base)
apply!(transaction, ProjectCommand(ProjectId("command.add_demo_node"), AddGraphElementPatch(node)))
apply!(transaction, ProjectCommand(ProjectId("command.add_demo_port"), AddGraphElementPatch(port)))
apply!(transaction, ProjectCommand(ProjectId("command.connect_demo"), ConnectGraphPatch(connection)))
revision = commit!(
    transaction,
    base,
    ContentDigest(repeat("5", 64)),
    ContentDigest(repeat("6", 64)),
    RevisionProvenance(
        ProjectId("action.build_demo_graph"),
        DateTime(2026, 8, 9, 12, 3, 0),
        provenance,
    ),
)

println("validated ", length(revision.project.graphs.physical_connections), " typed physical connection")
revision
