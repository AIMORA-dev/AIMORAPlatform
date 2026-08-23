using Test
using TOML

const PLATFORM_ROOT = normpath(joinpath(@__DIR__, ".."))

include(joinpath(PLATFORM_ROOT, "tools", "changed_packages.jl"))
using .PlatformChangedPackages

@testset "AIMORA Platform changed-package selection" begin
    @test affected_packages(PLATFORM_ROOT, ["AIMORAProject/src/AIMORAProject.jl"]) == ["AIMORAProject"]
    @test affected_packages(PLATFORM_ROOT, ["AIMORASymbols/metadata/library.toml"]) == ["AIMORASymbols"]
    @test length(affected_packages(PLATFORM_ROOT, ["licensing.toml"])) == 7
end

include(joinpath(PLATFORM_ROOT, "integration", "check_platform.jl"))
