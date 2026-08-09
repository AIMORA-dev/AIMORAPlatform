const MIGRATION_DIALECT = "https://json-schema.org/draft/2020-12/schema"

struct UnsupportedMigrationOperation <: MigrationOperation end
struct UnsupportedFormatPathSegment <: FormatPathSegment end

function migration_schema(
    schema_id::String,
    version::VersionNumber,
    properties::String,
    required::Vector{String};
    uri_prefix::String = "https://schema.aimora.dev/migration",
)
    uri = "$(uri_prefix)/$(version)"
    required_json = join(("\"$(name)\"" for name in required), ",")
    text = """{
      "\$schema":"$(MIGRATION_DIALECT)",
      "\$id":"$(uri)",
      "type":"object",
      "properties":{$(properties)},
      "required":[$(required_json)],
      "additionalProperties":false
    }"""
    identity = StructuralSchemaIdentity(schema_id, version; uri)
    result = compile_structural_schema(
        text,
        identity;
        source_name = "$(schema_id)-$(version).schema.json",
    )
    @test format_succeeded(result)
    return result.value
end

function lossy_migration_registry()
    schema_id = "schema.migration"
    version_property(version) =
        "\"schema_version\":{\"const\":\"$(version)\"}"
    settings_empty =
        "\"settings\":{\"type\":\"object\",\"additionalProperties\":false}"
    settings_location = """"settings":{
      "type":"object",
      "properties":{"location":{"type":"integer"}},
      "required":["location"],
      "additionalProperties":false
    }"""
    version_1 = migration_schema(
        schema_id,
        v"1.0.0",
        join([
            version_property(v"1.0.0"),
            "\"old_name\":{\"type\":\"string\"}",
            "\"location\":{\"type\":\"integer\"}",
            settings_empty,
            "\"obsolete\":{\"type\":\"string\"}",
        ], ","),
        ["schema_version", "old_name", "location", "settings", "obsolete"],
    )
    version_2 = migration_schema(
        schema_id,
        v"2.0.0",
        join([
            version_property(v"2.0.0"),
            "\"name\":{\"type\":\"string\"}",
            settings_location,
            "\"obsolete\":{\"type\":\"string\"}",
        ], ","),
        ["schema_version", "name", "settings", "obsolete"],
    )
    version_3 = migration_schema(
        schema_id,
        v"3.0.0",
        join([
            version_property(v"3.0.0"),
            "\"name\":{\"type\":\"string\"}",
            settings_location,
        ], ","),
        ["schema_version", "name", "settings"],
    )
    schema_version = FormatPath("schema_version")
    obsolete = FormatPath("obsolete")
    loss = MigrationLoss(
        "obsolete-field",
        obsolete,
        "The obsolete compatibility marker is removed.",
        "Consumers must not depend on the retired marker.",
    )
    first_step = MigrationStep(
        "rename-and-nest",
        schema_id,
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationAssertValue(schema_version, FormatString("1.0.0")),
            MigrationRenameKey(FormatPath(), "old_name", "name"),
            MigrationMoveValue(FormatPath("location"), FormatPath("settings", "location")),
            MigrationSetSchemaVersion(schema_version),
        ];
        provenance = "AIMORAFormats migration test fixture",
    )
    second_step = MigrationStep(
        "remove-obsolete-marker",
        schema_id,
        v"2.0.0",
        v"3.0.0",
        MigrationOperation[
            MigrationAssertValue(obsolete, FormatString("retire-me")),
            MigrationRemoveValue(obsolete, loss),
            MigrationSetSchemaVersion(schema_version),
        ];
        provenance = "AIMORAFormats migration test fixture",
    )
    policy = SchemaVersionPolicy(
        schema_id,
        v"3.0.0";
        backward_readers = [v"2.0.0"],
    )
    return StructuralSchemaRegistry(
        policy,
        [version_1, version_2, version_3],
        MigrationGraph(schema_id, [first_step, second_step]),
    )
end

function reversible_migration_registry(; include_inverse::Bool = true)
    schema_id = "schema.reversible"
    first = migration_schema(
        schema_id,
        v"1.0.0",
        "\"schema_version\":{\"const\":\"1.0.0\"},\"old_name\":{\"type\":\"string\"}",
        ["schema_version", "old_name"];
        uri_prefix = "https://schema.aimora.dev/reversible",
    )
    second = migration_schema(
        schema_id,
        v"2.0.0",
        "\"schema_version\":{\"const\":\"2.0.0\"},\"name\":{\"type\":\"string\"}",
        ["schema_version", "name"];
        uri_prefix = "https://schema.aimora.dev/reversible",
    )
    schema_version = FormatPath("schema_version")
    inverse = include_inverse ? MigrationOperation[
        MigrationRenameKey(FormatPath(), "name", "old_name"),
        MigrationSetSchemaVersion(schema_version),
    ] : nothing
    step = MigrationStep(
        "reversible-rename",
        schema_id,
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationRenameKey(FormatPath(), "old_name", "name"),
            MigrationSetSchemaVersion(schema_version),
        ];
        inverse_operations = inverse,
        provenance = "AIMORAFormats reversible migration fixture",
    )
    return StructuralSchemaRegistry(
        SchemaVersionPolicy(schema_id, v"2.0.0"),
        [first, second],
        MigrationGraph(schema_id, [step]),
    )
end

function parsed_migration_source()
    return parse_json(
        """{
          "schema_version":"1.0.0",
          "old_name":"North",
          "location":7,
          "settings":{},
          "obsolete":"retire-me"
        }""";
        source_name = "migration-source.json",
    ).value
end

function migration_mapping(report::MigrationReport, result_path::FormatPath)
    index = findfirst(mapping -> mapping.result_path == result_path, report.source_mappings)
    isnothing(index) && return nothing
    return report.source_mappings[index]
end

@testset "typed format paths and migration operation invariants" begin
    path = FormatPath("assets", 2, "name")
    @test path == FormatPath(
        FormatMappingKeySegment("assets"),
        FormatSequenceIndexSegment(2),
        FormatMappingKeySegment("name"),
    )
    @test sprint(show, path) == "\$.assets[2].name"
    @test sprint(show, FormatPath("a.b", "x[y]")) == "\$[\"a.b\"][\"x[y]\"]"
    @test hash(path) == hash(FormatPath("assets", 2, "name"))
    @test_throws ArgumentError FormatMappingKeySegment("")
    @test_throws ArgumentError FormatSequenceIndexSegment(0)
    @test_throws ArgumentError FormatPath(:assets)
    @test_throws ArgumentError FormatPath(UnsupportedFormatPathSegment())
    @test_throws ArgumentError MigrationRenameKey(FormatPath(), "same", "same")
    @test_throws ArgumentError MigrationMoveValue(FormatPath(), FormatPath("target"))
    @test_throws ArgumentError MigrationMoveValue(
        FormatPath("source"),
        FormatPath("source", "child"),
    )
    @test_throws ArgumentError MigrationMoveValue(
        FormatPath("source"),
        FormatPath("items", 1),
    )
    @test_throws ArgumentError MigrationSetSchemaVersion(FormatPath())
    @test_throws ArgumentError MigrationSetSchemaVersion(FormatPath("versions", 1))

    loss = MigrationLoss(
        "retired-field",
        FormatPath("retired"),
        "Retired data is removed.",
        "The retired field is unavailable after migration.",
    )
    @test_throws ArgumentError MigrationRemoveValue(FormatPath("other"), loss)
    @test_throws MethodError MigrationRemoveValue(FormatPath("retired"))
    @test_throws ArgumentError MigrationLoss(
        "bad id",
        FormatPath("retired"),
        "description",
        "consequence",
    )
    @test_throws ArgumentError MigrationStep(
        "missing-version-operation",
        "schema.demo",
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[MigrationAssertValue(FormatPath("x"), FormatString("x"))];
        provenance = "test",
    )
    @test_throws ArgumentError MigrationStep(
        "unsupported-operation",
        "schema.demo",
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            UnsupportedMigrationOperation(),
            MigrationSetSchemaVersion(FormatPath("version")),
        ];
        provenance = "test",
    )
    @test_throws ArgumentError MigrationStep(
        "reversed",
        "schema.demo",
        v"2.0.0",
        v"1.0.0",
        MigrationOperation[MigrationSetSchemaVersion(FormatPath("version"))];
        provenance = "test",
    )
    @test_throws ArgumentError MigrationStep(
        "lossy-inverse",
        "schema.demo",
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationRemoveValue(FormatPath("retired"), loss),
            MigrationSetSchemaVersion(FormatPath("version")),
        ];
        inverse_operations = MigrationOperation[
            MigrationSetSchemaVersion(FormatPath("version")),
        ],
        provenance = "test",
    )
    second_loss = MigrationLoss(
        "retired-field",
        FormatPath("other-retired"),
        "Other retired data is removed.",
        "The other retired field is unavailable after migration.",
    )
    @test_throws ArgumentError MigrationStep(
        "duplicate-loss-identities",
        "schema.demo",
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationRemoveValue(FormatPath("retired"), loss),
            MigrationRemoveValue(FormatPath("other-retired"), second_loss),
            MigrationSetSchemaVersion(FormatPath("version")),
        ];
        provenance = "test",
    )
    @test MigrationAssertValue(FormatPath("x"), FormatString("value")) ==
          MigrationAssertValue(FormatPath("x"), FormatString("value"))
    @test MigrationRenameKey(FormatPath(), "old", "new") ==
          MigrationRenameKey(FormatPath(), "old", "new")
    @test MigrationMoveValue(FormatPath("old"), FormatPath("nested", "new")) ==
          MigrationMoveValue(FormatPath("old"), FormatPath("nested", "new"))
    @test MigrationSetSchemaVersion(FormatPath("version")) ==
          MigrationSetSchemaVersion(FormatPath("version"))
    @test MigrationRemoveValue(FormatPath("retired"), loss) ==
          MigrationRemoveValue(FormatPath("retired"), loss)
end

@testset "deterministic multi-step upgrade, loss, mapping, and dry run" begin
    registry = lossy_migration_registry()
    source = parsed_migration_source()
    original = parse_json(
        source.source.text;
        source_name = "migration-source.json",
    ).value

    plan = plan_migration(registry.migrations, v"1.0.0", v"3.0.0")
    @test format_succeeded(plan)
    @test getfield.(getfield.(plan.value.steps, :step), :id) ==
          ["rename-and-nest", "remove-obsolete-marker"]
    @test all(step -> step.direction == MigrationUpgrade, plan.value.steps)
    @test schema_compatibility(registry, v"1.0.0").kind == SchemaMigrationRequired
    @test schema_compatibility(registry, v"2.0.0").kind == SchemaBackwardReadable
    @test schema_compatibility(registry, v"3.0.0").kind == SchemaExact
    @test schema_compatibility(registry, v"4.0.0").kind == SchemaFutureUnsupported

    backward_document = migrate_format_document(
        registry,
        source,
        v"1.0.0";
        to_version = v"2.0.0",
    )
    @test format_succeeded(backward_document)
    backward_bytes = serialize_canonical_json(backward_document.value.document.root)
    @test format_succeeded(backward_bytes)
    backward_reparsed = parse_json(
        collect(backward_bytes.value.bytes);
        source_name = "backward-reader-round-trip.json",
    )
    @test format_succeeded(backward_reparsed)
    backward_schema = resolve_structural_schema(registry, v"2.0.0")
    @test format_succeeded(backward_schema)
    @test format_succeeded(validate_structural_document(
        backward_schema.value,
        backward_reparsed.value,
    ))
    @test canonical_json_sha256(backward_reparsed.value).value ==
          backward_document.value.report.result_sha256

    result = migrate_format_document(registry, source, v"1.0.0")
    @test format_succeeded(result)
    @test !isnothing(result.value.document)
    @test !result.value.report.dry_run
    @test result.value.report.from_version == v"1.0.0"
    @test result.value.report.to_version == v"3.0.0"
    @test getfield.(result.value.report.steps, :direction) ==
          [MigrationUpgrade, MigrationUpgrade]
    @test length(result.value.report.changes) == 7
    @test getfield.(result.value.report.changes, :kind) == [
        MigrationAssertion,
        MigrationRename,
        MigrationMove,
        MigrationVersionChange,
        MigrationAssertion,
        MigrationRemoval,
        MigrationVersionChange,
    ]
    @test only(result.value.report.losses).id == "obsolete-field"
    @test source == original
    @test result.value.report.source_sha256 == canonical_json_sha256(source).value
    @test result.value.report.result_sha256 ==
          canonical_json_sha256(result.value.document.root).value

    serialized = serialize_canonical_json(result.value.document.root)
    @test format_succeeded(serialized)
    @test String(collect(serialized.value.bytes)) ==
          "{\"name\":\"North\",\"schema_version\":\"3.0.0\",\"settings\":{\"location\":7}}"
    final_document = ParsedFormatDocument(
        result.value.document.source,
        result.value.document.root,
    )
    target_schema = resolve_structural_schema(registry, v"3.0.0")
    @test format_succeeded(target_schema)
    @test format_succeeded(validate_structural_document(target_schema.value, final_document))

    name_mapping = migration_mapping(result.value.report, FormatPath("name"))
    @test !isnothing(name_mapping)
    @test name_mapping.source_path == FormatPath("old_name")
    location_mapping = migration_mapping(
        result.value.report,
        FormatPath("settings", "location"),
    )
    @test !isnothing(location_mapping)
    @test location_mapping.source_path == FormatPath("location")
    @test isnothing(migration_mapping(result.value.report, FormatPath("obsolete")))
    @test length(result.value.report.source_mappings) == 5

    repeated = migrate_format_document(registry, source, v"1.0.0")
    @test repeated == result
    dry_run = migrate_format_document(
        registry,
        source,
        v"1.0.0";
        dry_run = true,
    )
    @test format_succeeded(dry_run)
    @test isnothing(dry_run.value.document)
    @test dry_run.value.report.dry_run
    for field in (
        :schema_id,
        :from_version,
        :to_version,
        :source_sha256,
        :result_sha256,
        :steps,
        :changes,
        :losses,
        :source_mappings,
    )
        @test getproperty(dry_run.value.report, field) == getproperty(result.value.report, field)
    end
end

@testset "explicit inverse downgrade and same-version migration" begin
    registry = reversible_migration_registry()
    @test registry == reversible_migration_registry()
    source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"old_name\":\"Grid\"}";
        source_name = "reversible.json",
    ).value
    upgraded = migrate_format_document(registry, source, v"1.0.0")
    @test format_succeeded(upgraded)
    upgraded_document = ParsedFormatDocument(
        upgraded.value.document.source,
        upgraded.value.document.root,
    )
    downgrade_plan = plan_migration(registry.migrations, v"2.0.0", v"1.0.0")
    @test format_succeeded(downgrade_plan)
    @test only(downgrade_plan.value.steps).direction == MigrationDowngrade
    downgraded = migrate_format_document(
        registry,
        upgraded_document,
        v"2.0.0";
        to_version = v"1.0.0",
    )
    @test format_succeeded(downgraded)
    @test only(downgraded.value.report.steps).direction == MigrationDowngrade
    @test downgraded.value.report.result_sha256 == upgraded.value.report.source_sha256
    @test String(collect(serialize_canonical_json(downgraded.value.document.root).value.bytes)) ==
          "{\"old_name\":\"Grid\",\"schema_version\":\"1.0.0\"}"

    no_inverse = reversible_migration_registry(include_inverse = false)
    rejected = plan_migration(no_inverse.migrations, v"2.0.0", v"1.0.0")
    @test !format_succeeded(rejected)
    @test only(rejected.diagnostics).code == :migration_inverse_missing

    no_op = migrate_format_document(registry, source, v"1.0.0"; to_version = v"1.0.0")
    @test format_succeeded(no_op)
    @test isempty(no_op.value.report.steps)
    @test isempty(no_op.value.report.changes)
    @test isempty(no_op.value.report.losses)
    @test no_op.value.report.source_sha256 == no_op.value.report.result_sha256
    @test no_op.value.document.root == source.root
end

@testset "migration graphs reject ambiguity, gaps, and inconsistent registration" begin
    function version_step(id, from, to; schema_id = "schema.graph", inverse = false)
        operations = MigrationOperation[
            MigrationSetSchemaVersion(FormatPath("schema_version")),
        ]
        return MigrationStep(
            id,
            schema_id,
            from,
            to,
            operations;
            inverse_operations = inverse ? copy(operations) : nothing,
            provenance = "migration graph test",
        )
    end

    first = version_step("one-two", v"1.0.0", v"2.0.0")
    second = version_step("two-three", v"2.0.0", v"3.0.0")
    direct = version_step("one-three", v"1.0.0", v"3.0.0")
    @test_throws ArgumentError MigrationGraph("schema.graph", [first, second, direct])
    @test_throws ArgumentError MigrationGraph("schema.graph", [first, first])
    duplicate_edge = version_step("duplicate-edge", v"1.0.0", v"2.0.0")
    @test_throws ArgumentError MigrationGraph("schema.graph", [first, duplicate_edge])
    @test_throws ArgumentError MigrationGraph(
        "schema.other",
        [first],
    )

    graph = MigrationGraph("schema.graph", [first])
    gap = plan_migration(graph, v"1.0.0", v"3.0.0")
    @test !format_succeeded(gap)
    @test only(gap.diagnostics).code == :migration_path_missing

    schema_1 = migration_schema(
        "schema.graph",
        v"1.0.0",
        "\"schema_version\":{\"type\":\"string\"}",
        ["schema_version"];
        uri_prefix = "https://schema.aimora.dev/graph",
    )
    schema_2 = migration_schema(
        "schema.graph",
        v"2.0.0",
        "\"schema_version\":{\"type\":\"string\"}",
        ["schema_version"];
        uri_prefix = "https://schema.aimora.dev/graph",
    )
    @test_throws ArgumentError StructuralSchemaRegistry(
        SchemaVersionPolicy("schema.graph", v"2.0.0"),
        [schema_1],
        graph,
    )
    @test_throws ArgumentError StructuralSchemaRegistry(
        SchemaVersionPolicy("schema.other", v"2.0.0"),
        [schema_1, schema_2],
        graph,
    )
    unregistered_step = version_step("two-three", v"2.0.0", v"3.0.0")
    @test_throws ArgumentError StructuralSchemaRegistry(
        SchemaVersionPolicy("schema.graph", v"2.0.0"),
        [schema_1, schema_2],
        MigrationGraph("schema.graph", [unregistered_step]),
    )
    @test_throws ArgumentError StructuralSchemaRegistry(
        SchemaVersionPolicy("schema.graph", v"2.0.0"),
        [schema_1, schema_1, schema_2],
        graph,
    )
    duplicate_uri_schema = migration_schema(
        "schema.graph",
        v"3.0.0",
        "\"schema_version\":{\"type\":\"string\"}",
        ["schema_version"];
        uri_prefix = "https://schema.aimora.dev/graph/..",
    )
    duplicate_uri_identity = StructuralSchemaIdentity(
        "schema.graph",
        v"3.0.0";
        uri = schema_2.identity.uri,
    )
    duplicate_uri_text = replace(
        duplicate_uri_schema.source.text,
        duplicate_uri_schema.identity.uri => schema_2.identity.uri,
    )
    duplicate_uri_compiled = compile_structural_schema(
        duplicate_uri_text,
        duplicate_uri_identity,
    )
    @test format_succeeded(duplicate_uri_compiled)
    @test_throws ArgumentError StructuralSchemaRegistry(
        SchemaVersionPolicy("schema.graph", v"3.0.0"),
        [schema_1, schema_2, duplicate_uri_compiled.value],
        MigrationGraph("schema.graph", [first, version_step("two-three", v"2.0.0", v"3.0.0")]),
    )
end

@testset "migration failures are atomic and version/schema failures are explicit" begin
    registry = lossy_migration_registry()
    source = parsed_migration_source()
    invalid_source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"old_name\":\"North\"}";
        source_name = "invalid-source.json",
    ).value
    source_failure = migrate_format_document(registry, invalid_source, v"1.0.0")
    @test !format_succeeded(source_failure)
    @test isnothing(source_failure.value)
    @test first(source_failure.diagnostics).code == :migration_source_validation_failed

    future = migrate_format_document(
        registry,
        source,
        v"1.0.0";
        to_version = v"4.0.0",
    )
    @test !format_succeeded(future)
    @test only(future.diagnostics).code == :structural_schema_future_version
    missing_past = migrate_format_document(registry, source, v"0.5.0")
    @test !format_succeeded(missing_past)
    @test only(missing_past.diagnostics).code == :structural_schema_version_missing

    schema_id = "schema.atomic"
    source_schema = migration_schema(
        schema_id,
        v"1.0.0",
        "\"schema_version\":{\"const\":\"1.0.0\"},\"old_name\":{\"type\":\"string\"}",
        ["schema_version", "old_name"];
        uri_prefix = "https://schema.aimora.dev/atomic",
    )
    target_schema = migration_schema(
        schema_id,
        v"2.0.0",
        "\"schema_version\":{\"const\":\"2.0.0\"},\"name\":{\"type\":\"string\"}",
        ["schema_version", "name"];
        uri_prefix = "https://schema.aimora.dev/atomic",
    )
    failing_step = MigrationStep(
        "fail-after-rename",
        schema_id,
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationRenameKey(FormatPath(), "old_name", "name"),
            MigrationAssertValue(FormatPath("name"), FormatString("Wrong")),
            MigrationSetSchemaVersion(FormatPath("schema_version")),
        ];
        provenance = "atomic rollback test",
    )
    atomic_registry = StructuralSchemaRegistry(
        SchemaVersionPolicy(schema_id, v"2.0.0"),
        [source_schema, target_schema],
        MigrationGraph(schema_id, [failing_step]),
    )
    atomic_source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"old_name\":\"North\"}";
        source_name = "atomic-source.json",
    ).value
    original_source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"old_name\":\"North\"}";
        source_name = "atomic-source.json",
    ).value
    atomic_failure = migrate_format_document(atomic_registry, atomic_source, v"1.0.0")
    @test !format_succeeded(atomic_failure)
    @test isnothing(atomic_failure.value)
    @test only(atomic_failure.diagnostics).code == :migration_assertion_failed
    @test atomic_source == original_source

    incomplete_step = MigrationStep(
        "target-invalid",
        schema_id,
        v"1.0.0",
        v"2.0.0",
        MigrationOperation[
            MigrationSetSchemaVersion(FormatPath("schema_version")),
        ];
        provenance = "target validation failure test",
    )
    incomplete_registry = StructuralSchemaRegistry(
        SchemaVersionPolicy(schema_id, v"2.0.0"),
        [source_schema, target_schema],
        MigrationGraph(schema_id, [incomplete_step]),
    )
    target_failure = migrate_format_document(incomplete_registry, atomic_source, v"1.0.0")
    @test !format_succeeded(target_failure)
    @test isnothing(target_failure.value)
    @test first(target_failure.diagnostics).code == :migration_target_validation_failed
    @test atomic_source == original_source
end

@testset "move and version-operation diagnostics retain exact source locations" begin
    function move_failure_registry(destination::FormatPath)
        schema_id = "schema.move"
        source_schema = migration_schema(
            schema_id,
            v"1.0.0",
            "\"schema_version\":{\"type\":\"string\"},\"value\":{\"type\":\"integer\"},\"settings\":{\"type\":\"object\"}",
            ["schema_version", "value", "settings"];
            uri_prefix = "https://schema.aimora.dev/move",
        )
        target_schema = migration_schema(
            schema_id,
            v"2.0.0",
            "\"schema_version\":{\"type\":\"string\"},\"settings\":{\"type\":\"object\"}",
            ["schema_version", "settings"];
            uri_prefix = "https://schema.aimora.dev/move",
        )
        step = MigrationStep(
            "move-value",
            schema_id,
            v"1.0.0",
            v"2.0.0",
            MigrationOperation[
                MigrationMoveValue(FormatPath("value"), destination),
                MigrationSetSchemaVersion(FormatPath("schema_version")),
            ];
            provenance = "move failure test",
        )
        return StructuralSchemaRegistry(
            SchemaVersionPolicy(schema_id, v"2.0.0"),
            [source_schema, target_schema],
            MigrationGraph(schema_id, [step]),
        )
    end

    occupied_source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"value\":1,\"settings\":{\"value\":2}}";
        source_name = "occupied.json",
    ).value
    occupied = migrate_format_document(
        move_failure_registry(FormatPath("settings", "value")),
        occupied_source,
        v"1.0.0",
    )
    @test !format_succeeded(occupied)
    @test only(occupied.diagnostics).code == :migration_destination_invalid
    @test only(occupied.diagnostics).span.source_name == "occupied.json"

    missing_parent_source = parse_json(
        "{\"schema_version\":\"1.0.0\",\"value\":1,\"settings\":{}}";
        source_name = "missing-parent.json",
    ).value
    missing_parent = migrate_format_document(
        move_failure_registry(FormatPath("absent", "value")),
        missing_parent_source,
        v"1.0.0",
    )
    @test !format_succeeded(missing_parent)
    @test only(missing_parent.diagnostics).code == :migration_destination_invalid
    @test only(missing_parent.diagnostics).span.source_name == "missing-parent.json"

    version_registry = move_failure_registry(FormatPath("settings", "moved"))
    wrong_version = parse_json(
        "{\"schema_version\":\"not-the-endpoint\",\"value\":1,\"settings\":{}}";
        source_name = "wrong-version.json",
    ).value
    version_failure = migrate_format_document(version_registry, wrong_version, v"1.0.0")
    @test !format_succeeded(version_failure)
    @test only(version_failure.diagnostics).code == :migration_version_mismatch
    @test only(version_failure.diagnostics).span.source_name == "wrong-version.json"
end
