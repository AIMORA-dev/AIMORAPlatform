# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export new_drawing_project

"""Create an empty verified model-space drawing with caller-owned metadata and schema registrations."""
function new_drawing_project(metadata::ProjectMetadata, registry::SemanticSchemaRegistry,
    units::UnitRegistry = UnitRegistry())
    document_id = ProjectId(metadata.identity.id.value * ".drawing")
    view_id = ProjectId(metadata.identity.id.value * ".model")
    layer_id = ProjectId(metadata.identity.id.value * ".layer.default")
    source = metadata.provenance
    document = DrawingDocument(ObjectIdentity(document_id), metadata.name, [view_id], ProjectId[], source)
    view = DrawingView(ObjectIdentity(view_id), document_id, "Model", DrawingModelSpace, source)
    layer = DrawingLayer(ObjectIdentity(layer_id), document_id, "Default", source)
    drawings = DrawingWorkspace(documents = [document], views = [view], layers = [layer])
    project = CanonicalProject(metadata, registry, units, CanonicalRecord[], SemanticGraphs(),
        AssetLibrary(), HierarchyModel(), ControlSystem(), EventScenarioModel(), OrchestrationModel(),
        ProjectUnverified, drawings)
    return verified_project(project)
end
