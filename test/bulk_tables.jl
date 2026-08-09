function bulk_table_semantics(table::BulkTable)
    return [
        [semantic_format_value(cell) for cell in row.cells]
        for row in table.rows
    ]
end

function serialized_text(result::FormatSerializationResult)
    @test format_succeeded(result)
    return String(collect(result.value.bytes))
end

function standard_bulk_schema()
    return BulkTableSchema(
        "asset.rows",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("count", BulkInteger),
            BulkColumnSpec(
                "value",
                BulkDecimal;
                unit = "kV",
                basis = "line_to_line_rms",
            ),
            BulkColumnSpec("enabled", BulkBoolean),
            BulkColumnSpec("note", BulkString; nullable = true),
        ],
        "id",
    )
end

function standard_csv_text()
    return "id,count,value,enabled,note\r\n" *
           "\"line,α\",12,2300e-1,true,\"quoted \"\"text\"\"\r\nnext\"\r\n" *
           "plain,-3,-0.0,false,\\N\r\n" *
           "empty,0,1.25,false,\r\n" *
           "literal,1,2e0,true,\"\\N\"\r\n"
end

@testset "typed bulk table schemas and scalar invariants" begin
    schema = standard_bulk_schema()
    @test schema.id == "asset.rows"
    @test schema.version == v"1.0.0"
    @test schema.identity_column == "id"
    @test schema.columns[3].unit == "kV"
    @test schema.columns[3].basis == "line_to_line_rms"
    @test schema == standard_bulk_schema()
    @test DelimitedTextPolicy() == DelimitedTextPolicy()

    @test_throws ArgumentError BulkColumnSpec("bad column", BulkString)
    @test_throws ArgumentError BulkColumnSpec("id", BulkString; unit = "")
    @test_throws ArgumentError BulkColumnSpec("id", BulkString; basis = "bad\nbase")
    @test_throws ArgumentError BulkTableSchema(
        "bad schema",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString)],
        "id",
    )
    @test_throws ArgumentError BulkTableSchema(
        "duplicate.columns",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString), BulkColumnSpec("id", BulkString)],
        "id",
    )
    @test_throws ArgumentError BulkTableSchema(
        "missing.identity",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString)],
        "other",
    )
    @test_throws ArgumentError BulkTableSchema(
        "nullable.identity",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString; nullable = true)],
        "id",
    )
    @test_throws ArgumentError BulkTableSchema(
        "boolean.identity",
        v"1.0.0",
        [BulkColumnSpec("id", BulkBoolean)],
        "id",
    )
    @test_throws ArgumentError DelimitedTextPolicy(delimiter = ';')
    @test_throws ArgumentError DelimitedTextPolicy(quote_character = '\'')
    @test_throws ArgumentError DelimitedTextPolicy(null_token = "")
    @test_throws ArgumentError DelimitedTextPolicy(null_token = "bad,null")
    invalid_unicode = String(UInt8[0xff])
    @test_throws ArgumentError BulkColumnSpec(invalid_unicode, BulkString)
    @test_throws ArgumentError DelimitedTextPolicy(null_token = invalid_unicode)

    integer_identity_schema = BulkTableSchema(
        "integer.identity",
        v"1.0.0",
        [BulkColumnSpec("id", BulkInteger), BulkColumnSpec("label", BulkString)],
        "id",
    )
    integer_identity = parse_delimited_table(
        "id,label\n1,first\n2,second\n",
        integer_identity_schema,
    )
    @test format_succeeded(integer_identity)
    @test integer_identity.value.table.rows[2].cells[1].value == FormatInteger(2)
end

@testset "RFC-aligned CSV and TSV scalar table semantics" begin
    schema = standard_bulk_schema()
    parsed = parse_delimited_table(
        standard_csv_text(),
        schema;
        source_name = "assets.csv",
    )
    @test format_succeeded(parsed)
    @test isempty(parsed.diagnostics)
    table = parsed.value.table
    @test length(table.rows) == 4
    first_row = table.rows[1]
    @test bulk_cell(table, first_row, "id").value == FormatString("line,α")
    @test bulk_cell(table, first_row, "count").value == FormatInteger(12)
    @test bulk_cell(table, first_row, "value").value == FormatDecimal(23, 1)
    @test bulk_cell(table, first_row, "enabled").value == FormatBoolean(true)
    @test bulk_cell(table, first_row, "note").value ==
          FormatString("quoted \"text\"\r\nnext")
    @test first_row.span.start.line == 2
    @test first_row.span.stop.line == 3
    @test bulk_cell(table, first_row, "note").span.start.line == 2
    @test bulk_cell(table, first_row, "note").span.stop.line == 3
    @test table.rows[2].span.start.line == 4
    @test bulk_cell(table, table.rows[2], "note").value == FormatNull()
    @test bulk_cell(table, table.rows[3], "note").value == FormatString("")
    @test bulk_cell(table, table.rows[4], "note").value == FormatString("\\N")
    @test_throws KeyError bulk_cell(table, first_row, "missing")

    csv = serialized_text(serialize_delimited_table(table))
    @test csv ==
          "id,count,value,enabled,note\n" *
          "\"line,α\",12,23e1,true,\"quoted \"\"text\"\"\r\nnext\"\n" *
          "plain,-3,-0e0,false,\\N\n" *
          "empty,0,125e-2,false,\n" *
          "literal,1,2e0,true,\"\\N\"\n"
    reparsed = parse_delimited_table(csv, schema; source_name = "normalized.csv")
    @test format_succeeded(reparsed)
    @test bulk_table_semantics(reparsed.value.table) == bulk_table_semantics(table)
    @test serialized_text(serialize_delimited_table(reparsed.value.table)) == csv

    tsv_policy = DelimitedTextPolicy(delimiter = '\t')
    tsv = serialized_text(serialize_delimited_table(table; grammar = tsv_policy))
    @test startswith(tsv, "id\tcount\tvalue\tenabled\tnote\n")
    @test occursin("line,α\t12", tsv)
    reparsed_tsv = parse_delimited_table(
        tsv,
        schema;
        source_name = "assets.tsv",
        grammar = tsv_policy,
    )
    @test format_succeeded(reparsed_tsv)
    @test bulk_table_semantics(reparsed_tsv.value.table) == bulk_table_semantics(table)

    embedded_tsv = parse_delimited_table(
        "id\tnote\nrow\t\"tab\tline\nquote \"\"λ\"\"\"",
        BulkTableSchema(
            "tsv.embedded",
            v"1.0.0",
            [BulkColumnSpec("id", BulkString), BulkColumnSpec("note", BulkString)],
            "id",
        );
        source_name = "embedded.tsv",
        grammar = tsv_policy,
    )
    @test format_succeeded(embedded_tsv)
    @test embedded_tsv.value.table.rows[1].cells[2].value ==
          FormatString("tab\tline\nquote \"λ\"")

    custom_null = DelimitedTextPolicy(null_token = "NULL")
    custom_null_result = parse_delimited_table(
        "id,count,value,enabled,note\na,1,1.0,true,NULL\nb,2,2.0,false,\"NULL\"",
        schema;
        grammar = custom_null,
    )
    @test format_succeeded(custom_null_result)
    @test custom_null_result.value.table.rows[1].cells[5].value == FormatNull()
    @test custom_null_result.value.table.rows[2].cells[5].value == FormatString("NULL")

    quote_all = DelimitedTextPolicy(
        quote_mode = BulkQuoteAll,
        line_ending = BulkCarriageReturnLineFeed,
    )
    quoted = serialized_text(serialize_delimited_table(table; grammar = quote_all))
    @test startswith(quoted, "\"id\",\"count\",\"value\",\"enabled\",\"note\"\r\n")
    @test occursin("\"plain\",\"-3\",\"-0e0\",\"false\",\\N\r\n", quoted)
    @test format_succeeded(parse_delimited_table(
        quoted,
        schema;
        source_name = "quoted.csv",
        grammar = quote_all,
    ))

    no_header = DelimitedTextPolicy(header = BulkHeaderAbsent)
    body = serialized_text(serialize_delimited_table(table; grammar = no_header))
    @test !startswith(body, "id,count")
    reparsed_body = parse_delimited_table(
        body,
        schema;
        source_name = "body.csv",
        grammar = no_header,
    )
    @test format_succeeded(reparsed_body)
    @test bulk_table_semantics(reparsed_body.value.table) == bulk_table_semantics(table)

    empty_table = parse_delimited_table(
        "id,count,value,enabled,note\n",
        schema,
    ).value.table
    @test serialized_text(serialize_delimited_table(empty_table)) ==
          "id,count,value,enabled,note\n"
    @test serialized_text(serialize_json_lines(empty_table)) == ""
end

@testset "bulk string corpus round trips through every text surface" begin
    schema = BulkTableSchema(
        "string.corpus",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString), BulkColumnSpec("text", BulkString)],
        "id",
    )
    source = source_document(""; source_name = "constructed").value
    span = source_span(source, 1, 1)
    samples = [
        "",
        "\\N",
        "plain",
        "comma,value",
        "tab\tvalue",
        "line\nvalue",
        "carriage\rvalue",
        "quote \"value\"",
        "λ😀",
        " leading and trailing ",
    ]
    rows = BulkRow[
        BulkRow(
            [
                FormatNode(FormatString("row$(index)"), span),
                FormatNode(FormatString(value), span),
            ],
            span,
        ) for (index, value) in enumerate(samples)
    ]
    table = BulkTable(schema, rows)
    for grammar in (DelimitedTextPolicy(), DelimitedTextPolicy(delimiter = '\t'))
        bytes = serialize_delimited_table(table; grammar)
        reparsed = parse_delimited_table(
            collect(bytes.value.bytes),
            schema;
            source_name = "corpus.txt",
            grammar,
        )
        @test format_succeeded(reparsed)
        @test bulk_table_semantics(reparsed.value.table) == bulk_table_semantics(table)
        @test serialize_delimited_table(reparsed.value.table; grammar).value.bytes ==
              bytes.value.bytes
    end
    jsonl = serialize_json_lines(table)
    reparsed_jsonl = parse_json_lines(
        collect(jsonl.value.bytes),
        schema;
        source_name = "corpus.jsonl",
    )
    @test format_succeeded(reparsed_jsonl)
    @test bulk_table_semantics(reparsed_jsonl.value.table) == bulk_table_semantics(table)
    @test serialize_json_lines(reparsed_jsonl.value.table).value.bytes == jsonl.value.bytes
end

@testset "delimited text rejects inference and malformed records" begin
    schema = standard_bulk_schema()
    cases = [
        ("id,count,count,enabled,note\na,1,1.0,true,x\n", :duplicate_bulk_header),
        ("count,id,value,enabled,note\n1,a,1.0,true,x\n", :bulk_header_schema_mismatch),
        ("id,count,value,enabled\na,1,1.0,true\n", :bulk_header_width_mismatch),
        ("id,count,value,enabled,note\na,1,1.0,true\n", :bulk_row_width_mismatch),
        ("id,count,value,enabled,note\na,1,1.0,true,x,extra\n", :bulk_row_width_mismatch),
        ("id,count,value,enabled,note\na,1,1.0,true,x\na,2,2.0,false,y\n", :duplicate_bulk_row_identity),
        ("id,count,value,enabled,note\na,01,1.0,true,x\n", :invalid_bulk_integer),
        ("id,count,value,enabled,note\na,1,1,true,x\n", :invalid_bulk_decimal),
        ("id,count,value,enabled,note\na,1,230kV,true,x\n", :invalid_bulk_decimal),
        ("id,count,value,enabled,note\na,1,1.0,TRUE,x\n", :invalid_bulk_boolean),
        ("id,count,value,enabled,note\na,1,1.0,on,x\n", :invalid_bulk_boolean),
        ("id,count,value,enabled,note\na,1,1.0,true,\"unterminated\n", :unterminated_delimited_quote),
        ("id,count,value,enabled,note\na,1,1.0,true,un\"quoted\n", :unexpected_delimited_quote),
        ("id,count,value,enabled,note\na,1,1.0,true,\"x\"tail\n", :trailing_delimited_field_content),
        ("id,count,value,enabled,note\na,1,1.0,true,\\N\n", :null_in_required_bulk_column),
    ]
    for (text, code) in cases
        selected_schema = code == :null_in_required_bulk_column ?
            BulkTableSchema(
                "required.note",
                v"1.0.0",
                [
                    BulkColumnSpec("id", BulkString),
                    BulkColumnSpec("count", BulkInteger),
                    BulkColumnSpec("value", BulkDecimal),
                    BulkColumnSpec("enabled", BulkBoolean),
                    BulkColumnSpec("note", BulkString),
                ],
                "id",
            ) : schema
        result = parse_delimited_table(text, selected_schema; source_name = "bad.csv")
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
        @test !isnothing(only(result.diagnostics).span)
    end

    date_text = "id,count,value,enabled,note\n2026-08-09,1,1.0,false,yes\n"
    date_result = parse_delimited_table(date_text, schema; source_name = "literal.csv")
    @test format_succeeded(date_result)
    @test bulk_cell(date_result.value.table, only(date_result.value.table.rows), "id").value ==
          FormatString("2026-08-09")
    @test bulk_cell(date_result.value.table, only(date_result.value.table.rows), "note").value ==
          FormatString("yes")

    located_integer = parse_delimited_table(
        "id,count,value,enabled,note\na,01,1.0,true,x\n",
        schema;
        source_name = "located.csv",
    )
    located_diagnostic = only(located_integer.diagnostics)
    @test located_diagnostic.span.source_name == "located.csv"
    @test located_diagnostic.span.start.line == 2
    @test located_diagnostic.span.start.column == 3

    @test only(parse_delimited_table("", schema).diagnostics).code == :missing_bulk_header
    @test format_succeeded(parse_delimited_table(
        "",
        schema;
        grammar = DelimitedTextPolicy(header = BulkHeaderAbsent),
    ))
    invalid_utf8 = parse_delimited_table(UInt8[0x69, 0x64, 0x0a, 0x80], schema)
    @test !format_succeeded(invalid_utf8)
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
    nul = parse_delimited_table(
        Vector{UInt8}(codeunits("id,count,value,enabled,note\na,1,1.0,true,x\0y\n")),
        schema,
    )
    @test only(nul.diagnostics).code == :delimited_nul_prohibited
end

@testset "bulk table input and output resource bounds" begin
    schema = standard_bulk_schema()
    long_note = repeat("λ", 2_048)
    text = "id,count,value,enabled,note\na,1,1.0,true,\"$(long_note)\"\n"
    parsed = parse_delimited_table(
        text,
        schema;
        policy = FormatInputPolicy(max_scalar_bytes = ncodeunits(long_note) + 2),
    )
    @test format_succeeded(parsed)
    too_small = parse_delimited_table(
        text,
        schema;
        policy = FormatInputPolicy(max_scalar_bytes = ncodeunits(long_note) - 1),
    )
    @test only(too_small.diagnostics).code == :scalar_too_large
    too_large = parse_delimited_table(
        text,
        schema;
        policy = FormatInputPolicy(max_document_bytes = 16),
    )
    @test only(too_large.diagnostics).code == :document_too_large
    too_many = parse_delimited_table(
        "a,1,1.0,true,x\n",
        schema;
        grammar = DelimitedTextPolicy(header = BulkHeaderAbsent),
        policy = FormatInputPolicy(max_collection_items = 4),
    )
    @test only(too_many.diagnostics).code == :collection_too_large

    table = parsed.value.table
    scalar_limited = serialize_delimited_table(
        table;
        policy = FormatInputPolicy(max_scalar_bytes = ncodeunits(long_note) - 1),
    )
    @test only(scalar_limited.diagnostics).code == :scalar_too_large
    collection_limited = serialize_delimited_table(
        table;
        policy = FormatInputPolicy(max_collection_items = 4),
    )
    @test only(collection_limited.diagnostics).code == :collection_too_large
    document_limited = serialize_delimited_table(
        table;
        policy = FormatInputPolicy(max_document_bytes = 16),
    )
    @test only(document_limited.diagnostics).code == :document_too_large

    source = source_document(""; source_name = "constructed").value
    span = source_span(source, 1, 1)
    string_schema = BulkTableSchema(
        "constructed.string",
        v"1.0.0",
        [BulkColumnSpec("id", BulkString), BulkColumnSpec("text", BulkString)],
        "id",
    )
    nul_table = BulkTable(
        string_schema,
        [BulkRow([
            FormatNode(FormatString("row"), span),
            FormatNode(FormatString("nul\0value"), span),
        ], span)],
    )
    @test only(serialize_delimited_table(nul_table).diagnostics).code ==
          :delimited_nul_prohibited
    nul_jsonl = serialize_json_lines(nul_table)
    @test format_succeeded(nul_jsonl)
    @test parse_json_lines(collect(nul_jsonl.value.bytes), string_schema).value.table.rows[1].cells[2].value ==
          FormatString("nul\0value")

    invalid_string_table = BulkTable(
        string_schema,
        [BulkRow([
            FormatNode(FormatString("row"), span),
            FormatNode(FormatString(String(UInt8[0xff])), span),
        ], span)],
    )
    @test only(serialize_delimited_table(invalid_string_table).diagnostics).code ==
          :invalid_unicode_value
    @test only(serialize_json_lines(invalid_string_table).diagnostics).code ==
          :invalid_unicode_value
end

@testset "JSONL and delimited tables have lossless common semantics" begin
    schema = standard_bulk_schema()
    csv_table = parse_delimited_table(
        standard_csv_text(),
        schema;
        source_name = "assets.csv",
    ).value.table
    serialized = serialize_json_lines(csv_table)
    jsonl = serialized_text(serialized)
    @test count(==('\n'), jsonl) == length(csv_table.rows)
    @test !occursin("\r", jsonl)
    parsed = parse_json_lines(jsonl, schema; source_name = "assets.jsonl")
    @test format_succeeded(parsed)
    @test bulk_table_semantics(parsed.value.table) == bulk_table_semantics(csv_table)
    @test serialized_text(serialize_json_lines(parsed.value.table)) == jsonl

    csv = serialized_text(serialize_delimited_table(parsed.value.table))
    reparsed_csv = parse_delimited_table(csv, schema; source_name = "again.csv")
    @test bulk_table_semantics(reparsed_csv.value.table) == bulk_table_semantics(csv_table)
    @test parse_json_lines("", schema).value.table.rows == []

    crlf = replace(jsonl, "\n" => "\r\n")
    @test format_succeeded(parse_json_lines(crlf, schema; source_name = "windows.jsonl"))
    @test parse_json_lines(jsonl, schema).value.source.provenance.content_sha256 !=
          parse_json_lines(crlf, schema).value.source.provenance.content_sha256
end

@testset "JSONL diagnostics and resource bounds" begin
    schema = standard_bulk_schema()
    valid = "{\"id\":\"a\",\"count\":1,\"value\":1e0,\"enabled\":true,\"note\":null}"
    cases = [
        ("\n", :blank_jsonl_record),
        ("[]\n", :jsonl_record_must_be_object),
        ("{\"id\":\"a\",\"id\":\"b\",\"count\":1,\"value\":1e0,\"enabled\":true,\"note\":null}\n", :duplicate_json_key),
        ("{\"id\":\"a\",\"count\":1,\"value\":1e0,\"enabled\":true}\n", :jsonl_missing_column),
        ("{\"id\":\"a\",\"count\":1,\"value\":1e0,\"enabled\":true,\"note\":null,\"extra\":0}\n", :jsonl_unknown_column),
        ("{\"id\":\"a\",\"count\":1,\"value\":1,\"enabled\":true,\"note\":null}\n", :jsonl_column_kind_mismatch),
        (valid * "\n" * valid * "\n", :duplicate_bulk_row_identity),
        (valid * " " * valid * "\n", :trailing_json_content),
    ]
    for (text, code) in cases
        result = parse_json_lines(text, schema; source_name = "bad.jsonl")
        @test !format_succeeded(result)
        @test code in getfield.(result.diagnostics, :code)
        @test all(diagnostic -> !isnothing(diagnostic.span), result.diagnostics)
    end

    duplicate_location = parse_json_lines(
        valid * "\n" * valid * "\n",
        schema;
        source_name = "located.jsonl",
    )
    duplicate_diagnostic = only(duplicate_location.diagnostics)
    @test duplicate_diagnostic.span.source_name == "located.jsonl"
    @test duplicate_diagnostic.span.start.line == 2
    @test duplicate_diagnostic.span.start.column > 1

    invalid_utf8 = parse_json_lines(UInt8[0x7b, 0x80, 0x7d], schema)
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
    scalar_limited = parse_json_lines(
        valid * "\n",
        schema;
        policy = FormatInputPolicy(max_scalar_bytes = 16),
    )
    @test only(scalar_limited.diagnostics).code == :scalar_too_large
    document_limited = parse_json_lines(
        valid * "\n",
        schema;
        policy = FormatInputPolicy(max_document_bytes = 16),
    )
    @test only(document_limited.diagnostics).code == :document_too_large
    collection_limited = parse_json_lines(
        valid * "\n",
        schema;
        policy = FormatInputPolicy(max_collection_items = 4),
    )
    @test :collection_too_large in getfield.(collection_limited.diagnostics, :code)

    table = parse_json_lines(valid * "\n", schema).value.table
    scalar_output = serialize_json_lines(
        table;
        policy = FormatInputPolicy(max_scalar_bytes = 1),
    )
    @test only(scalar_output.diagnostics).code == :scalar_too_large
    collection_output = serialize_json_lines(
        table;
        policy = FormatInputPolicy(max_collection_items = 4),
    )
    @test only(collection_output.diagnostics).code == :collection_too_large
    document_output = serialize_json_lines(
        table;
        policy = FormatInputPolicy(max_document_bytes = 16),
    )
    @test only(document_output.diagnostics).code == :document_too_large
end

function streaming_schema()
    return BulkTableSchema(
        "stream.rows",
        v"1.0.0",
        [
            BulkColumnSpec("id", BulkString),
            BulkColumnSpec("note", BulkString),
        ],
        "id",
    )
end

@testset "bulk streaming scale budget" begin
    schema = streaming_schema()
    row_count = 20_000
    text = "id,note\n" * join(
        ("row$(index),value$(index)\n" for index in 1:row_count),
    )
    stream_delimited_rows(IOBuffer("id,note\none,value\n"), schema, _ -> true)
    measurement = @timed stream_delimited_rows(IOBuffer(text), schema, _ -> true)
    @test format_succeeded(measurement.value)
    @test measurement.value.value.rows_emitted == row_count
    @test measurement.time < 10.0
    @test measurement.bytes < 384 * 1024 * 1024
end

@testset "bounded delimited row streaming" begin
    schema = streaming_schema()
    text = "id,note\r\none,\"line 1\r\nline 2\"\r\ntwo,plain\r\nthree,last\r\n"
    received = String[]
    result = stream_delimited_rows(
        IOBuffer(text),
        schema,
        row -> begin
            push!(received, bulk_cell(schema, row, "id").value.value)
            return true
        end;
        source_name = "stream.csv",
    )
    @test format_succeeded(result)
    @test received == ["one", "two", "three"]
    @test result.value == BulkStreamSummary(4, 3, ncodeunits(text), false)

    first_row = Ref{Union{Nothing,BulkRow}}(nothing)
    early_input = IOBuffer(text)
    early = stream_delimited_rows(
        early_input,
        schema,
        row -> begin
            first_row[] = row
            return false
        end;
        source_name = "early.csv",
    )
    @test format_succeeded(early)
    @test early.value.records_read == 2
    @test early.value.rows_emitted == 1
    @test early.value.stopped_early
    @test position(early_input) < ncodeunits(text)
    @test first_row[].span.start.line == 1
    @test first_row[].span.stop.line == 2
    @test first_row[].span.source_name == "early.csv:record-2"

    duplicate = stream_delimited_rows(
        IOBuffer("id,note\na,x\na,y\n"),
        schema,
        _ -> true,
    )
    @test only(duplicate.diagnostics).code == :duplicate_bulk_row_identity
    malformed = stream_delimited_rows(
        IOBuffer("id,note\na,\"unterminated\n"),
        schema,
        _ -> true,
    )
    @test only(malformed.diagnostics).code == :unterminated_delimited_quote
    invalid_utf8 = stream_delimited_rows(
        IOBuffer(UInt8[0x69, 0x64, 0x2c, 0x6e, 0x6f, 0x74, 0x65, 0x0a, 0x80, 0x2c, 0x78]),
        schema,
        _ -> true,
    )
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
    scalar_limited = stream_delimited_rows(
        IOBuffer("id,note\na,$(repeat("x", 20))\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_scalar_bytes = 10),
    )
    @test only(scalar_limited.diagnostics).code == :scalar_too_large
    document_limited = stream_delimited_rows(
        IOBuffer("id,note\na,x\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_document_bytes = 4),
    )
    @test only(document_limited.diagnostics).code == :document_too_large
    collection_limited = stream_delimited_rows(
        IOBuffer("id,note\na,x\nb,y\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_collection_items = 3),
    )
    @test only(collection_limited.diagnostics).code == :collection_too_large
    missing_header = stream_delimited_rows(IOBuffer(), schema, _ -> true)
    @test only(missing_header.diagnostics).code == :missing_bulk_header
    empty_body = stream_delimited_rows(
        IOBuffer(),
        schema,
        _ -> true;
        grammar = DelimitedTextPolicy(header = BulkHeaderAbsent),
    )
    @test empty_body.value == BulkStreamSummary(0, 0, 0, false)
    @test_throws ArgumentError stream_delimited_rows(
        IOBuffer("id,note\na,x\n"),
        schema,
        _ -> nothing,
    )
    @test_throws ArgumentError stream_delimited_rows(IOBuffer(), schema, _ -> true; source_name = "")

    do_rows = String[]
    do_result = stream_delimited_rows(
        IOBuffer("id,note\na,x\n"),
        schema;
        source_name = "do.csv",
    ) do row
        push!(do_rows, bulk_cell(schema, row, "id").value.value)
        true
    end
    @test format_succeeded(do_result)
    @test do_rows == ["a"]

    mktemp() do _, io
        write(io, text)
        seekstart(io)
        file_result = stream_delimited_rows(io, schema, _ -> true)
        @test format_succeeded(file_result)
        @test file_result.value.rows_emitted == 3
    end
end

@testset "bounded JSONL row streaming" begin
    schema = streaming_schema()
    text = "{\"id\":\"one\",\"note\":\"first\"}\r\n" *
           "{\"id\":\"two\",\"note\":\"second\"}\r" *
           "{\"id\":\"three\",\"note\":\"third\"}\n"
    received = String[]
    result = stream_json_lines(
        IOBuffer(text),
        schema,
        row -> begin
            push!(received, row.cells[1].value.value)
            return true
        end;
        source_name = "stream.jsonl",
    )
    @test format_succeeded(result)
    @test received == ["one", "two", "three"]
    @test result.value == BulkStreamSummary(3, 3, ncodeunits(text), false)

    early_input = IOBuffer(text)
    early = stream_json_lines(early_input, schema, _ -> false)
    @test early.value.records_read == 1
    @test early.value.rows_emitted == 1
    @test early.value.stopped_early
    @test position(early_input) < ncodeunits(text)

    duplicate = stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"x\"}\n{\"id\":\"a\",\"note\":\"y\"}\n"),
        schema,
        _ -> true,
    )
    @test only(duplicate.diagnostics).code == :duplicate_bulk_row_identity
    blank = stream_json_lines(IOBuffer("\n"), schema, _ -> true)
    @test only(blank.diagnostics).code == :blank_jsonl_record
    malformed = stream_json_lines(IOBuffer("{\"id\":\"a\"\n"), schema, _ -> true)
    @test !format_succeeded(malformed)
    invalid_utf8 = stream_json_lines(IOBuffer(UInt8[0x7b, 0x80, 0x7d, 0x0a]), schema, _ -> true)
    @test only(invalid_utf8.diagnostics).code == :invalid_utf8
    scalar_limited = stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"$(repeat("x", 20))\"}\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_scalar_bytes = 16),
    )
    @test only(scalar_limited.diagnostics).code == :scalar_too_large
    document_limited = stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"x\"}\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_document_bytes = 8),
    )
    @test only(document_limited.diagnostics).code == :document_too_large
    collection_limited = stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"x\"}\n{\"id\":\"b\",\"note\":\"y\"}\n"),
        schema,
        _ -> true;
        policy = FormatInputPolicy(max_collection_items = 3),
    )
    @test only(collection_limited.diagnostics).code == :collection_too_large
    @test stream_json_lines(IOBuffer(), schema, _ -> true).value ==
          BulkStreamSummary(0, 0, 0, false)
    @test_throws ArgumentError stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"x\"}\n"),
        schema,
        _ -> nothing,
    )
    @test_throws ArgumentError stream_json_lines(IOBuffer(), schema, _ -> true; source_name = "")

    do_rows = String[]
    do_result = stream_json_lines(
        IOBuffer("{\"id\":\"a\",\"note\":\"x\"}\n"),
        schema;
        source_name = "do.jsonl",
    ) do row
        push!(do_rows, bulk_cell(schema, row, "id").value.value)
        true
    end
    @test format_succeeded(do_result)
    @test do_rows == ["a"]
end
