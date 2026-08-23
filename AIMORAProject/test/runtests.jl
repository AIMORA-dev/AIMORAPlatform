using Test
using UUIDs
using AIMORAProject

include("conformance_registry.jl")

function semantic_error_code(operation)
    try
        operation()
    catch error
        @test error isa SemanticValidationError
        return error.code
    end
    error("expected SemanticValidationError")
end

function canonical_test_licence()
    return LicenceIdentity(
        "CC0-1.0",
        "CC0 1.0 Universal";
        uri = GlobalId("https://creativecommons.org/publicdomain/zero/1.0/"),
    )
end

function canonical_test_provenance()
    return ProvenanceSource(
        ProjectId("source.synthetic_test"),
        "AIMORA synthetic canonical-project test source",
        canonical_test_licence();
        source_uri = GlobalId("https://example.com/aimora/test-source"),
        source_sha256 = repeat("a", 64),
        source_version = "1.0.0",
    )
end

@testset "canonical project package boundary" begin
    @test nameof(AIMORAProject) === :AIMORAProject
end

include("identities.jl")
include("quantities.jl")
include("schema_registry.jl")
include("transactions.jl")
include("graphs.jl")
include("assets.jl")
include("hierarchy.jl")
include("controls.jl")
include("events_scenarios.jl")
include("orchestration.jl")
include("extensions.jl")
include("semantic_hashes_readiness.jl")
include("builders_formats_tables.jl")
include("release_boundary.jl")
include("conformance.jl")
