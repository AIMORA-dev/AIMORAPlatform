# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingArrangementServiceTests
using AIMORAService
using AIMORAProject
using Test

@testset "service arrangements survive save, fresh reopen and saved-state undo redo" begin
    mktempdir() do root
        configuration = ServiceConfiguration(endpoint = joinpath(root, "arrangement.sock"),
            session_token = repeat("a", 64), allowed_roots = [root])
        state = AIMORAService.ServiceState(configuration)
        path = joinpath(root, "arrangement.aimora.yaml")
        opened = AIMORAService.dispatch_request!(state, "create", "project.create",
            Dict("path" => path, "name" => "Arrangement Journey")).result
        project_id = opened["project_id"]
        revision = Ref(opened["revision"])
        serial = Ref(0)
        initial_physics = project_physics_hash(open_project(path).value.project)
        function edit(operation, ids, points; attributes = Dict{String,Any}())
            serial[] += 1
            request = Dict{String,Any}("project_id" => project_id, "base_revision" => revision[],
                "transaction_id" => "arrangement-$(serial[])", "operation" => operation,
                "semantic_ids" => ids, "points" => points, "attributes" => attributes)
            response = AIMORAService.dispatch_request!(state, "edit-$(serial[])", "semantic.commit", request).result
            @test response["status"] == "accepted"
            @test response["revision"] != revision[]
            revision[] = response["revision"]
            return response
        end
        ids = String[]
        original_scene = nothing
        for (x, y) in ((0.0, 1.0), (2.0, 3.0), (10.0, 9.0))
            response = edit("draw.line", String[], [[x, y], [x + 1, y + 2]])
            push!(ids, only(response["changed_owner_ids"]))
            original_scene = response["drawing_scene"]
        end
        for (operation, expected) in (
            ("modify.align_anchor_x", [[0.0, 1.0], [0.0, 3.0], [0.0, 9.0]]),
            ("modify.align_anchor_y", [[0.0, 0.0], [2.0, 0.0], [10.0, 0.0]]),
            ("modify.distribute_anchor_x", [[0.0, 1.0], [5.0, 3.0], [10.0, 9.0]]),
            ("modify.distribute_anchor_y", [[0.0, 1.0], [2.0, 5.0], [10.0, 9.0]]))
            @test operation in opened["edit_operations"]
            points = startswith(operation, "modify.align") ? [[0.0, 0.0]] : Vector{Float64}[]
            arranged = edit(operation, reverse(ids), points)
            @test arranged["modified"]
            @test arranged["can_undo"] && !arranged["can_redo"]
            items = Dict(item["owner_id"] => item for item in arranged["drawing_scene"]["items"])
            @test Set(keys(items)) == Set(ids)
            for (id, anchor) in zip(ids, expected)
                @test items[id]["points"][1] == anchor
                @test items[id]["points"][2] == anchor + [1.0, 2.0]
            end
            unchanged_revision = revision[]
            @test_throws ServiceError edit(operation, ids, points)
            described = AIMORAService.dispatch_request!(state, "describe", "project.describe",
                Dict("project_id" => project_id)).result
            @test described["revision"] == unchanged_revision
            @test described["drawing_scene"] == arranged["drawing_scene"]
            saved = AIMORAService.dispatch_request!(state, "save", "project.save",
                Dict("project_id" => project_id, "base_revision" => revision[])).result
            @test saved["saved"] && !saved["modified"]
            canonical = open_project(path)
            @test !isnothing(canonical.value)
            @test project_physics_hash(canonical.value.project) == initial_physics
            fresh = AIMORAService.ServiceState(configuration)
            reopened = AIMORAService.dispatch_request!(fresh, "reopen", "project.open",
                Dict("path" => path, "mode" => "drafting")).result
            @test reopened["drawing_scene"] == arranged["drawing_scene"]
            @test !reopened["modified"] && !reopened["can_undo"] && !reopened["can_redo"]
            undone = edit("edit.undo", String[], Vector{Float64}[])
            @test undone["drawing_scene"] == original_scene
            @test undone["modified"] && undone["can_redo"]
            redone = edit("edit.redo", String[], Vector{Float64}[])
            @test redone["drawing_scene"] == arranged["drawing_scene"]
            @test !redone["modified"] && !redone["can_redo"]
            restored = edit("edit.undo", String[], Vector{Float64}[])
            @test restored["drawing_scene"] == original_scene
        end
    end
end
end
