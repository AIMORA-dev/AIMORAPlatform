# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingAlignmentTests
using AIMORAProject
using Dates
using UUIDs
using Test

@testset "anchor arrangements preserve exact shapes, identities, physics and undo" begin
    point(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    licence = LicenceIdentity("CC0-1.0", "Public domain dedication")
    source = ProvenanceSource(ProjectId("source.anchor.arrangement"), "Original anchor arrangement fixture", licence)
    namespace = NamespaceId("org.aimora.arrangement")
    registry = SemanticSchemaRegistry([NamespaceRegistration(namespace,
        UUID("7d2043cf-76eb-4f9a-91a4-92aad8c35414"), licence, source)])
    metadata = ProjectMetadata(ObjectIdentity(ProjectId("project.arrangement")), "Anchor Arrangement",
        namespace, v"1.0.0", DateTime(2026, 1, 1), source)
    empty_project = new_drawing_project(metadata, registry)
    view = only(empty_project.drawings.views).identity.id
    layer = only(empty_project.drawings.layers).identity.id
    ids = ProjectId.("drawing.anchor." .* ["left", "middle", "right"])
    anchors = [point("0.1", "1"), point("2.1", "3"), point("10.1", "9")]
    records = [DrawingEntity(ObjectIdentity(id), view, layer, ProjectId("entity.line"),
        [anchor, AIMORAProject._translated_drafting_point(anchor, point("1", "2"))], source)
        for (id, anchor) in zip(ids, anchors)]
    additions = plan_drafting_edit(empty_project, ProjectId("action.seed.arrangement"); additions = records)
    project = replay_commands(empty_project, additions.commands)
    original_hash = project_resolved_hash(project)
    for axis in (:x, :y)
        target = parse_exact_decimal("1.0000000000000000000000000000000001")
        aligned_plan = plan_drafting_anchor_alignment(project, ProjectId("action.align.anchors"), ids, axis, target)
        aligned = replay_commands(project, aligned_plan.commands)
        @test project_physics_hash(aligned) == project_physics_hash(project)
        for id in ids
            record = drawing_record(aligned.drawings, id)
            @test AIMORAProject._drafting_arrangement_coordinate(record, axis) == target
            @test record.points[2] == AIMORAProject._translated_drafting_point(record.points[1], point("1", "2"))
        end
        restored = replay_commands(aligned, inverse_commands(project, aligned_plan.commands))
        @test restored.drawings == project.drawings
        distribution = plan_drafting_anchor_distribution(project, ProjectId("action.distribute.anchors"), ids, axis)
        distributed = replay_commands(project, distribution.commands)
        @test length(distribution.commands) == 1
        @test_throws SemanticValidationError plan_drafting_anchor_distribution(distributed,
            ProjectId("action.already.distributed"), ids, axis)
        @test_throws SemanticValidationError plan_drafting_anchor_alignment(aligned,
            ProjectId("action.already.aligned"), ids, axis, target)
        expected_middle = axis == :x ? point("5.1", "3") : point("2.1", "5")
        @test first(drawing_record(distributed.drawings, ids[2]).points) == expected_middle
        @test drawing_record(distributed.drawings, ids[1]).points == records[1].points
        @test drawing_record(distributed.drawings, ids[3]).points == records[3].points
        reversed_plan = plan_drafting_anchor_distribution(project,
            ProjectId("action.distribute.reverse"), reverse(ids), axis)
        @test replay_commands(project, reversed_plan.commands).drawings == distributed.drawings
        @test project_physics_hash(distributed) == project_physics_hash(project)
    end
    @test project_resolved_hash(project) == original_hash
    @test AIMORAProject._drafting_distribution_step(parse_exact_decimal("1"), 8) == parse_exact_decimal("0.125")
    @test AIMORAProject._drafting_distribution_step(parse_exact_decimal("0"), 3) == parse_exact_decimal("0")
    @test_throws SemanticValidationError AIMORAProject._drafting_distribution_step(parse_exact_decimal("1"), 3)
    @test_throws SemanticValidationError plan_drafting_anchor_alignment(project,
        ProjectId("action.invalid.axis"), ids, :z, parse_exact_decimal("0"))
    @test_throws SemanticValidationError plan_drafting_anchor_distribution(project,
        ProjectId("action.duplicate.anchors"), [ids[1], ids[1], ids[2]], :x)
    @test_throws SemanticValidationError plan_drafting_anchor_distribution(project,
        ProjectId("action.insufficient.anchors"), ids[1:2], :x)
end
end
