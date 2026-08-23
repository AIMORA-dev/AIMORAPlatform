using TOML

@testset "package API dependency licence and release boundary" begin
    repository = normpath(joinpath(@__DIR__, ".."))
    project = TOML.parsefile(joinpath(repository, "Project.toml"))
    @test VersionNumber(project["version"]) == v"1.0.0"
    @test project["license"] == "PolyForm-Noncommercial-1.0.0"
    @test Set(keys(project["deps"])) ==
        Set(["AIMORAFormats", "Dates", "SHA", "Tables", "UUIDs"])
    @test project["compat"]["AIMORAFormats"] == "1"
    @test project["compat"]["Tables"] == "1"
    @test project["compat"]["julia"] == "1.10"
    @test Set(keys(project["extras"])) == Set(["Test", "TOML"])
    @test Set(project["targets"]["test"]) == Set(["Test", "TOML"])
    @test project["sources"]["AIMORAFormats"]["path"] == "../AIMORAFormats"

    ambiguities = Test.detect_ambiguities(AIMORAProject; recursive = true)
    @test isempty(ambiguities)
    @test all(name -> isdefined(AIMORAProject, name), names(AIMORAProject; all = false))
    exported_names = String.(names(AIMORAProject; all = false))
    @test !any(name -> occursin(r"Runtime|GUI|Toolkit|Callback", name), exported_names)

    source = join(read.(joinpath.(Ref(joinpath(repository, "src")), readdir(joinpath(repository, "src"))), String), '\n')
    for prohibited in (r"\beval\(", r"\bccall\(", r"\bdownload\(", r"\brun\(")
        @test isnothing(match(prohibited, source))
    end

    licence = read(joinpath(repository, "LICENSE"), String)
    @test occursin("PolyForm Noncommercial License 1.0.0", licence)
    @test occursin("Required Notice: Copyright 2026 Ahmed Elkholy.", licence)
    @test isfile(joinpath(repository, "CHANGELOG.md"))
    @test occursin("## 1.0.0 — 2026-08-11", read(joinpath(repository, "CHANGELOG.md"), String))

    platform_repository = normpath(joinpath(repository, ".."))
    workflow = read(joinpath(platform_repository, ".github", "workflows", "ci.yml"), String)
    for runner in ("ubuntu-latest", "macos-latest", "windows-latest")
        @test occursin(runner, workflow)
    end
    @test occursin("julia: ['1.10', '1']", workflow)
    @test occursin("push:", workflow)
    @test occursin("pull_request:", workflow)
end

record_project_conformance!(:release_boundary)
