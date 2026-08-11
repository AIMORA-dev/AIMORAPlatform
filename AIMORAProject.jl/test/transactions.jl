using Dates

function canonical_project_fixture(; two_records = false)
    units, provenance, _, schema, registry = canonical_schema_fixture()
    metadata = ProjectMetadata(
        ObjectIdentity(
            ProjectId("project.canonical_test"),
            uid = GlobalId("urn:uuid:1dce038d-2a55-4a17-b625-39af49f63f3d"),
        ),
        "Canonical Transaction Test",
        NamespaceId("aimora"),
        v"1.0.0",
        DateTime(2026, 8, 9, 12, 0, 0),
        provenance,
    )
    function bus_record(id, mode, voltage)
        return CanonicalRecord(
            ObjectIdentity(ProjectId(id)),
            schema.identity,
            [
                CanonicalField("id", id),
                CanonicalField("mode", mode),
                CanonicalField(
                    "nominal_voltage",
                    PhysicalValue(
                        ScalarQuantity(
                            parse_exact_decimal(voltage),
                            UnitId("kV"),
                            OrientationPhaseToPhaseRms,
                        ),
                        provenance,
                    ),
                ),
                CanonicalField("priority", 10),
            ],
            provenance,
        )
    end
    records = CanonicalRecord[bus_record("bus.HV", "slack", "132.0")]
    two_records && push!(records, bus_record("bus.MV", "PQ", "11.0"))
    project = CanonicalProject(metadata, registry, units, reverse(records))
    revision_provenance = RevisionProvenance(
        ProjectId("action.initial_import"),
        DateTime(2026, 8, 9, 12, 1, 0),
        provenance;
        actor = GlobalId("urn:uuid:c87ba2d1-c4da-498b-8c98-b08443157387"),
    )
    revision = initial_revision(
        project,
        ContentDigest(repeat("1", 64)),
        ContentDigest(repeat("2", 64)),
        revision_provenance,
    )
    return (; units, provenance, schema, registry, metadata, project, revision)
end

function transaction_provenance(fixture, action, second)
    return RevisionProvenance(
        ProjectId(action),
        DateTime(2026, 8, 9, 12, 2, second),
        fixture.provenance;
        actor = GlobalId("urn:uuid:c87ba2d1-c4da-498b-8c98-b08443157387"),
    )
end

@testset "public transactional project example" begin
    example_module = Module(:TransactionalProjectExample, true, true)
    example_revision = Base.include(
        example_module,
        joinpath(@__DIR__, "..", "examples", "transactional_project.jl"),
    )
    @test example_revision.project.verification == ProjectVerified
    @test example_revision.parent !== nothing
    @test length(example_revision.commands) == 1
    @test can_reuse_results(example_revision)
end

@testset "immutable canonical projects and explicit verification" begin
    fixture = canonical_project_fixture(two_records = true)
    @test fixture.project.verification == ProjectVerified
    @test validate_project(fixture.project)
    @test can_reuse_results(fixture.revision)
    @test [record.identity.id.value for record in fixture.project.records] == ["bus.HV", "bus.MV"]
    @test project_record(fixture.project, ProjectId("bus.HV")).identity.id == ProjectId("bus.HV")
    @test semantic_error_code(() -> project_record(fixture.project, ProjectId("bus.unknown"))) == :unknown_record_id
    @test semantic_error_code(() -> ContentDigest(repeat("A", 64))) == :invalid_content_digest
    @test semantic_error_code(() -> CanonicalField("mode", "bad\0value")) == :invalid_canonical_string
    @test semantic_error_code(() -> ProvenanceSource(
        ProjectId("source.bad_version"),
        "Bad version source",
        canonical_test_licence();
        source_version = "1.0\0bad",
    )) == :invalid_source_version
    @test semantic_error_code(() -> ProjectRevision(
        ContentDigest(repeat("f", 64)),
        fixture.revision.parent,
        fixture.revision.source_hash,
        fixture.revision.resolved_hash,
        fixture.revision.project,
        fixture.revision.commands,
        fixture.revision.provenance,
        fixture.revision.changed_owners,
        fixture.revision.invalidations,
    )) == :invalid_revision_digest
    @test semantic_error_code(() -> ProjectRevision(
        fixture.revision.id,
        fixture.revision.parent,
        fixture.revision.source_hash,
        fixture.revision.resolved_hash,
        fixture.revision.project,
        fixture.revision.commands,
        fixture.revision.provenance,
        CanonicalList{ProjectId}([ProjectId("bus.HV")]),
        fixture.revision.invalidations,
    )) == :invalid_changed_owners
    mismatched_identity = CanonicalRecord(
        ObjectIdentity(ProjectId("bus.identity")),
        fixture.schema.identity,
        [
            CanonicalField("id", "bus.different"),
            CanonicalField("mode", "PQ"),
            CanonicalField("nominal_voltage", project_record(fixture.project, ProjectId("bus.HV")).fields[3].value),
        ],
        fixture.provenance,
    )
    @test semantic_error_code(() -> validate_project(unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        [mismatched_identity],
    ))) == :record_identity_mismatch

    invalid_record = CanonicalRecord(
        ObjectIdentity(ProjectId("bus.invalid")),
        fixture.schema.identity,
        [CanonicalField("id", "bus.invalid"), CanonicalField("mode", "unknown")],
        fixture.provenance,
    )
    unverified = unsafe_project(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        [invalid_record],
    )
    @test unverified.verification == ProjectUnverified
    @test semantic_error_code(() -> validate_project(unverified)) == :value_not_allowed
    unverified_revision = initial_revision(
        unverified,
        ContentDigest(repeat("3", 64)),
        ContentDigest(repeat("4", 64)),
        transaction_provenance(fixture, "action.unsafe_import", 0),
    )
    @test !can_reuse_results(unverified_revision)
end

@testset "deterministic commands transactions replay undo and snapshots" begin
    fixture = canonical_project_fixture(two_records = true)
    commands = [
        ProjectCommand(
            ProjectId("command.set_mode"),
            SetRecordFieldPatch(ProjectId("bus.MV"), CanonicalField("mode", "PV")),
        ),
        ProjectCommand(
            ProjectId("command.rename_project"),
            SetProjectNamePatch("Canonical Transaction Test Revised"),
        ),
    ]
    provenance = transaction_provenance(fixture, "action.engineering_edit", 1)
    source_hash = ContentDigest(repeat("5", 64))
    resolved_hash = ContentDigest(repeat("6", 64))

    transaction = begin_project_transaction(fixture.revision)
    original = fixture.revision
    apply!(transaction, commands[1])
    @test transaction.working.verification == ProjectUnverified
    @test fixture.revision === original
    @test project_record(fixture.project, ProjectId("bus.MV")).fields[2].value != "PV"
    apply!(transaction, commands[2])
    validate!(transaction)
    @test transaction.state == TransactionValidated
    committed = commit!(transaction, fixture.revision, source_hash, resolved_hash, provenance)
    @test transaction.state == TransactionCommitted
    @test committed.parent == fixture.revision.id
    @test committed.source_hash == source_hash
    @test committed.resolved_hash == resolved_hash
    @test committed.project.verification == ProjectVerified
    @test can_reuse_results(committed)
    @test collect(committed.changed_owners) == [ProjectId("bus.MV"), ProjectId("project.canonical_test")]
    @test length(committed.invalidations) == 2
    @test collect(committed.commands) == commands

    repeated = begin_project_transaction(fixture.revision)
    foreach(command -> apply!(repeated, command), commands)
    repeated_revision = commit!(repeated, fixture.revision, source_hash, resolved_hash, provenance)
    @test repeated_revision == committed
    @test repeated_revision.id == committed.id
    @test replay_commands(fixture.project, committed.commands) == committed.project
    @test deepcopy(commands) == commands

    replayed = replay_commands(fixture.project, commands)
    @test replayed == committed.project
    inverses = inverse_commands(fixture.project, commands)
    restored = replay_commands(replayed, collect(inverses))
    @test restored == fixture.project
    @test [command.id.value for command in inverses] == ["undo.command.rename_project", "undo.command.set_mode"]

    before_snapshot = project_snapshot(fixture.revision)
    after_snapshot = project_snapshot(committed)
    @test before_snapshot.revision_id == fixture.revision.id
    @test query_record(before_snapshot, ProjectId("bus.MV")).fields[2].value != "PV"
    @test query_record(after_snapshot, ProjectId("bus.MV")).fields[2].value == "PV"
    @test length(query_records(after_snapshot)) == 2
    @test length(query_records(after_snapshot, fixture.schema.identity)) == 2
end

@testset "transaction failures conflicts and rollback preserve accepted revisions" begin
    fixture = canonical_project_fixture(two_records = true)
    base_copy = deepcopy(fixture.revision)

    invalid = begin_project_transaction(fixture.revision)
    invalid_command = ProjectCommand(
        ProjectId("command.invalid_priority"),
        SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 101)),
    )
    working_before = invalid.working
    @test semantic_error_code(() -> apply!(invalid, invalid_command)) == :value_above_schema_bound
    @test invalid.working === working_before
    @test isempty(invalid.commands)
    @test fixture.revision == base_copy
    @test semantic_error_code(() -> apply!(
        invalid,
        ProjectCommand(
            ProjectId("command.invalid_identity"),
            SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("id", "bus.changed")),
        ),
    )) == :record_identity_mismatch

    incomplete = begin_project_transaction(fixture.revision)
    apply!(
        incomplete,
        ProjectCommand(
            ProjectId("command.unset_required_mode"),
            UnsetRecordFieldPatch(ProjectId("bus.HV"), "mode"),
        ),
    )
    @test semantic_error_code(() -> commit!(
        incomplete,
        fixture.revision,
        ContentDigest(repeat("7", 64)),
        ContentDigest(repeat("8", 64)),
        transaction_provenance(fixture, "action.invalid_edit", 2),
    )) == :missing_required_field
    @test incomplete.state == TransactionOpen
    @test fixture.revision == base_copy
    rolled_back = rollback!(incomplete)
    @test rolled_back === fixture.revision
    @test incomplete.working === fixture.revision.project
    @test incomplete.state == TransactionRolledBack
    @test semantic_error_code(() -> apply!(incomplete, ProjectCommand(ProjectId("command.after_rollback"), SetProjectNamePatch("No")))) == :invalid_transaction_state

    empty = begin_project_transaction(fixture.revision)
    @test semantic_error_code(() -> commit!(
        empty,
        fixture.revision,
        ContentDigest(repeat("9", 64)),
        ContentDigest(repeat("a", 64)),
        transaction_provenance(fixture, "action.empty", 3),
    )) == :empty_transaction

    first = begin_project_transaction(fixture.revision)
    apply!(first, ProjectCommand(ProjectId("command.left_mode"), SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("mode", "PV"))))
    left = commit!(
        first,
        fixture.revision,
        ContentDigest(repeat("b", 64)),
        ContentDigest(repeat("c", 64)),
        transaction_provenance(fixture, "action.left", 4),
    )
    stale = begin_project_transaction(fixture.revision)
    apply!(stale, ProjectCommand(ProjectId("command.stale_name"), SetProjectNamePatch("Stale Edit")))
    @test semantic_error_code(() -> commit!(
        stale,
        left,
        ContentDigest(repeat("d", 64)),
        ContentDigest(repeat("e", 64)),
        transaction_provenance(fixture, "action.stale", 5),
    )) == :concurrent_base_mismatch
    @test stale.state == TransactionOpen

    duplicate = begin_project_transaction(fixture.revision)
    command = ProjectCommand(ProjectId("command.duplicate"), SetProjectNamePatch("First Name"))
    apply!(duplicate, command)
    @test semantic_error_code(() -> apply!(duplicate, command)) == :duplicate_command_id
    @test length(duplicate.commands) == 1

    unchanged_hash = begin_project_transaction(fixture.revision)
    apply!(unchanged_hash, ProjectCommand(ProjectId("command.changed_name"), SetProjectNamePatch("Changed Name")))
    @test semantic_error_code(() -> commit!(
        unchanged_hash,
        fixture.revision,
        ContentDigest(repeat("f", 64)),
        fixture.revision.resolved_hash,
        transaction_provenance(fixture, "action.bad_hash", 6),
    )) == :unchanged_resolved_hash
    @test unchanged_hash.state == TransactionOpen

    exception_transaction = begin_project_transaction(fixture.revision)
    try
        apply!(exception_transaction, ProjectCommand(ProjectId("command.before_exception"), SetProjectNamePatch("Provisional")))
        error("synthetic automation failure")
    catch
        rollback!(exception_transaction)
    end
    @test exception_transaction.working === fixture.revision.project
    @test fixture.revision == base_copy
end

@testset "unsafe patches are noninvertible and revision conflicts are explicit" begin
    fixture = canonical_project_fixture(two_records = true)
    invalid_record = CanonicalRecord(
        ObjectIdentity(ProjectId("bus.unsafe")),
        fixture.schema.identity,
        [CanonicalField("id", "bus.unsafe"), CanonicalField("mode", "unknown")],
        fixture.provenance,
    )
    unsafe_command = ProjectCommand(
        ProjectId("command.unsafe_replace"),
        UnsafeReplaceRecordsPatch([invalid_record]),
    )
    transaction = begin_project_transaction(fixture.revision)
    apply!(transaction, unsafe_command)
    @test transaction.working.verification == ProjectUnverified
    @test semantic_error_code(() -> validate!(transaction)) == :value_not_allowed
    @test semantic_error_code(() -> inverse_commands(fixture.project, [unsafe_command])) == :noninvertible_command
    @test !can_reuse_results(initial_revision(
        transaction.working,
        ContentDigest(repeat("0", 64)),
        ContentDigest(repeat("a", 64)),
        transaction_provenance(fixture, "action.unsafe", 7),
    ))

    left_transaction = begin_project_transaction(fixture.revision)
    apply!(left_transaction, ProjectCommand(ProjectId("command.left_priority"), SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("priority", 20))))
    left = commit!(
        left_transaction,
        fixture.revision,
        ContentDigest(repeat("1", 64)),
        ContentDigest(repeat("b", 64)),
        transaction_provenance(fixture, "action.left_priority", 8),
    )
    right_transaction = begin_project_transaction(fixture.revision)
    apply!(right_transaction, ProjectCommand(ProjectId("command.right_mode"), SetRecordFieldPatch(ProjectId("bus.HV"), CanonicalField("mode", "PV"))))
    right = commit!(
        right_transaction,
        fixture.revision,
        ContentDigest(repeat("2", 64)),
        ContentDigest(repeat("c", 64)),
        transaction_provenance(fixture, "action.right_mode", 9),
    )
    conflicts = detect_revision_conflicts(fixture.revision, left, right)
    @test length(conflicts) == 1
    @test conflicts[1] == RevisionConflict(ProjectId("bus.HV"), left.id, right.id)
    @test semantic_error_code(() -> detect_revision_conflicts(left, fixture.revision, right)) == :revision_parent_mismatch

    separate_transaction = begin_project_transaction(fixture.revision)
    apply!(separate_transaction, ProjectCommand(ProjectId("command.separate_mode"), SetRecordFieldPatch(ProjectId("bus.MV"), CanonicalField("mode", "PV"))))
    separate = commit!(
        separate_transaction,
        fixture.revision,
        ContentDigest(repeat("3", 64)),
        ContentDigest(repeat("d", 64)),
        transaction_provenance(fixture, "action.separate", 10),
    )
    @test isempty(detect_revision_conflicts(fixture.revision, left, separate))
end

record_project_conformance!(:revisions_transactions)
