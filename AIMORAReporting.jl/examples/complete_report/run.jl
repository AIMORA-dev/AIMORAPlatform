#!/usr/bin/env julia

using Dates
using AIMORAReporting

output_directory = isempty(ARGS) ? joinpath(@__DIR__, "outputs") : abspath(first(ARGS))

result_payload = Dict(
    "time_s" => collect(range(0.0, 0.01; length = 1001)),
    "voltage_pu" => [1 - exp(-500t) * cos(4000t) for t in range(0.0, 0.01; length = 1001)],
)

binding = ResultBinding(
    project_id = "public-reporting-example",
    project_revision = "project@1",
    scenario_id = "rlc-energization",
    study_id = "emt-reporting-example",
    study_family = :emt,
    result_id = "emt-result-reporting-example",
    solver_revision = "public-fixture@1",
    payload_hash = hash_payload(result_payload),
    units_base = "SI and per unit",
    assumptions = ["Ideal lumped RLC components", "Manufactured deterministic result fixture"],
    validity_domain = ["Reporting demonstration; not a new solver-validation claim"],
)

metadata = ReportMetadata(
    title = "AIMORA Complete Reporting Example",
    subtitle = "Semantic result binding, QA, review, freeze, and deterministic publication",
    report_number = "AIMORA-REPORT-EXAMPLE-001",
    revision_label = "D1",
    confidentiality = :public,
    prepared_by = ["AIMORA Reporting Example"],
    checked_by = ["Automated semantic QA"],
    organization = "AIMORA",
    issued_at = DateTime(2026, 8, 20),
    tags = ["reporting", "emt", "public-example"],
)

time_s = result_payload["time_s"]
voltage_pu = result_payload["voltage_pu"]
series = PlotSeries(
    "capacitor-voltage",
    "Capacitor voltage",
    time_s,
    voltage_pu;
    x_unit = "s",
    y_unit = "pu",
    source_hash = binding.payload_hash,
    event_indices = [1],
    style_key = "solid",
)
figure = FigureBlock(
    "capacitor-voltage-waveform",
    "Manufactured capacitor-voltage waveform used to exercise the reporting pipeline.",
    "A damped oscillatory voltage starts at zero and approaches one per unit.",
    PlotSpec(
        "capacitor-voltage-plot",
        "Capacitor voltage",
        AxisSpec("Time"; unit = "s"),
        AxisSpec("Voltage"; unit = "pu"),
        [series],
        annotations = [0.0 => "energization"],
        transforms = ["none; full-resolution public fixture"],
    );
    source_ids = [binding.result_id],
)

table = ReportTable(
    "key-results",
    "Key result metrics",
    ["metric", "value", "unit"],
    [
        ["samples", length(time_s), "count"],
        ["duration", last(time_s), "s"],
        ["maximum_absolute_voltage", maximum(abs, voltage_pu), "pu"],
    ];
    column_types = [String, Real, String],
    units = ["", "", ""],
    notes = ["Values are preserved as typed data and exported to CSV."],
    source_ids = [binding.result_id],
)

report = build_report(
    :emt,
    metadata,
    [binding],
    Dict(
        "report_id" => "complete-reporting-example",
        "summary" => "This public fixture demonstrates the complete AIMORA semantic reporting lifecycle without reading private solver memory.",
        "inputs" => Dict("duration_s" => last(time_s), "samples" => length(time_s), "units_base" => binding.units_base),
        "method" => "A deterministic manufactured trace is bound as an immutable typed result, checked by semantic QA, reviewed, approved, frozen, and rendered to portable formats.",
        "tables" => [table],
        "figures" => [figure],
        "quality" => Dict("finite_values" => true, "event_samples_preserved" => true, "source_hash_bound" => true),
        "findings" => [
            "All report content is derived from the immutable result binding.",
            "The same semantic document is rendered to Markdown, HTML, text, JSON, TeX, CSV, SVG, and TikZ.",
        ],
        "limitations" => [
            "The trace is manufactured to test reporting behavior and is not an additional numerical-solver qualification claim.",
            "PDF output requires an explicitly available locked Tectonic toolchain.",
        ],
    ),
)

quality = qa_report(report; required_roles = required_section_roles(:emt))
ispassing(quality) || error("semantic report QA failed")
submit_for_review!(report)
comment = add_comment!(report, "summary", "Example reviewer", "Confirm the public claim boundary"; severity = :warning)
resolve_comment!(report, comment.id, "The limitation section explicitly states the manufactured-fixture boundary")
approve!(report, "Example approver"; timestamp = DateTime(2026, 8, 20))
freeze!(report)
manifest = render_bundle(report, output_directory; generated_at = DateTime(2026, 8, 20))

println("Report: ", report.id)
println("Content hash: ", manifest.report_hash)
println("Artifacts: ", length(manifest.artifacts))
println("Output: ", output_directory)
