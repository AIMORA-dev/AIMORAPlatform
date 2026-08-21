const REPORT_SCHEMA_VERSION = v"1.0.0"

const _REPORT_STATES = Set((:draft, :review, :approved, :frozen, :superseded, :withdrawn))
const _QA_SEVERITIES = Set((:info, :warning, :error, :fatal))

abstract type AbstractReportBlock end

"""Immutable identity and provenance binding for one typed study result."""
struct ResultBinding
    project_id::String
    project_revision::String
    scenario_id::String
    study_id::String
    study_family::Symbol
    result_id::String
    result_schema::VersionNumber
    solver_revision::String
    payload_hash::String
    upstream_hashes::Vector{String}
    units_base::String
    assumptions::Vector{String}
    validity_domain::Vector{String}
    warnings::Vector{String}
end

function ResultBinding(;
    project_id,
    project_revision,
    scenario_id,
    study_id,
    study_family,
    result_id,
    result_schema = v"1.0.0",
    solver_revision,
    payload_hash,
    upstream_hashes = String[],
    units_base = "SI",
    assumptions = String[],
    validity_domain = String[],
    warnings = String[],
)
    isempty(strip(String(project_id))) && throw(ArgumentError("project_id must not be empty"))
    isempty(strip(String(result_id))) && throw(ArgumentError("result_id must not be empty"))
    return ResultBinding(
        String(project_id),
        String(project_revision),
        String(scenario_id),
        String(study_id),
        Symbol(study_family),
        String(result_id),
        result_schema isa VersionNumber ? result_schema : VersionNumber(result_schema),
        String(solver_revision),
        lowercase(String(payload_hash)),
        String.(upstream_hashes),
        String(units_base),
        String.(assumptions),
        String.(validity_domain),
        String.(warnings),
    )
end

"""Document-control metadata independent of any renderer."""
struct ReportMetadata
    title::String
    subtitle::String
    report_number::String
    revision_label::String
    confidentiality::Symbol
    prepared_by::Vector{String}
    checked_by::Vector{String}
    approved_by::Vector{String}
    organization::String
    client::String
    issued_at::DateTime
    language::String
    tags::Vector{String}
end

function ReportMetadata(;
    title,
    subtitle = "",
    report_number = "",
    revision_label = "DRAFT",
    confidentiality = :internal,
    prepared_by = String[],
    checked_by = String[],
    approved_by = String[],
    organization = "",
    client = "",
    issued_at = DateTime(1970, 1, 1),
    language = "en",
    tags = String[],
)
    isempty(strip(String(title))) && throw(ArgumentError("report title must not be empty"))
    return ReportMetadata(
        String(title),
        String(subtitle),
        String(report_number),
        String(revision_label),
        Symbol(confidentiality),
        String.(prepared_by),
        String.(checked_by),
        String.(approved_by),
        String(organization),
        String(client),
        issued_at isa DateTime ? issued_at : DateTime(issued_at),
        String(language),
        String.(tags),
    )
end

struct NarrativeBlock <: AbstractReportBlock
    id::String
    heading::String
    text::String
    source_ids::Vector{String}
end

NarrativeBlock(id, heading, text; source_ids = String[]) =
    NarrativeBlock(String(id), String(heading), String(text), String.(source_ids))

struct EquationBlock <: AbstractReportBlock
    id::String
    label::String
    expression::String
    definitions::Vector{Pair{String,String}}
    source_ids::Vector{String}
end

EquationBlock(id, label, expression; definitions = Pair{String,String}[], source_ids = String[]) =
    EquationBlock(
        String(id),
        String(label),
        String(expression),
        Pair{String,String}[String(k) => String(v) for (k, v) in definitions],
        String.(source_ids),
    )

struct KeyValueBlock <: AbstractReportBlock
    id::String
    title::String
    entries::Vector{Pair{String,Any}}
    units::Dict{String,String}
    source_ids::Vector{String}
end

KeyValueBlock(id, title, entries; units = Dict{String,String}(), source_ids = String[]) =
    KeyValueBlock(
        String(id),
        String(title),
        Pair{String,Any}[String(k) => v for (k, v) in entries],
        Dict(String(k) => String(v) for (k, v) in units),
        String.(source_ids),
    )

"""A typed numerical table. Values remain data, not preformatted display strings."""
struct ReportTable <: AbstractReportBlock
    id::String
    title::String
    columns::Vector{String}
    column_types::Vector{DataType}
    units::Vector{String}
    rows::Vector{Vector{Any}}
    notes::Vector{String}
    source_ids::Vector{String}
end

function ReportTable(
    id,
    title,
    columns,
    rows;
    column_types = DataType[Any for _ in columns],
    units = fill("", length(columns)),
    notes = String[],
    source_ids = String[],
)
    return ReportTable(
        String(id),
        String(title),
        String.(columns),
        DataType[column_types...],
        String.(units),
        [Any[row...] for row in rows],
        String.(notes),
        String.(source_ids),
    )
end

struct AxisSpec
    label::String
    unit::String
    scale::Symbol
    minimum::Union{Nothing,Float64}
    maximum::Union{Nothing,Float64}
end

function AxisSpec(label; unit = "", scale = :linear, minimum = nothing, maximum = nothing)
    scale in (:linear, :log10) || throw(ArgumentError("axis scale must be :linear or :log10"))
    return AxisSpec(
        String(label),
        String(unit),
        Symbol(scale),
        isnothing(minimum) ? nothing : Float64(minimum),
        isnothing(maximum) ? nothing : Float64(maximum),
    )
end

struct PlotSeries
    id::String
    label::String
    x::Vector{Float64}
    y::Vector{Float64}
    x_unit::String
    y_unit::String
    source_hash::String
    event_indices::Vector{Int}
    uncertainty_lower::Union{Nothing,Vector{Float64}}
    uncertainty_upper::Union{Nothing,Vector{Float64}}
    style_key::String
end

function PlotSeries(
    id,
    label,
    x,
    y;
    x_unit = "",
    y_unit = "",
    source_hash = "",
    event_indices = Int[],
    uncertainty_lower = nothing,
    uncertainty_upper = nothing,
    style_key = "series-1",
)
    return PlotSeries(
        String(id),
        String(label),
        Float64.(x),
        Float64.(y),
        String(x_unit),
        String(y_unit),
        lowercase(String(source_hash)),
        Int.(event_indices),
        isnothing(uncertainty_lower) ? nothing : Float64.(uncertainty_lower),
        isnothing(uncertainty_upper) ? nothing : Float64.(uncertainty_upper),
        String(style_key),
    )
end

struct PlotSpec
    id::String
    title::String
    xaxis::AxisSpec
    yaxis::AxisSpec
    series::Vector{PlotSeries}
    annotations::Vector{Pair{Float64,String}}
    transforms::Vector{String}
    clipped::Bool
end

PlotSpec(id, title, xaxis, yaxis, series; annotations = Pair{Float64,String}[], transforms = String[], clipped = false) =
    PlotSpec(
        String(id),
        String(title),
        xaxis,
        yaxis,
        PlotSeries[series...],
        Pair{Float64,String}[Float64(k) => String(v) for (k, v) in annotations],
        String.(transforms),
        Bool(clipped),
    )

struct FigureBlock <: AbstractReportBlock
    id::String
    caption::String
    alt_text::String
    plot::PlotSpec
    source_ids::Vector{String}
end

FigureBlock(id, caption, alt_text, plot; source_ids = String[]) =
    FigureBlock(String(id), String(caption), String(alt_text), plot, String.(source_ids))

struct DiagnosticBlock <: AbstractReportBlock
    id::String
    severity::Symbol
    code::Symbol
    message::String
    evidence_ids::Vector{String}
end

DiagnosticBlock(id, severity, code, message; evidence_ids = String[]) =
    DiagnosticBlock(String(id), Symbol(severity), Symbol(code), String(message), String.(evidence_ids))

struct ReportSection
    id::String
    role::String
    title::String
    blocks::Vector{AbstractReportBlock}
end

ReportSection(id, role, title) =
    ReportSection(String(id), String(role), String(title), AbstractReportBlock[])

ReportSection(id, role, title, blocks::AbstractVector) =
    ReportSection(String(id), String(role), String(title), AbstractReportBlock[blocks...])

mutable struct ReviewComment
    id::String
    component_id::String
    author::String
    severity::Symbol
    text::String
    status::Symbol
    created_at::DateTime
    resolved_at::Union{Nothing,DateTime}
    resolution::String
end

struct ApprovalRecord
    id::String
    role::Symbol
    actor::String
    action::Symbol
    timestamp::DateTime
    report_hash::String
end

mutable struct ReportDocument
    id::String
    revision::Int
    schema_version::VersionNumber
    metadata::ReportMetadata
    bindings::Vector{ResultBinding}
    dependencies::Dict{String,Vector{String}}
    sections::Vector{ReportSection}
    state::Symbol
    comments::Vector{ReviewComment}
    approvals::Vector{ApprovalRecord}
    frozen_hash::Union{Nothing,String}
    supersedes::Union{Nothing,String}
    superseded_by::Union{Nothing,String}
end

function ReportDocument(
    id,
    metadata,
    bindings,
    sections;
    revision = 1,
    schema_version = REPORT_SCHEMA_VERSION,
    dependencies = Dict{String,Vector{String}}(),
    state = :draft,
    comments = ReviewComment[],
    approvals = ApprovalRecord[],
    frozen_hash = nothing,
    supersedes = nothing,
    superseded_by = nothing,
)
    state in _REPORT_STATES || throw(ArgumentError("unsupported report state: $state"))
    return ReportDocument(
        String(id),
        Int(revision),
        schema_version isa VersionNumber ? schema_version : VersionNumber(schema_version),
        metadata,
        ResultBinding[bindings...],
        Dict(String(k) => String.(v) for (k, v) in dependencies),
        ReportSection[sections...],
        Symbol(state),
        ReviewComment[comments...],
        ApprovalRecord[approvals...],
        isnothing(frozen_hash) ? nothing : String(frozen_hash),
        isnothing(supersedes) ? nothing : String(supersedes),
        isnothing(superseded_by) ? nothing : String(superseded_by),
    )
end

struct QAIssue
    severity::Symbol
    code::Symbol
    component_id::String
    message::String
end

struct QAReport
    report_id::String
    report_hash::String
    issues::Vector{QAIssue}
end

struct ReportTemplate
    id::String
    version::VersionNumber
    licence::String
    family::Symbol
    supported_studies::Vector{Symbol}
    required_roles::Vector{String}
    output_profiles::Vector{Symbol}
    trusted::Bool
    source_path::String
    source_hash::String
end

struct PublicationManifest
    schema_version::VersionNumber
    report_id::String
    report_revision::Int
    report_hash::String
    template_hash::String
    generated_at::DateTime
    artifacts::Dict{String,String}
    warnings::Vector{String}
end

struct ToolchainUnavailable <: Exception
    tool::String
    profile::String
    message::String
end

Base.showerror(io::IO, error::ToolchainUnavailable) =
    print(io, error.message, " [tool=", error.tool, ", profile=", error.profile, "]")
