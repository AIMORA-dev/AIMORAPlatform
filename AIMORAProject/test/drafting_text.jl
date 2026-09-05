# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingTextTests
using AIMORAProject
using Dates
using UUIDs
using Test

@testset "public text editing preserves drawing ownership and rejects invalid batches" begin
    licence = LicenceIdentity("CC0-1.0", "Public domain dedication")
    source = ProvenanceSource(ProjectId("source.text.editing"), "Original text editing fixture", licence)
    namespace = NamespaceId("org.aimora.text")
    registry = SemanticSchemaRegistry([NamespaceRegistration(namespace,
        UUID("7d2043cf-76eb-4f9a-91a4-92aad8c35414"), licence, source)])
    metadata = ProjectMetadata(ObjectIdentity(ProjectId("project.text")), "Text Editing",
        namespace, v"1.0.0", DateTime(2026, 1, 1), source)
    empty_project = new_drawing_project(metadata, registry)
    view = only(empty_project.drawings.views).identity.id
    layer = only(empty_project.drawings.layers).identity.id
    anchor = DrawingCoordinate(parse_exact_decimal("0.1000000000000000000000000000000001"),
        parse_exact_decimal("-2.5"))
    first_id = ProjectId("drawing.text.first")
    second_id = ProjectId("drawing.text.second")
    line_id = ProjectId("drawing.text.line")
    labels = [DrawingLabel(ObjectIdentity(first_id), view, layer, anchor, "Feeder A", source),
        DrawingLabel(ObjectIdentity(second_id), view, layer, anchor, "Feeder B", source)]
    line = DrawingEntity(ObjectIdentity(line_id), view, layer, ProjectId("entity.line"),
        [anchor, DrawingCoordinate(parse_exact_decimal("1"), parse_exact_decimal("1"))], source)
    seeded = plan_drafting_edit(empty_project, ProjectId("action.seed.text");
        additions = CanonicalDrawingRecord[labels..., line])
    project = replay_commands(empty_project, seeded.commands)
    original_hash = project_resolved_hash(project)
    selection = [first_id, second_id]
    replacement = "Feeder \u03a9"
    plan = plan_drafting_text_replacement(project, ProjectId("action.replace.text"), selection, replacement)
    updated = replay_commands(project, plan.commands)
    @test length(plan.commands) == 2
    @test project_physics_hash(updated) == project_physics_hash(project)
    for label in labels
        changed = drawing_record(updated.drawings, label.identity.id)
        @test changed.text == replacement
        @test changed.anchor == anchor
        @test changed.identity == label.identity
        @test changed.layer == label.layer && changed.view == label.view
        @test changed.style == label.style && changed.provenance == label.provenance
    end
    @test replay_commands(updated, inverse_commands(project, plan.commands)).drawings == project.drawings
    @test drawing_record(updated.drawings, line_id) == line
    partial = plan_drafting_text_replacement(project, ProjectId("action.same.text"), selection, "Feeder A")
    @test length(partial.commands) == 1
    @test only(partial.changed_owners) == second_id
    for invalid_selection in (ProjectId[], [first_id, first_id], [first_id, line_id])
        @test_throws SemanticValidationError plan_drafting_text_replacement(project,
            ProjectId("action.invalid.text.selection"), invalid_selection, replacement)
    end
    for invalid in ("", "  ", "one\ntwo", "one\rtwo", "bad\0text", repeat("a", 65537))
        @test_throws SemanticValidationError plan_drafting_text_replacement(project,
            ProjectId("action.invalid.text.value"), selection, invalid)
    end
    @test_throws SemanticValidationError plan_drafting_text_replacement(updated,
        ProjectId("action.unchanged.text"), selection, replacement)
    bound = DrawingLabel(ObjectIdentity(ProjectId("drawing.text.bound")), view, layer, anchor,
        "Engineering name", source; bound_owner = ProjectId("equipment.feeder"), bound_field = "name")
    @test_throws SemanticValidationError AIMORAProject._require_drafting_record(bound)
    @test project_resolved_hash(project) == original_hash
end
end
