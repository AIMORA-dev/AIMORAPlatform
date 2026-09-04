struct FormatConformanceTarget
    id::Symbol
    owner::String
end

const MANDATORY_FORMAT_TARGETS = (
    FormatConformanceTarget(:source_yaml_json_locks, "test/runtests.jl"),
    FormatConformanceTarget(:bulk_tabular_streaming, "test/bulk_tables.jl"),
    FormatConformanceTarget(:structural_schemas, "test/structural_schemas.jl"),
    FormatConformanceTarget(:versioned_migrations, "test/migrations.jl"),
    FormatConformanceTarget(:inert_envelopes, "test/inert_envelopes.jl"),
    FormatConformanceTarget(:restricted_expressions, "test/restricted_expressions.jl"),
    FormatConformanceTarget(:project_documents, "test/project_documents.jl"),
    FormatConformanceTarget(:generic_imports, "test/import_plans.jl"),
    FormatConformanceTarget(:native_migrations, "test/native_migrations.jl"),
    FormatConformanceTarget(:native_drawing_documents, "test/drawing_documents.jl"),
    FormatConformanceTarget(:release_boundary, "test/release_boundary.jl"),
)

const PASSED_FORMAT_TARGETS = Set{Symbol}()

function record_format_conformance!(id::Symbol)
    id in getfield.(MANDATORY_FORMAT_TARGETS, :id) || error("unknown mandatory format target $(id)")
    id in PASSED_FORMAT_TARGETS && error("mandatory format target $(id) was recorded twice")
    push!(PASSED_FORMAT_TARGETS, id)
    return id
end
