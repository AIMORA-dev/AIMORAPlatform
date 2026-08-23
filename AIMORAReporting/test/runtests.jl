using Test
using Dates
using AIMORAReporting

function sample_binding(; result_id = "result-emt-001", family = :emt, upstream = String[])
    payload = Dict("result_id" => result_id, "values" => [0.0, 1.0, 0.5])
    return ResultBinding(
        project_id = "project-001",
        project_revision = "project@42",
        scenario_id = "scenario-energization",
        study_id = "study-$result_id",
        study_family = family,
        result_id = result_id,
        solver_revision = "solver@abc123",
        payload_hash = hash_payload(payload),
        upstream_hashes = upstream,
        units_base = "SI and per unit",
        assumptions = ["Accepted test assumption"],
        validity_domain = ["Public deterministic fixture"],
    )
end

function sample_metadata()
    return ReportMetadata(
        title = "AIMORA Reporting Test",
        report_number = "TEST-001",
        revision_label = "D1",
        prepared_by = ["Test Engineer"],
        issued_at = DateTime(2026, 8, 20),
    )
end

function sample_report()
    binding = sample_binding()
    x = collect(range(0.0, 0.01; length = 101))
    y = 1 .- exp.(-500 .* x) .* cos.(4000 .* x)
    series = PlotSeries(
        "series-voltage",
        "Voltage",
        x,
        y;
        x_unit = "s",
        y_unit = "pu",
        source_hash = binding.payload_hash,
        event_indices = [1, 51],
        style_key = "solid",
    )
    figure = FigureBlock(
        "figure-voltage",
        "Voltage transient from the bound result.",
        "Voltage starts at zero and approaches a damped steady value.",
        PlotSpec(
            "plot-voltage",
            "Voltage transient",
            AxisSpec("Time"; unit = "s"),
            AxisSpec("Voltage"; unit = "pu"),
            [series],
        );
        source_ids = [binding.result_id],
    )
    table = ReportTable(
        "table-summary",
        "Summary values",
        ["quantity", "value"],
        [["peak_voltage", maximum(y)], ["samples", length(y)]];
        units = ["", "pu or count"],
        source_ids = [binding.result_id],
    )
    return build_report(
        :emt,
        sample_metadata(),
        [binding],
        Dict(
            "report_id" => "report-test-001",
            "summary" => "A deterministic reporting fixture.",
            "inputs" => Dict("duration_s" => 0.01, "samples" => length(x)),
            "method" => "Manufactured fixed-step trace.",
            "tables" => [table],
            "figures" => [figure],
            "quality" => Dict("finite" => true, "events_preserved" => true),
            "findings" => ["The report is generated from typed result data."],
            "limitations" => ["This is a manufactured reporting fixture."],
        ),
    )
end

@testset "canonical result binding" begin
    binding = sample_binding()
    @test length(binding.payload_hash) == 64
    @test hash_payload(Dict("b" => 2, "a" => 1)) == hash_payload(Dict("a" => 1, "b" => 2))
    @test occursin("project-001", canonical_json(binding))
end

@testset "provider and semantic QA" begin
    report = sample_report()
    quality = qa_report(report; required_roles = required_section_roles(:emt))
    @test ispassing(quality)
    @test isempty(filter(issue -> issue.severity in (:error, :fatal), quality.issues))
    @test :emt in available_providers()
    @test_throws ArgumentError build_report(:power_flow, sample_metadata(), [sample_binding()], Dict())
end

@testset "event-preserving sampling" begin
    x = collect(1.0:1000.0)
    y = sin.(x ./ 20)
    y[500] = 25.0
    indices = event_preserving_indices(x, y, 50; events = [500])
    @test 1 in indices
    @test 1000 in indices
    @test all(index -> index in indices, (499, 500, 501))
    @test 500 in indices
    @test issorted(indices)
end

@testset "QA refuses invalid numerical presentation" begin
    report = sample_report()
    bad = PlotSeries(
        "bad-series",
        "Bad",
        [0.0, 1.0],
        [1.0, NaN];
        x_unit = "s",
        y_unit = "pu",
        source_hash = report.bindings[1].payload_hash,
    )
    bad_figure = FigureBlock(
        "bad-figure",
        "Bad figure",
        "Contains a non-finite value.",
        PlotSpec("bad-plot", "Bad", AxisSpec("x"; unit = "s"), AxisSpec("y"; unit = "pu", scale = :log10), [bad]),
    )
    push!(report.sections[4].blocks, bad_figure)
    quality = qa_report(report)
    @test !ispassing(quality)
    @test :nonfinite_value in getfield.(quality.issues, :code)
    @test :invalid_log_domain in getfield.(quality.issues, :code)
end

@testset "review, approval, freeze, and correction" begin
    report = sample_report()
    submit_for_review!(report)
    comment = add_comment!(report, "summary", "Reviewer", "Clarify the summary"; severity = :warning)
    resolve_comment!(report, comment.id, "Summary confirmed")
    approval = approve!(report, "Approver"; timestamp = DateTime(2026, 8, 20))
    @test approval.report_hash == content_hash(report)
    frozen_hash = freeze!(report)
    @test verify_frozen(report)
    @test frozen_hash == content_hash(report)
    correction = revised_copy(report; new_id = "report-test-002", revision_label = "R2")
    @test correction.state == :draft
    @test correction.supersedes == report.id
    supersede!(report, correction)
    @test report.state == :superseded
end

@testset "deterministic render bundle" begin
    report = sample_report()
    submit_for_review!(report)
    approve!(report, "Approver"; timestamp = DateTime(2026, 8, 20))
    freeze!(report)
    mktempdir() do first
        mktempdir() do second
            manifest_a = render_bundle(report, first; generated_at = DateTime(2026, 8, 20))
            manifest_b = render_bundle(report, second; generated_at = DateTime(2026, 8, 20))
            @test manifest_a.report_hash == manifest_b.report_hash
            @test manifest_a.artifacts == manifest_b.artifacts
            @test read(joinpath(first, "report.json"), String) == read(joinpath(second, "report.json"), String)
            @test read(joinpath(first, "report.md"), String) == read(joinpath(second, "report.md"), String)
            @test isfile(joinpath(first, "figures", "figure-voltage.svg"))
            @test isfile(joinpath(first, "data", "table-summary.csv"))
            @test isfile(joinpath(first, "manifest.toml"))
        end
    end
end

@testset "template validation" begin
    mktempdir() do directory
        path = joinpath(directory, "template.toml")
        write(
            path,
            """
            id = "engineering-standard"
            version = "1.0.0"
            licence = "PolyForm-Noncommercial-1.0.0"
            family = "engineering"
            supported_studies = ["emt", "line_constants"]
            required_roles = ["executive-summary", "results", "provenance"]
            output_profiles = ["markdown", "html", "tex"]
            """,
        )
        template = load_template(path; trusted = true)
        @test isempty(validate_template(template))
        @test length(template_hash(template)) == 64
    end
end
