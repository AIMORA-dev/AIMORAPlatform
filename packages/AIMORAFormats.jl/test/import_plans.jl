function generic_import_fixture()
    schema = BulkTableSchema(
        "generic.loads",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("name", BulkString),
            BulkColumnSpec("p_mw", BulkDecimal; unit = "MW"),
            BulkColumnSpec("note", BulkString; nullable = true),
            BulkColumnSpec("vendor", BulkString),
            BulkColumnSpec("legacy_code", BulkInteger),
        ],
        "id",
    )
    text = """id,name,p_mw,note,vendor,legacy_code
L1,Main Load,8.5,measured,Example,41
L2,Backup Load,2.0,\\N,Example,42
"""
    parsed = parse_delimited_table(text, schema; source_name = "loads.csv")
    @test format_succeeded(parsed)
    adapter = ImportAdapterIdentity(
        "aimora.generic.loads",
        v"1.0.0",
        "generic.loads",
        "1.0.0",
        [repeat("a", 64)],
    )
    rules = [
        ImportFieldRule("id", ImportMapped; destination = FormatPath("id")),
        ImportFieldRule("name", ImportMapped; destination = FormatPath("common", "name")),
        ImportFieldRule("p_mw", ImportMapped; destination = FormatPath("common", "p_set")),
        ImportFieldRule(
            "note",
            ImportMapped;
            destination = FormatPath("metadata", "note"),
            null_operation = ImportOmitNull,
        ),
        ImportFieldRule(
            "vendor",
            ImportIgnored;
            justification = "manufacturer label is retained in the original source only",
        ),
        ImportFieldRule(
            "legacy_code",
            ImportUnsupported;
            justification = "legacy code has no admitted canonical meaning",
        ),
    ]
    return parsed.value, adapter, rules
end

@testset "typed generic import plan and complete field accounting" begin
    parsed, adapter, rules = generic_import_fixture()
    assumption = ImportAssumption(
        "assumption.load_sign",
        "positive imported power denotes consumption",
        "source sign is retained as positive load demand",
    )
    compiled = compile_generic_table_import(
        parsed,
        adapter,
        "asset.load",
        "load",
        rules;
        assumptions = [assumption],
    )
    @test format_succeeded(compiled)
    result = compiled.value
    plan = result.plan
    report = result.report
    @test plan.adapter == adapter
    @test plan.source_sha256 == parsed.source.provenance.content_sha256
    @test length(plan.source_records) == 2
    @test getfield.(collect(plan.source_records), :raw_identifier) == ["L1", "L2"]
    @test all(record.source_name == "loads.csv" for record in plan.source_records)
    @test plan.source_records[1].span.start.line == 2
    @test plan.source_records[2].span.start.line == 3
    @test plan.source_records[1].fields[3].unit == "MW"
    @test length(plan.operations) == 7
    @test !plan.applicable
    @test plan.operations[1] == ImportCreateObject("load.L1", "asset.load", "record.L1")
    @test plan.operations[2] isa ImportFieldAssignment
    @test plan.operations[2].source == ImportSourceFieldRef("record.L1", "name")
    @test plan.operations[2].destination == FormatPath("common", "name")
    @test plan.operations[2].value.span.start.line == 2
    @test plan.sha256 == import_plan_sha256(plan)
    @test occursin(r"^[0-9a-f]{64}$", plan.sha256)

    @test report.source_records == 2
    @test report.source_fields == 12
    @test report.mapped_fields == 7
    @test report.ignored_fields == 3
    @test report.unsupported_fields == 2
    @test report.rejected_fields == 0
    @test report.operations == 7
    @test !report.complete
    @test report.source_fields ==
          report.mapped_fields + report.ignored_fields +
          report.unsupported_fields + report.rejected_fields
    @test length(report.accounting) == 12
    @test length(report.assumptions) == 1
    @test only(report.assumptions) == assumption
    @test length(report.losses) == 2
    @test all(loss.source.field == "legacy_code" for loss in report.losses)
    omitted = only(
        item for item in report.accounting
        if item.source == ImportSourceFieldRef("record.L2", "note")
    )
    @test omitted.disposition == ImportIgnored
    @test occursin("explicit null", omitted.justification)
    unsupported = only(
        item for item in report.accounting
        if item.source == ImportSourceFieldRef("record.L1", "legacy_code")
    )
    @test unsupported.span.source_name == "loads.csv"
    @test unsupported.span.start.line == 2

    repeated = compile_generic_table_import(
        parsed,
        adapter,
        "asset.load",
        "load",
        rules;
        assumptions = [assumption],
    )
    @test repeated.value == result
    @test repeated.value.plan.sha256 == plan.sha256
end

@testset "registered import adapter declarations require exact evidence ownership" begin
    _, adapter, _ = generic_import_fixture()
    other = ImportAdapterIdentity(
        "aimora.generic.branches",
        v"1.1.0",
        "generic.branches",
        "2.0.0",
        [repeat("c", 64), repeat("b", 64)],
    )
    registry = ImportAdapterRegistry([other, adapter])
    @test registry.adapters[1] == other
    @test registry.adapters[2] == adapter
    @test collect(other.fixture_sha256) == [repeat("b", 64), repeat("c", 64)]
    @test registry == ImportAdapterRegistry([adapter, other])

    @test_throws ArgumentError ImportAdapterIdentity(
        "bad adapter",
        v"1.0.0",
        "generic.loads",
        "1.0.0",
        [repeat("a", 64)],
    )
    @test_throws ArgumentError ImportAdapterIdentity(
        "adapter.valid",
        v"1.0.0",
        "generic.loads",
        "latest version",
        [repeat("a", 64)],
    )
    @test_throws ArgumentError ImportAdapterIdentity(
        "adapter.valid",
        v"1.0.0",
        "generic.loads",
        "1.0.0",
        String[],
    )
    @test_throws ArgumentError ImportAdapterIdentity(
        "adapter.valid",
        v"1.0.0",
        "generic.loads",
        "1.0.0",
        [repeat("A", 64)],
    )
    @test_throws ArgumentError ImportAdapterRegistry([adapter, adapter])
end

@testset "generic import rejects incomplete and ambiguous mapping declarations" begin
    parsed, adapter, rules = generic_import_fixture()
    cases = [
        (
            rules[1:(end - 1)],
            adapter,
            "asset.load",
            "load",
            ImportAssumption[],
            :missing_import_field_rule,
        ),
        (
            vcat(rules, [ImportFieldRule("unknown", ImportIgnored; justification = "not present")]),
            adapter,
            "asset.load",
            "load",
            ImportAssumption[],
            :unknown_import_field_rule,
        ),
        (
            vcat(rules, [rules[1]]),
            adapter,
            "asset.load",
            "load",
            ImportAssumption[],
            :duplicate_import_field_rule,
        ),
        (rules, adapter, "bad type", "load", ImportAssumption[], :invalid_import_object_type),
        (rules, adapter, "asset.load", "bad namespace", ImportAssumption[], :invalid_import_namespace),
        (
            rules,
            ImportAdapterIdentity(
                "other.adapter",
                v"1.0.0",
                "generic.other",
                "1.0.0",
                [repeat("d", 64)],
            ),
            "asset.load",
            "load",
            ImportAssumption[],
            :import_adapter_source_mismatch,
        ),
        (
            [
                ImportFieldRule(
                    rule.source_field,
                    rule.source_field == "id" ? ImportIgnored : rule.disposition;
                    destination = rule.source_field == "id" ? nothing : rule.destination,
                    justification = rule.source_field == "id" ? "identity discarded" : rule.justification,
                    null_operation = rule.null_operation,
                ) for rule in rules
            ],
            adapter,
            "asset.load",
            "load",
            ImportAssumption[],
            :import_identity_mapping_required,
        ),
        (
            [
                rule.source_field == "p_mw" ?
                    ImportFieldRule("p_mw", ImportMapped; destination = FormatPath("common", "name")) :
                    rule
                for rule in rules
            ],
            adapter,
            "asset.load",
            "load",
            ImportAssumption[],
            :ambiguous_import_destination,
        ),
    ]
    duplicate_assumption = ImportAssumption("same", "description", "consequence")
    push!(cases, (
        rules,
        adapter,
        "asset.load",
        "load",
        [duplicate_assumption, duplicate_assumption],
        :duplicate_import_assumption,
    ))
    for (case_rules, case_adapter, object_type, namespace, assumptions, code) in cases
        result = compile_generic_table_import(
            parsed,
            case_adapter,
            object_type,
            namespace,
            case_rules;
            assumptions,
        )
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
        @test only(result.diagnostics).span.source_name == "loads.csv"
    end

    @test_throws ArgumentError ImportFieldRule("name", ImportMapped)
    @test_throws ArgumentError ImportFieldRule(
        "name",
        ImportIgnored;
        destination = FormatPath("common", "name"),
        justification = "conflicting declaration",
    )
    @test_throws ArgumentError ImportFieldRule("name", ImportUnsupported)
end

@testset "rejected fields and empty generic sources remain reportable" begin
    parsed, adapter, rules = generic_import_fixture()
    rejected_rules = [
        rule.source_field == "legacy_code" ?
            ImportFieldRule(
                "legacy_code",
                ImportRejected;
                justification = "legacy code is prohibited by the destination policy",
            ) : rule
        for rule in rules
    ]
    rejected = compile_generic_table_import(
        parsed,
        adapter,
        "asset.load",
        "load",
        rejected_rules,
    )
    @test format_succeeded(rejected)
    @test rejected.value.report.rejected_fields == 2
    @test rejected.value.report.unsupported_fields == 0
    @test !rejected.value.report.complete
    @test !rejected.value.plan.applicable
    @test length(rejected.value.report.losses) == 2

    schema = parsed.table.schema
    empty_source = source_document(
        "id,name,p_mw,note,vendor,legacy_code\n";
        source_name = "empty.csv",
    ).value
    empty_table = ParsedBulkTable(empty_source, BulkTable(schema, BulkRow[]))
    empty_result = compile_generic_table_import(
        empty_table,
        adapter,
        "asset.load",
        "load",
        rules,
    )
    @test format_succeeded(empty_result)
    @test empty_result.value.report.source_records == 0
    @test empty_result.value.report.source_fields == 0
    @test empty_result.value.report.operations == 0
    @test empty_result.value.report.complete
    @test empty_result.value.plan.applicable
    @test empty_result.value.plan.sha256 == import_plan_sha256(empty_result.value.plan)
end

record_format_conformance!(:generic_imports)
