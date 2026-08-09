"""Exact scalar kinds admitted by scalar bulk-table columns."""
@enum BulkScalarKind::UInt8 begin
    BulkString = 0x01
    BulkInteger = 0x02
    BulkDecimal = 0x03
    BulkBoolean = 0x04
end

"""Explicit source encoding admitted by bulk-text grammars."""
@enum BulkEncoding::UInt8 begin
    BulkUtf8 = 0x01
end

"""Whether a delimited table requires its declared header or contains data only."""
@enum BulkHeaderMode::UInt8 begin
    BulkHeaderRequired = 0x01
    BulkHeaderAbsent = 0x02
end

"""Deterministic minimal or all-non-null-field delimited writer quoting."""
@enum BulkQuoteMode::UInt8 begin
    BulkQuoteMinimal = 0x01
    BulkQuoteAll = 0x02
end

"""Deterministic physical line ending emitted by a delimited writer."""
@enum BulkLineEnding::UInt8 begin
    BulkLineFeed = 0x01
    BulkCarriageReturnLineFeed = 0x02
end

"""One explicitly typed column in a scalar bulk-table schema."""
struct BulkColumnSpec
    name::String
    kind::BulkScalarKind
    nullable::Bool
    unit::Union{Nothing,String}
    basis::Union{Nothing,String}

    function BulkColumnSpec(
        name::AbstractString,
        kind::BulkScalarKind;
        nullable::Bool = false,
        unit::Union{Nothing,AbstractString} = nothing,
        basis::Union{Nothing,AbstractString} = nothing,
    )
        normalized_name = String(name)
        isvalid(normalized_name) || throw(ArgumentError("bulk column name is not valid Unicode"))
        occursin(r"^[A-Za-z_\$][A-Za-z0-9_.\$-]*$", normalized_name) ||
            throw(ArgumentError("bulk column name is not portable"))
        normalized_unit = isnothing(unit) ? nothing : String(unit)
        normalized_basis = isnothing(basis) ? nothing : String(basis)
        for (label, value) in (("unit", normalized_unit), ("basis", normalized_basis))
            isnothing(value) && continue
            isempty(value) && throw(ArgumentError("bulk column $(label) must not be empty"))
            isvalid(value) ||
                throw(ArgumentError("bulk column $(label) is not valid Unicode"))
            occursin(r"[\r\n\0]", value) &&
                throw(ArgumentError("bulk column $(label) contains a prohibited character"))
        end
        return new(normalized_name, kind, nullable, normalized_unit, normalized_basis)
    end
end

Base.:(==)(left::BulkColumnSpec, right::BulkColumnSpec) =
    left.name == right.name &&
    left.kind == right.kind &&
    left.nullable == right.nullable &&
    left.unit == right.unit &&
    left.basis == right.basis

"""A versioned scalar table schema with one required stable row-identity column."""
struct BulkTableSchema
    id::String
    version::VersionNumber
    columns::FormatItemList{BulkColumnSpec}
    identity_column::String

    function BulkTableSchema(
        id::AbstractString,
        version::VersionNumber,
        columns::AbstractVector{BulkColumnSpec},
        identity_column::AbstractString,
    )
        normalized_id = String(id)
        isvalid(normalized_id) || throw(ArgumentError("bulk schema ID is not valid Unicode"))
        occursin(r"^[A-Za-z][A-Za-z0-9_.-]*$", normalized_id) ||
            throw(ArgumentError("bulk schema ID is not portable"))
        copied_columns = collect(columns)
        isempty(copied_columns) && throw(ArgumentError("bulk schema must contain columns"))
        names = getfield.(copied_columns, :name)
        length(names) == length(unique(names)) ||
            throw(ArgumentError("bulk schema contains duplicate columns"))
        identity = String(identity_column)
        identity_index = findfirst(==(identity), names)
        isnothing(identity_index) &&
            throw(ArgumentError("bulk identity column does not exist"))
        identity_spec = copied_columns[identity_index]
        identity_spec.nullable &&
            throw(ArgumentError("bulk identity column must not be nullable"))
        identity_spec.kind in (BulkString, BulkInteger) ||
            throw(ArgumentError("bulk identity column must be a string or integer"))
        return new(normalized_id, version, FormatItemList(copied_columns), identity)
    end
end

Base.:(==)(left::BulkTableSchema, right::BulkTableSchema) =
    left.id == right.id &&
    left.version == right.version &&
    left.columns == right.columns &&
    left.identity_column == right.identity_column

"""Explicit UTF-8 delimited-text grammar and deterministic writer policy."""
struct DelimitedTextPolicy
    encoding::BulkEncoding
    delimiter::Char
    quote_character::Char
    header::BulkHeaderMode
    null_token::String
    quote_mode::BulkQuoteMode
    line_ending::BulkLineEnding

    function DelimitedTextPolicy(;
        encoding::BulkEncoding = BulkUtf8,
        delimiter::Char = ',',
        quote_character::Char = '"',
        header::BulkHeaderMode = BulkHeaderRequired,
        null_token::AbstractString = "\\N",
        quote_mode::BulkQuoteMode = BulkQuoteMinimal,
        line_ending::BulkLineEnding = BulkLineFeed,
    )
        delimiter in (',', '\t') ||
            throw(ArgumentError("only CSV comma and TSV tab delimiters are admitted"))
        quote_character == '"' ||
            throw(ArgumentError("restricted delimited text uses a double quote"))
        normalized_null = String(null_token)
        isempty(normalized_null) && throw(ArgumentError("bulk null token must not be empty"))
        isvalid(normalized_null) || throw(ArgumentError("bulk null token is not valid Unicode"))
        occursin('\0', normalized_null) &&
            throw(ArgumentError("bulk null token must not contain NUL"))
        any(
            character -> character in (delimiter, quote_character, '\r', '\n'),
            normalized_null,
        ) &&
            throw(ArgumentError("bulk null token conflicts with the text grammar"))
        return new(
            encoding,
            delimiter,
            quote_character,
            header,
            normalized_null,
            quote_mode,
            line_ending,
        )
    end
end

Base.:(==)(left::DelimitedTextPolicy, right::DelimitedTextPolicy) =
    left.encoding == right.encoding &&
    left.delimiter == right.delimiter &&
    left.quote_character == right.quote_character &&
    left.header == right.header &&
    left.null_token == right.null_token &&
    left.quote_mode == right.quote_mode &&
    left.line_ending == right.line_ending

function _bulk_kind_matches(kind::BulkScalarKind, value::FormatValue)
    value isa FormatNull && return true
    kind == BulkString && return value isa FormatString
    kind == BulkInteger && return value isa FormatInteger
    kind == BulkDecimal && return value isa FormatDecimal
    kind == BulkBoolean && return value isa FormatBoolean
    return false
end

"""One source-located scalar table row in schema column order."""
struct BulkRow
    cells::FormatItemList{FormatNode}
    span::SourceSpan

    BulkRow(cells::AbstractVector{FormatNode}, span::SourceSpan) =
        new(FormatItemList(collect(cells)), span)
end

Base.:(==)(left::BulkRow, right::BulkRow) =
    left.cells == right.cells && left.span == right.span

function _bulk_identity_key(schema::BulkTableSchema, row::BulkRow)
    index = findfirst(column -> column.name == schema.identity_column, schema.columns)
    value = row.cells[index].value
    value isa FormatString && return "string:" * value.value
    value isa FormatInteger && return "integer:" * string(value.value)
    throw(ArgumentError("bulk row identity has the wrong scalar kind"))
end

function _validate_bulk_row(schema::BulkTableSchema, row::BulkRow)
    length(row.cells) == length(schema.columns) ||
        throw(ArgumentError("bulk row width differs from its schema"))
    for (column, cell) in zip(schema.columns, row.cells)
        _bulk_kind_matches(column.kind, cell.value) ||
            throw(ArgumentError("bulk cell kind differs from column $(column.name)"))
        cell.value isa FormatNull && !column.nullable &&
            throw(ArgumentError("bulk column $(column.name) is not nullable"))
    end
    _bulk_identity_key(schema, row)
    return row
end

"""A typed scalar table whose row identities are unique and deterministic."""
struct BulkTable
    schema::BulkTableSchema
    rows::FormatItemList{BulkRow}

    function BulkTable(schema::BulkTableSchema, rows::AbstractVector{BulkRow})
        copied_rows = collect(rows)
        identities = String[]
        for row in copied_rows
            _validate_bulk_row(schema, row)
            push!(identities, _bulk_identity_key(schema, row))
        end
        length(identities) == length(unique(identities)) ||
            throw(ArgumentError("bulk table contains duplicate row identities"))
        return new(schema, FormatItemList(copied_rows))
    end
end

Base.:(==)(left::BulkTable, right::BulkTable) =
    left.schema == right.schema && left.rows == right.rows

"""A typed bulk table paired with its exact source document."""
struct ParsedBulkTable
    source::SourceDocument
    table::BulkTable
end

Base.:(==)(left::ParsedBulkTable, right::ParsedBulkTable) =
    left.source == right.source && left.table == right.table

"""Typed result returned by CSV, TSV, or JSONL table parsing."""
const BulkParseResult = FormatResult{ParsedBulkTable}

"""Return one row cell by its declared schema column name."""
function bulk_cell(schema::BulkTableSchema, row::BulkRow, column_name::AbstractString)
    index = findfirst(column -> column.name == column_name, schema.columns)
    isnothing(index) && throw(KeyError(String(column_name)))
    return row.cells[index]
end

bulk_cell(table::BulkTable, row::BulkRow, column_name::AbstractString) =
    bulk_cell(table.schema, row, column_name)

function _bulk_identity_span(schema::BulkTableSchema, row::BulkRow)
    index = findfirst(column -> column.name == schema.identity_column, schema.columns)
    return row.cells[index].span
end

struct _BulkFailure <: Exception
    diagnostic::FormatDiagnostic
end

function Base.showerror(io::IO, failure::_BulkFailure)
    show(io, failure.diagnostic)
end

struct _DelimitedRawField
    text::String
    quoted::Bool
    span::SourceSpan
end

struct _DelimitedRawRecord
    fields::Vector{_DelimitedRawField}
    span::SourceSpan
end

mutable struct _DelimitedScanner
    source::SourceDocument
    grammar::DelimitedTextPolicy
    policy::FormatInputPolicy
    byte::Int
    stop_byte::Int
    collection_items::Int
end

function _bulk_fail(
    code::Symbol,
    message::String,
    span::SourceSpan,
)
    throw(_BulkFailure(FormatDiagnostic(DiagnosticError, code, message, span)))
end

function _bulk_character_span(source::SourceDocument, byte::Int)
    byte > ncodeunits(source.text) && return source_span(source, byte, byte)
    return source_span(source, byte, nextind(source.text, byte))
end

function _delimited_is_newline(text::String, byte::Int, stop_byte::Int)
    byte >= stop_byte && return 0
    value = codeunit(text, byte)
    if value == 0x0d
        return byte + 1 < stop_byte && codeunit(text, byte + 1) == 0x0a ? 2 : 1
    end
    return value == 0x0a ? 1 : 0
end

function _delimited_count_item!(scanner::_DelimitedScanner, byte::Int)
    scanner.collection_items < scanner.policy.max_collection_items ||
        _bulk_fail(
            :collection_too_large,
            "bulk table exceeds the configured collection item limit",
            _bulk_character_span(scanner.source, byte),
        )
    scanner.collection_items += 1
end

function _delimited_parse_quoted_field!(scanner::_DelimitedScanner)
    source = scanner.source
    text = source.text
    start_byte = scanner.byte
    scanner.byte += 1
    output = IOBuffer()
    closed = false
    while scanner.byte < scanner.stop_byte
        byte = codeunit(text, scanner.byte)
        if byte == UInt8(scanner.grammar.quote_character)
            following = scanner.byte + 1
            if following < scanner.stop_byte &&
               codeunit(text, following) == UInt8(scanner.grammar.quote_character)
                print(output, scanner.grammar.quote_character)
                scanner.byte += 2
            else
                scanner.byte += 1
                closed = true
                break
            end
        elseif byte == 0x00
            _bulk_fail(
                :delimited_nul_prohibited,
                "delimited text field contains NUL",
                _bulk_character_span(source, scanner.byte),
            )
        else
            character = text[scanner.byte]
            print(output, character)
            scanner.byte = nextind(text, scanner.byte)
        end
        scanner.byte - start_byte <= scanner.policy.max_scalar_bytes ||
            _bulk_fail(
                :scalar_too_large,
                "delimited text field exceeds the configured scalar byte limit",
                source_span(source, start_byte, scanner.byte),
            )
    end
    closed || _bulk_fail(
        :unterminated_delimited_quote,
        "quoted delimited field is not terminated",
        source_span(source, start_byte, scanner.stop_byte),
    )
    return _DelimitedRawField(
        String(take!(output)),
        true,
        source_span(source, start_byte, scanner.byte),
    )
end

function _delimited_parse_unquoted_field!(scanner::_DelimitedScanner)
    source = scanner.source
    text = source.text
    start_byte = scanner.byte
    delimiter = UInt8(scanner.grammar.delimiter)
    while scanner.byte < scanner.stop_byte
        byte = codeunit(text, scanner.byte)
        (byte == delimiter || _delimited_is_newline(text, scanner.byte, scanner.stop_byte) > 0) &&
            break
        if byte == UInt8(scanner.grammar.quote_character)
            _bulk_fail(
                :unexpected_delimited_quote,
                "quote occurs inside an unquoted delimited field",
                _bulk_character_span(source, scanner.byte),
            )
        elseif byte == 0x00
            _bulk_fail(
                :delimited_nul_prohibited,
                "delimited text field contains NUL",
                _bulk_character_span(source, scanner.byte),
            )
        end
        scanner.byte = nextind(text, scanner.byte)
        scanner.byte - start_byte <= scanner.policy.max_scalar_bytes ||
            _bulk_fail(
                :scalar_too_large,
                "delimited text field exceeds the configured scalar byte limit",
                source_span(source, start_byte, scanner.byte),
            )
    end
    value = start_byte == scanner.byte ? "" : String(SubString(
        text,
        start_byte,
        prevind(text, scanner.byte),
    ))
    return _DelimitedRawField(
        value,
        false,
        source_span(source, start_byte, scanner.byte),
    )
end

function _delimited_next_record!(scanner::_DelimitedScanner)
    scanner.byte >= scanner.stop_byte && return nothing
    source = scanner.source
    text = source.text
    delimiter = UInt8(scanner.grammar.delimiter)
    record_start = scanner.byte
    fields = _DelimitedRawField[]
    while true
        _delimited_count_item!(scanner, scanner.byte)
        field = if scanner.byte < scanner.stop_byte &&
                   codeunit(text, scanner.byte) == UInt8(scanner.grammar.quote_character)
            _delimited_parse_quoted_field!(scanner)
        else
            _delimited_parse_unquoted_field!(scanner)
        end
        push!(fields, field)
        if scanner.byte >= scanner.stop_byte
            return _DelimitedRawRecord(
                fields,
                source_span(source, record_start, scanner.byte),
            )
        end
        byte = codeunit(text, scanner.byte)
        if byte == delimiter
            scanner.byte += 1
            continue
        end
        newline_width = _delimited_is_newline(text, scanner.byte, scanner.stop_byte)
        newline_width > 0 ||
            _bulk_fail(
                :trailing_delimited_field_content,
                "unexpected content follows a quoted delimited field",
                _bulk_character_span(source, scanner.byte),
            )
        record_stop = scanner.byte
        scanner.byte += newline_width
        return _DelimitedRawRecord(
            fields,
            source_span(source, record_start, record_stop),
        )
    end
end

function _bulk_decimal_value(text::String)
    matched = match(
        r"^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$",
        text,
    )
    isnothing(matched) && return nothing
    fraction = matched.captures[3]
    exponent_text = matched.captures[4]
    isnothing(fraction) && isnothing(exponent_text) && return nothing
    fraction_digits = isnothing(fraction) ? "" : fraction
    coefficient = parse(BigInt, matched.captures[2] * fraction_digits)
    matched.captures[1] == "-" && (coefficient = -coefficient)
    explicit_exponent = isnothing(exponent_text) ? BigInt(0) : parse(BigInt, exponent_text)
    exponent = explicit_exponent - ncodeunits(fraction_digits)
    typemin(Int) <= exponent <= typemax(Int) || return nothing
    return FormatDecimal(
        coefficient,
        Int(exponent);
        negative_zero = iszero(coefficient) && matched.captures[1] == "-",
    )
end

function _bulk_convert_field(
    field::_DelimitedRawField,
    column::BulkColumnSpec,
    grammar::DelimitedTextPolicy,
)
    if !field.quoted && field.text == grammar.null_token
        column.nullable || _bulk_fail(
            :null_in_required_bulk_column,
            "null occurs in required bulk column $(column.name)",
            field.span,
        )
        return FormatNode(FormatNull(), field.span)
    end
    value = if column.kind == BulkString
        FormatString(field.text)
    elseif column.kind == BulkInteger
        occursin(r"^(?:0|-?[1-9][0-9]*)$", field.text) ||
            _bulk_fail(
                :invalid_bulk_integer,
                "bulk column $(column.name) requires an exact integer",
                field.span,
            )
        FormatInteger(parse(BigInt, field.text))
    elseif column.kind == BulkDecimal
        decimal = _bulk_decimal_value(field.text)
        isnothing(decimal) && _bulk_fail(
            :invalid_bulk_decimal,
            "bulk column $(column.name) requires an exact decimal",
            field.span,
        )
        decimal
    else
        field.text in ("true", "false") ||
            _bulk_fail(
                :invalid_bulk_boolean,
                "bulk column $(column.name) requires lowercase true or false",
                field.span,
            )
        FormatBoolean(field.text == "true")
    end
    return FormatNode(value, field.span)
end

function _bulk_validate_header(
    record::_DelimitedRawRecord,
    schema::BulkTableSchema,
)
    length(record.fields) == length(schema.columns) ||
        _bulk_fail(
            :bulk_header_width_mismatch,
            "bulk header width differs from its schema",
            record.span,
        )
    names = getfield.(record.fields, :text)
    seen = Set{String}()
    for (index, name) in enumerate(names)
        name in seen && _bulk_fail(
            :duplicate_bulk_header,
            "bulk header contains duplicate column $(name)",
            record.fields[index].span,
        )
        push!(seen, name)
        name == schema.columns[index].name ||
            _bulk_fail(
                :bulk_header_schema_mismatch,
                "bulk header column $(name) differs from schema column $(schema.columns[index].name)",
                record.fields[index].span,
            )
    end
end

function _bulk_convert_record(
    record::_DelimitedRawRecord,
    schema::BulkTableSchema,
    grammar::DelimitedTextPolicy,
)
    length(record.fields) == length(schema.columns) ||
        _bulk_fail(
            :bulk_row_width_mismatch,
            "bulk row width differs from its schema",
            record.span,
        )
    cells = FormatNode[
        _bulk_convert_field(field, column, grammar)
        for (field, column) in zip(record.fields, schema.columns)
    ]
    return BulkRow(cells, record.span)
end

function _parse_delimited_table(
    source::SourceDocument,
    schema::BulkTableSchema,
    grammar::DelimitedTextPolicy,
    policy::FormatInputPolicy,
)
    scanner = _DelimitedScanner(
        source,
        grammar,
        policy,
        1,
        ncodeunits(source.text) + 1,
        0,
    )
    rows = BulkRow[]
    identities = Set{String}()
    try
        if grammar.header == BulkHeaderRequired
            header = _delimited_next_record!(scanner)
            isnothing(header) && _bulk_fail(
                :missing_bulk_header,
                "delimited table requires a header",
                source_span(source, 1, 1),
            )
            _bulk_validate_header(header, schema)
        end
        while true
            record = _delimited_next_record!(scanner)
            isnothing(record) && break
            row = _bulk_convert_record(record, schema, grammar)
            identity = _bulk_identity_key(schema, row)
            identity in identities && _bulk_fail(
                :duplicate_bulk_row_identity,
                "bulk row identity is duplicated",
                _bulk_identity_span(schema, row),
            )
            push!(identities, identity)
            push!(rows, row)
        end
        return BulkParseResult(ParsedBulkTable(source, BulkTable(schema, rows)))
    catch error
        error isa _BulkFailure || rethrow()
        return BulkParseResult(nothing, [error.diagnostic])
    end
end

"""Parse bounded UTF-8 CSV or TSV under an explicit scalar table schema."""
function parse_delimited_table(
    source::SourceDocument,
    schema::BulkTableSchema;
    grammar::DelimitedTextPolicy = DelimitedTextPolicy(),
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_document_bytes || begin
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "delimited table exceeds the configured byte limit",
            source_span(source, 1, 1),
        )
        return BulkParseResult(nothing, [diagnostic])
    end
    return _parse_delimited_table(source, schema, grammar, policy)
end

function parse_delimited_table(
    bytes::AbstractVector{UInt8},
    schema::BulkTableSchema;
    source_name::AbstractString = "<memory>",
    grammar::DelimitedTextPolicy = DelimitedTextPolicy(),
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return BulkParseResult(nothing, collect(admitted.diagnostics))
    return parse_delimited_table(admitted.value, schema; grammar, policy)
end

parse_delimited_table(
    text::AbstractString,
    schema::BulkTableSchema;
    source_name::AbstractString = "<memory>",
    grammar::DelimitedTextPolicy = DelimitedTextPolicy(),
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_delimited_table(
    Vector{UInt8}(codeunits(text)),
    schema;
    source_name,
    grammar,
    policy,
)

function _bulk_scalar_text(value::FormatValue)
    value isa FormatNull && return nothing
    value isa FormatString && return value.value
    value isa FormatInteger && return string(value.value)
    if value isa FormatDecimal
        if iszero(value.coefficient)
            return value.negative_zero ? "-0e0" : "0e0"
        end
        return string(value.coefficient, 'e', value.exponent)
    end
    value isa FormatBoolean && return value.value ? "true" : "false"
    throw(ArgumentError("bulk table contains a non-scalar value"))
end

function _delimited_emit_field(
    io::IO,
    text::String,
    grammar::DelimitedTextPolicy;
    force_quote::Bool = false,
)
    should_quote = force_quote || grammar.quote_mode == BulkQuoteAll ||
        isempty(text) && grammar.quote_mode == BulkQuoteAll ||
        text == grammar.null_token ||
        any(character -> character in (
            grammar.delimiter,
            grammar.quote_character,
            '\r',
            '\n',
        ), text)
    if should_quote
        print(io, grammar.quote_character)
        for character in text
            character == grammar.quote_character && print(io, grammar.quote_character)
            print(io, character)
        end
        print(io, grammar.quote_character)
    else
        print(io, text)
    end
end

function _delimited_line_ending(grammar::DelimitedTextPolicy)
    return grammar.line_ending == BulkLineFeed ? "\n" : "\r\n"
end

function _bulk_serialization_diagnostics(
    table::BulkTable,
    policy::FormatInputPolicy,
)
    if length(table.rows) > div(policy.max_collection_items, length(table.schema.columns))
        span = isempty(table.rows) ? nothing : last(table.rows).span
        return FormatDiagnostic[
            FormatDiagnostic(
                DiagnosticError,
                :collection_too_large,
                "bulk table exceeds the configured collection item limit",
                span,
            ),
        ]
    end
    for row in table.rows
        _validate_bulk_row(table.schema, row)
        for cell in row.cells
            text = _bulk_scalar_text(cell.value)
            isnothing(text) && continue
            if cell.value isa FormatString && !isvalid(text)
                return FormatDiagnostic[
                    FormatDiagnostic(
                        DiagnosticError,
                        :invalid_unicode_value,
                        "bulk table string is not valid Unicode",
                        cell.span,
                    ),
                ]
            end
            if ncodeunits(text) > policy.max_scalar_bytes
                return FormatDiagnostic[
                    FormatDiagnostic(
                        DiagnosticError,
                        :scalar_too_large,
                        "bulk table scalar exceeds the configured byte limit",
                        cell.span,
                    ),
                ]
            end
        end
    end
    return FormatDiagnostic[]
end

function _delimited_serialization_diagnostics(table::BulkTable)
    for row in table.rows
        for cell in row.cells
            cell.value isa FormatString || continue
            occursin('\0', cell.value.value) || continue
            return FormatDiagnostic[
                FormatDiagnostic(
                    DiagnosticError,
                    :delimited_nul_prohibited,
                    "delimited text field contains NUL",
                    cell.span,
                ),
            ]
        end
    end
    return FormatDiagnostic[]
end

"""Serialize a typed scalar table deterministically as UTF-8 CSV or TSV."""
function serialize_delimited_table(
    table::BulkTable;
    grammar::DelimitedTextPolicy = DelimitedTextPolicy(),
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = _bulk_serialization_diagnostics(table, policy)
    isempty(diagnostics) || return FormatSerializationResult(nothing, diagnostics)
    diagnostics = _delimited_serialization_diagnostics(table)
    isempty(diagnostics) || return FormatSerializationResult(nothing, diagnostics)
    output = IOBuffer()
    line_ending = _delimited_line_ending(grammar)
    if grammar.header == BulkHeaderRequired
        for (index, column) in enumerate(table.schema.columns)
            index > 1 && print(output, grammar.delimiter)
            _delimited_emit_field(output, column.name, grammar)
        end
        print(output, line_ending)
    end
    for row in table.rows
        for (index, cell) in enumerate(row.cells)
            index > 1 && print(output, grammar.delimiter)
            text = _bulk_scalar_text(cell.value)
            if isnothing(text)
                print(output, grammar.null_token)
            else
                _delimited_emit_field(
                    output,
                    text,
                    grammar;
                    force_quote = cell.value isa FormatString && text == grammar.null_token,
                )
            end
        end
        print(output, line_ending)
    end
    bytes = take!(output)
    if length(bytes) > policy.max_document_bytes
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "serialized delimited table exceeds the configured byte limit",
        )
        return FormatSerializationResult(nothing, [diagnostic])
    end
    media_type = grammar.delimiter == ',' ?
        "text/csv; charset=utf-8" : "text/tab-separated-values; charset=utf-8"
    return FormatSerializationResult(SerializedFormatDocument(bytes, media_type))
end

function _jsonl_physical_lines(source::SourceDocument)
    lines = Tuple{Int,Int}[]
    for line_index in eachindex(source.line_starts)
        first_byte = source.line_starts[line_index]
        stop_byte = line_index < length(source.line_starts) ?
            source.line_starts[line_index + 1] : ncodeunits(source.text) + 1
        while stop_byte > first_byte &&
              codeunit(source.text, prevind(source.text, stop_byte)) in (0x0a, 0x0d)
            stop_byte = prevind(source.text, stop_byte)
        end
        first_byte == stop_byte && line_index == length(source.line_starts) &&
            first_byte == ncodeunits(source.text) + 1 && continue
        push!(lines, (first_byte, stop_byte))
    end
    return lines
end

function _bulk_remap_node(
    node::FormatNode,
    source::SourceDocument,
    byte_offset::Int,
)
    span = source_span(
        source,
        node.span.start.byte + byte_offset,
        node.span.stop.byte + byte_offset,
    )
    value = node.value
    if value isa FormatSequence
        children = FormatNode[
            _bulk_remap_node(child, source, byte_offset) for child in value.elements
        ]
        value = FormatSequence(children)
    elseif value isa FormatMapping
        entries = FormatMappingEntry[
            FormatMappingEntry(
                _bulk_remap_node(entry.key, source, byte_offset),
                _bulk_remap_node(entry.value, source, byte_offset),
            ) for entry in value.entries
        ]
        value = FormatMapping(entries)
    end
    return FormatNode(value, span)
end

function _bulk_remap_diagnostic(
    diagnostic::FormatDiagnostic,
    source::SourceDocument,
    byte_offset::Int,
)
    isnothing(diagnostic.span) && return diagnostic
    span = source_span(
        source,
        diagnostic.span.start.byte + byte_offset,
        diagnostic.span.stop.byte + byte_offset,
    )
    return FormatDiagnostic(
        diagnostic.severity,
        diagnostic.code,
        diagnostic.message,
        span,
    )
end

function _jsonl_convert_record(
    node::FormatNode,
    schema::BulkTableSchema,
)
    node.value isa FormatMapping || _bulk_fail(
        :jsonl_record_must_be_object,
        "JSONL record must be a JSON object",
        node.span,
    )
    entries = Dict{String,FormatNode}(
        entry.key.value.value => entry.value for entry in node.value.entries
    )
    expected = Set(column.name for column in schema.columns)
    actual = Set(keys(entries))
    missing = sort!(collect(setdiff(expected, actual)))
    extra = sort!(collect(setdiff(actual, expected)))
    isempty(missing) || _bulk_fail(
        :jsonl_missing_column,
        "JSONL record is missing column $(first(missing))",
        node.span,
    )
    isempty(extra) || _bulk_fail(
        :jsonl_unknown_column,
        "JSONL record contains unknown column $(first(extra))",
        entries[first(extra)].span,
    )
    cells = FormatNode[]
    for column in schema.columns
        cell = entries[column.name]
        cell.value isa FormatNull && !column.nullable && _bulk_fail(
            :null_in_required_bulk_column,
            "null occurs in required bulk column $(column.name)",
            cell.span,
        )
        _bulk_kind_matches(column.kind, cell.value) || _bulk_fail(
            :jsonl_column_kind_mismatch,
            "JSONL column $(column.name) has the wrong scalar kind",
            cell.span,
        )
        push!(cells, cell)
    end
    return BulkRow(cells, node.span)
end

function _parse_json_lines(
    source::SourceDocument,
    schema::BulkTableSchema,
    policy::FormatInputPolicy,
)
    rows = BulkRow[]
    identities = Set{String}()
    try
        for (first_byte, stop_byte) in _jsonl_physical_lines(source)
            first_byte == stop_byte && _bulk_fail(
                :blank_jsonl_record,
                "JSONL must not contain blank records",
                source_span(source, first_byte, stop_byte),
            )
            stop_byte - first_byte <= policy.max_scalar_bytes ||
                _bulk_fail(
                    :scalar_too_large,
                    "JSONL record exceeds the configured byte limit",
                    source_span(source, first_byte, stop_byte),
                )
            text = String(SubString(source.text, first_byte, prevind(source.text, stop_byte)))
            local_result = parse_json(
                text;
                source_name = source.provenance.source_name,
                policy,
            )
            if !format_succeeded(local_result)
                diagnostics = FormatDiagnostic[
                    _bulk_remap_diagnostic(
                        diagnostic,
                        source,
                        first_byte - 1,
                    ) for diagnostic in local_result.diagnostics
                ]
                return BulkParseResult(nothing, diagnostics)
            end
            node = _bulk_remap_node(local_result.value.root, source, first_byte - 1)
            row = _jsonl_convert_record(node, schema)
            identity = _bulk_identity_key(schema, row)
            identity in identities && _bulk_fail(
                :duplicate_bulk_row_identity,
                "bulk row identity is duplicated",
                _bulk_identity_span(schema, row),
            )
            push!(identities, identity)
            push!(rows, row)
            length(rows) <= div(policy.max_collection_items, length(schema.columns)) ||
                _bulk_fail(
                    :collection_too_large,
                    "JSONL table exceeds the configured collection item limit",
                    row.span,
                )
        end
        return BulkParseResult(ParsedBulkTable(source, BulkTable(schema, rows)))
    catch error
        error isa _BulkFailure || rethrow()
        return BulkParseResult(nothing, [error.diagnostic])
    end
end

"""Parse bounded newline-delimited canonical JSON objects under a scalar table schema."""
function parse_json_lines(
    source::SourceDocument,
    schema::BulkTableSchema;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    source.provenance.byte_count <= policy.max_document_bytes || begin
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :document_too_large,
            "JSONL table exceeds the configured byte limit",
            source_span(source, 1, 1),
        )
        return BulkParseResult(nothing, [diagnostic])
    end
    return _parse_json_lines(source, schema, policy)
end

function parse_json_lines(
    bytes::AbstractVector{UInt8},
    schema::BulkTableSchema;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    admitted = source_document(bytes; source_name, policy)
    format_succeeded(admitted) ||
        return BulkParseResult(nothing, collect(admitted.diagnostics))
    return parse_json_lines(admitted.value, schema; policy)
end

parse_json_lines(
    text::AbstractString,
    schema::BulkTableSchema;
    source_name::AbstractString = "<memory>",
    policy::FormatInputPolicy = FormatInputPolicy(),
) = parse_json_lines(
    Vector{UInt8}(codeunits(text)),
    schema;
    source_name,
    policy,
)

"""Serialize a typed scalar table as deterministic canonical JSON objects, one per line."""
function serialize_json_lines(
    table::BulkTable;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    diagnostics = _bulk_serialization_diagnostics(table, policy)
    isempty(diagnostics) || return FormatSerializationResult(nothing, diagnostics)
    output = IOBuffer()
    for row in table.rows
        entries = FormatMappingEntry[]
        for (column, cell) in zip(table.schema.columns, row.cells)
            key = FormatNode(FormatString(column.name), cell.span)
            push!(entries, FormatMappingEntry(key, cell))
        end
        node = FormatNode(FormatMapping(entries), row.span)
        serialized = serialize_canonical_json(node; policy)
        format_succeeded(serialized) ||
            return FormatSerializationResult(
                nothing,
                collect(serialized.diagnostics),
            )
        write(output, collect(serialized.value.bytes))
        print(output, '\n')
        position(output) <= policy.max_document_bytes || begin
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :document_too_large,
                "serialized JSONL table exceeds the configured byte limit",
                row.span,
            )
            return FormatSerializationResult(nothing, [diagnostic])
        end
    end
    return FormatSerializationResult(SerializedFormatDocument(
        take!(output),
        "application/x-ndjson",
    ))
end

"""Counts returned by a bounded row stream; delimited `records_read` includes its header."""
struct BulkStreamSummary
    records_read::Int
    rows_emitted::Int
    bytes_read::Int
    stopped_early::Bool
end

"""Stream CSV or TSV rows from an IO without retaining the full input or result table."""
function _stream_delimited_record(
    input::IO,
    grammar::DelimitedTextPolicy,
    maximum_bytes::Int,
)
    bytes = UInt8[]
    inside_quote = false
    field_start = true
    quote_byte = UInt8(grammar.quote_character)
    delimiter_byte = UInt8(grammar.delimiter)
    while !eof(input)
        byte = read(input, UInt8)
        push!(bytes, byte)
        length(bytes) <= maximum_bytes || return (:too_large, bytes)
        if inside_quote
            if byte == quote_byte
                if !eof(input) && peek(input, UInt8) == quote_byte
                    push!(bytes, read(input, UInt8))
                    length(bytes) <= maximum_bytes || return (:too_large, bytes)
                else
                    inside_quote = false
                end
            end
            continue
        end
        if byte == quote_byte && field_start
            inside_quote = true
            field_start = false
        elseif byte == delimiter_byte
            field_start = true
        elseif byte == 0x0a
            return (:record, bytes)
        elseif byte == 0x0d
            if !eof(input) && peek(input, UInt8) == 0x0a
                push!(bytes, read(input, UInt8))
                length(bytes) <= maximum_bytes || return (:too_large, bytes)
            end
            return (:record, bytes)
        else
            field_start = false
        end
    end
    return isempty(bytes) ? (:eof, bytes) : (:record, bytes)
end

function _stream_grammar_without_header(grammar::DelimitedTextPolicy)
    return DelimitedTextPolicy(;
        encoding = grammar.encoding,
        delimiter = grammar.delimiter,
        quote_character = grammar.quote_character,
        header = BulkHeaderAbsent,
        null_token = grammar.null_token,
        quote_mode = grammar.quote_mode,
        line_ending = grammar.line_ending,
    )
end

function stream_delimited_rows(
    input::IO,
    schema::BulkTableSchema,
    consumer::Function;
    source_name::AbstractString = "<stream>",
    grammar::DelimitedTextPolicy = DelimitedTextPolicy(),
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    normalized_source_name = String(source_name)
    isempty(normalized_source_name) && throw(ArgumentError("source name must not be empty"))
    occursin('\0', normalized_source_name) &&
        throw(ArgumentError("source name must not contain NUL"))
    records_read = 0
    rows_emitted = 0
    bytes_read = 0
    identities = Set{String}()
    data_grammar = _stream_grammar_without_header(grammar)
    header_pending = grammar.header == BulkHeaderRequired
    while true
        status, bytes = _stream_delimited_record(
            input,
            grammar,
            policy.max_document_bytes,
        )
        status == :eof && break
        records_read += 1
        bytes_read += length(bytes)
        if status == :too_large || bytes_read > policy.max_document_bytes
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :document_too_large,
                "delimited stream exceeds the configured byte limit",
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        record_name = "$(normalized_source_name):record-$(records_read)"
        if header_pending
            parsed_header = parse_delimited_table(
                bytes,
                schema;
                source_name = record_name,
                grammar,
                policy,
            )
            format_succeeded(parsed_header) ||
                return FormatResult{BulkStreamSummary}(
                    nothing,
                    collect(parsed_header.diagnostics),
                )
            header_pending = false
            continue
        end
        parsed_row = parse_delimited_table(
            bytes,
            schema;
            source_name = record_name,
            grammar = data_grammar,
            policy,
        )
        format_succeeded(parsed_row) ||
            return FormatResult{BulkStreamSummary}(
                nothing,
                collect(parsed_row.diagnostics),
            )
        length(parsed_row.value.table.rows) == 1 || begin
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :stream_record_count_mismatch,
                "delimited stream chunk did not contain exactly one row",
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        row = only(parsed_row.value.table.rows)
        identity = _bulk_identity_key(schema, row)
        if identity in identities
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :duplicate_bulk_row_identity,
                "bulk row identity is duplicated",
                _bulk_identity_span(schema, row),
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        push!(identities, identity)
        if rows_emitted + 1 > div(policy.max_collection_items, length(schema.columns))
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :collection_too_large,
                "delimited stream exceeds the configured collection item limit",
                row.span,
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        keep_reading = consumer(row)
        keep_reading isa Bool ||
            throw(ArgumentError("bulk stream consumer must return Bool"))
        rows_emitted += 1
        if !keep_reading
            return FormatResult(BulkStreamSummary(
                records_read,
                rows_emitted,
                bytes_read,
                true,
            ))
        end
    end
    if header_pending
        document = source_document(""; source_name = normalized_source_name).value
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :missing_bulk_header,
            "delimited table requires a header",
            source_span(document, 1, 1),
        )
        return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
    end
    return FormatResult(BulkStreamSummary(
        records_read,
        rows_emitted,
        bytes_read,
        false,
    ))
end

stream_delimited_rows(
    consumer::Function,
    input::IO,
    schema::BulkTableSchema;
    keywords...,
) = stream_delimited_rows(input, schema, consumer; keywords...)

"""Stream JSONL rows from an IO without retaining the full input or result table."""
function _stream_json_line(input::IO, maximum_bytes::Int)
    bytes = UInt8[]
    while !eof(input)
        byte = read(input, UInt8)
        push!(bytes, byte)
        length(bytes) <= maximum_bytes || return (:too_large, bytes)
        if byte == 0x0a
            return (:record, bytes)
        elseif byte == 0x0d
            if !eof(input) && peek(input, UInt8) == 0x0a
                push!(bytes, read(input, UInt8))
                length(bytes) <= maximum_bytes || return (:too_large, bytes)
            end
            return (:record, bytes)
        end
    end
    return isempty(bytes) ? (:eof, bytes) : (:record, bytes)
end

function stream_json_lines(
    input::IO,
    schema::BulkTableSchema,
    consumer::Function;
    source_name::AbstractString = "<stream>",
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    normalized_source_name = String(source_name)
    isempty(normalized_source_name) && throw(ArgumentError("source name must not be empty"))
    occursin('\0', normalized_source_name) &&
        throw(ArgumentError("source name must not contain NUL"))
    records_read = 0
    rows_emitted = 0
    bytes_read = 0
    identities = Set{String}()
    while true
        status, bytes = _stream_json_line(input, policy.max_scalar_bytes)
        status == :eof && break
        records_read += 1
        bytes_read += length(bytes)
        if status == :too_large || bytes_read > policy.max_document_bytes
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                status == :too_large ? :scalar_too_large : :document_too_large,
                status == :too_large ?
                    "JSONL stream record exceeds the configured byte limit" :
                    "JSONL stream exceeds the configured byte limit",
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        record_name = "$(normalized_source_name):record-$(records_read)"
        parsed_row = parse_json_lines(bytes, schema; source_name = record_name, policy)
        format_succeeded(parsed_row) ||
            return FormatResult{BulkStreamSummary}(
                nothing,
                collect(parsed_row.diagnostics),
            )
        length(parsed_row.value.table.rows) == 1 || begin
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :stream_record_count_mismatch,
                "JSONL stream chunk did not contain exactly one row",
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        row = only(parsed_row.value.table.rows)
        identity = _bulk_identity_key(schema, row)
        if identity in identities
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :duplicate_bulk_row_identity,
                "bulk row identity is duplicated",
                _bulk_identity_span(schema, row),
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        push!(identities, identity)
        if rows_emitted + 1 > div(policy.max_collection_items, length(schema.columns))
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :collection_too_large,
                "JSONL stream exceeds the configured collection item limit",
                row.span,
            )
            return FormatResult{BulkStreamSummary}(nothing, [diagnostic])
        end
        keep_reading = consumer(row)
        keep_reading isa Bool ||
            throw(ArgumentError("bulk stream consumer must return Bool"))
        rows_emitted += 1
        if !keep_reading
            return FormatResult(BulkStreamSummary(
                records_read,
                rows_emitted,
                bytes_read,
                true,
            ))
        end
    end
    return FormatResult(BulkStreamSummary(
        records_read,
        rows_emitted,
        bytes_read,
        false,
    ))
end

stream_json_lines(
    consumer::Function,
    input::IO,
    schema::BulkTableSchema;
    keywords...,
) = stream_json_lines(input, schema, consumer; keywords...)
