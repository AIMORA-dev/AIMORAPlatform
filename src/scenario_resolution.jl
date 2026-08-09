function _scenario_lineage(model::EventScenarioModel, id::ProjectId)
    lineage = ScenarioDefinition[]
    cursor = scenario_definition(model, id)
    seen = Set{ProjectId}()
    while true
        cursor.identity.id in seen &&
            _semantic_fail(:scenario_parent_cycle, "scenario inheritance contains a cycle")
        push!(seen, cursor.identity.id)
        push!(lineage, cursor)
        isnothing(cursor.parent) && break
        cursor.parent.target isa LocalReferenceTarget ||
            _semantic_fail(:external_scenario_parent, "scenario parent must be project-local")
        cursor = scenario_definition(model, cursor.parent.target.id)
    end
    reverse!(lineage)
    return lineage
end

function _signature_atom(tag::AbstractString, value::AbstractString)
    text = String(value)
    return String(tag) * ":" * string(ncodeunits(text)) * ":" * text
end

function _scenario_value_signature(value)
    value === nothing && return "nothing"
    value isa Bool && return value ? "bool:true" : "bool:false"
    value isa Enum && return "enum:" * string(nameof(typeof(value))) * ":" * string(Integer(value))
    value isa Symbol && return _signature_atom("symbol", String(value))
    value isa AbstractString && return _signature_atom("string", String(value))
    value isa Integer && return "integer:" * string(value)
    value isa Rational && return "rational:" * string(numerator(value)) * "/" * string(denominator(value))
    value isa DateTime && return "datetime:" * Dates.format(value, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    value isa VersionNumber && return "version:" * string(value)
    value isa UUID && return "uuid:" * string(value)
    if value isa CanonicalList
        return "list:[" * join((_scenario_value_signature(item) for item in value), ",") * "]"
    elseif value isa Tuple
        return "tuple:(" * join((_scenario_value_signature(item) for item in value), ",") * ")"
    end
    type = typeof(value)
    isstructtype(type) ||
        _semantic_fail(:unsupported_scenario_hash_value, "scenario hash encountered unsupported mutable or executable data")
    parts = String[]
    for name in fieldnames(type)
        push!(parts, String(name) * "=" * _scenario_value_signature(getfield(value, name)))
    end
    return "struct:" * string(nameof(type)) * "{" * join(parts, ",") * "}"
end

function _scenario_base_signature(project::CanonicalProject)
    return join((
        _scenario_value_signature(project.metadata),
        _scenario_value_signature(project.registry),
        _scenario_value_signature(project.units),
        _scenario_value_signature(project.records),
        _scenario_value_signature(project.graphs),
        _scenario_value_signature(project.asset_library),
        _scenario_value_signature(project.hierarchy),
        _scenario_value_signature(project.control_system),
        _scenario_value_signature(project.event_scenarios.events),
    ), '\n')
end

"""Return the deterministic content identity of one resolved scenario lineage and patch payload."""
function scenario_content_hash(project::CanonicalProject, id::ProjectId)
    lineage = _scenario_lineage(project.event_scenarios, id)
    parts = String[
        "aimora-scenario-v1",
        bytes2hex(SHA.sha256(_scenario_base_signature(project))),
    ]
    for scenario in lineage
        push!(parts, _scenario_value_signature(scenario))
    end
    return ContentDigest(bytes2hex(SHA.sha256(join(parts, '\n'))))
end

"""One verified materialization with exact lineage, commands, changed owners, and invalidations."""
struct ResolvedScenario
    scenario::ProjectId
    lineage::CanonicalList{ProjectId}
    content_hash::ContentDigest
    project::CanonicalProject
    commands::CanonicalList{ProjectCommand}
    changed_owners::CanonicalList{ProjectId}
    invalidations::CanonicalList{DependencyInvalidation}
end

Base.:(==)(left::ResolvedScenario, right::ResolvedScenario) =
    left.scenario == right.scenario && left.lineage == right.lineage &&
    left.content_hash == right.content_hash && left.project == right.project &&
    left.commands == right.commands && left.changed_owners == right.changed_owners &&
    left.invalidations == right.invalidations

function _project_without_scenarios(project::CanonicalProject)
    model = EventScenarioModel(events = collect(project.event_scenarios.events))
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        model,
        project.orchestration,
        ProjectUnverified,
    )
end

function _verified_materialized_scenario_project(
    project::CanonicalProject,
    source_project::CanonicalProject,
)
    foreach(record -> _validate_record(project, record), project.records)
    validate_graphs(project)
    validate_asset_library(project)
    validate_hierarchy(project)
    validate_control_system(project)
    validate_event_scenario_model(project)
    orchestration_context = unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        source_project.event_scenarios,
        project.orchestration,
    )
    validate_orchestration(orchestration_context; scenario_source = source_project)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectVerified,
    )
end

function _resolve_scenario(
    project::CanonicalProject,
    id::ProjectId;
    require_verified::Bool,
)
    require_verified && project.verification != ProjectVerified &&
        _semantic_fail(:unverified_scenario_source, "scenario resolution requires a verified project")
    lineage = _scenario_lineage(project.event_scenarios, id)
    working = _project_without_scenarios(project)
    commands = ProjectCommand[]
    effects = CommandEffect[]
    for scenario in lineage, declaration in scenario.patches
        command = ProjectCommand(declaration.identity.id, declaration.patch)
        working, effect = _apply_command(working, command)
        push!(commands, command)
        push!(effects, effect)
    end
    resolved = _verified_materialized_scenario_project(working, project)
    return ResolvedScenario(
        id,
        CanonicalList{ProjectId}([scenario.identity.id for scenario in lineage]),
        scenario_content_hash(project, id),
        resolved,
        CanonicalList{ProjectCommand}(commands),
        CanonicalList{ProjectId}(_unique_changed_owners(effects)),
        CanonicalList{DependencyInvalidation}(_unique_invalidations(effects)),
    )
end

"""Materialize one immutable verified scenario without mutating its accepted source project."""
resolve_scenario(project::CanonicalProject, id::ProjectId) =
    _resolve_scenario(project, id; require_verified = true)
