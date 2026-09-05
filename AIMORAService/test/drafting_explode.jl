# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingExplosionServiceTests
using AIMORAService
using AIMORAProject
using Test

@testset "path explosion preserves exact segments and restores original owners through undo" begin
    mktempdir() do root
        state = AIMORAService.ServiceState(ServiceConfiguration(endpoint = joinpath(root, "explode.sock"),
            session_token = repeat("c", 64), allowed_roots = [root]))
        path = joinpath(root, "paths.aimora.yaml")
        opened = AIMORAService.dispatch_request!(state, "create", "project.create",
            Dict("path" => path, "name" => "Path Explosion")).result
        project_id = opened["project_id"]
        revision = Ref(opened["revision"])
        serial = Ref(0)
        function edit(operation, ids, points; attributes = Dict{String,Any}())
            serial[] += 1
            response = AIMORAService.dispatch_request!(state, "explode-$(serial[])", "semantic.commit",
                Dict{String,Any}("project_id" => project_id, "base_revision" => revision[],
                    "transaction_id" => "explode-$(serial[])", "operation" => operation,
                    "semantic_ids" => ids, "points" => points, "attributes" => attributes)).result
            @test response["status"] == "accepted"
            revision[] = response["revision"]
            return response
        end
        rectangle = edit("draw.rectangle", String[], [[0.0, 0.0], [2.0, 3.0]])
        rectangle_id = only(rectangle["changed_owner_ids"])
        exact_start = "0.1000000000000000000000000000000001"
        polyline = edit("draw.polyline", String[], [[0.1, 5.0], [2.0, 5.0], [2.0, 8.0]];
            attributes = Dict("exact_points" => [[exact_start, "5"], ["2", "5"], ["2", "8"]]))
        polyline_id = only(polyline["changed_owner_ids"])
        original_scene = polyline["drawing_scene"]
        save() = AIMORAService.dispatch_request!(state, "save", "project.save",
            Dict("project_id" => project_id, "base_revision" => revision[]))
        save()
        before = open_project(path).value.project
        @test "modify.explode_paths" in opened["edit_operations"]
        exploded = edit("modify.explode_paths", [polyline_id, rectangle_id], Vector{Float64}[])
        @test length(exploded["drawing_scene"]["items"]) == 6
        @test length(exploded["changed_owner_ids"]) == 8
        save()
        after = open_project(path).value.project
        @test project_physics_hash(after) == project_physics_hash(before)
        @test all(entity -> entity.kind == ProjectId("entity.line"), after.drawings.entities)
        @test all(entity -> !(entity.identity.id.value in (rectangle_id, polyline_id)), after.drawings.entities)
        @test any(entity -> first(entity.points).x == parse_exact_decimal(exact_start), after.drawings.entities)
        expected = Set{Tuple{DrawingCoordinate,DrawingCoordinate}}()
        for entity in before.drawings.entities
            points = collect(entity.points)
            entity.kind.value == "entity.rectangle" && push!(points, first(points))
            for index in 1:(length(points) - 1)
                push!(expected, (points[index], points[index + 1]))
            end
        end
        @test Set((entity.points[1], entity.points[2]) for entity in after.drawings.entities) == expected
        undo = edit("edit.undo", String[], Vector{Float64}[])
        @test undo["drawing_scene"] == original_scene
        redo = edit("edit.redo", String[], Vector{Float64}[])
        @test redo["drawing_scene"] == exploded["drawing_scene"]
        @test !redo["modified"]
        line_ids = [entity.identity.id.value for entity in after.drawings.entities]
        @test "modify.join_lines" in opened["edit_operations"]
        @test_throws ServiceError edit("modify.join_lines", line_ids, Vector{Float64}[])
        rectangle_lines = [entity.identity.id.value for entity in after.drawings.entities
            if all(point -> exact_rational(point.y) <= exact_rational(parse_exact_decimal("3")), entity.points)]
        @test length(rectangle_lines) == 4
        joined = edit("modify.join_lines", reverse(rectangle_lines), Vector{Float64}[])
        @test length(joined["drawing_scene"]["items"]) == 3
        save()
        joined_project = open_project(path).value.project
        joined_path = only(entity for entity in joined_project.drawings.entities if entity.kind.value == "entity.polyline")
        @test length(joined_path.points) == 5
        @test first(joined_path.points) == last(joined_path.points)
        @test project_physics_hash(joined_project) == project_physics_hash(before)
        unjoined = edit("edit.undo", String[], Vector{Float64}[])
        @test unjoined["drawing_scene"] == exploded["drawing_scene"]
        @test_throws ServiceError edit("modify.explode_paths", line_ids, Vector{Float64}[])
        @test_throws SemanticValidationError plan_drafting_path_explosion(before,
            ProjectId("action.duplicate.paths"), [ProjectId(rectangle_id), ProjectId(rectangle_id)])
    end
end
end
