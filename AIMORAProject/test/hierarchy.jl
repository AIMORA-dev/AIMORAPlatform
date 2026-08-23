function hierarchy_fixture()
    fixture = canonical_project_fixture(two_records = true)
    provenance = fixture.provenance
    namespace = NamespaceId("aimora")
    semantic_type(name, version = v"1.0.0") = SemanticTypeId(namespace, ProjectId(name), version)
    asset_type = SemanticTypeId(
        fixture.schema.identity.namespace,
        fixture.schema.identity.name,
        fixture.schema.identity.version,
    )
    voltage = PhysicalValue(
        ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
        provenance,
    )
    record = DefinitionRecord(
        ObjectIdentity(ProjectId("component.branch")),
        fixture.schema.identity,
        [
            CanonicalField("id", "component.branch"),
            CanonicalField("mode", "PQ"),
            CanonicalField("nominal_voltage", voltage),
            CanonicalField("priority", 10),
        ],
        provenance,
    )
    asset = CanonicalAsset(
        record.identity,
        asset_type,
        AssetProperty[],
        StudyRealization[],
        provenance,
    )
    ac = electrical_ac_domain()
    carriers = [CarrierIdentity(ac, ProjectId("carrier.$phase")) for phase in ("A", "B", "C")]
    physical_port = SemanticPort(
        ObjectIdentity(ProjectId("port.electrical")),
        record.identity.id,
        ac,
        PortBidirectional,
        carriers,
        provenance,
    )
    signal_contract = SignalContract(
        lookup_unit(fixture.units, UnitId("V")).dimension,
        UnitId("V"),
        OrientationScalar,
    )
    signal_port = SemanticPort(
        ObjectIdentity(ProjectId("port.command")),
        record.identity.id,
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        provenance;
        signal_contract,
    )
    parameters = [
        DefinitionParameterSpec(SchemaField(
            "rating",
            SchemaQuantity;
            required = true,
            constraints = [QuantityConstraint(
                lookup_unit(fixture.units, UnitId("MVA")).dimension,
                [OrientationScalar],
            )],
        )),
        DefinitionParameterSpec(
            SchemaField(
                "mode",
                SchemaString;
                constraints = [AllowedStringConstraint(["PQ", "PV", "slack"])],
            );
            default = "PQ",
        ),
    ]
    external_ports = [
        DefinitionExternalPort(
            ProjectId("electrical"),
            physical_port.identity.id,
            physical_port.domain,
            physical_port.direction,
            collect(physical_port.carriers),
        ),
        DefinitionExternalPort(
            ProjectId("command"),
            signal_port.identity.id,
            signal_port.domain,
            signal_port.direction,
            CarrierIdentity[];
            signal_contract,
        ),
    ]
    parameter_bindings = [
        DefinitionParameterBinding(
            "rating",
            asset.identity.id,
            DefinitionAssetCommonProperty,
            FieldPath("nameplate.rating"),
        ),
        DefinitionParameterBinding(
            "mode",
            record.identity.id,
            DefinitionRecordField,
            FieldPath("mode"),
        ),
    ]
    documentation = ArtifactIdentity(
        ProjectId("artifact.definition_help"),
        "definitions/controlled_branch.md",
        repeat("1", 64),
        "text/markdown",
        provenance,
    )
    definition = ReusableDefinition(
        ObjectIdentity(ProjectId("definition.controlled_branch")),
        semantic_type("definition.controlled_branch"),
        parameters,
        external_ports,
        [record],
        [asset],
        SemanticGraphs(ports = [physical_port, signal_port]),
        parameter_bindings,
        DefinitionInstance[],
        provenance;
        property_metadata = [DefinitionPropertyMetadata("rating", "Nameplate", 99, true, provenance)],
        documentation,
        default_view = ProjectReference(ReferenceView, GlobalId("aimora://view/default/controlled_branch@1")),
        report_providers = [semantic_type("report.controlled_branch")],
    )
    definition_v2 = ReusableDefinition(
        definition.identity,
        semantic_type("definition.controlled_branch", v"2.0.0"),
        collect(definition.parameters),
        collect(definition.external_ports),
        collect(definition.records),
        collect(definition.assets),
        definition.internals,
        collect(definition.parameter_bindings),
        DefinitionInstance[],
        provenance;
        documentation,
        default_view = ProjectReference(ReferenceView, GlobalId("aimora://view/default/controlled_branch@2")),
        report_providers = collect(definition.report_providers),
    )
    node = GraphNode(ObjectIdentity(ProjectId("node.grid")), ac, carriers, provenance)
    command_source = SemanticPort(
        ObjectIdentity(ProjectId("signal.command_source")),
        ProjectId("bus.MV"),
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        provenance;
        signal_contract,
    )
    project_graphs = SemanticGraphs(nodes = [node], ports = [command_source])
    function instance(id, rating; version = v"1.0.0")
        return DefinitionInstance(
            ObjectIdentity(ProjectId(id)),
            ProjectReference(ReferenceDefinition, definition.identity.id),
            version,
            [InstanceParameterValue(
                "rating",
                PhysicalValue(
                    ScalarQuantity(parse_exact_decimal(rating), UnitId("MVA"), OrientationScalar),
                    provenance,
                ),
                provenance,
            )],
            [
                InstancePortBinding(
                    ProjectId("electrical"),
                    InstanceTargetNode,
                    node.identity.id;
                    carrier_mappings = [CarrierMapping(carrier, carrier) for carrier in carriers],
                ),
                InstancePortBinding(ProjectId("command"), InstanceTargetPort, command_source.identity.id),
            ],
            provenance,
        )
    end
    first_instance = instance("subsystem.feed_one", "100.0")
    second_instance = instance("subsystem.feed_two", "125.0")
    migration = DefinitionMigration(
        definition.identity.id,
        v"1.0.0",
        v"2.0.0",
        semantic_type("migration.controlled_branch_v1_to_v2"),
        ContentDigest(repeat("2", 64)),
        provenance,
    )
    hierarchy = HierarchyModel(
        definitions = [definition, definition_v2],
        instances = [first_instance, second_instance],
        migrations = [migration],
    )
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        project_graphs,
        AssetLibrary(),
        hierarchy,
    )
    revision = initial_revision(
        project,
        ContentDigest(repeat("3", 64)),
        ContentDigest(repeat("4", 64)),
        transaction_provenance(fixture, "action.hierarchy_import", 20),
    )
    return (;
        fixture...,
        project,
        revision,
        definition,
        definition_v2,
        first_instance,
        second_instance,
        migration,
        node,
        command_source,
        carriers,
        signal_contract,
        semantic_type,
        instance,
    )
end

@testset "public reusable subsystem example" begin
    example_module = Module(:ReusableSubsystemExample, true, true)
    example = Base.include(example_module, joinpath(@__DIR__, "..", "examples", "reusable_subsystem.jl"))
    @test example.project.verification == ProjectVerified
    @test length(example.project.hierarchy.instances) == 2
    @test length(example.first.records) == 1
    @test example.first != example.second
end

@testset "definitions and instances expand independently with typed bindings" begin
    fixture = hierarchy_fixture()
    @test validate_hierarchy(fixture.project)
    @test reusable_definition(fixture.project.hierarchy, fixture.definition.identity.id, v"1.0.0") == fixture.definition
    @test definition_instance(fixture.project.hierarchy, fixture.first_instance.identity.id) == fixture.first_instance
    @test definition_migration(
        fixture.project.hierarchy,
        fixture.definition.identity.id,
        v"1.0.0",
        v"2.0.0",
    ) == fixture.migration
    first = expand_instance(fixture.project, fixture.first_instance)
    second = expand_instance(fixture.project, fixture.second_instance)
    @test first == expand_instance(fixture.project, fixture.first_instance.identity.id)
    @test first != second
    @test first.records[1].identity.id == ProjectId("subsystem.feed_one.component.branch")
    @test first.assets[1].identity.id == first.records[1].identity.id
    @test first.records[1].fields[2].value == "PQ"
    @test first.assets[1].common[1].value.quantity.value == parse_exact_decimal("100.0")
    @test second.assets[1].common[1].value.quantity.value == parse_exact_decimal("125.0")
    @test first.assets[1].common[1] !== second.assets[1].common[1]
    @test all(identity -> identity.instance == fixture.first_instance.identity.id, first.identities)
    @test length(first.graphs.physical_connections) == 1
    @test length(first.graphs.signal_connections) == 1
    view_variant = DefinitionInstance(
        fixture.first_instance.identity,
        fixture.first_instance.definition,
        v"2.0.0",
        collect(fixture.first_instance.parameters),
        collect(fixture.first_instance.port_bindings),
        fixture.provenance,
    )
    view_expansion = expand_instance(fixture.project, view_variant)
    @test view_expansion.records == first.records
    @test view_expansion.assets == first.assets
    @test view_expansion.graphs == first.graphs
end

@testset "hierarchy rejects missing mismatched and aliased declarations" begin
    fixture = hierarchy_fixture()
    incompatible_binding = ReusableDefinition(
        fixture.definition.identity,
        fixture.definition.definition_type,
        collect(fixture.definition.parameters),
        collect(fixture.definition.external_ports),
        collect(fixture.definition.records),
        collect(fixture.definition.assets),
        fixture.definition.internals,
        [DefinitionParameterBinding(
            "rating",
            ProjectId("component.branch"),
            DefinitionRecordField,
            FieldPath("mode"),
        )],
        DefinitionInstance[],
        fixture.provenance,
    )
    incompatible_project = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = [incompatible_binding]),
    )
    @test semantic_error_code(() -> validate_project(incompatible_project)) == :parameter_binding_type_mismatch
    @test semantic_error_code(() -> InstancePortBinding(
        ProjectId("electrical"),
        InstanceTargetNode,
        fixture.node.identity.id;
        carrier_mappings = [
            CarrierMapping(fixture.carriers[1], fixture.carriers[1]),
            CarrierMapping(fixture.carriers[1], fixture.carriers[2]),
        ],
    )) == :duplicate_instance_port_carrier
    missing_parameter = DefinitionInstance(
        ObjectIdentity(ProjectId("subsystem.missing_parameter")),
        fixture.first_instance.definition,
        fixture.first_instance.definition_version,
        InstanceParameterValue[],
        collect(fixture.first_instance.port_bindings),
        fixture.provenance,
    )
    invalid = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = collect(fixture.project.hierarchy.definitions), instances = [missing_parameter]),
    )
    @test semantic_error_code(() -> validate_project(invalid)) == :missing_instance_parameter

    bad_unit = fixture.instance("subsystem.bad_unit", "100.0")
    bad_unit = DefinitionInstance(
        bad_unit.identity,
        bad_unit.definition,
        bad_unit.definition_version,
        [InstanceParameterValue(
            "rating",
            PhysicalValue(
                ScalarQuantity(parse_exact_decimal("10.0"), UnitId("s"), OrientationScalar),
                fixture.provenance,
            ),
            fixture.provenance,
        )],
        collect(bad_unit.port_bindings),
        fixture.provenance,
    )
    invalid_unit = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = collect(fixture.project.hierarchy.definitions), instances = [bad_unit]),
    )
    @test semantic_error_code(() -> validate_project(invalid_unit)) == :dimension_mismatch

    incomplete = DefinitionInstance(
        ObjectIdentity(ProjectId("subsystem.incomplete_ports")),
        fixture.first_instance.definition,
        fixture.first_instance.definition_version,
        collect(fixture.first_instance.parameters),
        [fixture.first_instance.port_bindings[1]],
        fixture.provenance,
    )
    incomplete_project = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = collect(fixture.project.hierarchy.definitions), instances = [incomplete]),
    )
    @test semantic_error_code(() -> validate_project(incomplete_project)) == :missing_instance_port_binding

    wrong_direction = InstancePortBinding(
        ProjectId("command"),
        InstanceTargetPort,
        ProjectId("signal.wrong_direction"),
    )
    target_input = SemanticPort(
        ObjectIdentity(wrong_direction.target),
        ProjectId("bus.MV"),
        signal_domain(),
        PortInput,
        CarrierIdentity[],
        fixture.provenance;
        signal_contract = fixture.signal_contract,
    )
    wrong_instance = DefinitionInstance(
        ObjectIdentity(ProjectId("subsystem.wrong_direction")),
        fixture.first_instance.definition,
        fixture.first_instance.definition_version,
        collect(fixture.first_instance.parameters),
        [
            only(binding for binding in fixture.first_instance.port_bindings if binding.external_port == ProjectId("electrical")),
            wrong_direction,
        ],
        fixture.provenance,
    )
    wrong_project = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        SemanticGraphs(nodes = [fixture.node], ports = [target_input]),
        AssetLibrary(),
        HierarchyModel(definitions = collect(fixture.project.hierarchy.definitions), instances = [wrong_instance]),
    )
    @test semantic_error_code(() -> validate_project(wrong_project)) == :instance_signal_direction_mismatch

    collision = fixture.instance("bus.HV", "100.0")
    collision_project = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = collect(fixture.project.hierarchy.definitions), instances = [collision]),
    )
    @test semantic_error_code(() -> validate_project(collision_project)) == :instance_identity_collision
end

@testset "nested definitions reject recursion and expand with hierarchy identities" begin
    fixture = hierarchy_fixture()
    child = fixture.definition
    host_record = DefinitionRecord(
        ObjectIdentity(ProjectId("host.owner")),
        fixture.schema.identity,
        [
            CanonicalField("id", "host.owner"),
            CanonicalField("mode", "PQ"),
            CanonicalField(
                "nominal_voltage",
                PhysicalValue(
                    ScalarQuantity(parse_exact_decimal("132.0"), UnitId("kV"), OrientationPhaseToPhaseRms),
                    fixture.provenance,
                ),
            ),
            CanonicalField("priority", 1),
        ],
        fixture.provenance,
    )
    node = GraphNode(ObjectIdentity(ProjectId("node.internal")), electrical_ac_domain(), fixture.carriers, fixture.provenance)
    source = SemanticPort(
        ObjectIdentity(ProjectId("signal.internal_source")),
        host_record.identity.id,
        signal_domain(),
        PortOutput,
        CarrierIdentity[],
        fixture.provenance;
        signal_contract = fixture.signal_contract,
    )
    nested = DefinitionInstance(
        ObjectIdentity(ProjectId("nested.branch")),
        ProjectReference(ReferenceDefinition, child.identity.id),
        v"1.0.0",
        collect(fixture.first_instance.parameters),
        [
            InstancePortBinding(
                ProjectId("electrical"),
                InstanceTargetNode,
                node.identity.id;
                carrier_mappings = [CarrierMapping(carrier, carrier) for carrier in fixture.carriers],
            ),
            InstancePortBinding(ProjectId("command"), InstanceTargetPort, source.identity.id),
        ],
        fixture.provenance,
    )
    wrapper = ReusableDefinition(
        ObjectIdentity(ProjectId("definition.wrapper")),
        fixture.semantic_type("definition.wrapper"),
        DefinitionParameterSpec[],
        DefinitionExternalPort[],
        [host_record],
        CanonicalAsset[],
        SemanticGraphs(nodes = [node], ports = [source]),
        DefinitionParameterBinding[],
        [nested],
        fixture.provenance,
    )
    wrapper_instance = DefinitionInstance(
        ObjectIdentity(ProjectId("subsystem.wrapper")),
        ProjectReference(ReferenceDefinition, wrapper.identity.id),
        v"1.0.0",
        InstanceParameterValue[],
        InstancePortBinding[],
        fixture.provenance,
    )
    project = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = [child, fixture.definition_v2, wrapper], instances = [wrapper_instance]),
    )
    expanded = expand_instance(project, wrapper_instance)
    @test ProjectId("subsystem.wrapper.nested.branch.component.branch") in
        [record.identity.id for record in expanded.records]
    @test any(identity -> identity.instance == ProjectId("subsystem.wrapper.nested.branch"), expanded.identities)

    empty_graphs = SemanticGraphs()
    definition_a_ref = ProjectReference(ReferenceDefinition, ProjectId("definition.a"))
    definition_b_ref = ProjectReference(ReferenceDefinition, ProjectId("definition.b"))
    nested_b = DefinitionInstance(ObjectIdentity(ProjectId("nested.b")), definition_b_ref, v"1.0.0", InstanceParameterValue[], InstancePortBinding[], fixture.provenance)
    nested_a = DefinitionInstance(ObjectIdentity(ProjectId("nested.a")), definition_a_ref, v"1.0.0", InstanceParameterValue[], InstancePortBinding[], fixture.provenance)
    definition_a = ReusableDefinition(ObjectIdentity(ProjectId("definition.a")), fixture.semantic_type("definition.a"), DefinitionParameterSpec[], DefinitionExternalPort[], DefinitionRecord[], CanonicalAsset[], empty_graphs, DefinitionParameterBinding[], [nested_b], fixture.provenance)
    definition_b = ReusableDefinition(ObjectIdentity(ProjectId("definition.b")), fixture.semantic_type("definition.b"), DefinitionParameterSpec[], DefinitionExternalPort[], DefinitionRecord[], CanonicalAsset[], empty_graphs, DefinitionParameterBinding[], [nested_a], fixture.provenance)
    recursive = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        collect(fixture.project.records),
        fixture.project.graphs,
        AssetLibrary(),
        HierarchyModel(definitions = [definition_a, definition_b]),
    )
    @test semantic_error_code(() -> validate_project(recursive)) == :recursive_definition_cycle
end

@testset "hierarchy commands are deterministic invertible and dependency safe" begin
    fixture = hierarchy_fixture()
    updated_value = InstanceParameterValue(
        "rating",
        PhysicalValue(
            ScalarQuantity(parse_exact_decimal("150.0"), UnitId("MVA"), OrientationScalar),
            fixture.provenance,
        ),
        fixture.provenance,
    )
    third = fixture.instance("subsystem.feed_three", "90.0")
    commands = [
        ProjectCommand(
            ProjectId("command.set_instance_rating"),
            SetInstanceParameterPatch(fixture.first_instance.identity.id, updated_value),
        ),
        ProjectCommand(
            ProjectId("command.add_instance"),
            AddDefinitionInstancePatch(third),
        ),
    ]
    transaction = begin_project_transaction(fixture.revision)
    foreach(command -> apply!(transaction, command), commands)
    committed = commit!(
        transaction,
        fixture.revision,
        ContentDigest(repeat("5", 64)),
        ContentDigest(repeat("6", 64)),
        transaction_provenance(fixture, "action.hierarchy_update", 21),
    )
    @test length(committed.project.hierarchy.instances) == 3
    @test expand_instance(committed.project, fixture.first_instance.identity.id).assets[1].common[1].value.quantity.value == parse_exact_decimal("150.0")
    @test replay_commands(fixture.project, commands) == committed.project
    @test replay_commands(committed.project, inverse_commands(fixture.project, commands)) == fixture.project
    @test collect(committed.invalidations[1].scopes) == [InvalidateStudyResults, InvalidateWorkflowResults, InvalidateViews]

    rolled_back = begin_project_transaction(fixture.revision)
    apply!(rolled_back, commands[1])
    @test rollback!(rolled_back) == fixture.revision
    @test rolled_back.working == fixture.project
    @test rolled_back.state == TransactionRolledBack

    blocked = begin_project_transaction(fixture.revision)
    @test semantic_error_code(() -> apply!(
        blocked,
        ProjectCommand(
            ProjectId("command.remove_definition"),
            RemoveReusableDefinitionPatch(fixture.definition.identity.id, v"1.0.0"),
        ),
    )) == :definition_has_dependents

    isolated_definition = ReusableDefinition(
        ObjectIdentity(ProjectId("definition.isolated")),
        fixture.semantic_type("definition.isolated"),
        DefinitionParameterSpec[],
        DefinitionExternalPort[],
        DefinitionRecord[],
        CanonicalAsset[],
        SemanticGraphs(),
        DefinitionParameterBinding[],
        DefinitionInstance[],
        fixture.provenance,
    )
    add_remove = [
        ProjectCommand(ProjectId("command.add_definition"), AddReusableDefinitionPatch(isolated_definition)),
        ProjectCommand(ProjectId("command.remove_definition"), RemoveReusableDefinitionPatch(isolated_definition.identity.id, v"1.0.0")),
    ]
    @test replay_commands(fixture.project, add_remove) == fixture.project
end

@testset "hierarchy canonical types contain no runtime state or generic dictionaries" begin
    canonical_types = [
        DefinitionParameterSpec,
        DefinitionParameterBinding,
        DefinitionRecord,
        DefinitionExternalPort,
        InstanceParameterValue,
        InstancePortBinding,
        DefinitionInstance,
        DefinitionPropertyMetadata,
        ReusableDefinition,
        DefinitionMigration,
        HierarchyModel,
        ExpansionIdentity,
        InstanceExpansion,
    ]
    @test all(!ismutabletype(type) for type in canonical_types)
    @test all(type -> all(field -> field !== Any && field !== Function && !(field <: AbstractDict), fieldtypes(type)), canonical_types)
end

record_project_conformance!(:definitions_instances)
