using AIMORAProject
using AIMORAFormats: format_succeeded, parse_restricted_yaml, serialize_restricted_yaml
using Tables

revision = Base.include(@__MODULE__, joinpath(@__DIR__, "transactional_project.jl"))
snapshot = project_snapshot(revision)
schema = first(revision.project.registry.schemas).identity
table = record_table(snapshot, schema)

yaml = serialize_restricted_yaml(project_format_node(revision.project))
format_succeeded(yaml) || error("project YAML serialization failed")
parsed = parse_restricted_yaml(collect(yaml.value.bytes); source_name = "project-authoring.aimora.yaml")
format_succeeded(parsed) || error("project YAML parse failed")
decoded = project_from_format(parsed.value.root)
format_succeeded(decoded) || error("project semantic decode failed")
decoded.value == revision.project || error("Julia and YAML authoring views differ")

row = only(Tables.rows(table))
println(
    "equivalent Julia/YAML project ",
    revision.project.metadata.identity.id.value,
    " exposes table owner ",
    row.owner_id,
    " at resolved hash ",
    project_resolved_hash(decoded.value).sha256,
)
(; revision, decoded = decoded.value, table)
