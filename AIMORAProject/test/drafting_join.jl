# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingJoinTests
using AIMORAProject
using Dates
using UUIDs
using Test

function line_fixture(segments)
    licence = LicenceIdentity("CC0-1.0", "Public domain dedication")
    source = ProvenanceSource(ProjectId("source.line.join"), "Original exact line joining fixture", licence)
    namespace = NamespaceId("org.aimora.join")
    registry = SemanticSchemaRegistry([NamespaceRegistration(namespace,
        UUID("7d2043cf-76eb-4f9a-91a4-92aad8c35414"), licence, source)])
    metadata = ProjectMetadata(ObjectIdentity(ProjectId("project.join")), "Line Joining",
        namespace, v"1.0.0", DateTime(2026, 1, 1), source)
    base = new_drawing_project(metadata, registry)
    view = only(base.drawings.views).identity.id
    layer = only(base.drawings.layers).identity.id
    coordinate(pair) = DrawingCoordinate(parse_exact_decimal(pair[1]), parse_exact_decimal(pair[2]))
    records = [DrawingEntity(ObjectIdentity(ProjectId("drawing.line.s" * string(index))), view, layer,
        ProjectId("entity.line"), coordinate.(segment), source) for (index, segment) in enumerate(segments)]
    plan = plan_drafting_edit(base, ProjectId("action.seed.lines"); additions = records)
    return replay_commands(base, plan.commands), [record.identity.id for record in records]
end

@testset "line joining is exact, deterministic, shape preserving and reversible" begin
    origin = ("0", "0")
    corner = ("1.0000000000000000000000000000000001", "0")
    finish = ("1.0000000000000000000000000000000001", "2")
    project, ids = line_fixture([[origin, corner], [finish, corner]])
    original_hash = project_resolved_hash(project)
    action = ProjectId("action.join.lines")
    plan = plan_drafting_line_join(project, action, ids)
    joined = replay_commands(project, plan.commands)
    path = only(joined.drawings.entities)
    @test path.kind == ProjectId("entity.polyline")
    @test length(path.points) == 3
    @test path.points[2].x == parse_exact_decimal(corner[1])
    @test path.points[3].y == parse_exact_decimal("2")
    @test path.layer == first(project.drawings.entities).layer
    @test path.style == first(project.drawings.entities).style
    @test project_physics_hash(joined) == project_physics_hash(project)
    @test replay_commands(project, plan_drafting_line_join(project, action, reverse(ids)).commands).drawings == joined.drawings
    @test replay_commands(joined, inverse_commands(project, plan.commands)).drawings == project.drawings
    exploded = replay_commands(joined, plan_drafting_path_explosion(joined,
        ProjectId("action.explode.joined"), [path.identity.id]).commands)
    @test length(exploded.drawings.entities) == 2
    @test Set((entity.points[1], entity.points[2]) for entity in exploded.drawings.entities) ==
        Set(((path.points[1], path.points[2]), (path.points[2], path.points[3])))
    @test project_resolved_hash(project) == original_hash
end

@testset "invalid line joining never infers gaps, branches or disconnected topology" begin
    origin = ("0", "0")
    right = ("1", "0")
    upper = ("0", "1")
    diagonal = ("1", "1")
    distant = ("3", "0")
    near_right = ("1.0000000000000000000000000000000001", "0")
    invalid_batches = (
        [[origin, right], [near_right, diagonal]],
        [[origin, right], [right, diagonal], [right, distant]],
        [[origin, right], [right, origin]],
        [[origin, right], [upper, diagonal]],
        [[origin, right], [right, upper], [upper, origin],
         [("3", "0"), ("4", "0")], [("4", "0"), ("3", "1")], [("3", "1"), ("3", "0")]],
        [[origin, right], [right, upper], [upper, origin], [("3", "0"), ("4", "0")]])
    for segments in invalid_batches
        project, ids = line_fixture(segments)
        original_hash = project_resolved_hash(project)
        @test_throws SemanticValidationError plan_drafting_line_join(project, ProjectId("action.invalid.join"), ids)
        @test project_resolved_hash(project) == original_hash
    end
    project, ids = line_fixture([[origin, right], [right, diagonal]])
    @test_throws SemanticValidationError plan_drafting_line_join(project, ProjectId("action.single.join"), ids[1:1])
    @test_throws SemanticValidationError plan_drafting_line_join(project, ProjectId("action.duplicate.join"), [ids[1], ids[1]])
end
end
