# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module ProjectCreationTests
using AIMORAService
using AIMORAProject
using Test
using UUIDs

@testset "generated drawing project identities accept every UUID leading digit" begin
    ids = ProjectId[]
    for digit in "0123456789abcdef"
        identity = UUID(string(digit) * "0000000-0000-4000-8000-000000000001")
        id = AIMORAService._new_drawing_project_id(identity)
        @test startswith(id.value, "project.p")
        @test id.value == "project.p" * replace(string(identity), "-" => "")
        push!(ids, id)
    end
    @test length(unique(ids)) == 16
end

@testset "service creates an empty editable drawing without replacing existing files" begin
    mktempdir() do root
        state = AIMORAService.ServiceState(ServiceConfiguration(endpoint = joinpath(root, "service.sock"),
            session_token = repeat("d", 64), allowed_roots = [root]))
        path = joinpath(root, "new.aimora.yaml")
        request = Dict("path" => path, "name" => "New Drawing")
        created = AIMORAService.dispatch_request!(state, "create-drawing", "project.create", request)
        @test created.result["can_save"]
        @test !created.result["modified"]
        @test !created.result["can_undo"] && !created.result["can_redo"]
        @test isempty(created.result["drawing_scene"]["items"])
        @test isfile(path)
        original = read(path)
        loaded = open_project(path)
        @test !isnothing(loaded.value)
        @test loaded.value.project.metadata.name == "New Drawing"
        @test isempty(loaded.value.project.records)
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "create-existing", "project.create", request)
        @test read(path) == original
        @test length(state.projects) == 1
        invalid = Dict("path" => joinpath(root, "wrong.txt"), "name" => "Wrong extension")
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "create-wrong-extension", "project.create", invalid)
        @test !ispath(invalid["path"])
        overwrite_request = Dict{String,Any}("path" => path, "name" => "Replacement", "overwrite" => true)
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "create-with-overwrite", "project.create", overwrite_request)
        @test read(path) == original
        limited_state = AIMORAService.ServiceState(ServiceConfiguration(
            endpoint = joinpath(root, "limited.sock"), session_token = repeat("e", 64),
            allowed_roots = [root], limits = ServiceLimits(max_project_bytes = 1)))
        limited_path = joinpath(root, "over-budget.aimora.yaml")
        limited_request = Dict("path" => limited_path, "name" => "Over budget")
        @test_throws ServiceError AIMORAService.dispatch_request!(limited_state,
            "create-over-budget", "project.create", limited_request)
        @test !ispath(limited_path)
        @test isempty(limited_state.projects)
        @test isempty(limited_state.semantic_edit_providers)
    end
end
end
