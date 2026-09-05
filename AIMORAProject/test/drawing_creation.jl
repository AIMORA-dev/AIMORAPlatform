# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DrawingCreationTests
using AIMORAProject
using Dates
using UUIDs
using Test

@testset "new drawings are empty editable canonical projects with stable ownership" begin
    licence = LicenceIdentity("CC0-1.0", "Public domain dedication")
    source = ProvenanceSource(ProjectId("source.empty.drawing"), "Original empty drawing fixture", licence)
    namespace = NamespaceId("org.aimora.drawing")
    registry = SemanticSchemaRegistry([NamespaceRegistration(namespace,
        UUID("7d2043cf-76eb-4f9a-91a4-92aad8c35414"), licence, source)])
    metadata = ProjectMetadata(ObjectIdentity(ProjectId("project.empty.drawing")), "New Drawing",
        namespace, v"1.0.0", DateTime(2026, 1, 1), source)
    project = new_drawing_project(metadata, registry)
    @test project.verification == ProjectVerified
    @test isempty(project.records)
    @test isempty(project.drawings.entities)
    @test isempty(project.drawings.routes)
    @test isempty(project.drawings.labels)
    @test length(project.drawings.documents) == length(project.drawings.views) == length(project.drawings.layers) == 1
    view = only(project.drawings.views)
    layer = only(project.drawings.layers)
    @test view.space == DrawingModelSpace
    @test view.document == layer.document == only(project.drawings.documents).identity.id
    @test layer.visible && layer.printable
    @test project_resolved_hash(new_drawing_project(metadata, registry)) == project_resolved_hash(project)
    first = DrawingCoordinate(parse_exact_decimal("0"), parse_exact_decimal("0"))
    opposite = DrawingCoordinate(parse_exact_decimal("10"), parse_exact_decimal("5"))
    plan = plan_drafting_rectangle(project, ProjectId("action.first.rectangle"),
        ObjectIdentity(ProjectId("drawing.first.rectangle")), view.identity.id, layer.identity.id,
        first, opposite, source)
    @test length(plan.changed_owners) == 1
    @test isempty(project.drawings.entities)
    mktempdir() do root
        path = joinpath(root, "empty.aimora.yaml")
        save_project(path, project)
        loaded = open_project(path)
        @test !isnothing(loaded.value)
        reopened = loaded.value.project
        @test project_physics_hash(reopened) == project_physics_hash(project)
        @test reopened.drawings == project.drawings
        @test reopened.metadata.name == "New Drawing"
    end
end
end
