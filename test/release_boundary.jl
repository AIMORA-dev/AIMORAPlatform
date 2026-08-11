using TOML

@testset "package API dependency licence and release boundary" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    project = TOML.parsefile(joinpath(repository, "Project.toml"))
    @test VersionNumber(project["version"]) == v"1.0.0"
    @test project["license"] == "PolyForm-Noncommercial-1.0.0"
    @test Set(keys(project["deps"])) == Set(["SHA", "TOML", "UUIDs", "Unicode"])
    @test project["compat"]["julia"] == "1.10"

    ambiguities = Test.detect_ambiguities(AIMORAFormats; recursive = true)
    @test isempty(ambiguities)
    @test all(name -> isdefined(AIMORAFormats, name), names(AIMORAFormats; all = false))

    licence = read(joinpath(repository, "LICENSE"), String)
    @test occursin("PolyForm Noncommercial License 1.0.0", licence)
    @test occursin("Required Notice: Copyright 2026 Ahmed Elkholy.", licence)
    @test isfile(joinpath(repository, "CHANGELOG.md"))
    @test occursin("## 1.0.0 — 2026-08-11", read(joinpath(repository, "CHANGELOG.md"), String))

    workflow = read(joinpath(repository, ".github", "workflows", "ci.yml"), String)
    for runner in ("ubuntu-latest", "macos-latest", "windows-latest")
        @test occursin(runner, workflow)
    end
    @test occursin("julia: ['1.10', '1']", workflow)
    @test !occursin("push:", workflow)
end

record_format_conformance!(:release_boundary)
