function _assert_mutable(report::ReportDocument)
    report.state in (:frozen, :superseded, :withdrawn) &&
        throw(ArgumentError("report state $(report.state) is immutable"))
    return nothing
end

function submit_for_review!(report::ReportDocument)
    _assert_mutable(report)
    report.state == :draft || throw(ArgumentError("only a draft report can enter review"))
    quality = qa_report(report)
    ispassing(quality) || throw(ArgumentError("report cannot enter review while semantic QA errors remain"))
    report.state = :review
    return report
end

function add_comment!(
    report::ReportDocument,
    component_id,
    author,
    text;
    severity = :warning,
    id = string(uuid4()),
    created_at = DateTime(1970, 1, 1),
)
    report.state in (:review, :approved) || throw(ArgumentError("review comments require review or approved state"))
    component_ids = Set{String}((report.id,))
    for section in report.sections
        push!(component_ids, section.id)
        for block in section.blocks
            push!(component_ids, getfield(block, :id))
        end
    end
    String(component_id) in component_ids || throw(ArgumentError("unknown report component: $component_id"))
    push!(
        report.comments,
        ReviewComment(
            String(id),
            String(component_id),
            String(author),
            Symbol(severity),
            String(text),
            :open,
            DateTime(created_at),
            nothing,
            "",
        ),
    )
    report.state == :approved && (report.state = :review)
    return last(report.comments)
end

function resolve_comment!(
    report::ReportDocument,
    comment_id,
    resolution;
    resolved_at = DateTime(1970, 1, 1),
)
    comment = findfirst(item -> item.id == String(comment_id), report.comments)
    isnothing(comment) && throw(ArgumentError("unknown review comment: $comment_id"))
    report.comments[comment].status == :resolved && return report.comments[comment]
    report.comments[comment].status = :resolved
    report.comments[comment].resolved_at = DateTime(resolved_at)
    report.comments[comment].resolution = String(resolution)
    return report.comments[comment]
end

function approve!(
    report::ReportDocument,
    actor;
    role = :approver,
    id = string(uuid4()),
    timestamp = DateTime(1970, 1, 1),
)
    report.state == :review || throw(ArgumentError("only a report in review can be approved"))
    quality = qa_report(report)
    ispassing(quality) || throw(ArgumentError("report cannot be approved while semantic QA errors remain"))
    any(comment -> comment.status != :resolved && comment.severity in (:critical, :error, :fatal), report.comments) &&
        throw(ArgumentError("blocking review comments remain unresolved"))
    approval = ApprovalRecord(
        String(id),
        Symbol(role),
        String(actor),
        :approve,
        DateTime(timestamp),
        content_hash(report),
    )
    push!(report.approvals, approval)
    report.state = :approved
    return approval
end

function freeze!(report::ReportDocument)
    report.state == :approved || throw(ArgumentError("only an approved report can be frozen"))
    current_hash = content_hash(report)
    any(approval -> approval.action == :approve && approval.report_hash == current_hash, report.approvals) ||
        throw(ArgumentError("the report has no approval bound to its current content"))
    quality = qa_report(report)
    ispassing(quality) || throw(ArgumentError("report cannot be frozen while semantic QA errors remain"))
    report.frozen_hash = current_hash
    report.state = :frozen
    return current_hash
end

verify_frozen(report::ReportDocument) =
    report.state == :frozen && !isnothing(report.frozen_hash) && report.frozen_hash == content_hash(report)

function revised_copy(
    report::ReportDocument;
    new_id = report.id,
    revision = report.revision + 1,
    revision_label = "R$(revision)",
    issued_at = report.metadata.issued_at,
)
    metadata = ReportMetadata(
        title = report.metadata.title,
        subtitle = report.metadata.subtitle,
        report_number = report.metadata.report_number,
        revision_label = revision_label,
        confidentiality = report.metadata.confidentiality,
        prepared_by = report.metadata.prepared_by,
        checked_by = report.metadata.checked_by,
        approved_by = String[],
        organization = report.metadata.organization,
        client = report.metadata.client,
        issued_at = issued_at,
        language = report.metadata.language,
        tags = report.metadata.tags,
    )
    return ReportDocument(
        String(new_id),
        metadata,
        deepcopy(report.bindings),
        deepcopy(report.sections);
        revision = revision,
        schema_version = report.schema_version,
        dependencies = deepcopy(report.dependencies),
        state = :draft,
        supersedes = report.id,
    )
end

function supersede!(report::ReportDocument, replacement::ReportDocument)
    report.state == :frozen || throw(ArgumentError("only a frozen report can be superseded"))
    replacement.supersedes == report.id || throw(ArgumentError("replacement does not identify the superseded report"))
    report.state = :superseded
    report.superseded_by = replacement.id
    return report
end
