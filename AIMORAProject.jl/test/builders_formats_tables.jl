import AIMORAFormats
using AIMORAFormats: BulkColumnSpec,
    BulkString,
    BulkTableSchema,
    FormatPath,
    ImportAdapterIdentity,
    ImportFieldRule,
    ImportMapped,
    compile_generic_table_import,
    format_succeeded,
    parse_delimited_table,
    parse_restricted_yaml,
    serialize_restricted_yaml
using Tables

const FORMATS_FIXTURE_ROOT = joinpath(
    dirname(dirname(pathof(AIMORAFormats))),
    "test",
    "fixtures",
    "native_migrations",
)

formats_fixture(name::AbstractString) = joinpath(FORMATS_FIXTURE_ROOT, name)

@testset "public Julia YAML and table authoring example" begin
    example_module = Module(:ProjectAuthoringExample, true, true)
    example = Base.include(
        example_module,
        joinpath(@__DIR__, "..", "examples", "project_authoring.jl"),
    )
    @test example.revision.project == example.decoded
    @test length(collect(Tables.rows(example.table))) == 1
end

@testset "typed builders queries and record table commits share project commands" begin
    fixture = canonical_project_fixture(two_records = true)
    builder = project_builder(fixture.revision)
    set_record_field!(builder, ProjectId("bus.MV"), CanonicalField("mode", "PV"))
    set_project_name!(builder, "Builder Project")
    revision = commit_builder!(
        builder;
        provenance = transaction_provenance(fixture, "action.builder_edit", 31),
    )
    @test revision.project.metadata.name == "Builder Project"
    @test only(field.value for field in project_record(revision.project, ProjectId("bus.MV")).fields if field.name == "mode") == "PV"
    @test all(command.patch isa ProjectPatch for command in revision.commands)
    @test revision.resolved_hash == project_resolved_hash(revision.project)

    snapshot = project_snapshot(revision)
    handles = query_record_handles(snapshot, fixture.schema.identity)
    @test length(handles) == 2
    @test resolve_handle(snapshot, first(handles)) isa CanonicalRecord
    @test semantic_error_code(() -> resolve_handle(project_snapshot(fixture.revision), first(handles))) == :stale_project_handle
    selected = select_records(snapshot, record -> record.identity.id == ProjectId("bus.MV"))
    @test only(selected).identity.id == ProjectId("bus.MV")

    table = record_table(snapshot, fixture.schema.identity)
    @test Tables.istable(typeof(table))
    @test Tables.rowaccess(typeof(table))
    @test first(Tables.schema(table).names) == :owner_id
    rows = collect(Tables.rows(table))
    @test getproperty(only(row for row in rows if row.owner_id == "bus.MV"), :mode) == "PV"

    edit = begin_record_table_edit(revision, fixture.schema.identity)
    set_table_cell!(edit, ProjectId("bus.MV"), CanonicalField("priority", 25))
    edited = commit_table!(
        edit;
        provenance = transaction_provenance(fixture, "action.table_edit", 32),
    )
    @test only(field.value for field in project_record(edited.project, ProjectId("bus.MV")).fields if field.name == "priority") == 25
    @test semantic_error_code(() -> set_table_cell!(edit, ProjectId("bus.MV"), CanonicalField("priority", 26))) == :duplicate_table_edit
end

@testset "asset table edits preserve realizations catalog access and provenance" begin
    fixture = asset_fixture()
    snapshot = project_snapshot(fixture.revision)
    table = asset_table(snapshot)
    @test Tables.istable(typeof(table))
    row = only(Tables.rows(table))
    @test row.id == "bus.HV"
    @test getproperty(row, :physical__in_service)

    edit = begin_asset_table_edit(fixture.revision)
    set_table_cell!(
        edit,
        ProjectId("bus.HV"),
        FieldPath("physical.in_service"),
        false,
        fixture.provenance,
    )
    revision = commit_table!(
        edit;
        provenance = transaction_provenance(fixture, "action.asset_table_edit", 33),
    )
    before = fixture.asset
    after = canonical_asset(revision.project, ProjectId("bus.HV"))
    @test !only(property.value for property in after.common if property.path == FieldPath("physical.in_service"))
    @test after.realizations == before.realizations
    @test after.catalog == before.catalog
    @test after.overrides == before.overrides
    @test after.access == before.access
    @test after.provenance == before.provenance
end

@testset "restricted YAML Julia builders compact and directory projects are equivalent" begin
    fixture = canonical_project_fixture(two_records = true)
    node = project_format_node(fixture.project)
    yaml = serialize_restricted_yaml(node)
    @test format_succeeded(yaml)
    parsed = parse_restricted_yaml(collect(yaml.value.bytes); source_name = "equivalent.aimora.yaml")
    @test format_succeeded(parsed)
    decoded = project_from_format(parsed.value.root)
    @test format_succeeded(decoded)
    @test decoded.value == fixture.project
    @test project_resolved_hash(decoded.value) == project_resolved_hash(fixture.project)

    builder = project_builder(initial_revision(
        CanonicalProject(fixture.metadata, fixture.registry, fixture.units, CanonicalRecord[]),
        ContentDigest(repeat("a", 64)),
        ContentDigest(repeat("b", 64)),
        transaction_provenance(fixture, "action.empty_builder", 34),
    ))
    for record in fixture.project.records
        add_record!(builder, record)
    end
    built = commit_builder!(
        builder;
        provenance = transaction_provenance(fixture, "action.builder_import", 35),
    )
    @test built.project == decoded.value
    @test project_resolved_hash(built.project) == project_resolved_hash(decoded.value)

    mktempdir() do root
        compact = joinpath(root, "grid.aimora.yaml")
        written = save_project(compact, fixture.project)
        @test format_succeeded(written)
        opened_compact = open_project(compact)
        @test format_succeeded(opened_compact)
        @test opened_compact.value.project == fixture.project

        directory = joinpath(root, "grid")
        written_directory = save_project(directory, fixture.project)
        @test format_succeeded(written_directory)
        @test isfile(joinpath(directory, "project.aimora.yaml"))
        opened_directory = open_project(directory)
        @test format_succeeded(opened_directory)
        @test opened_directory.value.project == fixture.project
        normalized_compact = normalize_project(compact)
        normalized_directory = normalize_project(directory)
        @test format_succeeded(normalized_compact)
        @test collect(normalized_compact.value.bytes) == collect(normalized_directory.value.bytes)
        @test validate_project(directory).value.project == fixture.project
    end
end

@testset "format command conversion is deterministic strict and atomic" begin
    fixture = canonical_project_fixture(two_records = true)
    commands = [
        ProjectCommand(ProjectId("command.target_name"), SetProjectNamePatch("Format Target")),
        ProjectCommand(
            ProjectId("command.target_mode"),
            SetRecordFieldPatch(ProjectId("bus.MV"), CanonicalField("mode", "PV")),
        ),
    ]
    target = replay_commands(fixture.project, commands)
    converted = commands_from_format(fixture.revision, project_format_node(target))
    @test format_succeeded(converted)
    @test replay_commands(fixture.project, converted.value) == target
    repeated = commands_from_format(fixture.revision, project_format_node(target))
    @test repeated.value == converted.value

    serialized = serialize_restricted_yaml(project_format_node(fixture.project))
    malformed_text = replace(
        String(collect(serialized.value.bytes)),
        "\"records\":" => "\"unknown_records\":",
    )
    malformed = parse_restricted_yaml(malformed_text; source_name = "bad.aimora.yaml")
    @test format_succeeded(malformed)
    rejected = project_from_format(malformed.value.root)
    @test !format_succeeded(rejected)
    @test only(rejected.diagnostics).code in (:missing_project_key, :unknown_project_key)
    @test only(rejected.diagnostics).span.source_name == "bad.aimora.yaml"

    asset_project = asset_fixture().project
    @test semantic_error_code(() -> project_format_node(asset_project)) == :project_profile_requires_split_semantic_sections
end

@testset "versioned exact control task schedules round trip without executable behavior" begin
    control = control_fixture()
    writer = ControlTaskDeclaration(
        ProjectId("task.writer"),
        ConverterControlTask,
        control_time("0.0", control.provenance),
        control_time("0.00001", control.provenance),
        control_time("0.000001", control.provenance),
        control_time("0.000002", control.provenance);
        priority = 2,
        write_resources = [ProjectId("resource.command")],
        invalidations = [InvalidateControlPowerHistory, InvalidateControlOutput],
    )
    reader = ControlTaskDeclaration(
        ProjectId("task.reader"),
        ProtectionControlTask,
        control_time("0.0", control.provenance),
        control_time("0.00002", control.provenance),
        control_time("0.000001", control.provenance),
        control_time("0.0", control.provenance);
        priority = -2,
        read_resources = [ProjectId("resource.command")],
        write_resources = [ProjectId("resource.trip")],
        predecessors = [writer.task],
        invalidations = [InvalidateControlTopology],
    )
    schedule = ControlSchedule(
        ControlHybrid,
        HybridOrderedExecution,
        [writer.task, reader.task];
        sample_time = control_time("0.000001", control.provenance),
        phase_offset = control_time("0.0", control.provenance),
        computational_delay = control_time("0.0", control.provenance),
        task_declarations = [writer, reader],
    )
    @test AIMORAProject._validate_control_schedule(control.project, schedule)
    serialized = serialize_restricted_yaml(control_schedule_format_node(schedule))
    @test format_succeeded(serialized)
    parsed = parse_restricted_yaml(
        collect(serialized.value.bytes);
        source_name = "control_schedule.aimora.yaml",
    )
    @test format_succeeded(parsed)
    decoded = control_schedule_from_format(parsed.value.root)
    @test format_succeeded(decoded)
    @test decoded.value == schedule
    @test AIMORAProject._validate_control_schedule(control.project, decoded.value)
    @test collect(serialize_restricted_yaml(
        control_schedule_format_node(decoded.value),
    ).value.bytes) == collect(serialized.value.bytes)

    unsupported_text = replace(
        String(serialized.value.bytes),
        "\"version\":\"1.0.0\"" => "\"version\":\"2.0.0\"";
        count = 1,
    )
    @test unsupported_text != String(serialized.value.bytes)
    unsupported = parse_restricted_yaml(
        unsupported_text;
        source_name = "unsupported_control_schedule.aimora.yaml",
    )
    @test format_succeeded(unsupported)
    rejected = control_schedule_from_format(unsupported.value.root)
    @test !format_succeeded(rejected)
    @test only(rejected.diagnostics).code == :unknown_control_schedule_format_version
end

function import_application_fixture()
    fixture = canonical_project_fixture()
    schema = SemanticSchema(
        SemanticSchemaIdentity(
            UUID("ae285c95-399f-46e3-a124-50694aa06f38"),
            NamespaceId("aimora"),
            ProjectId("import.object"),
            v"1.0.0",
        ),
        [
            SchemaField("id", SchemaString; required = true),
            SchemaField("name", SchemaString; required = true),
        ],
        fixture.provenance,
    )
    registry = register_schema(fixture.registry, schema)
    project = CanonicalProject(fixture.metadata, registry, fixture.units, collect(fixture.project.records))
    revision = initial_revision(
        project,
        ContentDigest(repeat("c", 64)),
        project_resolved_hash(project),
        transaction_provenance(fixture, "action.import_base", 36),
    )
    bulk_schema = BulkTableSchema(
        "generic.objects",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString), BulkColumnSpec("name", BulkString)],
        "id",
    )
    adapter = ImportAdapterIdentity(
        "aimora.generic.objects",
        v"1.0.0",
        "generic.objects",
        "1.0.0",
        [repeat("d", 64)],
    )
    parsed = parse_delimited_table("id,name\nL1,Main Load\n", bulk_schema; source_name = "objects.csv")
    rules = [
        ImportFieldRule("id", ImportMapped; destination = FormatPath("id")),
        ImportFieldRule("name", ImportMapped; destination = FormatPath("name")),
    ]
    compiled = compile_generic_table_import(parsed.value, adapter, "import.object", "asset", rules)
    return (; fixture, schema, project, revision, bulk_schema, adapter, parsed, rules, compiled)
end

@testset "generic and current migration plans commit completely or not at all" begin
    fixture = import_application_fixture()
    @test format_succeeded(fixture.compiled)
    applied = apply_import_plan(
        fixture.revision,
        fixture.compiled.value;
        provenance = transaction_provenance(fixture.fixture, "action.generic_import", 37),
    )
    @test format_succeeded(applied)
    record = project_record(applied.value.revision.project, ProjectId("asset.L1"))
    @test only(field.value for field in record.fields if field.name == "id") == "asset.L1"
    @test only(field.value for field in record.fields if field.name == "name") == "Main Load"
    @test applied.value.report.complete

    migrated_csv = migrate_aimora_asset_csv(
        fixture.revision,
        "id,name\nL2,Backup Load\n",
        fixture.bulk_schema,
        "import.object",
        "asset",
        fixture.rules;
        provenance = transaction_provenance(fixture.fixture, "action.asset_csv_import", 40),
    )
    @test format_succeeded(migrated_csv)
    @test project_record(migrated_csv.value.revision.project, ProjectId("asset.L2")).schema == fixture.schema.identity

    invalid_rules = [
        ImportFieldRule("id", ImportMapped; destination = FormatPath("id")),
        ImportFieldRule("name", ImportMapped; destination = FormatPath("unknown")),
    ]
    invalid = compile_generic_table_import(
        fixture.parsed.value,
        fixture.adapter,
        "import.object",
        "asset",
        invalid_rules,
    )
    rejected = apply_import_plan(
        fixture.revision,
        invalid.value;
        provenance = transaction_provenance(fixture.fixture, "action.invalid_import", 38),
    )
    @test !format_succeeded(rejected)
    @test only(rejected.diagnostics).code == :unknown_import_destination
    @test fixture.revision.project == fixture.project

    catalog_source = read(formats_fixture("catalog_v1.toml"), String)
    catalog = migrate_aimora_catalog_entry_v1(
        fixture.revision,
        catalog_source;
        provenance = transaction_provenance(fixture.fixture, "action.catalog_import", 41),
    )
    @test !format_succeeded(catalog)
    @test only(catalog.diagnostics).code == :unknown_import_object_type

    cases_source = read(formats_fixture("cases_v2.toml"), String)
    cases = migrate_aimora_cases_catalog_v2(
        fixture.revision,
        cases_source;
        provenance = transaction_provenance(fixture.fixture, "action.cases_import", 42),
    )
    @test !format_succeeded(cases)
    @test only(cases.diagnostics).code == :unknown_import_object_type

    legacy = read(formats_fixture("project_v1.toml"), String)
    migrated = migrate_aimora_project_v1(
        fixture.revision,
        legacy;
        provenance = transaction_provenance(fixture.fixture, "action.legacy_import", 39),
    )
    @test !format_succeeded(migrated)
    @test only(migrated.diagnostics).code == :blocked_import_plan
    @test fixture.revision.project == fixture.project
end

record_project_conformance!(:builders_queries_tables_formats_imports)
