# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingCurveTests

using AIMORAProject
using Dates
using Test

@testset "three-point drafting arcs preserve exact editable geometry" begin
    base = include(joinpath(pkgdir(AIMORAProject), "examples", "transactional_project.jl"))
    source = base.provenance.source
    document_id = ProjectId("drawing.document.curves")
    view_id = ProjectId("drawing.view.curves")
    layer_id = ProjectId("drawing.layer.curves")
    document = DrawingDocument(ObjectIdentity(document_id), "Curve drawing", [view_id], ProjectId[], source)
    view = DrawingView(ObjectIdentity(view_id), document_id, "Model", DrawingModelSpace, source)
    layer = DrawingLayer(ObjectIdentity(layer_id), document_id, "Drafting", source)
    project = replay_commands(base.project, ProjectCommand[
        ProjectCommand(ProjectId("command.curve.record$index"), AddDrawingRecordPatch(record))
        for (index, record) in enumerate((document, view, layer))
    ])
    point(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    start = point("0", "0")
    through = point("1", "1")
    finish = point("2", "0")
    identity = ObjectIdentity(ProjectId("drawing.arc"))
    action = ProjectId("action.draw.arc")
    plan = plan_drafting_arc(project, action, identity, view_id, layer_id, start, through, finish, source)
    provenance = RevisionProvenance(action, DateTime(2026, 9, 5), source)
    revision = initial_revision(project, base.source_hash, project_resolved_hash(project), provenance)
    transaction = begin_project_transaction(revision)
    apply_drafting_edit!(transaction, plan)
    committed = commit!(transaction, revision, revision.source_hash,
        project_resolved_hash(transaction.working), provenance)
    arc = drawing_record(committed.project.drawings, identity.id)
    @test arc.kind == ProjectId("entity.arc")
    @test collect(arc.points) == [start, through, finish]
    @test arc.layer == layer_id
    @test arc.container == view_id
    @test project_physics_hash(committed.project) == project_physics_hash(project)
    @test isempty(project.drawings.entities)
    mktempdir() do root
        path = joinpath(root, "arc.aimora.yaml")
        @test !isnothing(save_project(path, committed.project).value)
        reopened = open_project(path)
        @test !isnothing(reopened.value)
        @test drawing_record(reopened.value.project.drawings, identity.id) == arc
    end
    for middle in (start, finish, point("1", "0"))
        @test_throws SemanticValidationError plan_drafting_arc(project, action, identity,
            view_id, layer_id, start, middle, finish, source)
    end
    precise_finish = point("2", "2.0000000000000000000000000000000001")
    precise = plan_drafting_arc(project, action, identity, view_id, layer_id,
        start, through, precise_finish, source)
    @test precise.changed_owners == plan.changed_owners
    reversed = plan_drafting_arc(project, action, identity, view_id, layer_id,
        finish, through, start, source)
    @test reversed.changed_owners == plan.changed_owners
    samples = drawing_arc_display_points(start, through, finish)
    @test first(samples) == [0.0, 0.0]
    @test last(samples) == [2.0, 0.0]
    @test [1.0, 1.0] in samples
    @test length(samples) <= 131
    @test all(sample -> all(isfinite, sample), samples)
    @test all(sample -> abs(hypot(sample[1] - 1, sample[2]) - 1) < 1e-12, samples)
    @test all(sample -> sample[2] >= -1e-12, samples)
    reverse_samples = drawing_arc_display_points(finish, through, start)
    @test first(reverse_samples) == last(samples)
    @test last(reverse_samples) == first(samples)
    @test all(sample -> sample[2] >= -1e-12, reverse_samples)
    @test_throws SemanticValidationError drawing_arc_display_points(start, start, finish)
    @test_throws SemanticValidationError drawing_arc_display_points(start, through, finish; segments_per_circle = 0)
end

end # module DraftingCurveTests
