# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
using AIMORAProject
include("drafting_history.jl")
include("new_project_paths.jl")
include("project_creation.jl")
using Dates
using Test

@testset "service drafting commands commit canonical Julia revisions" begin
    base = include(joinpath(pkgdir(AIMORAProject), "examples", "transactional_project.jl"))
    source = base.provenance.source
    document_id = ProjectId("drawing.document.service")
    view_id = ProjectId("drawing.view.service")
    layer_id = ProjectId("drawing.layer.service")
    document = DrawingDocument(ObjectIdentity(document_id), "Service drawing", [view_id], ProjectId[], source)
    view = DrawingView(ObjectIdentity(view_id), document_id, "Model", DrawingModelSpace, source)
    layer = DrawingLayer(ObjectIdentity(layer_id), document_id, "Drafting", source)
    project = replay_commands(base.project, ProjectCommand[
        ProjectCommand(ProjectId("command.drawing.record$index"), AddDrawingRecordPatch(record))
        for (index, record) in enumerate((document, view, layer))
    ])
    revision = initial_revision(project, base.source_hash, project_resolved_hash(project),
        RevisionProvenance(ProjectId("action.drawing.start"), DateTime(2026, 9, 5), source))
    mktempdir() do root
        path = joinpath(root, "drawing.json")
        write(path, "{}")
        state = AIMORAService.ServiceState(ServiceConfiguration(
            endpoint = joinpath(root, "service.sock"), session_token = repeat("c", 64),
            allowed_roots = [root],
        ))
        opened = AIMORAService.dispatch_request!(state, "open", "project.open", Dict("path" => path))
        project_id = opened.result["project_id"]
        session = register_drafting_session!(state, project_id, revision, view_id, layer_id)
        initial = drafting_revision(session)
        request = Dict{String,Any}(
            "project_id" => project_id, "base_revision" => initial,
            "transaction_id" => "draw-1", "operation" => "draw.line",
            "semantic_ids" => String[], "points" => [[0.1, 0.2], [1.1, 1.2]],
            "attributes" => Dict{String,Any}("exact_points" => [["0.1", "0.2"], ["1.1", "1.2"]]),
        )
        created = AIMORAService.dispatch_request!(state, "draw", "semantic.commit", request)
        @test created.result["status"] == "accepted"
        @test drafting_revision(session) != initial
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        @test created.result["invalidations"] == ["views"]
        @test length(created.result["drawing_scene"]["items"]) == 1
        @test only(created.result["drawing_scene"]["items"])["points"][1] == [0.1, 0.2]
        ids = created.result["changed_owner_ids"]
        @test length(ids) == 1
        entity = drawing_record(session.revision.project.drawings, ProjectId(only(ids)))
        @test entity.kind == ProjectId("entity.line")
        @test entity.points[1].x == parse_exact_decimal("0.1")
        unchanged = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "stale", "semantic.commit", request)
        @test session.revision === unchanged
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "move-1"
        request["operation"] = "modify.move"
        request["semantic_ids"] = ids
        request["points"] = [[0.0, 0.0], [0.2, -0.1]]
        request["attributes"] = Dict("exact_points" => [["0", "0"], ["0.2", "-0.1"]])
        moved = AIMORAService.dispatch_request!(state, "move", "semantic.commit", request)
        @test moved.result["status"] == "accepted"
        entity = drawing_record(session.revision.project.drawings, ProjectId(only(ids)))
        @test entity.points[1] == DrawingCoordinate(parse_exact_decimal("0.3"), parse_exact_decimal("0.1"))
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "copy-1"
        request["operation"] = "modify.copy"
        request["points"] = [[0.0, 0.0], [1.0, 1.0]]
        request["attributes"] = Dict("exact_points" => [["0", "0"], ["1", "1"]])
        copied = AIMORAService.dispatch_request!(state, "copy", "semantic.commit", request)
        copy_ids = copied.result["changed_owner_ids"]
        @test length(copy_ids) == 1
        @test only(copy_ids) != only(ids)
        @test drawing_record(session.revision.project.drawings, ProjectId(only(ids))) == entity
        duplicate = drawing_record(session.revision.project.drawings, ProjectId(only(copy_ids)))
        @test duplicate.points[1] == DrawingCoordinate(parse_exact_decimal("1.3"), parse_exact_decimal("1.1"))
        @test length(copied.result["drawing_scene"]["items"]) == 2
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        request["base_revision"] = drafting_revision(session)
        before_duplicate = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "duplicate-copy", "semantic.commit", request)
        @test session.revision === before_duplicate
        request["semantic_ids"] = vcat(ids, copy_ids)
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "erase-1"
        request["operation"] = "modify.erase"
        request["points"] = []
        request["attributes"] = Dict()
        erased = AIMORAService.dispatch_request!(state, "erase", "semantic.commit", request)
        @test erased.result["status"] == "accepted"
        @test isempty(erased.result["drawing_scene"]["items"])
        @test session.revision.project == project
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "rectangle-1"
        request["operation"] = "draw.rectangle"
        request["semantic_ids"] = String[]
        request["points"] = [[4.0, 3.0], [1.0, 1.0]]
        rectangle_reply = AIMORAService.dispatch_request!(state, "rectangle", "semantic.commit", request)
        polygon = only(rectangle_reply.result["drawing_scene"]["items"])
        @test polygon["kind"] == "polygon"
        @test polygon["points"] == [[1.0, 1.0], [4.0, 1.0], [4.0, 3.0], [1.0, 3.0]]
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        rectangle_id = ProjectId(only(rectangle_reply.result["changed_owner_ids"]))
        @test drawing_record(session.revision.project.drawings, rectangle_id).kind == ProjectId("entity.rectangle")
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "rectangle-degenerate"
        request["points"] = [[1.0, 1.0], [1.0, 3.0]]
        before_rejection = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "degenerate", "semantic.commit", request)
        @test session.revision === before_rejection
        @test_throws ServiceError register_drafting_session!(state, project_id, revision, view_id, layer_id)
        canonical_path = joinpath(root, "canonical.aimora.yaml")
        @test !isnothing(save_project(canonical_path, project).value)
        canonical_open = AIMORAService.dispatch_request!(state, "canonical-open", "project.open",
            Dict("path" => canonical_path, "mode" => "drafting"))
        @test canonical_open.result["drawing_view_id"] == view_id.value
        @test canonical_open.result["drawing_layer_id"] == layer_id.value
        @test "draw.line" in canonical_open.result["edit_operations"]
        request["project_id"] = canonical_open.result["project_id"]
        request["base_revision"] = canonical_open.result["revision"]
        request["transaction_id"] = "open-and-draw"
        request["operation"] = "draw.line"
        request["semantic_ids"] = String[]
        request["points"] = [[0.0, 0.0], [10.0, 0.0]]
        committed = AIMORAService.dispatch_request!(state, "canonical-draw", "semantic.commit", request)
        described = AIMORAService.dispatch_request!(state, "canonical-describe", "project.describe",
            Dict("project_id" => request["project_id"]))
        @test described.result["revision"] == committed.result["revision"]
        reopened = AIMORAService.dispatch_request!(state, "canonical-reopen", "project.open",
            Dict("path" => canonical_path, "mode" => "drafting"))
        @test reopened.result["revision"] == committed.result["revision"]
        @test reopened.result["modified"]
        @test reopened.result["can_save"]
        save_parameters = Dict("project_id" => request["project_id"], "base_revision" => canonical_open.result["revision"])
        before_stale_save = read(canonical_path)
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "stale-save", "project.save", save_parameters)
        @test read(canonical_path) == before_stale_save
        save_parameters["base_revision"] = committed.result["revision"]
        saved_reply = AIMORAService.dispatch_request!(state, "save", "project.save", save_parameters)
        @test saved_reply.result["saved"]
        @test !saved_reply.result["modified"]
        @test saved_reply.result["revision"] == committed.result["revision"]
        saved_project = open_project(canonical_path)
        @test !isnothing(saved_project.value)
        @test length(saved_project.value.project.drawings.entities) == 1
        second_save = AIMORAService.dispatch_request!(state, "save-again", "project.save", save_parameters)
        @test second_save.result["saved"]
        externally_changed = vcat(read(canonical_path), UInt8[0x0a])
        write(canonical_path, externally_changed)
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "external-change", "project.save", save_parameters)
        @test read(canonical_path) == externally_changed
        request["project_id"] = project_id
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "text-1"
        request["operation"] = "draw.text"
        request["points"] = [[3.0, 4.0]]
        request["attributes"] = Dict("text" => "Feeder A \u03a9")
        text_reply = AIMORAService.dispatch_request!(state, "text", "semantic.commit", request)
        label_id = ProjectId(only(text_reply.result["changed_owner_ids"]))
        label = drawing_record(session.revision.project.drawings, label_id)
        @test label isa DrawingLabel
        @test label.text == "Feeder A \u03a9"
        @test isnothing(label.bound_owner)
        @test label.anchor == DrawingCoordinate(parse_exact_decimal("3"), parse_exact_decimal("4"))
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        displayed = only(filter(item -> item["kind"] == "text", text_reply.result["drawing_scene"]["items"]))
        @test displayed["text"] == label.text
        text_path = joinpath(root, "annotated.aimora.yaml")
        @test !isnothing(save_project(text_path, session.revision.project).value)
        restored = open_project(text_path)
        @test !isnothing(restored.value)
        @test drawing_record(restored.value.project.drawings, label_id) == label
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "text-invalid"
        request["attributes"] = Dict("text" => "first\nsecond")
        before_invalid_text = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "invalid-text", "semantic.commit", request)
        @test session.revision === before_invalid_text
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "closed-polyline"
        request["operation"] = "draw.polyline"
        request["points"] = [[0.1, 0.2], [10.1, 0.2], [10.1, 15.2], [0.1, 0.2]]
        request["attributes"] = Dict("exact_points" =>
            [["0.1", "0.2"], ["10.1", "0.2"], ["10.1", "15.2"], ["0.1", "0.2"]])
        outline_reply = AIMORAService.dispatch_request!(state, "outline", "semantic.commit", request)
        @test outline_reply.result["status"] == "accepted"
        outline_id = ProjectId(only(outline_reply.result["changed_owner_ids"]))
        outline = drawing_record(session.revision.project.drawings, outline_id)
        @test outline.kind == ProjectId("entity.polyline")
        @test length(outline.points) == 4
        @test first(outline.points) == last(outline.points)
        @test outline.points[3] == DrawingCoordinate(parse_exact_decimal("10.1"), parse_exact_decimal("15.2"))
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        displayed_outline = only(filter(item -> item["owner_id"] == outline_id.value,
            outline_reply.result["drawing_scene"]["items"]))
        @test displayed_outline["kind"] == "polyline"
        @test displayed_outline["points"] == request["points"]
        outline_path = joinpath(root, "outlined.aimora.yaml")
        @test !isnothing(save_project(outline_path, session.revision.project).value)
        restored_outline = open_project(outline_path)
        @test !isnothing(restored_outline.value)
        @test drawing_record(restored_outline.value.project.drawings, outline_id) == outline
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "circle-outline"
        request["operation"] = "draw.circle"
        request["points"] = [[2.1, 3.2], [5.1, 7.2]]
        request["attributes"] = Dict("exact_points" => [["2.1", "3.2"], ["5.1", "7.2"]])
        circle_reply = AIMORAService.dispatch_request!(state, "circle", "semantic.commit", request)
        @test circle_reply.result["status"] == "accepted"
        circle_id = ProjectId(only(circle_reply.result["changed_owner_ids"]))
        circle = drawing_record(session.revision.project.drawings, circle_id)
        @test circle.kind == ProjectId("entity.circle")
        @test collect(circle.points) == [DrawingCoordinate(parse_exact_decimal("2.1"), parse_exact_decimal("3.2")),
            DrawingCoordinate(parse_exact_decimal("5.1"), parse_exact_decimal("7.2"))]
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        displayed_circle = only(filter(item -> item["owner_id"] == circle_id.value,
            circle_reply.result["drawing_scene"]["items"]))
        @test displayed_circle["kind"] == "circle"
        @test displayed_circle["points"] == request["points"]
        circle_path = joinpath(root, "circles.aimora.yaml")
        @test !isnothing(save_project(circle_path, session.revision.project).value)
        restored_circle = open_project(circle_path)
        @test !isnothing(restored_circle.value)
        @test drawing_record(restored_circle.value.project.drawings, circle_id) == circle
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "circle-degenerate"
        request["points"] = [[2.0, 3.0], [2.0, 3.0]]
        request["attributes"] = Dict()
        before_invalid_circle = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "invalid-circle", "semantic.commit", request)
        @test session.revision === before_invalid_circle
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "scale-circle"
        request["operation"] = "modify.scale"
        request["semantic_ids"] = [circle_id.value]
        request["points"] = [[2.1, 3.2]]
        request["attributes"] = Dict("factor" => "2.5", "exact_points" => [["2.1", "3.2"]])
        scaled_reply = AIMORAService.dispatch_request!(state, "scale", "semantic.commit", request)
        @test scaled_reply.result["status"] == "accepted"
        scaled_circle = drawing_record(session.revision.project.drawings, circle_id)
        @test scaled_circle.points[1] == circle.points[1]
        @test scaled_circle.points[2] == DrawingCoordinate(parse_exact_decimal("9.6"), parse_exact_decimal("13.2"))
        @test scaled_circle.identity == circle.identity
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "unscale-circle"
        request["attributes"]["factor"] = "0.4"
        inverse_reply = AIMORAService.dispatch_request!(state, "unscale", "semantic.commit", request)
        @test inverse_reply.result["status"] == "accepted"
        @test drawing_record(session.revision.project.drawings, circle_id) == circle
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "scale-invalid"
        request["attributes"]["factor"] = "0"
        before_invalid_scale = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "invalid-scale", "semantic.commit", request)
        @test session.revision === before_invalid_scale
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "precise-outline"
        request["operation"] = "draw.polyline"
        request["semantic_ids"] = String[]
        request["points"] = [[0.1, 0.2], [1.1, 0.2], [1.1, 3.2], [0.1, 0.2]]
        request["attributes"] = Dict("coordinate_inputs" => [
            Dict("text" => "0.1000000000000000000000000000000001,0.2"),
            Dict("text" => "@1,0"), Dict("text" => "@0,3"), Dict("reference" => 0),
        ])
        precise_reply = AIMORAService.dispatch_request!(state, "precise", "semantic.commit", request)
        @test precise_reply.result["status"] == "accepted"
        precise_id = ProjectId(only(precise_reply.result["changed_owner_ids"]))
        precise = drawing_record(session.revision.project.drawings, precise_id)
        @test precise.points[1].x == parse_exact_decimal("0.1000000000000000000000000000000001")
        @test precise.points[2].x == parse_exact_decimal("1.1000000000000000000000000000000001")
        @test precise.points[3].y == parse_exact_decimal("3.2")
        @test precise.points[4] == precise.points[1]
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        precise_path = joinpath(root, "precise.aimora.yaml")
        @test !isnothing(save_project(precise_path, session.revision.project).value)
        restored_precise = open_project(precise_path)
        @test !isnothing(restored_precise.value)
        @test drawing_record(restored_precise.value.project.drawings, precise_id) == precise
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "forward-coordinate-reference"
        request["attributes"]["coordinate_inputs"][1] = Dict("reference" => 2)
        before_bad_reference = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "forward-reference", "semantic.commit", request)
        @test session.revision === before_bad_reference
        request["transaction_id"] = "precise-circle-radius"
        request["operation"] = "draw.circle"
        request["points"] = [[0.1, 0.2], [1.1, 0.2]]
        request["attributes"] = Dict("coordinate_inputs" => [
            Dict("text" => "0.1000000000000000000000000000000001,0.2"),
            Dict("text" => "@1.0000000000000000000000000000000002,0"),
        ])
        precise_circle_reply = AIMORAService.dispatch_request!(state, "precise-radius", "semantic.commit", request)
        @test precise_circle_reply.result["status"] == "accepted"
        precise_circle_id = ProjectId(only(precise_circle_reply.result["changed_owner_ids"]))
        precise_circle = drawing_record(session.revision.project.drawings, precise_circle_id)
        @test precise_circle.points[2].x == parse_exact_decimal("1.1000000000000000000000000000000003")
        @test precise_circle.points[1].y == precise_circle.points[2].y
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "connected-line-sequence"
        request["operation"] = "draw.line"
        request["points"] = [[0.1, 0.2], [10.1, 0.2], [10.1, 5.2], [0.1, 0.2]]
        request["attributes"] = Dict("coordinate_inputs" => [
            Dict("text" => "0.1000000000000000000000000000000001,0.2"),
            Dict("text" => "@10,0"), Dict("text" => "@0,5"), Dict("reference" => 0),
        ])
        before_lines = session.revision
        line_reply = AIMORAService.dispatch_request!(state, "line-sequence", "semantic.commit", request)
        @test line_reply.result["status"] == "accepted"
        line_ids = line_reply.result["changed_owner_ids"]
        @test length(line_ids) == 3
        @test length(unique(line_ids)) == 3
        lines = sort([drawing_record(session.revision.project.drawings, ProjectId(id)) for id in line_ids];
            by = line -> line.identity.id.value)
        @test all(line -> line.kind == ProjectId("entity.line") && length(line.points) == 2, lines)
        @test lines[1].points[2] == lines[2].points[1]
        @test lines[2].points[2] == lines[3].points[1]
        @test lines[3].points[2] == lines[1].points[1]
        @test lines[1].points[1].x == parse_exact_decimal("0.1000000000000000000000000000000001")
        @test lines[1].points[2].x == parse_exact_decimal("10.1000000000000000000000000000000001")
        @test length(session.revision.project.drawings.entities) == length(before_lines.project.drawings.entities) + 3
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        line_path = joinpath(root, "connected-lines.aimora.yaml")
        @test !isnothing(save_project(line_path, session.revision.project).value)
        restored_lines = open_project(line_path)
        @test !isnothing(restored_lines.value)
        @test all(line -> drawing_record(restored_lines.value.project.drawings, line.identity.id) == line, lines)
        request["base_revision"] = drafting_revision(session)
        request["transaction_id"] = "line-sequence-degenerate-middle"
        request["points"] = [[0.0, 0.0], [1.0, 0.0], [1.0, 0.0], [2.0, 0.0]]
        request["attributes"] = Dict()
        before_bad_lines = session.revision
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "bad-line-sequence", "semantic.commit", request)
        @test session.revision === before_bad_lines
        request["transaction_id"] = "visually-coincident-exact-closure"
        request["operation"] = "draw.polyline"
        request["points"] = [[0.1, 0.0], [10.0, 10.0], [0.1, 0.0]]
        request["attributes"] = Dict(
            "close_path" => true,
            "exact_points" => [["0.1000000000000000000000000000000001", "0"],
                ["10", "10"], ["0.1000000000000000000000000000000002", "0"]],
        )
        closed_reply = AIMORAService.dispatch_request!(state, "exact-close", "semantic.commit", request)
        @test closed_reply.result["status"] == "accepted"
        closed = drawing_record(session.revision.project.drawings,
            ProjectId(only(closed_reply.result["changed_owner_ids"])))
        @test length(closed.points) == 4
        @test closed.points[1] == closed.points[4]
        @test closed.points[3] != closed.points[1]
        @test closed.points[3].x == parse_exact_decimal("0.1000000000000000000000000000000002")
        @test project_physics_hash(session.revision.project) == project_physics_hash(project)
        visible_layer_id = ProjectId("drawing.layer.default")
        hidden_layer_id = ProjectId("drawing.layer.aaa.hidden")
        layered_project = replay_commands(project, ProjectCommand[
            ProjectCommand(ProjectId("command.add.visible.layer"), AddDrawingRecordPatch(
                DrawingLayer(ObjectIdentity(visible_layer_id), document_id, "Visible drafting", source))),
            ProjectCommand(ProjectId("command.add.hidden.layer"), AddDrawingRecordPatch(
                DrawingLayer(ObjectIdentity(hidden_layer_id), document_id, "Hidden drafting", source; visible = false))),
        ])
        layered_path = joinpath(root, "multiple-layers.aimora.yaml")
        @test !isnothing(save_project(layered_path, layered_project).value)
        layered_bytes = read(layered_path)
        layered_open = AIMORAService.dispatch_request!(state, "open-multiple-layers", "project.open",
            Dict("path" => layered_path, "mode" => "drafting"))
        @test layered_open.result["drawing_layer_id"] == visible_layer_id.value
        @test layered_open.result["drawing_view_id"] == view_id.value
        @test !layered_open.result["modified"]
        @test read(layered_path) == layered_bytes
        layered_request = Dict{String,Any}(
            "project_id" => layered_open.result["project_id"],
            "base_revision" => layered_open.result["revision"],
            "transaction_id" => "line-on-default-visible-layer",
            "operation" => "draw.line", "semantic_ids" => String[],
            "points" => [[1.0, 2.0], [3.0, 4.0]], "attributes" => Dict(),
        )
        layered_line = AIMORAService.dispatch_request!(state, "layered-line", "semantic.commit", layered_request)
        @test layered_line.result["status"] == "accepted"
        @test length(layered_line.result["drawing_scene"]["items"]) == 1
        @test read(layered_path) == layered_bytes
        layered_saved = AIMORAService.dispatch_request!(state, "save-layered-line", "project.save",
            Dict("project_id" => layered_request["project_id"], "base_revision" => layered_line.result["revision"]))
        @test layered_saved.result["saved"]
        @test !layered_saved.result["modified"]
        restored_layered = open_project(layered_path)
        @test !isnothing(restored_layered.value)
        layer_line_id = ProjectId(only(layered_line.result["changed_owner_ids"]))
        restored_line = drawing_record(restored_layered.value.project.drawings, layer_line_id)
        @test restored_line.layer == visible_layer_id
        @test restored_line.kind == ProjectId("entity.line")
        @test collect(restored_layered.value.project.drawings.layers) == collect(layered_project.drawings.layers)
        @test !drawing_record(restored_layered.value.project.drawings, hidden_layer_id).visible
        @test project_physics_hash(restored_layered.value.project) == project_physics_hash(layered_project)
        for (axis, invalid_points) in (("horizontal", [[true, 2.0], [3.0, 4.0]]),
                                      ("vertical", [[1.0, false], [3.0, 4.0]]))
            invalid_coordinate_request = copy(layered_request)
            invalid_coordinate_request["base_revision"] = layered_line.result["revision"]
            invalid_coordinate_request["transaction_id"] = "reject-boolean-$axis-coordinate"
            # Keep the JSON scalar types rather than letting Julia promote Bool to Float64.
            invalid_coordinate_request["points"] = axis == "horizontal" ?
                [Any[true, 2.0], Any[3.0, 4.0]] : [Any[1.0, false], Any[3.0, 4.0]]
            before_invalid_coordinate = read(layered_path)
            @test_throws ServiceError AIMORAService.dispatch_request!(state,
                "invalid-coordinate-$axis", "semantic.commit", invalid_coordinate_request)
            unchanged_description = AIMORAService.dispatch_request!(state,
                "describe-after-invalid-$axis", "project.describe",
                Dict("project_id" => layered_request["project_id"]))
            @test unchanged_description.result["revision"] == layered_line.result["revision"]
            @test !unchanged_description.result["modified"]
            @test read(layered_path) == before_invalid_coordinate
        end
        arc_request = copy(layered_request)
        arc_request["base_revision"] = layered_line.result["revision"]
        arc_request["transaction_id"] = "three-point-arc"
        arc_request["operation"] = "draw.arc"
        arc_request["points"] = [[0.0, 0.0], [1.0, 1.0], [2.0, 0.0]]
        arc_reply = AIMORAService.dispatch_request!(state, "draw-arc", "semantic.commit", arc_request)
        arc_owner_before_undo = only(arc_reply.result["changed_owner_ids"])
        arc_scene_before_undo = arc_reply.result["drawing_scene"]
        undo_request = copy(arc_request)
        undo_request["base_revision"] = arc_reply.result["revision"]
        undo_request["transaction_id"] = "undo-three-point-arc"
        undo_request["operation"] = "edit.undo"
        undo_request["points"] = Any[]
        undo_request["attributes"] = Dict{String,Any}()
        undone = AIMORAService.dispatch_request!(state, "undo-arc", "semantic.commit", undo_request)
        @test undone.result["status"] == "accepted"
        @test undone.result["can_redo"]
        @test !undone.result["modified"]
        @test all(item -> item["owner_id"] != arc_owner_before_undo, undone.result["drawing_scene"]["items"])
        @test_throws AIMORAService.ServiceError AIMORAService.dispatch_request!(state,
            "stale-undo-arc", "semantic.commit", undo_request)
        redo_request = copy(undo_request)
        redo_request["base_revision"] = undone.result["revision"]
        redo_request["transaction_id"] = "redo-three-point-arc"
        redo_request["operation"] = "edit.redo"
        arc_reply = AIMORAService.dispatch_request!(state, "redo-arc", "semantic.commit", redo_request)
        @test arc_reply.result["drawing_scene"] == arc_scene_before_undo
        @test arc_reply.result["can_undo"]
        @test !arc_reply.result["can_redo"]
        @test arc_reply.result["modified"]
        @test arc_reply.result["status"] == "accepted"
        arc_id = only(arc_reply.result["changed_owner_ids"])
        displayed_arc = only(filter(item -> item["owner_id"] == arc_id, arc_reply.result["drawing_scene"]["items"]))
        @test displayed_arc["kind"] == "polyline"
        @test first(displayed_arc["points"]) == [0.0, 0.0]
        @test last(displayed_arc["points"]) == [2.0, 0.0]
        @test [1.0, 1.0] in displayed_arc["points"]
        arc_saved = AIMORAService.dispatch_request!(state, "save-arc", "project.save",
            Dict("project_id" => arc_request["project_id"], "base_revision" => arc_reply.result["revision"]))
        @test arc_saved.result["saved"]
        reopened_arc = open_project(layered_path)
        @test !isnothing(reopened_arc.value)
        exact_arc = drawing_record(reopened_arc.value.project.drawings, ProjectId(arc_id))
        @test exact_arc.kind == ProjectId("entity.arc")
        @test length(exact_arc.points) == 3
        @test project_physics_hash(reopened_arc.value.project) == project_physics_hash(layered_project)
        arc_request["base_revision"] = arc_reply.result["revision"]
        arc_request["transaction_id"] = "collinear-arc"
        arc_request["points"] = [[0.0, 0.0], [1.0, 0.0], [2.0, 0.0]]
        before_bad_arc = read(layered_path)
        @test_throws ServiceError AIMORAService.dispatch_request!(state, "invalid-arc", "semantic.commit", arc_request)
        @test read(layered_path) == before_bad_arc
    end
end
