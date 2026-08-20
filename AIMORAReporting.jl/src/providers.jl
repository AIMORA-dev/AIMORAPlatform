const _REPORT_PROVIDERS = Dict{Symbol,Function}()

const _PROVIDER_REQUIRED_ROLES = Dict{Symbol,Vector{String}}(
    :emt => ["executive-summary", "study-definition", "method", "results", "quality", "limitations", "provenance"],
    :line_constants => ["executive-summary", "geometry", "results", "quality", "limitations", "provenance"],
    :cable_constants => ["executive-summary", "geometry", "results", "quality", "limitations", "provenance"],
    :transformer_parameters => ["executive-summary", "test-data", "results", "quality", "limitations", "provenance"],
    :validation => ["executive-summary", "study-definition", "results", "quality", "limitations", "provenance"],
    :combined => ["executive-summary", "dependency-graph", "study-comparison", "consolidated-findings", "limitations", "provenance"],
)

function register_provider!(family::Symbol, provider::Function; replace = false)
    if haskey(_REPORT_PROVIDERS, family) && !replace
        throw(ArgumentError("a report provider is already registered for $family"))
    end
    _REPORT_PROVIDERS[family] = provider
    return family
end

available_providers() = sort!(collect(keys(_REPORT_PROVIDERS)); by = string)
required_section_roles(family::Symbol) = copy(get(_PROVIDER_REQUIRED_ROLES, family, String[]))

_payload_get(payload::AbstractDict, key::AbstractString, default) =
    haskey(payload, key) ? payload[key] : haskey(payload, Symbol(key)) ? payload[Symbol(key)] : default
_payload_get(payload::NamedTuple, key::AbstractString, default) =
    hasproperty(payload, Symbol(key)) ? getproperty(payload, Symbol(key)) : default
_payload_get(payload, key::AbstractString, default) = default

function _text_list(value)
    value === nothing && return String[]
    value isa AbstractString && return [String(value)]
    return String.(collect(value))
end

function _pairs(value)
    value isa AbstractDict && return Pair{String,Any}[String(key) => item for (key, item) in value]
    value isa NamedTuple && return Pair{String,Any}[String(key) => getproperty(value, key) for key in keys(value)]
    value isa AbstractVector{<:Pair} && return Pair{String,Any}[String(first(item)) => last(item) for item in value]
    return Pair{String,Any}[]
end

function _binding_provenance(binding::ResultBinding)
    return Pair{String,Any}[
        "project_id" => binding.project_id,
        "project_revision" => binding.project_revision,
        "scenario_id" => binding.scenario_id,
        "study_id" => binding.study_id,
        "study_family" => binding.study_family,
        "result_id" => binding.result_id,
        "result_schema" => binding.result_schema,
        "solver_revision" => binding.solver_revision,
        "payload_hash" => binding.payload_hash,
        "upstream_hashes" => binding.upstream_hashes,
        "units_base" => binding.units_base,
    ]
end

function _normalise_tables(value)
    value === nothing && return ReportTable[]
    value isa ReportTable && return [value]
    tables = ReportTable[]
    for (index, item) in enumerate(value)
        if item isa ReportTable
            push!(tables, item)
        elseif item isa AbstractDict || item isa NamedTuple
            columns = _payload_get(item, "columns", String[])
            rows = _payload_get(item, "rows", Vector{Any}[])
            push!(
                tables,
                ReportTable(
                    _payload_get(item, "id", "table-$index"),
                    _payload_get(item, "title", "Result table $index"),
                    columns,
                    rows;
                    units = _payload_get(item, "units", fill("", length(columns))),
                    notes = _text_list(_payload_get(item, "notes", String[])),
                    source_ids = _text_list(_payload_get(item, "source_ids", String[])),
                ),
            )
        end
    end
    return tables
end

function _normalise_figures(value)
    value === nothing && return FigureBlock[]
    value isa FigureBlock && return [value]
    return FigureBlock[item for item in value if item isa FigureBlock]
end

function _study_provider(family::Symbol, metadata, bindings, payload; dependencies = Dict{String,Vector{String}}())
    isempty(bindings) && throw(ArgumentError("a report requires at least one immutable result binding"))
    summary = String(_payload_get(payload, "summary", "No executive summary was supplied."))
    method = String(_payload_get(payload, "method", "The calculation method is recorded by the bound typed result."))
    assumptions = _text_list(_payload_get(payload, "assumptions", bindings[1].assumptions))
    limitations = _text_list(_payload_get(payload, "limitations", bindings[1].validity_domain))
    inputs = _pairs(_payload_get(payload, "inputs", Pair{String,Any}[]))
    quality = _pairs(_payload_get(payload, "quality", Pair{String,Any}[]))
    findings = _text_list(_payload_get(payload, "findings", String[]))
    tables = _normalise_tables(_payload_get(payload, "tables", ReportTable[]))
    figures = _normalise_figures(_payload_get(payload, "figures", FigureBlock[]))

    sections = ReportSection[
        ReportSection(
            "section-executive-summary",
            "executive-summary",
            "Executive summary",
            [NarrativeBlock("summary", "Summary", summary)],
        ),
        ReportSection(
            "section-study-definition",
            family in (:line_constants, :cable_constants) ? "geometry" :
                family == :transformer_parameters ? "test-data" : "study-definition",
            family in (:line_constants, :cable_constants) ? "Geometry and study definition" :
                family == :transformer_parameters ? "Test data and study definition" : "Study definition",
            [KeyValueBlock("study-inputs", "Inputs", inputs)],
        ),
        ReportSection(
            "section-method",
            "method",
            "Method",
            [NarrativeBlock("method", "Method", method)],
        ),
        ReportSection(
            "section-results",
            "results",
            "Results",
            AbstractReportBlock[vcat(tables, figures)...],
        ),
        ReportSection(
            "section-quality",
            "quality",
            "Numerical quality and checks",
            [KeyValueBlock("quality-metrics", "Quality metrics", quality)],
        ),
        ReportSection(
            "section-findings",
            "findings",
            "Findings",
            [NarrativeBlock("findings", "Findings", isempty(findings) ? "No findings were supplied." : join("• " .* findings, "\n"))],
        ),
        ReportSection(
            "section-limitations",
            "limitations",
            "Assumptions and limitations",
            [
                NarrativeBlock("assumptions", "Assumptions", isempty(assumptions) ? "None declared." : join("• " .* assumptions, "\n")),
                NarrativeBlock("limitations", "Limitations", isempty(limitations) ? "None declared." : join("• " .* limitations, "\n")),
            ],
        ),
        ReportSection(
            "section-provenance",
            "provenance",
            "Traceability and provenance",
            [KeyValueBlock("result-binding-$index", "Bound result $index", _binding_provenance(binding)) for (index, binding) in enumerate(bindings)],
        ),
    ]

    return ReportDocument(
        _payload_get(payload, "report_id", "$(family)-report"),
        metadata,
        bindings,
        sections;
        revision = Int(_payload_get(payload, "revision", 1)),
        dependencies = dependencies,
    )
end

function _combined_provider(metadata, bindings, payload; dependencies = Dict{String,Vector{String}}())
    isempty(bindings) && throw(ArgumentError("a combined report requires bound upstream results"))
    dependency_rows = Vector{Any}[]
    for result_id in sort!(collect(keys(dependencies)))
        parents = dependencies[result_id]
        push!(dependency_rows, Any[result_id, join(parents, ", ")])
    end
    comparison_tables = _normalise_tables(_payload_get(payload, "tables", ReportTable[]))
    sections = ReportSection[
        ReportSection(
            "section-executive-summary",
            "executive-summary",
            "Executive summary",
            [NarrativeBlock("summary", "Summary", String(_payload_get(payload, "summary", "Combined AIMORA study report.")))],
        ),
        ReportSection(
            "section-dependency-graph",
            "dependency-graph",
            "Calculation dependency graph",
            [ReportTable("dependency-dag", "Result dependencies", ["result_id", "upstream_result_ids"], dependency_rows; units = ["", ""])],
        ),
        ReportSection(
            "section-study-comparison",
            "study-comparison",
            "Study comparison",
            AbstractReportBlock[comparison_tables...],
        ),
        ReportSection(
            "section-consolidated-findings",
            "consolidated-findings",
            "Consolidated findings",
            [NarrativeBlock("findings", "Findings", join("• " .* _text_list(_payload_get(payload, "findings", ["No consolidated findings were supplied."])), "\n"))],
        ),
        ReportSection(
            "section-limitations",
            "limitations",
            "Representation and domain limitations",
            [NarrativeBlock("limitations", "Limitations", join("• " .* _text_list(_payload_get(payload, "limitations", ["No combined-study limitations were supplied."])), "\n"))],
        ),
        ReportSection(
            "section-provenance",
            "provenance",
            "Traceability and provenance",
            [KeyValueBlock("result-binding-$index", "Bound result $index", _binding_provenance(binding)) for (index, binding) in enumerate(bindings)],
        ),
    ]
    return ReportDocument(
        _payload_get(payload, "report_id", "combined-report"),
        metadata,
        bindings,
        sections;
        revision = Int(_payload_get(payload, "revision", 1)),
        dependencies = dependencies,
    )
end

function build_report(
    family::Symbol,
    metadata::ReportMetadata,
    bindings::AbstractVector{<:ResultBinding},
    payload;
    dependencies = Dict{String,Vector{String}}(),
)
    provider = get(_REPORT_PROVIDERS, family, nothing)
    isnothing(provider) && throw(ArgumentError("no report provider is registered for $family"))
    report = provider(metadata, bindings, payload; dependencies = dependencies)
    issues = qa_report(report; required_roles = required_section_roles(family)).issues
    blocking = filter(issue -> issue.severity in (:error, :fatal), issues)
    isempty(blocking) || throw(ArgumentError("report provider produced an invalid semantic report: " * join(issue.message for issue in blocking, "; ")))
    return report
end

function _register_default_providers!()
    for family in (:emt, :line_constants, :cable_constants, :transformer_parameters, :validation)
        _REPORT_PROVIDERS[family] = (metadata, bindings, payload; dependencies = Dict{String,Vector{String}}()) ->
            _study_provider(family, metadata, bindings, payload; dependencies = dependencies)
    end
    _REPORT_PROVIDERS[:combined] = _combined_provider
    return nothing
end
