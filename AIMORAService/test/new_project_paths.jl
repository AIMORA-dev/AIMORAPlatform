# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module NewProjectPathTests
using AIMORAService
using Test

@testset "new project destinations are confined and never overwrite existing entries" begin
    mktempdir() do root
        approved = joinpath(root, "approved")
        mkdir(approved)
        policy = AIMORAService.PathPolicy([approved], 4096)
        destination = joinpath(approved, "new.aimora.yaml")
        @test AIMORAService.confine_new_project_file(policy, destination) == joinpath(realpath(approved), "new.aimora.yaml")
        @test !ispath(destination)
        write(destination, "existing project bytes")
        @test_throws AIMORAService.ServiceError AIMORAService.confine_new_project_file(policy, destination)
        @test read(destination, String) == "existing project bytes"
        for path in (joinpath(root, "outside.aimora.yaml"),
            joinpath(approved, "..", "outside.aimora.yaml"),
            joinpath(approved, "missing", "new.aimora.yaml"),
            joinpath(approved, "CON.aimora.yaml"), joinpath(approved, "new.aimora.yaml:stream"),
            joinpath(approved, "bad.aimora.yaml "), joinpath(approved, "bad\nname.aimora.yaml"),
            joinpath(approved, "bad\tname.aimora.yaml"), "relative.aimora.yaml", destination * "\0")
            @test_throws AIMORAService.ServiceError AIMORAService.confine_new_project_file(policy, path)
        end
        @test !ispath(joinpath(root, "outside.aimora.yaml"))
    end
end
end
