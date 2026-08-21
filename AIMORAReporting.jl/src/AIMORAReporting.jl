"""Semantic engineering reports, traceable rendering, review, and publication for AIMORA."""
module AIMORAReporting

using Dates
using Printf
using SHA
using TOML
using UUIDs

include("types.jl")
include("canonical.jl")
include("visuals.jl")
include("providers.jl")
include("qa.jl")
include("templates.jl")
include("renderers.jl")
include("workflow.jl")

export REPORT_SCHEMA_VERSION,
       ResultBinding,
       ReportMetadata,
       AbstractReportBlock,
       NarrativeBlock,
       EquationBlock,
       KeyValueBlock,
       ReportTable,
       AxisSpec,
       PlotSeries,
       PlotSpec,
       FigureBlock,
       DiagnosticBlock,
       ReportSection,
       ReviewComment,
       ApprovalRecord,
       ReportDocument,
       QAIssue,
       QAReport,
       ReportTemplate,
       PublicationManifest,
       ToolchainUnavailable,
       canonical_json,
       hash_payload,
       content_hash,
       report_semantic_data,
       event_preserving_indices,
       downsample_series,
       register_provider!,
       available_providers,
       required_section_roles,
       build_report,
       qa_report,
       ispassing,
       load_template,
       validate_template,
       template_hash,
       render_markdown,
       render_html,
       render_text,
       render_json,
       render_tex,
       render_csv_companions,
       render_svg_figures,
       render_tikz_figures,
       render_bundle,
       submit_for_review!,
       add_comment!,
       resolve_comment!,
       approve!,
       freeze!,
       verify_frozen,
       revised_copy,
       supersede!

function __init__()
    _register_default_providers!()
end

end
