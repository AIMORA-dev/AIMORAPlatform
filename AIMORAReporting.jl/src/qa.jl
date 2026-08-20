ispassing(report::QAReport) = all(issue -> !(issue.severity in (:error, :fatal)), report.issues)

function _issue!(issues, severity, code, component, message)
    severity in _QA_SEVERITIES || throw(ArgumentError("unsupported QA severity: $severity"))
    push!(issues, QAIssue(severity, code, String(component), String(message)))
    return nothing
end

function _check_finite!(issues, values, component, name)
    for (index, value) in enumerate(values)
        if value isa Real && !isfinite(value)
            _issue!(issues, :error, :nonfinite_value, component, "$name contains a non-finite value at index $index")
        end
    end
end

function _check_table!(issues, table::ReportTable)
    isempty(table.columns) && _issue!(issues, :error, :empty_table_schema, table.id, "table has no columns")
    length(table.column_types) == length(table.columns) ||
        _issue!(issues, :error, :table_type_shape, table.id, "column_types does not match the column count")
    length(table.units) == length(table.columns) ||
        _issue!(issues, :error, :table_unit_shape, table.id, "units does not match the column count")
    isempty(table.rows) && _issue!(issues, :warning, :empty_table, table.id, "table contains no rows")

    for (row_index, row) in enumerate(table.rows)
        length(row) == length(table.columns) || begin
            _issue!(issues, :error, :table_row_shape, table.id, "row $row_index does not match the column count")
            continue
        end
        for column_index in eachindex(row)
            value = row[column_index]
            declared = table.column_types[column_index]
            if declared !== Any && value !== missing && !(value isa declared)
                _issue!(
                    issues,
                    :error,
                    :table_type_mismatch,
                    table.id,
                    "row $row_index column $(table.columns[column_index]) does not match $(declared)",
                )
            end
            if value isa Real && !isfinite(value)
                _issue!(issues, :error, :nonfinite_value, table.id, "row $row_index column $(table.columns[column_index]) is non-finite")
            end
        end
    end
end

function _check_plot!(issues, figure::FigureBlock)
    plot = figure.plot
    isempty(strip(figure.caption)) && _issue!(issues, :error, :missing_caption, figure.id, "figure caption is empty")
    isempty(strip(figure.alt_text)) && _issue!(issues, :error, :missing_alt_text, figure.id, "figure alternative text is empty")
    isempty(plot.series) && _issue!(issues, :error, :empty_plot, plot.id, "plot has no series")
    plot.clipped && _issue!(issues, :warning, :clipped_plot, plot.id, "plot declares clipped data; the report must explain the clipping")

    style_keys = String[]
    for series in plot.series
        push!(style_keys, series.style_key)
        length(series.x) == length(series.y) ||
            _issue!(issues, :error, :series_shape, series.id, "x and y lengths differ")
        isempty(series.x) && _issue!(issues, :error, :empty_series, series.id, "series is empty")
        _check_finite!(issues, series.x, series.id, "x")
        _check_finite!(issues, series.y, series.id, "y")
        issorted(series.x) || _issue!(issues, :error, :nonmonotonic_axis, series.id, "x coordinates are not monotonic")
        plot.xaxis.scale == :log10 && any(value -> !(isfinite(value) && value > 0), series.x) &&
            _issue!(issues, :error, :invalid_log_domain, series.id, "x data contains values outside the log10 domain")
        plot.yaxis.scale == :log10 && any(value -> !(isfinite(value) && value > 0), series.y) &&
            _issue!(issues, :error, :invalid_log_domain, series.id, "y data contains values outside the log10 domain")
        isempty(series.x_unit) && isempty(plot.xaxis.unit) &&
            _issue!(issues, :warning, :missing_unit, series.id, "x unit is not declared")
        isempty(series.y_unit) && isempty(plot.yaxis.unit) &&
            _issue!(issues, :warning, :missing_unit, series.id, "y unit is not declared")
        !isempty(series.source_hash) && !_is_sha256(series.source_hash) &&
            _issue!(issues, :error, :invalid_source_hash, series.id, "series source hash is not SHA-256")
        for event in series.event_indices
            1 <= event <= length(series.x) ||
                _issue!(issues, :error, :invalid_event_index, series.id, "event index $event is outside the series")
        end
        if xor(isnothing(series.uncertainty_lower), isnothing(series.uncertainty_upper))
            _issue!(issues, :error, :incomplete_uncertainty, series.id, "both lower and upper uncertainty bounds are required")
        elseif !isnothing(series.uncertainty_lower)
            length(series.uncertainty_lower) == length(series.y) ||
                _issue!(issues, :error, :uncertainty_shape, series.id, "lower uncertainty length differs from y")
            length(series.uncertainty_upper) == length(series.y) ||
                _issue!(issues, :error, :uncertainty_shape, series.id, "upper uncertainty length differs from y")
            if length(series.uncertainty_lower) == length(series.y) == length(series.uncertainty_upper)
                for index in eachindex(series.y)
                    series.uncertainty_lower[index] <= series.y[index] <= series.uncertainty_upper[index] ||
                        _issue!(issues, :error, :invalid_uncertainty, series.id, "uncertainty does not enclose y at index $index")
                end
            end
        end
    end
    length(unique(style_keys)) == length(style_keys) ||
        _issue!(issues, :warning, :duplicate_visual_style, plot.id, "multiple series use the same style key")
end

function _dependency_cycles(dependencies::Dict{String,Vector{String}})
    visiting = Set{String}()
    visited = Set{String}()
    cycles = Vector{Vector{String}}()
    stack = String[]

    function visit(node)
        node in visited && return
        if node in visiting
            start_index = findfirst(==(node), stack)
            push!(cycles, vcat(stack[start_index:end], node))
            return
        end
        push!(visiting, node)
        push!(stack, node)
        for parent in get(dependencies, node, String[])
            haskey(dependencies, parent) && visit(parent)
        end
        pop!(stack)
        delete!(visiting, node)
        push!(visited, node)
    end

    for node in keys(dependencies)
        visit(node)
    end
    return cycles
end

function qa_report(report::ReportDocument; required_roles = String[])
    issues = QAIssue[]
    isempty(strip(report.id)) && _issue!(issues, :error, :missing_report_id, "report", "report id is empty")
    report.revision >= 1 || _issue!(issues, :error, :invalid_revision, report.id, "report revision must be positive")
    report.state in _REPORT_STATES || _issue!(issues, :error, :invalid_state, report.id, "report state is invalid")
    isempty(report.bindings) && _issue!(issues, :error, :missing_result_binding, report.id, "report has no immutable result binding")
    isempty(report.sections) && _issue!(issues, :error, :empty_report, report.id, "report has no sections")

    result_ids = Set(binding.result_id for binding in report.bindings)
    for binding in report.bindings
        _is_sha256(binding.payload_hash) ||
            _issue!(issues, :error, :invalid_result_hash, binding.result_id, "bound payload hash is not SHA-256")
        for upstream in binding.upstream_hashes
            _is_sha256(upstream) || _issue!(issues, :error, :invalid_upstream_hash, binding.result_id, "upstream hash is not SHA-256")
        end
        isempty(strip(binding.units_base)) && _issue!(issues, :error, :missing_unit_base, binding.result_id, "units base is empty")
    end

    component_ids = String[]
    roles = String[]
    for section in report.sections
        push!(component_ids, section.id)
        push!(roles, section.role)
        isempty(strip(section.role)) && _issue!(issues, :error, :missing_section_role, section.id, "section role is empty")
        isempty(section.blocks) && _issue!(issues, :warning, :empty_section, section.id, "section has no content blocks")
        for block in section.blocks
            push!(component_ids, getfield(block, :id))
            if block isa ReportTable
                _check_table!(issues, block)
            elseif block isa FigureBlock
                _check_plot!(issues, block)
            elseif block isa NarrativeBlock
                isempty(strip(block.text)) && _issue!(issues, :warning, :empty_narrative, block.id, "narrative block is empty")
            elseif block isa DiagnosticBlock
                block.severity in (:info, :warning, :error, :fatal) ||
                    _issue!(issues, :error, :invalid_diagnostic_severity, block.id, "diagnostic severity is invalid")
            end
        end
    end
    length(component_ids) == length(unique(component_ids)) ||
        _issue!(issues, :error, :duplicate_component_id, report.id, "report component IDs are not unique")

    for role in required_roles
        role in roles || _issue!(issues, :error, :missing_required_section, report.id, "required section role '$role' is absent")
    end

    for (node, parents) in report.dependencies
        node in result_ids || _issue!(issues, :error, :unknown_dependency_node, node, "dependency node is not a bound result")
        for parent in parents
            parent in result_ids || _issue!(issues, :error, :unknown_dependency_parent, node, "dependency parent '$parent' is not a bound result")
        end
    end
    for cycle in _dependency_cycles(report.dependencies)
        _issue!(issues, :error, :dependency_cycle, report.id, "result dependency cycle: " * join(cycle, " → "))
    end

    for comment in report.comments
        if comment.status != :resolved && comment.severity in (:error, :fatal, :critical)
            _issue!(issues, :error, :unresolved_review_comment, comment.component_id, "unresolved blocking review comment $(comment.id)")
        end
    end

    if report.state in (:approved, :frozen)
        current_hash = content_hash(report)
        any(approval -> approval.action == :approve && approval.report_hash == current_hash, report.approvals) ||
            _issue!(issues, :error, :missing_current_approval, report.id, "no approval is bound to the current report content")
    end
    if report.state == :frozen
        isnothing(report.frozen_hash) && _issue!(issues, :error, :missing_freeze_hash, report.id, "frozen report has no freeze hash")
        !isnothing(report.frozen_hash) && report.frozen_hash != content_hash(report) &&
            _issue!(issues, :fatal, :frozen_content_changed, report.id, "frozen report content no longer matches its freeze hash")
    end

    return QAReport(report.id, content_hash(report), issues)
end
