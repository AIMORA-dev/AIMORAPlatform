const _AIMORA_PROJECT_V1_FIXTURE_SHA256 = [
    "67ba47221d182f7f648b98844e1d0b505eff5e4a61f82addc8990604e44ac2a5",
]
const _AIMORA_ASSET_CSV_FIXTURE_SHA256 = [
    "48b7d73130e8990dd9f522e89fb61cfd78b15cf4504958c76aa779c76400b10c",
]
const _AIMORA_CATALOG_V1_FIXTURE_SHA256 = [
    "6c81f8642d8f584b9a0b44917dc8c552b5d5c63b681591aa69f2775aee6525bf",
    "b501d1a73b500c2ac15a632ddcb3701109f695459d45b7020e4b6dbf7003ea86",
    "fbd27222d0141848046e579f989ae0bc48deeefc36d6a5c0b266c38ad9eb1b44",
    "741c5a5d23da204f525c48dbabda28a69d7eb082bf6aad73bb22e32583d3c495",
]
const _AIMORA_CASES_V2_FIXTURE_SHA256 = [
    "bafc0b707b1ec8ce9a6f707ceb9566dff76761b1f323230d0fa8819c22209cbe",
    "9047090e0108d301a97613e24384cd6211bb67033cc46fb622e613cf85758856",
]

mutable struct _NativeRecordDraft
    record_id::String
    record_type::String
    raw_identifier::String
    source_name::String
    span::SourceSpan
    fields::Vector{ImportSourceField}
end

struct _NativeTomlLocations
    root::SourceSpan
    keys::Dict{String,SourceSpan}
    headers::Dict{String,SourceSpan}
end

struct _NativeMigrationFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _native_fail(code::Symbol, message::AbstractString, span::SourceSpan)
    throw(_NativeMigrationFailure(FormatDiagnostic(
        DiagnosticError,
        code,
        String(message),
        span,
    )))
end

function _native_toml_locations(source::SourceDocument)
    root = source_span(source, 1, ncodeunits(source.text) + 1)
    keys = Dict{String,SourceSpan}()
    headers = Dict{String,SourceSpan}()
    active = String[]
    current_indices = Dict{String,Int}()
    for line_index in eachindex(source.line_starts)
        first_byte = source.line_starts[line_index]
        stop_byte = _toml_line_stop(source, line_index)
        line = first_byte < stop_byte ? String(SubString(
            source.text,
            first_byte,
            prevind(source.text, stop_byte),
        )) : ""
        header_match = match(r"^\s*(\[\[|\[)([A-Za-z0-9_.-]+)(\]\]|\])\s*(?:#.*)?$", line)
        if !isnothing(header_match)
            is_array = header_match.captures[1] == "[["
            logical = split(header_match.captures[2], '.')
            resolved = String[]
            for (index, token) in enumerate(logical)
                key = join(vcat(resolved, token), ".")
                if is_array && index == length(logical)
                    current_indices[key] = get(current_indices, key, 0) + 1
                end
                if haskey(current_indices, key)
                    push!(resolved, string(token, '[', current_indices[key], ']'))
                else
                    push!(resolved, token)
                end
            end
            active = resolved
            header_range = findfirst(header_match.match, line)
            offset = isnothing(header_range) || first(header_range) == firstindex(line) ? 0 :
                ncodeunits(SubString(line, firstindex(line), prevind(line, first(header_range))))
            headers[join(active, ".")] = source_span(
                source,
                first_byte + offset,
                first_byte + offset + ncodeunits(header_match.match),
            )
            continue
        end
        key_match = match(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=", line)
        isnothing(key_match) && continue
        key = key_match.captures[1]
        key_range = findfirst(key, line)
        isnothing(key_range) && continue
        offset = first(key_range) == firstindex(line) ? 0 :
            ncodeunits(SubString(line, firstindex(line), prevind(line, first(key_range))))
        keys[join(vcat(active, key), ".")] = source_span(
            source,
            first_byte + offset,
            first_byte + offset + ncodeunits(key),
        )
    end
    return _NativeTomlLocations(root, keys, headers)
end

function _native_span(locations::_NativeTomlLocations, path::AbstractString)
    candidate = String(path)
    while true
        haskey(locations.keys, candidate) && return locations.keys[candidate]
        haskey(locations.headers, candidate) && return locations.headers[candidate]
        separator = findlast(==('.'), candidate)
        isnothing(separator) && return locations.root
        candidate = candidate[firstindex(candidate):prevind(candidate, separator)]
    end
end

function _native_toml(source::SourceDocument, policy::FormatInputPolicy, syntax_code::Symbol)
    source.provenance.byte_count <= policy.max_document_bytes ||
        _native_fail(:document_too_large, "native migration source exceeds the configured byte limit", source_span(source, 1, 1))
    parsed = TOML.tryparse(source.text)
    if parsed isa Exception
        byte = _toml_position_byte(source, parsed.line, parsed.column)
        _native_fail(
            syntax_code,
            "native migration TOML syntax is invalid: $(sprint(showerror, parsed))",
            source_span(source, byte, byte),
        )
    end
    locations = _native_toml_locations(source)
    diagnostics = _toml_policy_diagnostics(parsed, policy, locations.root)
    isempty(diagnostics) || throw(_NativeMigrationFailure(first(diagnostics)))
    return parsed, locations
end

function _native_required(raw::AbstractDict, key::String, expected, span::SourceSpan)
    haskey(raw, key) || _native_fail(:missing_native_field, "native migration source is missing required field $(key)", span)
    value = raw[key]
    value isa expected || _native_fail(:invalid_native_field, "native migration field $(key) has the wrong type", span)
    return value
end

function _native_nonempty_string(raw::AbstractDict, key::String, span::SourceSpan)
    value = _native_required(raw, key, AbstractString, span)
    isempty(value) && _native_fail(:invalid_native_field, "native migration field $(key) must not be empty", span)
    return String(value)
end

function _native_decimal(value::AbstractFloat, span::SourceSpan)
    isfinite(value) || _native_fail(:invalid_native_number, "native migration numbers must be finite", span)
    text = string(value)
    decimal = _bulk_decimal_value(text)
    isnothing(decimal) && _native_fail(:invalid_native_number, "native migration decimal cannot be normalized", span)
    return decimal
end

function _native_format_node(value, span::SourceSpan)
    formatted = if value isa AbstractString
        FormatString(value)
    elseif value isa Bool
        FormatBoolean(value)
    elseif value isa Integer
        FormatInteger(value)
    elseif value isa AbstractFloat
        _native_decimal(value, span)
    elseif value isa AbstractVector
        FormatSequence(FormatNode[_native_format_node(item, span) for item in value])
    elseif value isa AbstractDict
        entries = FormatMappingEntry[]
        for key in sort!(String[String(item) for item in keys(value)])
            push!(entries, FormatMappingEntry(
                FormatNode(FormatString(key), span),
                _native_format_node(value[key], span),
            ))
        end
        FormatMapping(entries)
    else
        FormatString(string(value))
    end
    return FormatNode(formatted, span)
end

function _native_record(
    record_id::String,
    record_type::String,
    raw_identifier::String,
    source::SourceDocument,
    span::SourceSpan,
)
    return _NativeRecordDraft(
        record_id,
        record_type,
        raw_identifier,
        source.provenance.source_name,
        span,
        ImportSourceField[],
    )
end

function _native_add_field!(
    draft::_NativeRecordDraft,
    field_name::String,
    value,
    span::SourceSpan,
    disposition::ImportFieldDisposition,
    destination::Union{Nothing,FormatPath},
    justification::Union{Nothing,String},
    object_id::String,
    operations::Vector{ImportPlanOperation},
    accounting::Vector{ImportFieldAccounting},
    losses::Vector{ImportConversionLoss},
)
    any(field -> field.name == field_name, draft.fields) &&
        error("native migration record repeats source field $(field_name)")
    node = value isa FormatNode ? value : _native_format_node(value, span)
    push!(draft.fields, ImportSourceField(field_name, node, nothing, nothing))
    source_ref = ImportSourceFieldRef(draft.record_id, field_name)
    push!(accounting, ImportFieldAccounting(
        source_ref,
        disposition,
        destination,
        justification,
        span,
    ))
    if disposition == ImportMapped && destination != FormatPath("id")
        push!(operations, ImportFieldAssignment(object_id, destination, node, source_ref))
    elseif disposition in (ImportUnsupported, ImportRejected)
        push!(losses, ImportConversionLoss(
            string("loss.", length(losses) + 1),
            something(justification, "native source meaning is unavailable"),
            disposition == ImportUnsupported ?
                "source meaning is unavailable in the canonical import plan" :
                "source field prevents an accepted conversion",
            source_ref,
        ))
    end
    return source_ref
end

function _native_finish(draft::_NativeRecordDraft)
    return ImportSourceRecord(
        draft.record_id,
        draft.record_type,
        draft.raw_identifier,
        draft.source_name,
        draft.span,
        FormatItemList(draft.fields),
    )
end

function _native_flatten(value, prefix::String = "")
    flattened = Pair{String,Any}[]
    if value isa AbstractDict && !isempty(value)
        for key in sort!(String[String(item) for item in keys(value)])
            child = isempty(prefix) ? key : string(prefix, '.', key)
            append!(flattened, _native_flatten(value[key], child))
        end
    else
        push!(flattened, prefix => value)
    end
    return flattened
end

function _native_adapter(id::String, source_format::String, source_version::String, fixtures)
    return ImportAdapterIdentity(id, v"1.0.0", source_format, source_version, fixtures)
end

function _native_bulk_schema_digest(schema::BulkTableSchema)
    output = IOBuffer()
    print(output, schema.id, '\0', schema.version, '\0', schema.identity_column, '\0')
    for column in schema.columns
        print(
            output,
            column.name,
            '\0',
            UInt8(column.kind),
            '\0',
            column.nullable,
            '\0',
            something(column.unit, ""),
            '\0',
            something(column.basis, ""),
            '\0',
        )
    end
    return bytes2hex(sha256(take!(output)))
end

function _native_result(
    source::SourceDocument,
    adapter::ImportAdapterIdentity,
    drafts::Vector{_NativeRecordDraft},
    operations::Vector{ImportPlanOperation},
    accounting::Vector{ImportFieldAccounting},
    assumptions::Vector{ImportAssumption},
    losses::Vector{ImportConversionLoss},
)
    records = ImportSourceRecord[_native_finish(draft) for draft in drafts]
    return FormatResult(_compile_import_components(
        source,
        adapter,
        records,
        operations,
        accounting;
        assumptions,
        losses,
    ))
end

function _native_portable_segment(value::String, span::SourceSpan)
    occursin(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", value) ||
        _native_fail(:invalid_native_identifier, "native migration ID is not a portable stable segment", span)
    return value
end

function _native_unknown_fields!(
    raw::AbstractDict,
    known::Set{String},
    path::String,
    draft::_NativeRecordDraft,
    object_id::String,
    locations::_NativeTomlLocations,
    operations,
    accounting,
    losses,
)
    for key in sort!(String[String(item) for item in keys(raw) if String(item) ∉ known])
        field_path = isempty(path) ? key : string(path, '.', key)
        _native_add_field!(
            draft,
            string("unknown.", key),
            raw[key],
            _native_span(locations, field_path),
            ImportRejected,
            nothing,
            "field is not owned by this exact native source version",
            object_id,
            operations,
            accounting,
            losses,
        )
    end
end

function _native_admitted_source(
    bytes::AbstractVector{UInt8},
    source_name::AbstractString,
    policy::FormatInputPolicy,
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) || return admitted
    return admitted
end

function _read_aimora_project_v1(source::SourceDocument, policy::FormatInputPolicy)
    raw, locations = _native_toml(source, policy, :invalid_aimora_project_v1_toml)
    format = _native_required(raw, "format", AbstractString, _native_span(locations, "format"))
    format == "aimora-project-v1" || _native_fail(
        :unknown_aimora_project_version,
        "AIMORA project TOML format is not aimora-project-v1",
        _native_span(locations, "format"),
    )
    project_raw = _native_required(raw, "project", AbstractDict, _native_span(locations, "project"))
    project_id = _native_portable_segment(
        _native_nonempty_string(project_raw, "id", _native_span(locations, "project.id")),
        _native_span(locations, "project.id"),
    )
    _native_nonempty_string(project_raw, "name", _native_span(locations, "project.name"))
    cases_raw = get(raw, "cases", Any[])
    cases_raw isa AbstractVector || _native_fail(
        :invalid_native_field,
        "native migration field cases must be an array of tables",
        _native_span(locations, "cases"),
    )

    drafts = _NativeRecordDraft[]
    operations = ImportPlanOperation[]
    accounting = ImportFieldAccounting[]
    losses = ImportConversionLoss[]
    assumptions = ImportAssumption[]

    format_draft = _native_record("source.format", "source.format", format, source, locations.root)
    _native_add_field!(
        format_draft,
        "format",
        format,
        _native_span(locations, "format"),
        ImportIgnored,
        nothing,
        "exact source-version discriminator is owned by the adapter identity",
        "source.format",
        operations,
        accounting,
        losses,
    )
    _native_unknown_fields!(
        raw,
        Set(["format", "project", "cases"]),
        "",
        format_draft,
        "source.format",
        locations,
        operations,
        accounting,
        losses,
    )
    push!(drafts, format_draft)

    project_object = string("project.", project_id)
    project_draft = _native_record("record.project", "project", project_id, source, _native_span(locations, "project"))
    push!(operations, ImportCreateObject(project_object, "project", project_draft.record_id))
    _native_add_field!(project_draft, "id", project_id, _native_span(locations, "project.id"), ImportMapped, FormatPath("id"), nothing, project_object, operations, accounting, losses)
    _native_add_field!(project_draft, "name", project_raw["name"], _native_span(locations, "project.name"), ImportMapped, FormatPath("name"), nothing, project_object, operations, accounting, losses)
    metadata_refs = ImportSourceFieldRef[]
    if haskey(project_raw, "metadata")
        metadata = project_raw["metadata"]
        metadata isa AbstractDict || _native_fail(:invalid_native_field, "project metadata must be a TOML table", _native_span(locations, "project.metadata"))
        for (name, value) in _native_flatten(metadata, "metadata")
            ref = _native_add_field!(project_draft, name, value, _native_span(locations, string("project.", name)), ImportMapped, FormatPath(split(name, '.')...), nothing, project_object, operations, accounting, losses)
            push!(metadata_refs, ref)
        end
    end
    _native_unknown_fields!(project_raw, Set(["id", "name", "metadata"]), "project", project_draft, project_object, locations, operations, accounting, losses)
    push!(drafts, project_draft)
    isempty(metadata_refs) || push!(assumptions, ImportAssumption(
        "assumption.project_metadata_dictionary",
        "legacy project metadata is an arbitrary Dict-shaped TOML subtree without a field schema",
        "values are retained as metadata leaves but receive no engineering interpretation",
        metadata_refs,
    ))

    parameter_refs = ImportSourceFieldRef[]
    seen_case_ids = Set{String}()
    for (case_index, case_value) in enumerate(cases_raw)
        case_path = string("cases[", case_index, ']')
        case_value isa AbstractDict || _native_fail(:invalid_native_field, "project case must be a TOML table", _native_span(locations, case_path))
        case_id = _native_portable_segment(_native_nonempty_string(case_value, "id", _native_span(locations, string(case_path, ".id"))), _native_span(locations, string(case_path, ".id")))
        case_id in seen_case_ids && _native_fail(:duplicate_native_identifier, "project repeats case ID $(case_id)", _native_span(locations, string(case_path, ".id")))
        push!(seen_case_ids, case_id)
        _native_nonempty_string(case_value, "name", _native_span(locations, string(case_path, ".name")))
        case_object = string("case.", case_id)
        case_record_id = string("record.case.", case_id)
        case_draft = _native_record(case_record_id, "case", case_id, source, _native_span(locations, case_path))
        push!(operations, ImportCreateObject(case_object, "case", case_record_id))
        case_id_ref = _native_add_field!(case_draft, "id", case_id, _native_span(locations, string(case_path, ".id")), ImportMapped, FormatPath("id"), nothing, case_object, operations, accounting, losses)
        _native_add_field!(case_draft, "name", case_value["name"], _native_span(locations, string(case_path, ".name")), ImportMapped, FormatPath("name"), nothing, case_object, operations, accounting, losses)
        push!(operations, ImportFieldAssignment(case_object, FormatPath("project_id"), _native_format_node(project_id, _native_span(locations, case_path)), case_id_ref))
        _native_unknown_fields!(case_value, Set(["id", "name", "revisions", "scenarios"]), case_path, case_draft, case_object, locations, operations, accounting, losses)
        push!(drafts, case_draft)

        revisions = get(case_value, "revisions", Any[])
        revisions isa AbstractVector || _native_fail(:invalid_native_field, "case revisions must be an array", _native_span(locations, string(case_path, ".revisions")))
        seen_revision_ids = Set{String}()
        for (revision_index, revision) in enumerate(revisions)
            revision_path = string(case_path, ".revisions[", revision_index, ']')
            revision isa AbstractDict || _native_fail(:invalid_native_field, "case revision must be a TOML table", _native_span(locations, revision_path))
            revision_id = _native_portable_segment(_native_nonempty_string(revision, "id", _native_span(locations, string(revision_path, ".id"))), _native_span(locations, string(revision_path, ".id")))
            revision_id in seen_revision_ids && _native_fail(:duplicate_native_identifier, "case repeats revision ID $(revision_id)", _native_span(locations, string(revision_path, ".id")))
            push!(seen_revision_ids, revision_id)
            _native_nonempty_string(revision, "created_at", _native_span(locations, string(revision_path, ".created_at")))
            for field in ("author", "description")
                haskey(revision, field) && _native_required(revision, field, AbstractString, _native_span(locations, string(revision_path, '.', field)))
            end
            if haskey(revision, "parent_id")
                parent_id = _native_nonempty_string(revision, "parent_id", _native_span(locations, string(revision_path, ".parent_id")))
                _native_portable_segment(parent_id, _native_span(locations, string(revision_path, ".parent_id")))
            end
            revision_object = string("revision.", case_id, '.', revision_id)
            revision_record_id = string("record.revision.", case_id, '.', revision_id)
            draft = _native_record(revision_record_id, "revision", revision_id, source, _native_span(locations, revision_path))
            push!(operations, ImportCreateObject(revision_object, "revision", revision_record_id))
            for field in ("id", "created_at", "author", "description", "parent_id")
                haskey(revision, field) || continue
                destination = field == "id" ? FormatPath("id") : FormatPath(field)
                _native_add_field!(draft, field, revision[field], _native_span(locations, string(revision_path, '.', field)), ImportMapped, destination, nothing, revision_object, operations, accounting, losses)
            end
            revision_id_ref = ImportSourceFieldRef(revision_record_id, "id")
            push!(operations, ImportFieldAssignment(revision_object, FormatPath("case_id"), _native_format_node(case_id, _native_span(locations, revision_path)), revision_id_ref))
            _native_unknown_fields!(revision, Set(["id", "created_at", "author", "description", "parent_id"]), revision_path, draft, revision_object, locations, operations, accounting, losses)
            push!(drafts, draft)
        end

        scenarios = get(case_value, "scenarios", Any[])
        scenarios isa AbstractVector || _native_fail(:invalid_native_field, "case scenarios must be an array", _native_span(locations, string(case_path, ".scenarios")))
        seen_scenario_ids = Set{String}()
        for (scenario_index, scenario) in enumerate(scenarios)
            scenario_path = string(case_path, ".scenarios[", scenario_index, ']')
            scenario isa AbstractDict || _native_fail(:invalid_native_field, "case scenario must be a TOML table", _native_span(locations, scenario_path))
            scenario_id = _native_portable_segment(_native_nonempty_string(scenario, "id", _native_span(locations, string(scenario_path, ".id"))), _native_span(locations, string(scenario_path, ".id")))
            scenario_id in seen_scenario_ids && _native_fail(:duplicate_native_identifier, "case repeats scenario ID $(scenario_id)", _native_span(locations, string(scenario_path, ".id")))
            push!(seen_scenario_ids, scenario_id)
            _native_nonempty_string(scenario, "name", _native_span(locations, string(scenario_path, ".name")))
            scenario_object = string("scenario.", case_id, '.', scenario_id)
            scenario_record_id = string("record.scenario.", case_id, '.', scenario_id)
            draft = _native_record(scenario_record_id, "scenario", scenario_id, source, _native_span(locations, scenario_path))
            push!(operations, ImportCreateObject(scenario_object, "scenario", scenario_record_id))
            _native_add_field!(draft, "id", scenario_id, _native_span(locations, string(scenario_path, ".id")), ImportMapped, FormatPath("id"), nothing, scenario_object, operations, accounting, losses)
            _native_add_field!(draft, "name", scenario["name"], _native_span(locations, string(scenario_path, ".name")), ImportMapped, FormatPath("name"), nothing, scenario_object, operations, accounting, losses)
            scenario_id_ref = ImportSourceFieldRef(scenario_record_id, "id")
            push!(operations, ImportFieldAssignment(scenario_object, FormatPath("case_id"), _native_format_node(case_id, _native_span(locations, scenario_path)), scenario_id_ref))
            if haskey(scenario, "asset_tables")
                tables = scenario["asset_tables"]
                tables isa AbstractVector || _native_fail(:invalid_native_field, "scenario asset_tables must be an array", _native_span(locations, string(scenario_path, ".asset_tables")))
                if isempty(tables)
                    _native_add_field!(draft, "asset_tables", tables, _native_span(locations, string(scenario_path, ".asset_tables")), ImportIgnored, nothing, "empty legacy table-name list carries no asset content", scenario_object, operations, accounting, losses)
                else
                    for (table_index, table) in enumerate(tables)
                        table isa AbstractString || _native_fail(:invalid_native_field, "scenario asset table name must be a string", _native_span(locations, string(scenario_path, ".asset_tables")))
                        _native_add_field!(draft, string("asset_tables.", table_index), table, _native_span(locations, string(scenario_path, ".asset_tables")), ImportUnsupported, nothing, "legacy project TOML stores only a table name and supplies no path, schema, content, unit contract, or hash", scenario_object, operations, accounting, losses)
                    end
                end
            end
            _native_unknown_fields!(scenario, Set(["id", "name", "asset_tables", "study_settings"]), scenario_path, draft, scenario_object, locations, operations, accounting, losses)
            push!(drafts, draft)

            settings = get(scenario, "study_settings", Any[])
            settings isa AbstractVector || _native_fail(:invalid_native_field, "scenario study_settings must be an array", _native_span(locations, string(scenario_path, ".study_settings")))
            seen_studies = Set{String}()
            for (settings_index, setting) in enumerate(settings)
                setting_path = string(scenario_path, ".study_settings[", settings_index, ']')
                setting isa AbstractDict || _native_fail(:invalid_native_field, "study settings must be a TOML table", _native_span(locations, setting_path))
                study = _native_portable_segment(_native_nonempty_string(setting, "study", _native_span(locations, string(setting_path, ".study"))), _native_span(locations, string(setting_path, ".study")))
                study in seen_studies && _native_fail(:duplicate_native_identifier, "scenario repeats study settings for $(study)", _native_span(locations, string(setting_path, ".study")))
                push!(seen_studies, study)
                parameters = get(setting, "parameters", Dict{String,Any}())
                parameters isa AbstractDict || _native_fail(:invalid_native_field, "study parameters must be a TOML table", _native_span(locations, string(setting_path, ".parameters")))
                settings_object = string("study_settings.", case_id, '.', scenario_id, '.', study)
                settings_record_id = string("record.study_settings.", case_id, '.', scenario_id, '.', study)
                settings_draft = _native_record(settings_record_id, "study_settings", study, source, _native_span(locations, setting_path))
                push!(operations, ImportCreateObject(settings_object, "study_settings", settings_record_id))
                _native_add_field!(settings_draft, "study", study, _native_span(locations, string(setting_path, ".study")), ImportMapped, FormatPath("study"), nothing, settings_object, operations, accounting, losses)
                for (name, value) in _native_flatten(parameters, "parameters")
                    ref = _native_add_field!(settings_draft, name, value, _native_span(locations, string(setting_path, '.', name)), ImportMapped, FormatPath(split(name, '.')...), nothing, settings_object, operations, accounting, losses)
                    push!(parameter_refs, ref)
                end
                _native_unknown_fields!(setting, Set(["study", "parameters"]), setting_path, settings_draft, settings_object, locations, operations, accounting, losses)
                push!(drafts, settings_draft)
            end
        end
    end
    isempty(parameter_refs) || push!(assumptions, ImportAssumption(
        "assumption.study_settings_dictionary",
        "legacy study settings are arbitrary Dict-shaped values without field schemas, units, or provenance",
        "values are retained verbatim but receive no validated study semantics",
        parameter_refs,
    ))
    push!(assumptions, ImportAssumption(
        "assumption.project_v1_artifact_identity",
        "aimora-project-v1 contains no project-wide schema lock, catalog lock, plugin lock, artifact checksum, or table-content hash",
        "the original source hash is recorded, but referenced resources cannot be authenticated or resolved from this document alone",
    ))
    adapter = _native_adapter("aimora.native.project_v1", "aimora-project", "aimora-project-v1", _AIMORA_PROJECT_V1_FIXTURE_SHA256)
    return _native_result(source, adapter, drafts, operations, accounting, assumptions, losses)
end

"""Read inert `aimora-project-v1` TOML into source records, an import plan, and a complete loss report."""
function read_aimora_project_v1(source::SourceDocument; policy::FormatInputPolicy = FormatInputPolicy())
    try
        return _read_aimora_project_v1(source, policy)
    catch error
        error isa _NativeMigrationFailure || rethrow()
        return FormatResult{GenericImportResult}(nothing, [error.diagnostic])
    end
end

function read_aimora_project_v1(bytes::AbstractVector{UInt8}; source_name::AbstractString = "<memory>", policy::FormatInputPolicy = FormatInputPolicy())
    admitted = _native_admitted_source(bytes, source_name, policy)
    format_succeeded(admitted) || return FormatResult{GenericImportResult}(nothing, collect(admitted.diagnostics))
    return read_aimora_project_v1(admitted.value; policy)
end

read_aimora_project_v1(text::AbstractString; source_name::AbstractString = "<memory>", policy::FormatInputPolicy = FormatInputPolicy()) =
    read_aimora_project_v1(Vector{UInt8}(codeunits(text)); source_name, policy)

function _native_asset_csv_cell(field::_DelimitedRawField, column::BulkColumnSpec)
    field.span.start.line == field.span.stop.line || _bulk_fail(
        :unsupported_legacy_csv_multiline,
        "current AIMORA asset CSV does not admit a field spanning physical lines",
        field.span,
    )
    text = String(strip(field.text))
    if isempty(text)
        column.nullable || _bulk_fail(
            :null_in_required_bulk_column,
            "empty legacy CSV field occurs in required column $(column.name)",
            field.span,
        )
        return FormatNode(FormatNull(), field.span)
    end
    value = if column.kind == BulkString
        FormatString(text)
    elseif column.kind == BulkInteger
        parsed = tryparse(BigInt, text)
        isnothing(parsed) && _bulk_fail(
            :invalid_bulk_integer,
            "legacy CSV column $(column.name) requires an integer",
            field.span,
        )
        FormatInteger(parsed)
    elseif column.kind == BulkDecimal
        parsed = _bulk_decimal_value(text)
        if isnothing(parsed) && occursin(r"^(?:0|-?[1-9][0-9]*)$", text)
            parsed = FormatDecimal(parse(BigInt, text), 0)
        end
        isnothing(parsed) && _bulk_fail(
            :invalid_bulk_decimal,
            "legacy CSV column $(column.name) requires a finite decimal",
            field.span,
        )
        parsed
    else
        lowercase(text) in ("true", "false") || _bulk_fail(
            :invalid_bulk_boolean,
            "legacy CSV column $(column.name) requires true or false",
            field.span,
        )
        FormatBoolean(lowercase(text) == "true")
    end
    return FormatNode(value, field.span)
end

function _parse_aimora_asset_csv(
    source::SourceDocument,
    schema::BulkTableSchema,
    policy::FormatInputPolicy,
)
    grammar = DelimitedTextPolicy()
    isempty(source.text) && return BulkParseResult(ParsedBulkTable(source, BulkTable(schema, BulkRow[])))
    scanner = _DelimitedScanner(source, grammar, policy, 1, ncodeunits(source.text) + 1, 0)
    rows = BulkRow[]
    identities = Set{String}()
    try
        header = _delimited_next_record!(scanner)
        isnothing(header) && _bulk_fail(:missing_bulk_header, "legacy asset CSV requires a header", source_span(source, 1, 1))
        _bulk_validate_header(header, schema)
        while true
            record = _delimited_next_record!(scanner)
            isnothing(record) && break
            if length(record.fields) == 1 &&
               !record.fields[1].quoted &&
               isempty(strip(record.fields[1].text))
                continue
            end
            length(record.fields) == length(schema.columns) || _bulk_fail(
                :bulk_row_width_mismatch,
                "legacy asset CSV row width differs from its supplied schema",
                record.span,
            )
            row = BulkRow(
                FormatNode[_native_asset_csv_cell(field, column) for (field, column) in zip(record.fields, schema.columns)],
                record.span,
            )
            identity = _bulk_identity_key(schema, row)
            identity in identities && _bulk_fail(:duplicate_bulk_row_identity, "legacy asset CSV row identity is duplicated", _bulk_identity_span(schema, row))
            push!(identities, identity)
            push!(rows, row)
        end
        return BulkParseResult(ParsedBulkTable(source, BulkTable(schema, rows)))
    catch error
        error isa _BulkFailure || rethrow()
        return BulkParseResult(nothing, [error.diagnostic])
    end
end

"""Read current schema-aware AIMORA asset CSV without invoking engine defaults or project constructors."""
function read_aimora_asset_csv(
    source::SourceDocument,
    schema::BulkTableSchema,
    object_type::AbstractString,
    object_namespace::AbstractString,
    rules::AbstractVector{ImportFieldRule};
    assumptions::AbstractVector{ImportAssumption} = ImportAssumption[],
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    parsed = _parse_aimora_asset_csv(source, schema, policy)
    format_succeeded(parsed) || return FormatResult{GenericImportResult}(nothing, collect(parsed.diagnostics))
    numeric_without_units = String[
        column.name for column in schema.columns
        if column.kind in (BulkInteger, BulkDecimal) && isnothing(column.unit)
    ]
    standard = ImportAssumption[
        ImportAssumption(
            "assumption.asset_csv_external_schema",
            "current asset CSV embeds no schema ID, schema version, column types, defaults, unit registry, provenance, or content hash",
            "the caller-supplied BulkTableSchema and field rules are authoritative for this inert migration only",
        ),
        ImportAssumption(
            "assumption.asset_csv_empty_missing",
            "the current AIMORA CSV reader treats a stripped empty field as missing even when quoted",
            "empty cells are retained as explicit null only in nullable supplied columns; engine-owned defaults are not invented or applied",
        ),
    ]
    isempty(numeric_without_units) || push!(standard, ImportAssumption(
        "assumption.asset_csv_implicit_units",
        "numeric CSV columns without supplied unit metadata have implicit or unknown engineering units",
        "numeric values are retained without inferred unit conversion",
    ))
    append!(standard, assumptions)
    adapter = _native_adapter(
        string("aimora.native.asset_csv.schema_", first(_native_bulk_schema_digest(schema), 16)),
        schema.id,
        string(schema.version),
        _AIMORA_ASSET_CSV_FIXTURE_SHA256,
    )
    return compile_generic_table_import(
        parsed.value,
        adapter,
        object_type,
        object_namespace,
        rules;
        assumptions = standard,
    )
end

function read_aimora_asset_csv(
    bytes::AbstractVector{UInt8},
    schema::BulkTableSchema,
    object_type::AbstractString,
    object_namespace::AbstractString,
    rules::AbstractVector{ImportFieldRule};
    source_name::AbstractString = "<memory>",
    assumptions::AbstractVector{ImportAssumption} = ImportAssumption[],
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = _native_admitted_source(bytes, source_name, policy)
    format_succeeded(admitted) || return FormatResult{GenericImportResult}(nothing, collect(admitted.diagnostics))
    return read_aimora_asset_csv(admitted.value, schema, object_type, object_namespace, rules; assumptions, policy)
end

read_aimora_asset_csv(
    text::AbstractString,
    schema::BulkTableSchema,
    object_type::AbstractString,
    object_namespace::AbstractString,
    rules::AbstractVector{ImportFieldRule};
    source_name::AbstractString = "<memory>",
    assumptions::AbstractVector{ImportAssumption} = ImportAssumption[],
    policy::FormatInputPolicy = FormatInputPolicy(),
) = read_aimora_asset_csv(
    Vector{UInt8}(codeunits(text)),
    schema,
    object_type,
    object_namespace,
    rules;
    source_name,
    assumptions,
    policy,
)

function _read_aimora_catalog_entry_v1(source::SourceDocument, policy::FormatInputPolicy)
    raw, locations = _native_toml(source, policy, :invalid_aimora_catalog_v1_toml)
    schema = _native_required(raw, "schema", AbstractString, _native_span(locations, "schema"))
    schema == "aimora-catalog-entry-v1" || _native_fail(
        :unknown_aimora_catalog_version,
        "AIMORA catalog TOML schema is not aimora-catalog-entry-v1",
        _native_span(locations, "schema"),
    )
    id = _native_portable_segment(
        _native_nonempty_string(raw, "id", _native_span(locations, "id")),
        _native_span(locations, "id"),
    )
    for key in ("equipment_class", "model", "provenance", "licence")
        _native_nonempty_string(raw, key, _native_span(locations, key))
    end
    manufacturer = _native_required(raw, "manufacturer", AbstractString, _native_span(locations, "manufacturer"))
    common = _native_required(raw, "common", AbstractDict, _native_span(locations, "common"))
    study = _native_required(raw, "study", AbstractDict, _native_span(locations, "study"))
    isempty(study) && _native_fail(:invalid_native_field, "catalog entry requires at least one study facet", _native_span(locations, "study"))

    drafts = _NativeRecordDraft[]
    operations = ImportPlanOperation[]
    accounting = ImportFieldAccounting[]
    losses = ImportConversionLoss[]
    assumptions = ImportAssumption[]
    format_draft = _native_record("source.schema", "source.schema", schema, source, locations.root)
    _native_add_field!(format_draft, "schema", schema, _native_span(locations, "schema"), ImportIgnored, nothing, "exact source-version discriminator is owned by the adapter identity", "source.schema", operations, accounting, losses)
    push!(drafts, format_draft)

    object_id = string("catalog.", id)
    draft = _native_record(string("record.catalog.", id), "catalog_entry", id, source, locations.root)
    push!(operations, ImportCreateObject(object_id, "catalog_entry", draft.record_id))
    for (key, destination) in (
        "id" => FormatPath("id"),
        "equipment_class" => FormatPath("equipment_class"),
        "manufacturer" => FormatPath("manufacturer"),
        "model" => FormatPath("model"),
        "provenance" => FormatPath("provenance"),
        "licence" => FormatPath("licence"),
    )
        value = key == "manufacturer" ? manufacturer : raw[key]
        _native_add_field!(draft, key, value, _native_span(locations, key), ImportMapped, destination, nothing, object_id, operations, accounting, losses)
    end
    parameter_refs = ImportSourceFieldRef[]
    for (name, value) in _native_flatten(common, "common")
        ref = _native_add_field!(draft, name, value, _native_span(locations, name), ImportMapped, FormatPath(split(name, '.')...), nothing, object_id, operations, accounting, losses)
        push!(parameter_refs, ref)
    end
    for study_name in sort!(String[String(key) for key in keys(study)])
        facet = study[study_name]
        facet isa AbstractDict || _native_fail(:invalid_native_field, "catalog study facet $(study_name) must be a TOML table", _native_span(locations, string("study.", study_name)))
        for (name, value) in _native_flatten(facet, string("study.", study_name))
            destination = FormatPath(vcat(["realizations", study_name, "parameters"], split(name, '.')[3:end])...)
            ref = _native_add_field!(draft, name, value, _native_span(locations, name), ImportMapped, destination, nothing, object_id, operations, accounting, losses)
            push!(parameter_refs, ref)
        end
    end
    _native_unknown_fields!(raw, Set(["schema", "id", "equipment_class", "manufacturer", "model", "provenance", "licence", "common", "study"]), "", draft, object_id, locations, operations, accounting, losses)
    push!(drafts, draft)
    push!(assumptions, ImportAssumption(
        "assumption.catalog_parameter_dictionaries",
        "current catalog common and study facets are arbitrary Dict-shaped parameter sets without registered field schemas",
        "all leaves are retained, but their canonical parameter ownership and validity domains remain unverified",
        parameter_refs,
    ))
    push!(assumptions, ImportAssumption(
        "assumption.catalog_implicit_units",
        "current catalog engineering units and per-unit bases are encoded only by optional parameter-name suffixes",
        "values receive no inferred unit, base, orientation, or conversion",
        parameter_refs,
    ))
    push!(assumptions, ImportAssumption(
        "assumption.catalog_missing_lock",
        "current catalog entries contain no asset-schema version, source artifact hash, uncertainty contract, validity schema, or catalog lock",
        "the exact TOML source hash is retained, but package-level compatibility and authenticity require separate evidence",
    ))
    adapter = _native_adapter("aimora.native.catalog_v1", "aimora-catalog-entry", "aimora-catalog-entry-v1", _AIMORA_CATALOG_V1_FIXTURE_SHA256)
    return _native_result(source, adapter, drafts, operations, accounting, assumptions, losses)
end

"""Read one current AIMORACatalogs `aimora-catalog-entry-v1` TOML record inertly."""
function read_aimora_catalog_entry_v1(source::SourceDocument; policy::FormatInputPolicy = FormatInputPolicy())
    try
        return _read_aimora_catalog_entry_v1(source, policy)
    catch error
        error isa _NativeMigrationFailure || rethrow()
        return FormatResult{GenericImportResult}(nothing, [error.diagnostic])
    end
end

function read_aimora_catalog_entry_v1(bytes::AbstractVector{UInt8}; source_name::AbstractString = "<memory>", policy::FormatInputPolicy = FormatInputPolicy())
    admitted = _native_admitted_source(bytes, source_name, policy)
    format_succeeded(admitted) || return FormatResult{GenericImportResult}(nothing, collect(admitted.diagnostics))
    return read_aimora_catalog_entry_v1(admitted.value; policy)
end

read_aimora_catalog_entry_v1(text::AbstractString; source_name::AbstractString = "<memory>", policy::FormatInputPolicy = FormatInputPolicy()) =
    read_aimora_catalog_entry_v1(Vector{UInt8}(codeunits(text)); source_name, policy)

function _native_relative_resource_path(path::String)
    isempty(path) && return false
    startswith(path, '/') && return false
    occursin('\\', path) && return false
    occursin(r"^[A-Za-z]:", path) && return false
    segments = split(path, '/')
    return all(segment -> !isempty(segment) && segment ∉ (".", ".."), segments)
end

function _read_aimora_cases_catalog_v2(
    source::SourceDocument,
    policy::FormatInputPolicy,
    available_paths,
)
    raw, locations = _native_toml(source, policy, :invalid_aimora_cases_v2_toml)
    schema = _native_required(raw, "schema", AbstractString, _native_span(locations, "schema"))
    schema == "aimora-examples-v2" || _native_fail(
        :unknown_aimora_cases_version,
        "AIMORACases catalogue TOML schema is not aimora-examples-v2",
        _native_span(locations, "schema"),
    )
    cases = _native_required(raw, "case", AbstractVector, _native_span(locations, "case"))
    known_paths = if isnothing(available_paths)
        nothing
    else
        values = String[]
        for path in available_paths
            path isa AbstractString || throw(ArgumentError("available case resource paths must be strings"))
            push!(values, String(path))
        end
        Set(values)
    end

    drafts = _NativeRecordDraft[]
    operations = ImportPlanOperation[]
    accounting = ImportFieldAccounting[]
    losses = ImportConversionLoss[]
    assumptions = ImportAssumption[]
    format_draft = _native_record("source.schema", "source.schema", schema, source, locations.root)
    _native_add_field!(format_draft, "schema", schema, _native_span(locations, "schema"), ImportIgnored, nothing, "exact source-version discriminator is owned by the adapter identity", "source.schema", operations, accounting, losses)
    _native_unknown_fields!(raw, Set(["schema", "case"]), "", format_draft, "source.schema", locations, operations, accounting, losses)
    push!(drafts, format_draft)

    seen_ids = Set{String}()
    resource_refs = ImportSourceFieldRef[]
    for (index, case) in enumerate(cases)
        case_path = string("case[", index, ']')
        case isa AbstractDict || _native_fail(:invalid_native_field, "case catalogue row must be a TOML table", _native_span(locations, case_path))
        id = _native_portable_segment(_native_nonempty_string(case, "id", _native_span(locations, string(case_path, ".id"))), _native_span(locations, string(case_path, ".id")))
        id in seen_ids && _native_fail(:duplicate_native_identifier, "case catalogue repeats ID $(id)", _native_span(locations, string(case_path, ".id")))
        push!(seen_ids, id)
        for key in ("study", "path", "entrypoint", "description", "result_kind")
            _native_nonempty_string(case, key, _native_span(locations, string(case_path, '.', key)))
        end
        for key in ("requires_solver", "reference_compatible")
            _native_required(case, key, Bool, _native_span(locations, string(case_path, '.', key)))
        end
        if haskey(case, "source_ids")
            ids = case["source_ids"]
            ids isa AbstractVector || _native_fail(:invalid_native_field, "case source_ids must be an array", _native_span(locations, string(case_path, ".source_ids")))
            all(item -> item isa AbstractString && !isempty(item), ids) || _native_fail(:invalid_native_field, "case source_ids must contain nonempty strings", _native_span(locations, string(case_path, ".source_ids")))
        end
        object_id = string("example.", id)
        draft = _native_record(string("record.example.", id), "example_case", id, source, _native_span(locations, case_path))
        push!(operations, ImportCreateObject(object_id, "example_case", draft.record_id))
        for key in ("id", "study", "description", "requires_solver", "reference_compatible", "result_kind", "source_ids")
            haskey(case, key) || continue
            destination = key == "id" ? FormatPath("id") : FormatPath(key)
            _native_add_field!(draft, key, case[key], _native_span(locations, string(case_path, '.', key)), ImportMapped, destination, nothing, object_id, operations, accounting, losses)
        end
        for key in ("path", "entrypoint")
            path = String(case[key])
            span = _native_span(locations, string(case_path, '.', key))
            portable = _native_relative_resource_path(path)
            present = isnothing(known_paths) || path in known_paths
            disposition = portable && present ? ImportMapped : ImportRejected
            justification = if !portable
                "case resource path is not a portable package-relative path"
            elseif !present
                "case resource path is absent from the explicitly supplied resource inventory"
            else
                nothing
            end
            ref = _native_add_field!(draft, key, path, span, disposition, disposition == ImportMapped ? FormatPath(key) : nothing, justification, object_id, operations, accounting, losses)
            push!(resource_refs, ref)
        end
        _native_unknown_fields!(case, Set(["id", "study", "path", "entrypoint", "description", "requires_solver", "reference_compatible", "result_kind", "source_ids"]), case_path, draft, object_id, locations, operations, accounting, losses)
        push!(drafts, draft)
    end
    if isnothing(known_paths)
        push!(assumptions, ImportAssumption(
            "assumption.case_resource_inventory_unavailable",
            "case paths and Julia entrypoints were parsed inertly without an explicit resource inventory",
            "existence is unverified and no entrypoint is loaded or executed",
            resource_refs,
        ))
    end
    push!(assumptions, ImportAssumption(
        "assumption.case_catalog_missing_hashes",
        "current case catalogue rows contain no referenced-file hashes, package revision, input schema binding, environment lock, licence, or per-row provenance",
        "the catalogue source hash is retained, but referenced inputs and executable entrypoints are not authenticated",
        resource_refs,
    ))
    adapter = _native_adapter("aimora.native.cases_v2", "aimora-examples", "aimora-examples-v2", _AIMORA_CASES_V2_FIXTURE_SHA256)
    return _native_result(source, adapter, drafts, operations, accounting, assumptions, losses)
end

"""Read the current AIMORACases `aimora-examples-v2` catalogue without loading or executing entrypoints."""
function read_aimora_cases_catalog_v2(
    source::SourceDocument;
    available_paths = nothing,
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    try
        return _read_aimora_cases_catalog_v2(source, policy, available_paths)
    catch error
        error isa _NativeMigrationFailure || rethrow()
        return FormatResult{GenericImportResult}(nothing, [error.diagnostic])
    end
end

function read_aimora_cases_catalog_v2(
    bytes::AbstractVector{UInt8};
    source_name::AbstractString = "<memory>",
    available_paths = nothing,
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = _native_admitted_source(bytes, source_name, policy)
    format_succeeded(admitted) || return FormatResult{GenericImportResult}(nothing, collect(admitted.diagnostics))
    return read_aimora_cases_catalog_v2(admitted.value; available_paths, policy)
end

read_aimora_cases_catalog_v2(
    text::AbstractString;
    source_name::AbstractString = "<memory>",
    available_paths = nothing,
    policy::FormatInputPolicy = FormatInputPolicy(),
) = read_aimora_cases_catalog_v2(
    Vector{UInt8}(codeunits(text));
    source_name,
    available_paths,
    policy,
)
