struct ProjectConformanceTarget
    id::Symbol
    owner::String
end

const MANDATORY_PROJECT_TARGETS = (
    ProjectConformanceTarget(:canonical_primitives_schemas, "test/schema_registry.jl"),
    ProjectConformanceTarget(:revisions_transactions, "test/transactions.jl"),
    ProjectConformanceTarget(:graph_domains_topology, "test/graphs.jl"),
    ProjectConformanceTarget(:drawing_model, "test/drawing_model.jl"),
    ProjectConformanceTarget(:drawing_serialization, "test/drawing_serialization.jl"),
    ProjectConformanceTarget(:assets_realizations_data, "test/assets.jl"),
    ProjectConformanceTarget(:definitions_instances, "test/hierarchy.jl"),
    ProjectConformanceTarget(:control_networks, "test/controls.jl"),
    ProjectConformanceTarget(:events_scenarios, "test/events_scenarios.jl"),
    ProjectConformanceTarget(:studies_workflows_experiments, "test/orchestration.jl"),
    ProjectConformanceTarget(:semantic_hashes_readiness, "test/semantic_hashes_readiness.jl"),
    ProjectConformanceTarget(:builders_queries_tables_formats_imports, "test/builders_formats_tables.jl"),
    ProjectConformanceTarget(:release_boundary, "test/release_boundary.jl"),
)

const PASSED_PROJECT_TARGETS = Set{Symbol}()

function record_project_conformance!(id::Symbol)
    id in getfield.(MANDATORY_PROJECT_TARGETS, :id) ||
        error("unknown mandatory project target $(id)")
    id in PASSED_PROJECT_TARGETS &&
        error("mandatory project target $(id) was recorded twice")
    push!(PASSED_PROJECT_TARGETS, id)
    return id
end
