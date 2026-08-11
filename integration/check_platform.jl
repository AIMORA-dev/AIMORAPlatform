using Test
using TOML
using UUIDs

const PLATFORM_ROOT = normpath(joinpath(@__DIR__, ".."))

function platform_toml(relative_path::AbstractString)
    return TOML.parsefile(joinpath(PLATFORM_ROOT, relative_path))
end

@testset "AIMORA Platform package and licence contract" begin
    package_graph = platform_toml("package-graph.toml")
    licensing = platform_toml("licensing.toml")
    packages = package_graph["package"]
    @test package_graph["schema"] == "aimora-platform-package-graph-v1"
    @test length(packages) == 7
    @test length(Set(package["id"] for package in packages)) == 7
    @test length(Set(package["path"] for package in packages)) == 7

    julia_packages = filter(package -> package["kind"] == "julia", packages)
    @test length(julia_packages) == 6
    for package in julia_packages
        package_root = joinpath(PLATFORM_ROOT, package["path"])
        project = TOML.parsefile(joinpath(package_root, "Project.toml"))
        @test project["name"] == package["name"]
        @test project["uuid"] == package["uuid"]
        @test project["version"] == "0.1.0"
        @test project["license"] == "PolyForm-Noncommercial-1.0.0"
        @test isfile(joinpath(package_root, "src", "$(package["name"]).jl"))
        @test isfile(joinpath(package_root, "test", "runtests.jl"))
        pushfirst!(LOAD_PATH, package_root)
        loaded_module = Base.require(Base.PkgId(UUID(package["uuid"]), package["name"]))
        @test nameof(loaded_module) == Symbol(package["name"])
    end

    symbols = only(filter(package -> package["kind"] == "content", packages))
    symbol_metadata = TOML.parsefile(joinpath(PLATFORM_ROOT, symbols["path"], "metadata", "library.toml"))
    @test symbol_metadata["library_id"] == symbols["name"]
    @test symbol_metadata["version"] == symbols["version"]
    @test symbol_metadata["licence"] == "PolyForm-Noncommercial-1.0.0"
    @test isfile(joinpath(PLATFORM_ROOT, symbols["path"], "tests", "runtests.jl"))

    licence_paths = Dict(record["path"] => record for record in licensing["path"])
    @test Set(keys(licence_paths)) == Set(package["path"] for package in packages)
    for package in packages
        record = licence_paths[package["path"]]
        @test record["licence"] == "PolyForm-Noncommercial-1.0.0"
        @test isfile(joinpath(PLATFORM_ROOT, record["notice"]))
    end
end
