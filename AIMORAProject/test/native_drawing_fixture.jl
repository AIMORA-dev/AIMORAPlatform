using AIMORAProject
using AIMORAFormats: format_succeeded, parse_restricted_yaml

if length(ARGS) == 2 && ARGS[1] == "--verify-exact-line"
    parsed = parse_restricted_yaml(read(ARGS[2]); source_name = basename(ARGS[2]))
    format_succeeded(parsed) || error("saved drawing YAML did not parse")
    decoded = project_from_format(parsed.value.root)
    format_succeeded(decoded) || error("saved drawing did not decode canonically")
    coordinate(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    expected = [
        coordinate("10.1000000000000000000000000000000001", "50"),
        coordinate("10.3000000000000000000000000000000001", "70"),
    ]
    any(entity -> entity.kind == ProjectId("entity.line") && collect(entity.points) == expected,
        decoded.value.drawings.entities) || error("native typed coordinates lost exact decimal precision")
    println("Saved native command coordinates match exact canonical decimals")
    exit(0)
end

length(ARGS) == 1 || error("expected an isolated destination project path")
base = include(joinpath(@__DIR__, "..", "examples", "transactional_project.jl"))
project = base.project
provenance = project.metadata.provenance
document_id = ProjectId("drawing.document")
view_id = ProjectId("drawing.model")
layer_id = ProjectId("drawing.layer")
workspace = DrawingWorkspace(
    documents = [DrawingDocument(ObjectIdentity(document_id), "Native Drawing", [view_id], ProjectId[], provenance)],
    views = [DrawingView(ObjectIdentity(view_id), document_id, "Model", DrawingModelSpace, provenance)],
    layers = [DrawingLayer(ObjectIdentity(layer_id), document_id, "Drafting", provenance)],
)
drawing_project = CanonicalProject(
    project.metadata, project.registry, project.units, collect(project.records),
    project.graphs, project.asset_library, project.hierarchy, project.control_system,
    project.event_scenarios, project.orchestration, workspace,
)
result = save_project(ARGS[1], drawing_project)
isfile(ARGS[1]) || error("canonical drawing fixture was not saved: $(result)")
