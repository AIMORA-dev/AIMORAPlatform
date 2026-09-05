# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingLayerServiceTests
using AIMORAService
using AIMORAProject
using Test

@testset "layer creation assignment visibility printing and history preserve canonical drawings" begin
    mktempdir() do root
        configuration = ServiceConfiguration(endpoint = joinpath(root, "layers.sock"),
            session_token = repeat("f", 64), allowed_roots = [root])
        state = AIMORAService.ServiceState(configuration)
        path = joinpath(root, "layers.aimora.yaml")
        opened = AIMORAService.dispatch_request!(state, "create", "project.create",
            Dict("path" => path, "name" => "Layer Editing")).result
        project_id = opened["project_id"]
        revision = Ref(opened["revision"])
        serial = Ref(0)
        function edit(operation, ids = String[], points = Vector{Float64}[]; attributes = Dict{String,Any}())
            serial[] += 1
            response = AIMORAService.dispatch_request!(state, "layer-$(serial[])", "semantic.commit",
                Dict{String,Any}("project_id" => project_id, "base_revision" => revision[],
                    "transaction_id" => "layer-$(serial[])", "operation" => operation,
                    "semantic_ids" => ids, "points" => points, "attributes" => attributes)).result
            @test response["status"] == "accepted"
            revision[] = response["revision"]
            return response
        end
        describe() = AIMORAService.dispatch_request!(state, "describe", "project.describe",
            Dict("project_id" => project_id)).result
        @test length(opened["drawing_layers"]) == 1
        created = edit("layer.create"; attributes = Dict("name" => "Annotations"))
        layer_id = only(created["changed_owner_ids"])
        @test length(describe()["drawing_layers"]) == 2
        @test_throws ServiceError edit("layer.create"; attributes = Dict("name" => "annotations"))
        line = edit("draw.line", String[], [[0.0, 0.0], [10.0, 5.0]])
        line_id = only(line["changed_owner_ids"])
        moved = edit("modify.layer", [line_id]; attributes = Dict("layer_id" => layer_id))
        @test length(moved["drawing_scene"]["items"]) == 1
        hidden = edit("layer.update"; attributes = Dict("layer_id" => layer_id,
            "name" => "Notes", "visible" => false, "printable" => false))
        @test isempty(hidden["drawing_scene"]["items"])
        restored = edit("edit.undo")
        @test length(restored["drawing_scene"]["items"]) == 1
        layer = only(layer for layer in describe()["drawing_layers"] if layer["id"] == layer_id)
        @test layer["name"] == "Annotations" && layer["visible"] && layer["printable"]
        redone = edit("edit.redo")
        @test isempty(redone["drawing_scene"]["items"])
        AIMORAService.dispatch_request!(state, "save", "project.save",
            Dict("project_id" => project_id, "base_revision" => revision[]))
        saved = open_project(path).value.project
        @test drawing_record(saved.drawings, ProjectId(line_id)).layer == ProjectId(layer_id)
        @test length(saved.drawings.entities) == 1
        fresh = AIMORAService.ServiceState(configuration)
        reopened = AIMORAService.dispatch_request!(fresh, "reopen", "project.open",
            Dict("path" => path, "mode" => "drafting")).result
        @test isempty(reopened["drawing_scene"]["items"])
        @test length(reopened["drawing_layers"]) == 2
        layer = only(layer for layer in reopened["drawing_layers"] if layer["id"] == layer_id)
        @test layer["name"] == "Notes" && !layer["visible"] && !layer["printable"]
        edit("edit.undo")
        edit("edit.undo")
        edit("edit.undo")
        edit("edit.undo")
        @test length(describe()["drawing_layers"]) == 1
        @test isempty(describe()["drawing_scene"]["items"])
    end
end
end
