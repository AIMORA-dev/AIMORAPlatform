using AIMORAProject
using Dates
using UUIDs

function build_control_network_example()
    licence = LicenceIdentity(
        "CC0-1.0",
        "CC0 1.0 Universal";
        uri = GlobalId("https://creativecommons.org/publicdomain/zero/1.0/"),
    )
    provenance = ProvenanceSource(
        ProjectId("source.control_example"),
        "AIMORA synthetic sampled-control declaration example",
        licence;
        source_version = "1.0.0",
    )
    namespace = NamespaceId("aimora")
    registry = register_namespace(
        SemanticSchemaRegistry(),
        NamespaceRegistration(
            namespace,
            UUID("c2b122f9-f2bf-4636-916f-8933df29f26d"),
            licence,
            provenance,
        ),
    )
    units = si_unit_registry()
    contract = SignalContract(
        lookup_unit(units, UnitId("V")).dimension,
        UnitId("V"),
        OrientationScalar,
    )
    block_schema = ControlBlockSchema(
        SemanticSchemaIdentity(
            UUID("80da435d-dc19-49fd-9c3b-70484a4134e7"),
            namespace,
            ProjectId("control.zero_order_hold"),
            v"1.0.0",
        ),
        [ControlSampled],
        SchemaField[],
        [
            ControlPortSpec("input", PortInput, contract),
            ControlPortSpec("output", PortOutput, contract),
        ],
        [ControlStateSpec(
            SchemaField(
                "held_value",
                SchemaQuantity;
                required = true,
                constraints = [QuantityConstraint(
                    lookup_unit(units, UnitId("V")).dimension,
                    [OrientationScalar],
                )],
            ),
            HoldControlState,
        )],
        false,
        provenance,
    )

    network_id = ProjectId("control.sample_hold")
    block_id = ProjectId("control.sample_hold.hold")
    external_input = SemanticPort(
        ObjectIdentity(ProjectId("control.sample_hold.external_input")),
        network_id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    external_output = SemanticPort(
        ObjectIdentity(ProjectId("control.sample_hold.external_output")),
        network_id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    block_input = SemanticPort(
        ObjectIdentity(ProjectId("control.sample_hold.hold.input")),
        block_id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    block_output = SemanticPort(
        ObjectIdentity(ProjectId("control.sample_hold.hold.output")),
        block_id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract = contract,
    )
    held_value = ControlStateDeclaration(
        ObjectIdentity(ProjectId("control.sample_hold.hold.held_value")),
        "held_value",
        HoldControlState,
        PhysicalValue(
            ScalarQuantity(parse_exact_decimal("0.0"), UnitId("V"), OrientationScalar),
            provenance,
        ),
        ResetToInitial,
        RollbackRestoreAccepted,
        CheckpointRequired,
        provenance,
    )
    block = ControlBlock(
        ObjectIdentity(block_id),
        block_schema.identity,
        CanonicalField[],
        [
            ControlPortBinding("input", block_input.identity.id),
            ControlPortBinding("output", block_output.identity.id),
        ],
        [held_value],
        provenance,
    )
    links = [
        SignalConnection(
            ObjectIdentity(ProjectId("control.sample_hold.link.input")),
            external_input.identity.id,
            block_input.identity.id,
            false,
            provenance,
        ),
        SignalConnection(
            ObjectIdentity(ProjectId("control.sample_hold.link.output")),
            block_output.identity.id,
            external_output.identity.id,
            false,
            provenance,
        ),
    ]
    time(value) = PhysicalValue(
        ScalarQuantity(parse_exact_decimal(value), UnitId("s"), OrientationScalar),
        provenance,
    )
    schedule = ControlSchedule(
        ControlSampled,
        ReadComputeEnqueueReleaseWriteHold,
        [block_id];
        sample_time = time("0.0001"),
        phase_offset = time("0.0"),
        computational_delay = time("0.00002"),
    )
    network = ControlNetwork(
        ObjectIdentity(network_id),
        schedule,
        [
            ControlExternalPort("input", external_input.identity.id, PortInput),
            ControlExternalPort("output", external_output.identity.id, PortOutput),
        ],
        [block],
        ProjectId[link.identity.id for link in links],
        [held_value.identity.id],
        ControlBoundaryBinding[],
        AlgebraicLoopDeclaration[],
        provenance,
    )
    metadata = ProjectMetadata(
        ObjectIdentity(ProjectId("project.control_example")),
        "Sampled Control Declaration",
        namespace,
        v"1.0.0",
        DateTime(2026, 8, 9, 12, 0, 0),
        provenance,
    )
    project = CanonicalProject(
        metadata,
        registry,
        units,
        CanonicalRecord[],
        SemanticGraphs(
            ports = [external_input, external_output, block_input, block_output],
            signal_connections = links,
        ),
        AssetLibrary(),
        HierarchyModel(),
        ControlSystem(block_schemas = [block_schema], networks = [network]),
    )
    println("validated sampled network ", network.identity.id.value, " with explicit held state")
    return project
end

build_control_network_example()
