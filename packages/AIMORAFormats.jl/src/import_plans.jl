@enum ImportFieldDisposition::UInt8 begin
    ImportMapped = 0x01
    ImportIgnored = 0x02
    ImportUnsupported = 0x03
    ImportRejected = 0x04
end

@enum ImportNullOperation::UInt8 begin
    ImportCopyValue = 0x01
    ImportOmitNull = 0x02
end

const _IMPORT_PORTABLE_ID_PATTERN = r"^[A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z][A-Za-z0-9_-]*)*$"
const _IMPORT_FORMAT_ID_PATTERN = r"^[A-Za-z][A-Za-z0-9_.+@-]*$"

struct ImportAdapterIdentity
    id::String
    version::VersionNumber
    source_format::String
    source_version::String
    fixture_sha256::FormatItemList{String}

    function ImportAdapterIdentity(
        id::AbstractString,
        version::VersionNumber,
        source_format::AbstractString,
        source_version::AbstractString,
        fixture_sha256::AbstractVector{<:AbstractString},
    )
        normalized_id = String(id)
        occursin(_IMPORT_PORTABLE_ID_PATTERN, normalized_id) ||
            throw(ArgumentError("import adapter ID is not portable"))
        normalized_format = String(source_format)
        occursin(_IMPORT_FORMAT_ID_PATTERN, normalized_format) ||
            throw(ArgumentError("import source format is not portable"))
        normalized_source_version = String(source_version)
        isempty(normalized_source_version) &&
            throw(ArgumentError("import source version must be exact and nonempty"))
        occursin(r"[\x00-\x20]", normalized_source_version) &&
            throw(ArgumentError("import source version contains whitespace or control bytes"))
        fixtures = String[String(digest) for digest in fixture_sha256]
        isempty(fixtures) &&
            throw(ArgumentError("import adapter requires at least one exact fixture"))
        all(digest -> occursin(r"^[0-9a-f]{64}$", digest), fixtures) ||
            throw(ArgumentError("import adapter fixture SHA-256 is malformed"))
        length(fixtures) == length(unique(fixtures)) ||
            throw(ArgumentError("import adapter repeats a fixture SHA-256"))
        sort!(fixtures)
        return new(
            normalized_id,
            version,
            normalized_format,
            normalized_source_version,
            FormatItemList(fixtures),
        )
    end
end

Base.:(==)(left::ImportAdapterIdentity, right::ImportAdapterIdentity) =
    left.id == right.id &&
    left.version == right.version &&
    left.source_format == right.source_format &&
    left.source_version == right.source_version &&
    left.fixture_sha256 == right.fixture_sha256

struct ImportAdapterRegistry
    adapters::FormatItemList{ImportAdapterIdentity}

    function ImportAdapterRegistry(adapters::AbstractVector{ImportAdapterIdentity})
        copied = collect(adapters)
        keys = [(adapter.source_format, adapter.source_version) for adapter in copied]
        length(keys) == length(unique(keys)) ||
            throw(ArgumentError("import registry contains duplicate format/version ownership"))
        identities = [(adapter.id, adapter.version) for adapter in copied]
        length(identities) == length(unique(identities)) ||
            throw(ArgumentError("import registry contains duplicate adapter identities"))
        sort!(copied; by = adapter -> (
            adapter.source_format,
            adapter.source_version,
            adapter.id,
            adapter.version,
        ))
        return new(FormatItemList(copied))
    end
end

Base.:(==)(left::ImportAdapterRegistry, right::ImportAdapterRegistry) =
    left.adapters == right.adapters

struct ImportFieldRule
    source_field::String
    disposition::ImportFieldDisposition
    destination::Union{Nothing,FormatPath}
    justification::Union{Nothing,String}
    null_operation::ImportNullOperation

    function ImportFieldRule(
        source_field::AbstractString,
        disposition::ImportFieldDisposition;
        destination::Union{Nothing,FormatPath} = nothing,
        justification::Union{Nothing,AbstractString} = nothing,
        null_operation::ImportNullOperation = ImportCopyValue,
    )
        field = String(source_field)
        occursin(r"^[A-Za-z_\$][A-Za-z0-9_.\$-]*$", field) ||
            throw(ArgumentError("import source field is not portable"))
        reason = isnothing(justification) ? nothing : String(justification)
        if disposition == ImportMapped
            isnothing(destination) &&
                throw(ArgumentError("mapped import field requires a destination path"))
            !isnothing(reason) && isempty(reason) &&
                throw(ArgumentError("import field justification must not be empty"))
        else
            !isnothing(destination) &&
                throw(ArgumentError("nonmapped import field cannot declare a destination"))
            (isnothing(reason) || isempty(reason)) &&
                throw(ArgumentError("nonmapped import field requires a justification"))
            null_operation == ImportCopyValue ||
                throw(ArgumentError("nonmapped import field cannot declare null behavior"))
        end
        return new(field, disposition, destination, reason, null_operation)
    end
end

Base.:(==)(left::ImportFieldRule, right::ImportFieldRule) =
    left.source_field == right.source_field &&
    left.disposition == right.disposition &&
    left.destination == right.destination &&
    left.justification == right.justification &&
    left.null_operation == right.null_operation

struct ImportSourceFieldRef
    record_id::String
    field::String
end

Base.:(==)(left::ImportSourceFieldRef, right::ImportSourceFieldRef) =
    left.record_id == right.record_id && left.field == right.field

struct ImportSourceField
    name::String
    value::FormatNode
    unit::Union{Nothing,String}
    basis::Union{Nothing,String}
end

Base.:(==)(left::ImportSourceField, right::ImportSourceField) =
    left.name == right.name &&
    left.value == right.value &&
    left.unit == right.unit &&
    left.basis == right.basis

struct ImportSourceRecord
    record_id::String
    record_type::String
    raw_identifier::String
    source_name::String
    span::SourceSpan
    fields::FormatItemList{ImportSourceField}
end

Base.:(==)(left::ImportSourceRecord, right::ImportSourceRecord) =
    left.record_id == right.record_id &&
    left.record_type == right.record_type &&
    left.raw_identifier == right.raw_identifier &&
    left.source_name == right.source_name &&
    left.span == right.span &&
    left.fields == right.fields

abstract type ImportPlanOperation end

struct ImportCreateObject <: ImportPlanOperation
    object_id::String
    object_type::String
    source_record_id::String
end

Base.:(==)(left::ImportCreateObject, right::ImportCreateObject) =
    left.object_id == right.object_id &&
    left.object_type == right.object_type &&
    left.source_record_id == right.source_record_id

struct ImportFieldAssignment <: ImportPlanOperation
    object_id::String
    destination::FormatPath
    value::FormatNode
    source::ImportSourceFieldRef
end

Base.:(==)(left::ImportFieldAssignment, right::ImportFieldAssignment) =
    left.object_id == right.object_id &&
    left.destination == right.destination &&
    left.value == right.value &&
    left.source == right.source

struct ImportFieldAccounting
    source::ImportSourceFieldRef
    disposition::ImportFieldDisposition
    destination::Union{Nothing,FormatPath}
    justification::Union{Nothing,String}
    span::SourceSpan
end

Base.:(==)(left::ImportFieldAccounting, right::ImportFieldAccounting) =
    left.source == right.source &&
    left.disposition == right.disposition &&
    left.destination == right.destination &&
    left.justification == right.justification &&
    left.span == right.span

struct ImportAssumption
    id::String
    description::String
    consequence::String
    affected_fields::FormatItemList{ImportSourceFieldRef}

    function ImportAssumption(
        id::AbstractString,
        description::AbstractString,
        consequence::AbstractString,
        affected_fields::AbstractVector{ImportSourceFieldRef} = ImportSourceFieldRef[],
    )
        normalized_id = String(id)
        occursin(_IMPORT_PORTABLE_ID_PATTERN, normalized_id) ||
            throw(ArgumentError("import assumption ID is not portable"))
        normalized_description = String(description)
        normalized_consequence = String(consequence)
        isempty(normalized_description) &&
            throw(ArgumentError("import assumption description must not be empty"))
        isempty(normalized_consequence) &&
            throw(ArgumentError("import assumption consequence must not be empty"))
        return new(
            normalized_id,
            normalized_description,
            normalized_consequence,
            FormatItemList(collect(affected_fields)),
        )
    end
end


Base.:(==)(left::ImportAssumption, right::ImportAssumption) =
    left.id == right.id &&
    left.description == right.description &&
    left.consequence == right.consequence &&
    left.affected_fields == right.affected_fields

struct ImportConversionLoss
    id::String
    description::String
    consequence::String
    source::ImportSourceFieldRef
end

Base.:(==)(left::ImportConversionLoss, right::ImportConversionLoss) =
    left.id == right.id &&
    left.description == right.description &&
    left.consequence == right.consequence &&
    left.source == right.source

struct ImportConversionReport
    source_records::Int
    source_fields::Int
    mapped_fields::Int
    ignored_fields::Int
    unsupported_fields::Int
    rejected_fields::Int
    operations::Int
    complete::Bool
    accounting::FormatItemList{ImportFieldAccounting}
    assumptions::FormatItemList{ImportAssumption}
    losses::FormatItemList{ImportConversionLoss}

    function ImportConversionReport(
        source_records::Int,
        source_fields::Int,
        mapped_fields::Int,
        ignored_fields::Int,
        unsupported_fields::Int,
        rejected_fields::Int,
        operations::Int,
        complete::Bool,
        accounting::FormatItemList{ImportFieldAccounting},
        assumptions::FormatItemList{ImportAssumption},
        losses::FormatItemList{ImportConversionLoss},
        ::Val{:compiled_import_report},
    )
        counts = (
            source_records,
            source_fields,
            mapped_fields,
            ignored_fields,
            unsupported_fields,
            rejected_fields,
            operations,
        )
        all(count -> count >= 0, counts) ||
            throw(ArgumentError("import report counts must be nonnegative"))
        mapped_fields + ignored_fields + unsupported_fields + rejected_fields ==
            source_fields || throw(ArgumentError("import report field totals do not reconcile"))
        length(accounting) == source_fields ||
            throw(ArgumentError("import report accounting length differs from its total"))
        complete == (iszero(unsupported_fields) && iszero(rejected_fields)) ||
            throw(ArgumentError("import report completeness differs from blocking totals"))
        return new(
            source_records,
            source_fields,
            mapped_fields,
            ignored_fields,
            unsupported_fields,
            rejected_fields,
            operations,
            complete,
            accounting,
            assumptions,
            losses,
        )
    end
end

Base.:(==)(left::ImportConversionReport, right::ImportConversionReport) =
    left.source_records == right.source_records &&
    left.source_fields == right.source_fields &&
    left.mapped_fields == right.mapped_fields &&
    left.ignored_fields == right.ignored_fields &&
    left.unsupported_fields == right.unsupported_fields &&
    left.rejected_fields == right.rejected_fields &&
    left.operations == right.operations &&
    left.complete == right.complete &&
    left.accounting == right.accounting &&
    left.assumptions == right.assumptions &&
    left.losses == right.losses

struct ImportPlan
    adapter::ImportAdapterIdentity
    source_sha256::String
    source_records::FormatItemList{ImportSourceRecord}
    operations::FormatItemList{ImportPlanOperation}
    applicable::Bool
    sha256::String

    function ImportPlan(
        adapter::ImportAdapterIdentity,
        source_sha256::String,
        source_records::AbstractVector{ImportSourceRecord},
        operations::AbstractVector{<:ImportPlanOperation},
        applicable::Bool,
        sha256::String,
        ::Val{:compiled_import_plan},
    )
        return new(
            adapter,
            source_sha256,
            FormatItemList(source_records),
            FormatItemList{ImportPlanOperation}(collect(operations)),
            applicable,
            sha256,
        )
    end
end


Base.:(==)(left::ImportPlan, right::ImportPlan) =
    left.adapter == right.adapter &&
    left.source_sha256 == right.source_sha256 &&
    left.source_records == right.source_records &&
    left.operations == right.operations &&
    left.applicable == right.applicable &&
    left.sha256 == right.sha256

struct GenericImportResult
    plan::ImportPlan
    report::ImportConversionReport
end

Base.:(==)(left::GenericImportResult, right::GenericImportResult) =
    left.plan == right.plan && left.report == right.report

function _import_identifier_text(value::FormatValue)
    value isa FormatString && return value.value
    value isa FormatInteger && return string(value.value)
    error("bulk identity invariant was violated")
end

function _import_plan_digest(
    adapter::ImportAdapterIdentity,
    source_sha256::String,
    records::AbstractVector{ImportSourceRecord},
    operations::AbstractVector{<:ImportPlanOperation},
    applicable::Bool,
)
    output = IOBuffer()
    print(
        output,
        adapter.id,
        '\0',
        adapter.version,
        '\0',
        adapter.source_format,
        '\0',
        adapter.source_version,
        '\0',
        source_sha256,
        '\0',
        applicable ? "applicable\0" : "blocked\0",
    )
    for record in records
        print(output, record.record_id, '\0', record.record_type, '\0', record.raw_identifier, '\0')
        for field in record.fields
            serialized = serialize_canonical_json(field.value)
            format_succeeded(serialized) || error("validated source field did not serialize")
            print(output, field.name, '\0')
            write(output, collect(serialized.value.bytes))
            print(output, '\0', something(field.unit, ""), '\0', something(field.basis, ""), '\0')
        end
    end
    for operation in operations
        if operation isa ImportCreateObject
            print(
                output,
                "create\0",
                operation.object_id,
                '\0',
                operation.object_type,
                '\0',
                operation.source_record_id,
                '\0',
            )
        else
            serialized = serialize_canonical_json(operation.value)
            format_succeeded(serialized) || error("validated import assignment did not serialize")
            print(output, "set\0", operation.object_id, '\0', sprint(show, operation.destination), '\0')
            write(output, collect(serialized.value.bytes))
            print(output, '\0', operation.source.record_id, '\0', operation.source.field, '\0')
        end
    end
    return bytes2hex(sha256(take!(output)))
end

"""Recompute the deterministic identity of an inert import plan."""
import_plan_sha256(plan::ImportPlan) = _import_plan_digest(
    plan.adapter,
    plan.source_sha256,
    collect(plan.source_records),
    collect(plan.operations),
    plan.applicable,
)

function _compile_import_components(
    source::SourceDocument,
    adapter::ImportAdapterIdentity,
    source_records::AbstractVector{ImportSourceRecord},
    operations::AbstractVector{<:ImportPlanOperation},
    accounting::AbstractVector{ImportFieldAccounting};
    assumptions::AbstractVector{ImportAssumption} = ImportAssumption[],
    losses::AbstractVector{ImportConversionLoss} = ImportConversionLoss[],
)
    record_ids = getfield.(source_records, :record_id)
    length(record_ids) == length(unique(record_ids)) ||
        throw(ArgumentError("import source records repeat an ID"))
    source_fields = Set{Tuple{String,String}}()
    for record in source_records, field in record.fields
        key = (record.record_id, field.name)
        key in source_fields && throw(ArgumentError("import source record repeats a field"))
        push!(source_fields, key)
    end
    accounted_fields = [
        (item.source.record_id, item.source.field) for item in accounting
    ]
    length(accounted_fields) == length(unique(accounted_fields)) ||
        throw(ArgumentError("import report accounts for a source field more than once"))
    Set(accounted_fields) == source_fields ||
        throw(ArgumentError("import report does not account for every source field"))
    for item in accounting
        if item.disposition == ImportMapped
            isnothing(item.destination) &&
                throw(ArgumentError("mapped import accounting lacks a destination"))
        else
            !isnothing(item.destination) &&
                throw(ArgumentError("nonmapped import accounting declares a destination"))
            (isnothing(item.justification) || isempty(item.justification)) &&
                throw(ArgumentError("nonmapped import accounting lacks a justification"))
        end
    end
    assumption_ids = getfield.(assumptions, :id)
    length(assumption_ids) == length(unique(assumption_ids)) ||
        throw(ArgumentError("import report repeats an assumption ID"))
    for assumption in assumptions, source_ref in assumption.affected_fields
        (source_ref.record_id, source_ref.field) in source_fields ||
            throw(ArgumentError("import assumption cites an unknown source field"))
    end
    loss_ids = getfield.(losses, :id)
    length(loss_ids) == length(unique(loss_ids)) ||
        throw(ArgumentError("import report repeats a conversion-loss ID"))
    loss_fields = [(loss.source.record_id, loss.source.field) for loss in losses]
    length(loss_fields) == length(unique(loss_fields)) ||
        throw(ArgumentError("import report repeats a conversion loss for one source field"))
    blocking_fields = [
        (item.source.record_id, item.source.field) for item in accounting
        if item.disposition in (ImportUnsupported, ImportRejected)
    ]
    Set(loss_fields) == Set(blocking_fields) ||
        throw(ArgumentError("import conversion losses differ from blocking field accounting"))
    created_objects = Set{String}()
    for operation in operations
        if operation isa ImportCreateObject
            operation.object_id in created_objects &&
                throw(ArgumentError("import plan creates an object more than once"))
            operation.source_record_id in record_ids ||
                throw(ArgumentError("import object creation cites an unknown source record"))
            push!(created_objects, operation.object_id)
        else
            operation.object_id in created_objects ||
                throw(ArgumentError("import assignment precedes or lacks object creation"))
            (operation.source.record_id, operation.source.field) in source_fields ||
                throw(ArgumentError("import assignment cites an unknown source field"))
        end
    end
    counts = Dict(
        disposition => count(item -> item.disposition == disposition, accounting)
        for disposition in instances(ImportFieldDisposition)
    )
    complete = iszero(counts[ImportUnsupported]) && iszero(counts[ImportRejected])
    report = ImportConversionReport(
        length(source_records),
        length(accounting),
        counts[ImportMapped],
        counts[ImportIgnored],
        counts[ImportUnsupported],
        counts[ImportRejected],
        length(operations),
        complete,
        FormatItemList(collect(accounting)),
        FormatItemList(collect(assumptions)),
        FormatItemList(collect(losses)),
        Val(:compiled_import_report),
    )
    digest = _import_plan_digest(
        adapter,
        source.provenance.content_sha256,
        source_records,
        operations,
        complete,
    )
    plan = ImportPlan(
        adapter,
        source.provenance.content_sha256,
        source_records,
        operations,
        complete,
        digest,
        Val(:compiled_import_plan),
    )
    return GenericImportResult(plan, report)
end

function _import_rule_diagnostic(code::Symbol, message::String, span::SourceSpan)
    return FormatDiagnostic(DiagnosticError, code, message, span)
end

"""Compile a typed generic scalar table into an inert canonical import plan and complete report."""
function compile_generic_table_import(
    parsed::ParsedBulkTable,
    adapter::ImportAdapterIdentity,
    object_type::AbstractString,
    object_namespace::AbstractString,
    rules::AbstractVector{ImportFieldRule};
    assumptions::AbstractVector{ImportAssumption} = ImportAssumption[],
)
    schema = parsed.table.schema
    diagnostic_span = isempty(parsed.table.rows) ?
        source_span(parsed.source, 1, 1) : parsed.table.rows[1].span
    normalized_object_type = String(object_type)
    normalized_namespace = String(object_namespace)
    if !occursin(_IMPORT_PORTABLE_ID_PATTERN, normalized_object_type)
        diagnostic = _import_rule_diagnostic(
            :invalid_import_object_type,
            "generic import object type is not portable",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    if !occursin(_IMPORT_PORTABLE_ID_PATTERN, normalized_namespace)
        diagnostic = _import_rule_diagnostic(
            :invalid_import_namespace,
            "generic import namespace is not portable",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    rules_by_field = Dict(rule.source_field => rule for rule in rules)
    if length(rules_by_field) != length(rules)
        diagnostic = _import_rule_diagnostic(
            :duplicate_import_field_rule,
            "generic import contains duplicate field rules",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    column_names = getfield.(collect(schema.columns), :name)
    missing_rules = sort!(collect(setdiff(Set(column_names), Set(keys(rules_by_field)))))
    unknown_rules = sort!(collect(setdiff(Set(keys(rules_by_field)), Set(column_names))))
    if !isempty(missing_rules) || !isempty(unknown_rules)
        code = isempty(missing_rules) ? :unknown_import_field_rule : :missing_import_field_rule
        fields = isempty(missing_rules) ? unknown_rules : missing_rules
        diagnostic = _import_rule_diagnostic(
            code,
            "generic import field accounting differs at $(first(fields))",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    if adapter.source_format != schema.id || adapter.source_version != string(schema.version)
        diagnostic = _import_rule_diagnostic(
            :import_adapter_source_mismatch,
            "import adapter does not own the exact table schema ID and version",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    mapped_destinations = [
        rule.destination for rule in rules
        if rule.disposition == ImportMapped
    ]
    if any(path -> isempty(path.segments), mapped_destinations) ||
       length(mapped_destinations) != length(unique(mapped_destinations))
        diagnostic = _import_rule_diagnostic(
            :ambiguous_import_destination,
            "mapped import fields require unique nonroot destination paths",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    assumption_ids = getfield.(collect(assumptions), :id)
    if length(assumption_ids) != length(unique(assumption_ids))
        diagnostic = _import_rule_diagnostic(
            :duplicate_import_assumption,
            "generic import repeats an assumption ID",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    identity_rule = rules_by_field[schema.identity_column]
    if identity_rule.disposition != ImportMapped ||
       identity_rule.destination != FormatPath("id") ||
       identity_rule.null_operation != ImportCopyValue
        diagnostic = _import_rule_diagnostic(
            :import_identity_mapping_required,
            "bulk identity column must map directly to canonical id",
            diagnostic_span,
        )
        return FormatResult{GenericImportResult}(nothing, [diagnostic])
    end
    source_records = ImportSourceRecord[]
    operations = ImportPlanOperation[]
    accounting = ImportFieldAccounting[]
    losses = ImportConversionLoss[]
    for (row_index, row) in enumerate(parsed.table.rows)
        raw_identifier = _import_identifier_text(bulk_cell(schema, row, schema.identity_column).value)
        occursin(r"^[A-Za-z0-9][A-Za-z0-9_-]*$", raw_identifier) || begin
            diagnostic = _import_rule_diagnostic(
                :invalid_import_record_identifier,
                "generic import row identity is not a portable stable segment",
                _bulk_identity_span(schema, row),
            )
            return FormatResult{GenericImportResult}(nothing, [diagnostic])
        end
        record_id = string("record.", raw_identifier)
        object_id = string(normalized_namespace, '.', raw_identifier)
        fields = ImportSourceField[]
        for (column, cell) in zip(schema.columns, row.cells)
            push!(fields, ImportSourceField(column.name, cell, column.unit, column.basis))
        end
        push!(source_records, ImportSourceRecord(
            record_id,
            schema.id,
            raw_identifier,
            parsed.source.provenance.source_name,
            row.span,
            FormatItemList(fields),
        ))
        push!(operations, ImportCreateObject(object_id, normalized_object_type, record_id))
        for (column, cell) in zip(schema.columns, row.cells)
            rule = rules_by_field[column.name]
            source_ref = ImportSourceFieldRef(record_id, column.name)
            disposition = rule.disposition
            destination = rule.destination
            justification = rule.justification
            if column.name == schema.identity_column
                push!(accounting, ImportFieldAccounting(
                    source_ref,
                    ImportMapped,
                    FormatPath("id"),
                    nothing,
                    cell.span,
                ))
                continue
            elseif disposition == ImportMapped &&
                   cell.value isa FormatNull &&
                   rule.null_operation == ImportOmitNull
                disposition = ImportIgnored
                destination = nothing
                justification = "explicit null omitted by the declared field rule"
            elseif disposition == ImportMapped
                push!(operations, ImportFieldAssignment(
                    object_id,
                    rule.destination,
                    cell,
                    source_ref,
                ))
            elseif disposition in (ImportUnsupported, ImportRejected)
                loss_id = string("loss.", row_index, '.', column.name)
                push!(losses, ImportConversionLoss(
                    loss_id,
                    rule.justification,
                    disposition == ImportUnsupported ?
                        "source meaning is unavailable in the canonical import plan" :
                        "source field prevents an accepted conversion",
                    source_ref,
                ))
            end
            push!(accounting, ImportFieldAccounting(
                source_ref,
                disposition,
                destination,
                justification,
                cell.span,
            ))
        end
    end
    return FormatResult(_compile_import_components(
        parsed.source,
        adapter,
        source_records,
        operations,
        accounting;
        assumptions,
        losses,
    ))
end
