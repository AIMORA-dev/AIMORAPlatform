using Test
using TOML

const REPOSITORY_ROOT = normpath(joinpath(@__DIR__, ".."))

@testset "semantic symbol library boundary" begin
    library = TOML.parsefile(joinpath(REPOSITORY_ROOT, "metadata", "library.toml"))
    profile = TOML.parsefile(joinpath(REPOSITORY_ROOT, "profiles", "aimora", "profile.toml"))

    @test library["schema"] == "aimora-symbol-library-v1"
    @test library["artwork_provenance_required"] === true
    @test isempty(profile["symbol_ids"])
end
