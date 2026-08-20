_html_escape(value) = replace(String(value), '&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#39;")
_tex_escape(value) = replace(String(value), '\\' => "\\textbackslash{}", '&' => "\\&", '%' => "\\%", '$' => "\\$", '#' => "\\#", '_' => "\\_", '{' => "\\{", '}' => "\\}", '~' => "\\textasciitilde{}", '^' => "\\textasciicircum{}")

function _display_value(value)
    value === missing && return "—"
    value === nothing && return "—"
    value isa AbstractFloat && return @sprintf("%.8g", value)
    value isa AbstractVector && return join(_display_value.(value), ", ")
    return string(value)
end

function _markdown_block(block::NarrativeBlock)
    return "### $(block.heading)\n\n$(block.text)\n"
end

function _markdown_block(block::EquationBlock)
    definitions = isempty(block.definitions) ? "" : "\n" * join("- `$(key)`: $(value)" for (key, value) in block.definitions, "\n") * "\n"
    return "### $(block.label)\n\n```math\n$(block.expression)\n```\n" * definitions
end

function _markdown_block(block::KeyValueBlock)
    lines = ["| Property | Value | Unit |", "| --- | ---: | --- |"]
    for (key, value) in block.entries
        push!(lines, "| $(key) | $(_display_value(value)) | $(get(block.units, key, "")) |")
    end
    return "### $(block.title)\n\n" * join(lines, "\n") * "\n"
end

function _markdown_block(table::ReportTable)
    header = "| " * join(table.columns, " | ") * " |"
    separator = "| " * join(fill("---", length(table.columns)), " | ") * " |"
    unit_row = any(!isempty, table.units) ? "| " * join([isempty(unit) ? "" : "[$unit]" for unit in table.units], " | ") * " |" : ""
    rows = ["| " * join(_display_value.(row), " | ") * " |" for row in table.rows]
    notes = isempty(table.notes) ? "" : "\n" * join("- " .* table.notes, "\n") * "\n"
    return "### $(table.title)\n\n" * join(filter(!isempty, vcat([header, separator, unit_row], rows)), "\n") * "\n" * notes
end

function _markdown_block(figure::FigureBlock)
    return "### $(figure.plot.title)\n\n![${figure.alt_text}](figures/$(figure.id).svg)\n\n*$(figure.caption)*\n"
end

function _markdown_block(block::DiagnosticBlock)
    return "> **$(uppercase(String(block.severity))) — $(block.code):** $(block.message)\n"
end

function render_markdown(report::ReportDocument)
    io = IOBuffer()
    println(io, "# ", report.metadata.title)
    !isempty(report.metadata.subtitle) && println(io, "\n", report.metadata.subtitle)
    println(io, "\n- Report ID: `", report.id, "`")
    println(io, "- Revision: ", report.revision)
    println(io, "- State: `", report.state, "`")
    println(io, "- Content SHA-256: `", content_hash(report), "`")
    for section in report.sections
        println(io, "\n## ", section.title, "\n")
        for block in section.blocks
            println(io, _markdown_block(block))
        end
    end
    return String(take!(io))
end

function _html_block(block::NarrativeBlock)
    paragraphs = join("<p>" * _html_escape(line) * "</p>" for line in split(block.text, '\n') if !isempty(strip(line)))
    return "<article id=\"$(_html_escape(block.id))\"><h3>$(_html_escape(block.heading))</h3>$paragraphs</article>"
end

function _html_block(block::EquationBlock)
    definitions = isempty(block.definitions) ? "" : "<dl>" * join("<dt>$(_html_escape(key))</dt><dd>$(_html_escape(value))</dd>" for (key, value) in block.definitions) * "</dl>"
    return "<article id=\"$(_html_escape(block.id))\"><h3>$(_html_escape(block.label))</h3><pre class=\"equation\">$(_html_escape(block.expression))</pre>$definitions</article>"
end

function _html_block(block::KeyValueBlock)
    rows = join("<tr><th scope=\"row\">$(_html_escape(key))</th><td>$(_html_escape(_display_value(value)))</td><td>$(_html_escape(get(block.units, key, "")))</td></tr>" for (key, value) in block.entries)
    return "<article id=\"$(_html_escape(block.id))\"><h3>$(_html_escape(block.title))</h3><table><thead><tr><th>Property</th><th>Value</th><th>Unit</th></tr></thead><tbody>$rows</tbody></table></article>"
end

function _html_block(table::ReportTable)
    headers = join("<th scope=\"col\">$(_html_escape(column))</th>" for column in table.columns)
    units = join("<td>$(_html_escape(unit))</td>" for unit in table.units)
    rows = join("<tr>" * join("<td>$(_html_escape(_display_value(value)))</td>" for value in row) * "</tr>" for row in table.rows)
    unit_row = any(!isempty, table.units) ? "<tr class=\"units\">$units</tr>" : ""
    return "<article id=\"$(_html_escape(table.id))\"><h3>$(_html_escape(table.title))</h3><table><thead><tr>$headers</tr>$unit_row</thead><tbody>$rows</tbody></table></article>"
end

function _html_block(figure::FigureBlock)
    return "<figure id=\"$(_html_escape(figure.id))\"><img src=\"figures/$(_html_escape(figure.id)).svg\" alt=\"$(_html_escape(figure.alt_text))\"><figcaption>$(_html_escape(figure.caption))</figcaption></figure>"
end

function _html_block(block::DiagnosticBlock)
    return "<aside id=\"$(_html_escape(block.id))\" class=\"diagnostic $(_html_escape(String(block.severity)))\"><strong>$(_html_escape(String(block.code)))</strong>: $(_html_escape(block.message))</aside>"
end

function render_html(report::ReportDocument)
    body = IOBuffer()
    println(body, "<header><h1>", _html_escape(report.metadata.title), "</h1><p>", _html_escape(report.metadata.subtitle), "</p></header>")
    println(body, "<dl><dt>Report ID</dt><dd>", _html_escape(report.id), "</dd><dt>Revision</dt><dd>", report.revision, "</dd><dt>Content hash</dt><dd><code>", content_hash(report), "</code></dd></dl>")
    for section in report.sections
        println(body, "<section id=\"", _html_escape(section.id), "\"><h2>", _html_escape(section.title), "</h2>")
        for block in section.blocks
            println(body, _html_block(block))
        end
        println(body, "</section>")
    end
    content = String(take!(body))
    return "<!doctype html><html lang=\"$(_html_escape(report.metadata.language))\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>$(_html_escape(report.metadata.title))</title><style>body{font-family:system-ui,sans-serif;max-width:1100px;margin:auto;padding:2rem;line-height:1.5}table{border-collapse:collapse;width:100%;overflow-wrap:anywhere}th,td{border:1px solid #777;padding:.4rem;text-align:left}code,pre{white-space:pre-wrap}.diagnostic{border-left:.35rem solid;padding:.7rem;margin:1rem 0}.warning{border-color:#8a5a00}.error,.fatal{border-color:#9f1515}img{max-width:100%;height:auto}</style></head><body>$content</body></html>"
end

function render_text(report::ReportDocument)
    markdown = render_markdown(report)
    text = replace(markdown, r"```math\n?" => "", "```" => "", r"[#*_`]" => "")
    return replace(text, r"!\[([^\]]*)\]\([^\)]*\)" => s"Figure: \1")
end

render_json(report::ReportDocument) = canonical_json(report_semantic_data(report)) * "\n"

function _tex_block(block::NarrativeBlock)
    return "\\subsection*{$(_tex_escape(block.heading))}\n$(_tex_escape(block.text))\n"
end

function _tex_block(block::EquationBlock)
    definitions = isempty(block.definitions) ? "" : "\\begin{description}\n" * join("\\item[$(_tex_escape(key))] $(_tex_escape(value))" for (key, value) in block.definitions, "\n") * "\n\\end{description}\n"
    return "\\subsection*{$(_tex_escape(block.label))}\n\\begin{equation}\n$(block.expression)\n\\end{equation}\n$definitions"
end

function _tex_block(block::KeyValueBlock)
    rows = join("$(_tex_escape(key)) & $(_tex_escape(_display_value(value))) & $(_tex_escape(get(block.units, key, ""))) \\\\" for (key, value) in block.entries, "\n")
    return "\\subsection*{$(_tex_escape(block.title))}\n\\begin{longtable}{p{0.35\\linewidth}p{0.4\\linewidth}p{0.15\\linewidth}}\nProperty & Value & Unit \\\\ \\hline\n$rows\n\\end{longtable}\n"
end

function _tex_block(table::ReportTable)
    specification = join(fill("p{" * string(round(0.9 / max(length(table.columns), 1); digits = 3)) * "\\linewidth}", length(table.columns)))
    header = join(_tex_escape.(table.columns), " & ") * " \\\\ \\hline"
    unit_row = any(!isempty, table.units) ? join([isempty(unit) ? "" : "[$(_tex_escape(unit))]" for unit in table.units], " & ") * " \\\\" : ""
    rows = join(join(_tex_escape.(_display_value.(row)), " & ") * " \\\\" for row in table.rows, "\n")
    return "\\subsection*{$(_tex_escape(table.title))}\n\\begin{longtable}{$specification}\n$header\n$unit_row\n$rows\n\\end{longtable}\n"
end

function _tex_block(figure::FigureBlock)
    return "\\begin{figure}[htbp]\n\\centering\n\\includegraphics[width=0.95\\linewidth]{figures/$(_tex_escape(figure.id)).svg}\n\\caption{$(_tex_escape(figure.caption))}\n\\label{fig:$(_tex_escape(figure.id))}\n\\end{figure}\n"
end

function _tex_block(block::DiagnosticBlock)
    return "\\paragraph{$(_tex_escape(uppercase(String(block.severity)))): $(_tex_escape(String(block.code)))} $(_tex_escape(block.message))\n"
end

function render_tex(report::ReportDocument)
    io = IOBuffer()
    println(io, "\\documentclass[11pt]{article}")
    println(io, "\\usepackage[margin=25mm]{geometry}")
    println(io, "\\usepackage{longtable,booktabs,graphicx,hyperref}")
    println(io, "\\usepackage[T1]{fontenc}")
    println(io, "\\title{", _tex_escape(report.metadata.title), "}")
    println(io, "\\author{", _tex_escape(join(report.metadata.prepared_by, ", ")), "}")
    println(io, "\\date{", _tex_escape(string(report.metadata.issued_at)), "}")
    println(io, "\\begin{document}\\maketitle")
    println(io, "\\noindent Report ID: \\texttt{", _tex_escape(report.id), "}\\\\")
    println(io, "Revision: ", report.revision, "\\\\")
    println(io, "Content SHA-256: \\texttt{", content_hash(report), "}")
    for section in report.sections
        println(io, "\\section{", _tex_escape(section.title), "}")
        for block in section.blocks
            println(io, _tex_block(block))
        end
    end
    println(io, "\\end{document}")
    return String(take!(io))
end

function _csv_escape(value)
    text = _display_value(value)
    if occursin(',', text) || occursin('"', text) || occursin('\n', text)
        return "\"" * replace(text, '"' => "\"\"") * "\""
    end
    return text
end

function render_csv_companions(report::ReportDocument, directory::AbstractString)
    mkpath(directory)
    paths = String[]
    for section in report.sections, block in section.blocks
        block isa ReportTable || continue
        path = joinpath(directory, "$(block.id).csv")
        open(path, "w") do io
            println(io, join(_csv_escape.(block.columns), ','))
            any(!isempty, block.units) && println(io, join(_csv_escape.(block.units), ','))
            for row in block.rows
                println(io, join(_csv_escape.(row), ','))
            end
        end
        push!(paths, path)
    end
    return paths
end

function _series_svg_points(series::PlotSeries, xbounds, ybounds; width = 900.0, height = 420.0, margin = 55.0)
    xmin, xmax = xbounds
    ymin, ymax = ybounds
    xscale = (width - 2margin) / (xmax - xmin)
    yscale = (height - 2margin) / (ymax - ymin)
    points = String[]
    for (x, y) in zip(series.x, series.y)
        isfinite(x) && isfinite(y) || continue
        px = margin + (x - xmin) * xscale
        py = height - margin - (y - ymin) * yscale
        push!(points, @sprintf("%.3f,%.3f", px, py))
    end
    return join(points, " ")
end

function _render_svg(figure::FigureBlock)
    all_x = reduce(vcat, (series.x for series in figure.plot.series); init = Float64[])
    all_y = reduce(vcat, (series.y for series in figure.plot.series); init = Float64[])
    xbounds = _finite_bounds(all_x)
    ybounds = _finite_bounds(all_y)
    width, height, margin = 900.0, 420.0, 55.0
    polylines = String[]
    dash_patterns = ("", "8 4", "2 4", "12 4 2 4", "5 3")
    for (index, series) in enumerate(figure.plot.series)
        points = _series_svg_points(series, xbounds, ybounds; width = width, height = height, margin = margin)
        dash = dash_patterns[mod1(index, length(dash_patterns))]
        dash_attribute = isempty(dash) ? "" : " stroke-dasharray=\"$dash\""
        push!(polylines, "<polyline fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\"$dash_attribute points=\"$points\"><title>$(_html_escape(series.label))</title></polyline>")
    end
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"900\" height=\"420\" viewBox=\"0 0 900 420\" role=\"img\" aria-labelledby=\"title desc\"><title id=\"title\">$(_html_escape(figure.plot.title))</title><desc id=\"desc\">$(_html_escape(figure.alt_text))</desc><rect width=\"100%\" height=\"100%\" fill=\"white\"/><g color=\"#111\"><line x1=\"55\" y1=\"365\" x2=\"845\" y2=\"365\" stroke=\"currentColor\"/><line x1=\"55\" y1=\"55\" x2=\"55\" y2=\"365\" stroke=\"currentColor\"/>$(join(polylines))</g><text x=\"450\" y=\"405\" text-anchor=\"middle\">$(_html_escape(figure.plot.xaxis.label)) [$(_html_escape(figure.plot.xaxis.unit))]</text><text x=\"18\" y=\"210\" text-anchor=\"middle\" transform=\"rotate(-90 18 210)\">$(_html_escape(figure.plot.yaxis.label)) [$(_html_escape(figure.plot.yaxis.unit))]</text></svg>"
end

function render_svg_figures(report::ReportDocument, directory::AbstractString)
    mkpath(directory)
    paths = String[]
    for section in report.sections, block in section.blocks
        block isa FigureBlock || continue
        path = joinpath(directory, "$(block.id).svg")
        write(path, _render_svg(block))
        push!(paths, path)
    end
    return paths
end

function _render_tikz(figure::FigureBlock)
    plots = String[]
    for series in figure.plot.series
        coordinates = join("($(@sprintf("%.17g", x)),$(@sprintf("%.17g", y)))" for (x, y) in zip(series.x, series.y) if isfinite(x) && isfinite(y), " ")
        push!(plots, "\\addplot coordinates {$coordinates};\\addlegendentry{$(_tex_escape(series.label))}")
    end
    xmode = figure.plot.xaxis.scale == :log10 ? ",xmode=log" : ""
    ymode = figure.plot.yaxis.scale == :log10 ? ",ymode=log" : ""
    return "\\begin{tikzpicture}\n\\begin{axis}[title={$(_tex_escape(figure.plot.title))},xlabel={$(_tex_escape(figure.plot.xaxis.label)) [$(_tex_escape(figure.plot.xaxis.unit))]},ylabel={$(_tex_escape(figure.plot.yaxis.label)) [$(_tex_escape(figure.plot.yaxis.unit))]}$xmode$ymode]\n$(join(plots, "\n"))\n\\end{axis}\n\\end{tikzpicture}\n"
end

function render_tikz_figures(report::ReportDocument, directory::AbstractString)
    mkpath(directory)
    paths = String[]
    for section in report.sections, block in section.blocks
        block isa FigureBlock || continue
        path = joinpath(directory, "$(block.id).tex")
        write(path, _render_tikz(block))
        push!(paths, path)
    end
    return paths
end

function _write_manifest(path, manifest::PublicationManifest)
    document = Dict(
        "schema_version" => string(manifest.schema_version),
        "report_id" => manifest.report_id,
        "report_revision" => manifest.report_revision,
        "report_hash" => manifest.report_hash,
        "template_hash" => manifest.template_hash,
        "generated_at" => string(manifest.generated_at),
        "artifacts" => manifest.artifacts,
        "warnings" => manifest.warnings,
    )
    open(path, "w") do io
        TOML.print(io, document; sorted = true)
    end
    return path
end

function _prior_generated_files(directory)
    manifest_path = joinpath(directory, "manifest.toml")
    isfile(manifest_path) || return Set{String}()
    document = TOML.parsefile(manifest_path)
    artifacts = get(document, "artifacts", Dict{String,Any}())
    return Set(String.(keys(artifacts)))
end

function _compile_tectonic(tex_path, output_directory)
    executable = Sys.which("tectonic")
    isnothing(executable) && throw(ToolchainUnavailable("tectonic", "tectonic", "PDF compilation was requested, but Tectonic is unavailable. The portable TeX source remains valid."))
    command = `$(executable) --only-cached --keep-logs --outdir $(output_directory) $(tex_path)`
    success(run(command; wait = true)) || error("Tectonic failed to compile the report")
    return joinpath(output_directory, replace(basename(tex_path), r"\.tex$" => ".pdf"))
end

function render_bundle(
    report::ReportDocument,
    output_directory::AbstractString;
    formats = [:markdown, :html, :text, :json, :tex, :csv, :svg, :tikz],
    template::Union{Nothing,ReportTemplate} = nothing,
    compile_pdf = false,
    generated_at = DateTime(1970, 1, 1),
)
    required_roles = isnothing(template) ? String[] : template.required_roles
    quality = qa_report(report; required_roles = required_roles)
    ispassing(quality) || throw(ArgumentError("report QA failed: " * join(issue.message for issue in quality.issues if issue.severity in (:error, :fatal), "; ")))
    report.state == :frozen && !verify_frozen(report) && throw(ArgumentError("frozen report content hash is invalid"))

    destination = abspath(output_directory)
    destination in (abspath("/"), abspath(homedir())) && throw(ArgumentError("unsafe report output directory"))
    mkpath(destination)
    previous = _prior_generated_files(destination)
    warnings = [issue.message for issue in quality.issues if issue.severity == :warning]
    template_digest = isnothing(template) ? repeat("0", 64) : template_hash(template)

    return mktempdir() do stage
        generated = String[]
        if :markdown in formats
            write(joinpath(stage, "report.md"), render_markdown(report)); push!(generated, "report.md")
        end
        if :html in formats
            write(joinpath(stage, "report.html"), render_html(report)); push!(generated, "report.html")
        end
        if :text in formats
            write(joinpath(stage, "report.txt"), render_text(report)); push!(generated, "report.txt")
        end
        if :json in formats
            write(joinpath(stage, "report.json"), render_json(report)); push!(generated, "report.json")
        end
        tex_path = joinpath(stage, "report.tex")
        if :tex in formats || compile_pdf
            write(tex_path, render_tex(report)); push!(generated, "report.tex")
        end
        if :csv in formats
            for path in render_csv_companions(report, joinpath(stage, "data"))
                push!(generated, relpath(path, stage))
            end
        end
        if :svg in formats
            for path in render_svg_figures(report, joinpath(stage, "figures"))
                push!(generated, relpath(path, stage))
            end
        end
        if :tikz in formats
            for path in render_tikz_figures(report, joinpath(stage, "tikz"))
                push!(generated, relpath(path, stage))
            end
        end
        if compile_pdf
            pdf_path = _compile_tectonic(tex_path, stage)
            push!(generated, relpath(pdf_path, stage))
        end

        artifacts = Dict{String,String}()
        for relative in sort!(unique(generated))
            artifacts[relative] = _artifact_hash(joinpath(stage, relative))
        end
        manifest = PublicationManifest(
            REPORT_SCHEMA_VERSION,
            report.id,
            report.revision,
            content_hash(report),
            template_digest,
            DateTime(generated_at),
            artifacts,
            warnings,
        )
        _write_manifest(joinpath(stage, "manifest.toml"), manifest)

        for relative in setdiff(previous, Set(keys(artifacts)))
            stale = joinpath(destination, relative)
            isfile(stale) && rm(stale)
        end
        for relative in sort!(collect(keys(artifacts)))
            source = joinpath(stage, relative)
            target = joinpath(destination, relative)
            mkpath(dirname(target))
            cp(source, target; force = true)
        end
        cp(joinpath(stage, "manifest.toml"), joinpath(destination, "manifest.toml"); force = true)
        return manifest
    end
end
