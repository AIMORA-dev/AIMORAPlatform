const NATIVE_FIXTURE_ROOT = joinpath(@__DIR__, "fixtures", "native_migrations")

native_fixture(name) = read(joinpath(NATIVE_FIXTURE_ROOT, name), String)

function native_load_csv_contract()
    schema = BulkTableSchema(
        "aimora.loads",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("name", BulkString),
            BulkColumnSpec("p_mw", BulkDecimal; unit = "MW"),
            BulkColumnSpec("note", BulkString; nullable = true),
        ],
        "id",
    )
    rules = [
        ImportFieldRule("id", ImportMapped; destination = FormatPath("id")),
        ImportFieldRule("name", ImportMapped; destination = FormatPath("name")),
        ImportFieldRule("p_mw", ImportMapped; destination = FormatPath("common", "p_set")),
        ImportFieldRule(
            "note",
            ImportMapped;
            destination = FormatPath("metadata", "note"),
            null_operation = ImportOmitNull,
        ),
    ]
    return schema, rules
end

function assert_native_report_reconciles(result)
    report = result.report
    @test report.source_fields ==
          report.mapped_fields + report.ignored_fields +
          report.unsupported_fields + report.rejected_fields
    @test length(report.accounting) == report.source_fields
    @test length(result.plan.source_records) == report.source_records
    @test length(result.plan.operations) == report.operations
    @test result.plan.applicable == report.complete
    @test result.plan.sha256 == import_plan_sha256(result.plan)
end

@testset "aimora-project-v1 inert native migration" begin
    text = native_fixture("project_v1.toml")
    parsed = read_aimora_project_v1(text; source_name = "legacy/project.toml")
    @test format_succeeded(parsed)
    result = parsed.value
    assert_native_report_reconciles(result)
    @test result.plan.adapter.source_format == "aimora-project"
    @test result.plan.adapter.source_version == "aimora-project-v1"
    @test result.plan.source_sha256 in result.plan.adapter.fixture_sha256
    @test result.report.source_records == 6
    @test result.report.unsupported_fields == 1
    @test !result.plan.applicable
    table_loss = only(loss for loss in result.report.losses if occursin("table name", loss.description))
    @test table_loss.source.field == "asset_tables.1"
    @test any(item -> item.id == "assumption.project_metadata_dictionary", result.report.assumptions)
    @test any(item -> item.id == "assumption.study_settings_dictionary", result.report.assumptions)
    @test any(item -> item.id == "assumption.project_v1_artifact_identity", result.report.assumptions)
    revision = only(record for record in result.plan.source_records if record.record_type == "revision")
    @test Set(field.name for field in revision.fields) ==
          Set(["id", "parent_id", "created_at", "author", "description"])
    @test revision.span.source_name == "legacy/project.toml"
    @test revision.span.start.line == 12

    repeated = read_aimora_project_v1(text; source_name = "legacy/project.toml")
    @test repeated.value == result
    changed = read_aimora_project_v1(
        replace(text, "Native migration demo" => "Changed migration demo");
        source_name = "legacy/project.toml",
    )
    @test changed.value.plan.source_sha256 != result.plan.source_sha256
    @test changed.value.plan.sha256 != result.plan.sha256

    unknown = read_aimora_project_v1(replace(text, "aimora-project-v1" => "aimora-project-v2"))
    @test !format_succeeded(unknown)
    @test only(unknown.diagnostics).code == :unknown_aimora_project_version
    malformed = read_aimora_project_v1(replace(text, "id = \"demo\"" => "id = [\"demo\"]"))
    @test !format_succeeded(malformed)
    @test only(malformed.diagnostics).code == :invalid_native_field
    duplicate_case = read_aimora_project_v1(text * "\n[[cases]]\nid = \"base\"\nname = \"Duplicate\"\n")
    @test !format_succeeded(duplicate_case)
    @test only(duplicate_case.diagnostics).code == :duplicate_native_identifier
    malformed_parent = read_aimora_project_v1(replace(text, "parent_id = \"r0\"" => "parent_id = 0"))
    @test !format_succeeded(malformed_parent)
    @test only(malformed_parent.diagnostics).code == :invalid_native_field
    syntax = read_aimora_project_v1("format = [\n")
    @test !format_succeeded(syntax)
    @test only(syntax.diagnostics).code == :invalid_aimora_project_v1_toml
end

@testset "current schema-aware AIMORA asset CSV migration" begin
    schema, rules = native_load_csv_contract()
    text = native_fixture("assets.csv")
    parsed = read_aimora_asset_csv(
        text,
        schema,
        "asset.load",
        "load",
        rules;
        source_name = "tables/loads.csv",
    )
    @test format_succeeded(parsed)
    result = parsed.value
    assert_native_report_reconciles(result)
    @test result.plan.adapter.source_format == schema.id
    @test result.plan.adapter.source_version == string(schema.version)
    @test result.plan.source_sha256 in result.plan.adapter.fixture_sha256
    @test result.report.source_records == 2
    @test result.report.source_fields == 8
    @test result.report.ignored_fields == 1
    @test result.plan.applicable
    omitted = only(item for item in result.report.accounting if item.source == ImportSourceFieldRef("record.L2", "note"))
    @test omitted.disposition == ImportIgnored
    @test any(item -> item.id == "assumption.asset_csv_external_schema", result.report.assumptions)
    @test any(item -> item.id == "assumption.asset_csv_empty_missing", result.report.assumptions)
    @test !any(item -> item.id == "assumption.asset_csv_implicit_units", result.report.assumptions)

    implicit_schema = BulkTableSchema(
        "aimora.loads.untyped_units",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("name", BulkString),
            BulkColumnSpec("p_mw", BulkDecimal),
            BulkColumnSpec("note", BulkString; nullable = true),
        ],
        "id",
    )
    implicit = read_aimora_asset_csv(text, implicit_schema, "asset.load", "load", rules)
    @test format_succeeded(implicit)
    @test any(item -> item.id == "assumption.asset_csv_implicit_units", implicit.value.report.assumptions)
    @test implicit.value.plan.adapter.id != result.plan.adapter.id

    changed = read_aimora_asset_csv(replace(text, "8.5" => "8.6"), schema, "asset.load", "load", rules)
    @test changed.value.plan.source_sha256 != result.plan.source_sha256
    @test changed.value.plan.sha256 != result.plan.sha256
    malformed = read_aimora_asset_csv(replace(text, "8.5" => "not-a-number"), schema, "asset.load", "load", rules)
    @test !format_succeeded(malformed)
    @test only(malformed.diagnostics).code == :invalid_bulk_decimal
    width = read_aimora_asset_csv(text * "L3,Too,Few\n", schema, "asset.load", "load", rules)
    @test !format_succeeded(width)
    @test only(width.diagnostics).code == :bulk_row_width_mismatch
    blank_lines = read_aimora_asset_csv(replace(text, "L2," => "\n   \nL2,"), schema, "asset.load", "load", rules)
    @test format_succeeded(blank_lines)
    @test blank_lines.value.report.source_records == 2
    empty = read_aimora_asset_csv("", schema, "asset.load", "load", rules)
    @test format_succeeded(empty)
    @test empty.value.report.source_records == 0
    multiline = read_aimora_asset_csv("id,name,p_mw,note\nL1,\"Main\nLoad\",8.5,note\n", schema, "asset.load", "load", rules)
    @test !format_succeeded(multiline)
    @test only(multiline.diagnostics).code == :unsupported_legacy_csv_multiline
end

@testset "current AIMORACatalogs entry migration" begin
    text = native_fixture("catalog_v1.toml")
    parsed = read_aimora_catalog_entry_v1(text; source_name = "catalogs/generic/line.toml")
    @test format_succeeded(parsed)
    result = parsed.value
    assert_native_report_reconciles(result)
    @test result.plan.adapter.source_version == "aimora-catalog-entry-v1"
    @test result.plan.source_sha256 in result.plan.adapter.fixture_sha256
    @test result.report.source_records == 2
    @test result.report.source_fields == 12
    @test result.plan.applicable
    @test Set(item.id for item in result.report.assumptions) == Set([
        "assumption.catalog_parameter_dictionaries",
        "assumption.catalog_implicit_units",
        "assumption.catalog_missing_lock",
    ])
    entry = only(record for record in result.plan.source_records if record.record_type == "catalog_entry")
    @test any(field -> field.name == "study.emt.unsupported_phenomena", entry.fields)
    @test all(isnothing(field.unit) && isnothing(field.basis) for field in entry.fields)

    changed = read_aimora_catalog_entry_v1(replace(text, "132.0" => "133.0"))
    @test changed.value.plan.source_sha256 != result.plan.source_sha256
    @test changed.value.plan.sha256 != result.plan.sha256
    unknown_field = read_aimora_catalog_entry_v1(replace(text, "licence =" => "extra = \"unknown\"\nlicence ="))
    @test format_succeeded(unknown_field)
    @test unknown_field.value.report.rejected_fields == 1
    @test !unknown_field.value.plan.applicable
    unknown_version = read_aimora_catalog_entry_v1(replace(text, "entry-v1" => "entry-v2"))
    @test !format_succeeded(unknown_version)
    @test only(unknown_version.diagnostics).code == :unknown_aimora_catalog_version
    missing_provenance = read_aimora_catalog_entry_v1(replace(text, "provenance = \"Synthetic native migration fixture\"" => "provenance = \"\""))
    @test !format_succeeded(missing_provenance)
    @test only(missing_provenance.diagnostics).code == :invalid_native_field
end

@testset "current AIMORACases catalogue migration and resource inventory" begin
    text = native_fixture("cases_v2.toml")
    path = "examples/native_demo/run.jl"
    parsed = read_aimora_cases_catalog_v2(
        text;
        source_name = "examples/catalog.toml",
        available_paths = Set([path]),
    )
    @test format_succeeded(parsed)
    result = parsed.value
    assert_native_report_reconciles(result)
    @test result.plan.adapter.source_version == "aimora-examples-v2"
    @test result.plan.source_sha256 in result.plan.adapter.fixture_sha256
    @test result.report.source_records == 2
    @test result.report.source_fields == 10
    @test result.plan.applicable
    @test !any(item -> item.id == "assumption.case_resource_inventory_unavailable", result.report.assumptions)
    @test any(item -> item.id == "assumption.case_catalog_missing_hashes", result.report.assumptions)

    unverified = read_aimora_cases_catalog_v2(text)
    @test format_succeeded(unverified)
    @test unverified.value.plan.applicable
    @test any(item -> item.id == "assumption.case_resource_inventory_unavailable", unverified.value.report.assumptions)
    missing = read_aimora_cases_catalog_v2(text; available_paths = Set{String}())
    @test format_succeeded(missing)
    @test missing.value.report.rejected_fields == 2
    @test length(missing.value.report.losses) == 2
    @test !missing.value.plan.applicable

    changed = read_aimora_cases_catalog_v2(replace(text, "Inert native" => "Changed native"); available_paths = Set([path]))
    @test changed.value.plan.source_sha256 != result.plan.source_sha256
    @test changed.value.plan.sha256 != result.plan.sha256
    unsafe = read_aimora_cases_catalog_v2(replace(text, path => "../run.jl"))
    @test format_succeeded(unsafe)
    @test unsafe.value.report.rejected_fields == 2
    malformed = read_aimora_cases_catalog_v2(replace(text, "requires_solver = false" => "requires_solver = \"false\""))
    @test !format_succeeded(malformed)
    @test only(malformed.diagnostics).code == :invalid_native_field
    unknown_version = read_aimora_cases_catalog_v2(replace(text, "aimora-examples-v2" => "aimora-examples-v3"))
    @test !format_succeeded(unknown_version)
    @test only(unknown_version.diagnostics).code == :unknown_aimora_cases_version
end

@testset "public native migration example" begin
    example_results = include(joinpath(@__DIR__, "..", "examples", "native_migrations.jl"))
    @test all(format_succeeded, example_results)
    @test all(result -> result.value.plan.sha256 == import_plan_sha256(result.value.plan), example_results)
end
