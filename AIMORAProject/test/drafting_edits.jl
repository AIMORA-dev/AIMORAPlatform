@testset "canonical drafting batch and exact translation" begin
    fixture = drawing_project_fixture()
    project = fixture.project
    coordinate = fixture.coordinate
    line = DrawingEntity(
        ObjectIdentity(ProjectId("drawing.entity.draft_line")),
        fixture.model_view.identity.id, fixture.layer.identity.id, ProjectId("entity.line"),
        [coordinate("0.1", "0.2"), coordinate("1.1", "1.2")], fixture.provenance,
    )
    label = DrawingLabel(
        ObjectIdentity(ProjectId("drawing.label.draft_note")),
        fixture.model_view.identity.id, fixture.layer.identity.id,
        coordinate("0.1", "0.2"), "Drafting note", fixture.provenance,
    )
    action = ProjectId("action.add_drafting")
    plan = plan_drafting_edit(project, action;
        additions = Union{DrawingEntity,DrawingLabel}[line, label])
    reversed = plan_drafting_edit(project, action;
        additions = Union{DrawingEntity,DrawingLabel}[label, line])
    created = replay_commands(project, collect(plan.commands))
    @test created == replay_commands(project, collect(reversed.commands))
    @test drawing_record(created.drawings, line.identity.id) == line
    @test project_physics_hash(created) == project_physics_hash(project)
    selection = [line.identity.id, label.identity.id]
    move = plan_drafting_translation(created, ProjectId("action.move_drafting"),
        selection, coordinate("0.2", "-0.1"))
    moved = replay_commands(created, collect(move.commands))
    @test drawing_record(moved.drawings, line.identity.id).points[1] == coordinate("0.3", "0.1")
    @test drawing_record(moved.drawings, label.identity.id).anchor == coordinate("0.3", "0.1")
    @test project_physics_hash(moved) == project_physics_hash(project)
    restore = plan_drafting_translation(moved, ProjectId("action.restore_drafting"),
        selection, coordinate("-0.2", "0.1"))
    @test replay_commands(moved, collect(restore.commands)) == created
    scale = plan_drafting_scale(created, ProjectId("action.scale_drafting"),
        [line.identity.id], coordinate("0.1", "0.2"), parse_exact_decimal("2.5"))
    scaled = replay_commands(created, collect(scale.commands))
    scaled_line = drawing_record(scaled.drawings, line.identity.id)
    @test scaled_line.points[1] == coordinate("0.1", "0.2")
    @test scaled_line.points[2] == coordinate("2.6", "2.7")
    @test scaled_line.identity == line.identity
    @test project_physics_hash(scaled) == project_physics_hash(created)
    inverse_scale = plan_drafting_scale(scaled, ProjectId("action.restore_scale"),
        [line.identity.id], coordinate("0.1", "0.2"), parse_exact_decimal("0.4"))
    @test replay_commands(scaled, collect(inverse_scale.commands)) == created
    @test semantic_error_code(() -> plan_drafting_scale(created, action, selection,
        coordinate("0", "0"), parse_exact_decimal("2"))) == :unsupported_drafting_scale
    @test semantic_error_code(() -> plan_drafting_scale(created, action, [line.identity.id],
        coordinate("0", "0"), parse_exact_decimal("0"))) == :invalid_drafting_scale
    @test semantic_error_code(() -> plan_drafting_scale(project, action, [fixture.route.identity.id],
        coordinate("0", "0"), parse_exact_decimal("2"))) == :non_drafting_selection
    removal = plan_drafting_edit(moved, ProjectId("action.erase_drafting"); removals = selection)
    @test replay_commands(moved, collect(removal.commands)) == project
    @test semantic_error_code(() -> plan_drafting_edit(project, action;
        additions = [line, line])) == :duplicate_drafting_target
    @test semantic_error_code(() -> plan_drafting_translation(project, action,
        [fixture.route.identity.id], coordinate("1", "0"))) == :non_drafting_selection
    @test semantic_error_code(() -> plan_drafting_edit(project, action;
        removals = [fixture.label.identity.id])) == :non_drafting_selection
    unbound = DrawingLabel(fixture.label.identity, fixture.label.view, fixture.label.layer,
        fixture.label.anchor, "Detached", fixture.provenance)
    @test semantic_error_code(() -> plan_drafting_edit(project, action;
        replacements = [unbound])) == :non_drafting_selection
    revision = initial_revision(project, ContentDigest(repeat("1", 64)),
        project_resolved_hash(project), RevisionProvenance(ProjectId("action.drafting_base"),
        DateTime(2026, 9, 5), fixture.provenance))
    transaction = begin_project_transaction(revision)
    @test apply_drafting_edit!(transaction, plan) === transaction
    @test transaction.working == created
    @test semantic_error_code(() -> apply_drafting_edit!(transaction, plan)) ==
        :drafting_edit_base_mismatch
end
include("drafting_curves.jl")
include("drafting_ellipses.jl")
include("drafting_reflections.jl")
include("drafting_rotations.jl")
include("drafting_alignment.jl")
include("drafting_text.jl")
include("drawing_value_hashes.jl")
include("drafting_join.jl")
include("drawing_creation.jl")
