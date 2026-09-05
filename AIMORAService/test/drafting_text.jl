# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingTextServiceTests
using AIMORAService
using AIMORAProject
using Test

@testset "text replacement retains label identity and rejects mixed edits atomically" begin
    mktempdir() do root
        state = AIMORAService.ServiceState(ServiceConfiguration(endpoint = joinpath(root, "text.sock"),
            session_token = repeat("b", 64), allowed_roots = [root]))
        path = joinpath(root, "labels.aimora.yaml")
        opened = AIMORAService.dispatch_request!(state, "create", "project.create",
            Dict("path" => path, "name" => "Label Editing")).result
        project_id = opened["project_id"]
        revision = Ref(opened["revision"])
        serial = Ref(0)
        function edit(operation, ids, points; attributes = Dict{String,Any}())
            serial[] += 1
            response = AIMORAService.dispatch_request!(state, "text-$(serial[])", "semantic.commit",
                Dict{String,Any}("project_id" => project_id, "base_revision" => revision[],
                    "transaction_id" => "text-$(serial[])", "operation" => operation,
                    "semantic_ids" => ids, "points" => points, "attributes" => attributes)).result
            @test response["status"] == "accepted"
            revision[] = response["revision"]
            return response
        end
        ids = String[]
        for (index, text) in enumerate(("Feeder A", "Feeder B"))
            created = edit("draw.text", String[], [[Float64(index), 3.0]];
                attributes = Dict("text" => text))
            push!(ids, only(created["changed_owner_ids"]))
        end
        line = edit("draw.line", String[], [[0.0, 0.0], [2.0, 2.0]])
        line_id = only(line["changed_owner_ids"])
        original_scene = line["drawing_scene"]
        save() = AIMORAService.dispatch_request!(state, "save", "project.save",
            Dict("project_id" => project_id, "base_revision" => revision[]))
        save()
        before = open_project(path).value.project
        @test "modify.text" in opened["edit_operations"]
        for invalid in ("", "   ", "two\nlines", "null\0text")
            @test_throws ServiceError edit("modify.text", ids, Vector{Float64}[];
                attributes = Dict("text" => invalid))
        end
        @test_throws ServiceError edit("modify.text", [ids[1], line_id], Vector{Float64}[];
            attributes = Dict("text" => "Cannot partially apply"))
        unchanged = AIMORAService.dispatch_request!(state, "describe", "project.describe",
            Dict("project_id" => project_id)).result
        @test unchanged["drawing_scene"] == original_scene
        replacement = "Feeder \u03a9 / \u0645\u063a\u0630\u064a"
        edited = edit("modify.text", reverse(ids), Vector{Float64}[];
            attributes = Dict("text" => replacement))
        @test Set(edited["changed_owner_ids"]) == Set(ids)
        @test edited["modified"] && edited["can_undo"]
        save()
        after = open_project(path).value.project
        @test project_physics_hash(after) == project_physics_hash(before)
        for id in ProjectId.(ids)
            original = drawing_record(before.drawings, id)
            updated = drawing_record(after.drawings, id)
            @test updated.text == replacement
            @test updated.identity == original.identity
            @test updated.anchor == original.anchor
            @test updated.layer == original.layer && updated.style == original.style
        end
        @test drawing_record(after.drawings, ProjectId(line_id)) == drawing_record(before.drawings, ProjectId(line_id))
        @test_throws ServiceError edit("modify.text", ids, Vector{Float64}[];
            attributes = Dict("text" => replacement))
        undone = edit("edit.undo", String[], Vector{Float64}[])
        @test undone["drawing_scene"] == original_scene
        @test undone["modified"] && undone["can_redo"]
        redone = edit("edit.redo", String[], Vector{Float64}[])
        @test redone["drawing_scene"] == edited["drawing_scene"]
        @test !redone["modified"]
    end
end
end
