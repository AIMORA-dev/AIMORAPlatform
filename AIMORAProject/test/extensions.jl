function extension_state_fixture()
    reason(family) = ProjectId("not_applicable.$(String(family))")
    return [
        ExtensionStateDeclaration(:continuous, [ProjectId("control.state")]),
        ExtensionStateDeclaration(:algebraic; not_applicable_reason = reason(:algebraic)),
        ExtensionStateDeclaration(:discrete, [ProjectId("control.saturation_mode")]),
        ExtensionStateDeclaration(:delayed; not_applicable_reason = reason(:delayed)),
        ExtensionStateDeclaration(:scheduler, [ProjectId("control.next_tick")]),
        ExtensionStateDeclaration(:random; not_applicable_reason = reason(:random)),
        ExtensionStateDeclaration(:history, [ProjectId("control.held_input")]),
        ExtensionStateDeclaration(:output, [ProjectId("control.output")]),
        ExtensionStateDeclaration(:checkpoint, [ProjectId("control.checkpoint")]),
    ]
end

function extension_declaration_fixture()
    provenance = canonical_test_provenance()
    semantic_type = SemanticTypeId(
        NamespaceId("example.extensions"),
        ProjectId("sampled_saturating_lag"),
        v"1.0.0",
    )
    implementation = RegisteredFunctionIdentity(
        UUID("4cf129db-b3fb-41c2-8667-cf22679bd5ba"),
        semantic_type,
        ProjectId("SampledSaturatingLag"),
        ContentDigest(repeat("a", 64)),
    )
    return ExtensionDeclaration(
        ObjectIdentity(ProjectId("control.user_lag")),
        implementation,
        v"1.0.0",
        InstantaneousEMT,
        SwitchingDetailed,
        [ProjectReference(ReferenceControlBlock, ProjectId("control.input"))],
        [AssetProperty(FieldPath("control.gain"), parse_exact_decimal("2.0"), provenance)],
        extension_state_fixture(),
        [
            ExtensionInitializationService,
            ExtensionSampledTaskService,
            ExtensionOutputService,
            ExtensionCheckpointService,
        ],
        provenance,
    )
end

@testset "inert user extension declarations" begin
    declaration = extension_declaration_fixture()
    @test declaration == extension_declaration_fixture()
    @test declaration.api_version == v"1.0.0"
    @test getfield.(declaration.state, :family) == [
        :continuous,
        :algebraic,
        :discrete,
        :delayed,
        :scheduler,
        :random,
        :history,
        :output,
        :checkpoint,
    ]
    @test extension_declaration_hash(declaration) ==
        extension_declaration_hash(extension_declaration_fixture())

    incomplete_state = extension_state_fixture()[1:end-1]
    @test semantic_error_code() do
        ExtensionDeclaration(
            declaration.identity,
            declaration.implementation,
            declaration.api_version,
            declaration.representation,
            declaration.fidelity,
            collect(declaration.terminals),
            collect(declaration.parameters),
            incomplete_state,
            collect(declaration.services),
            declaration.provenance,
        )
    end == :incomplete_extension_state_inventory

    executable_parameter = AssetProperty(
        FieldPath("runtime.source"),
        "eval(read(\"component.jl\", String))",
        declaration.provenance,
    )
    @test semantic_error_code() do
        ExtensionDeclaration(
            declaration.identity,
            declaration.implementation,
            declaration.api_version,
            declaration.representation,
            declaration.fidelity,
            collect(declaration.terminals),
            [executable_parameter],
            collect(declaration.state),
            collect(declaration.services),
            declaration.provenance,
        )
    end == :executable_extension_parameter

    @test semantic_error_code() do
        ExtensionDeclaration(
            declaration.identity,
            declaration.implementation,
            declaration.api_version,
            declaration.representation,
            declaration.fidelity,
            collect(declaration.terminals),
            collect(declaration.parameters),
            collect(declaration.state),
            [ExtensionSampledTaskService, ExtensionCheckpointService],
            declaration.provenance,
        )
    end == :missing_extension_initialization

    newer = RegisteredFunctionIdentity(
        declaration.implementation.package_uuid,
        SemanticTypeId(
            declaration.implementation.package.namespace,
            declaration.implementation.package.name,
            v"1.1.0",
        ),
        declaration.implementation.symbol,
        ContentDigest(repeat("b", 64)),
    )
    migration = RegisteredFunctionIdentity(
        declaration.implementation.package_uuid,
        SemanticTypeId(
            NamespaceId("example.extensions"),
            ProjectId("migration.sampled_lag"),
            v"1.0.0",
        ),
        ProjectId("migrate_sampled_lag"),
        ContentDigest(repeat("c", 64)),
    )
    @test ExtensionMigrationDeclaration(declaration.implementation, newer, migration).to == newer
end
