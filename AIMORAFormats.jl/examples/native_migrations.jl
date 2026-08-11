using AIMORAFormats

function run_native_migration_example()
    project = read_aimora_project_v1("""
format = "aimora-project-v1"
[project]
id = "example"
name = "Legacy project"
"""; source_name = "project.toml")

    table_schema = BulkTableSchema(
        "aimora.example.loads",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("p_mw", BulkDecimal; unit = "MW"),
        ],
        "id",
    )
    table_rules = [
        ImportFieldRule("id", ImportMapped; destination = FormatPath("id")),
        ImportFieldRule("p_mw", ImportMapped; destination = FormatPath("common", "p_set")),
    ]
    assets = read_aimora_asset_csv(
        "id,p_mw\nL1,8.5\n",
        table_schema,
        "asset.load",
        "load",
        table_rules;
        source_name = "loads.csv",
    )

    catalog = read_aimora_catalog_entry_v1("""
schema = "aimora-catalog-entry-v1"
id = "example_load"
equipment_class = "load"
manufacturer = ""
model = "Example load"
provenance = "Synthetic public example"
licence = "PolyForm-Noncommercial-1.0.0"
[common]
rated_power_mw = 10.0
[study.power_flow]
model = "constant_power"
"""; source_name = "catalog.toml")

    cases = read_aimora_cases_catalog_v2("""
schema = "aimora-examples-v2"
[[case]]
id = "example_case"
study = "core"
path = "examples/example/run.jl"
entrypoint = "examples/example/run.jl"
description = "Public inert migration example."
requires_solver = false
reference_compatible = false
result_kind = "catalog"
""";
        source_name = "examples/catalog.toml",
        available_paths = Set(["examples/example/run.jl"]),
    )

    results = (project = project, assets = assets, catalog = catalog, cases = cases)
    all(format_succeeded, results) || error("native migration example failed")
    for (name, result) in pairs(results)
        println(name, ": ", result.value.report.source_records, " records, plan ", result.value.plan.sha256)
    end
    return results
end

run_native_migration_example()
