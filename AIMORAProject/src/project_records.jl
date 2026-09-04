@enum ProjectVerificationState::UInt8 begin
    ProjectUnverified = 0x01
    ProjectVerified = 0x02
end

"""One immutable semantic record governed by an exact registered schema."""
struct CanonicalRecord
    identity::ObjectIdentity
    schema::SemanticSchemaIdentity
    fields::CanonicalList{CanonicalField}
    provenance::ProvenanceSource

    function CanonicalRecord(
        identity::ObjectIdentity,
        schema::SemanticSchemaIdentity,
        fields::AbstractVector{CanonicalField},
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(fields); by = field -> field.name)
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_canonical_field, "canonical record repeats a field")
        return new(identity, schema, CanonicalList{CanonicalField}(copied), provenance)
    end
end

Base.:(==)(left::CanonicalRecord, right::CanonicalRecord) =
    left.identity == right.identity &&
    left.schema == right.schema &&
    left.fields == right.fields &&
    left.provenance == right.provenance

"""Stable project identity and inspectable project-level metadata."""
struct ProjectMetadata
    identity::ObjectIdentity
    name::String
    default_namespace::NamespaceId
    format_version::VersionNumber
    created_at_utc::DateTime
    provenance::ProvenanceSource

    function ProjectMetadata(
        identity::ObjectIdentity,
        name::AbstractString,
        default_namespace::NamespaceId,
        format_version::VersionNumber,
        created_at_utc::DateTime,
        provenance::ProvenanceSource,
    )
        normalized_name = String(name)
        isempty(strip(normalized_name)) &&
            _semantic_fail(:invalid_project_name, "project name must not be empty")
        occursin('\0', normalized_name) &&
            _semantic_fail(:invalid_project_name, "project name contains NUL")
        format_version.major > 0 ||
            _semantic_fail(:invalid_project_format_version, "project format major version must be positive")
        return new(
            identity,
            normalized_name,
            default_namespace,
            format_version,
            created_at_utc,
            provenance,
        )
    end
end

Base.:(==)(left::ProjectMetadata, right::ProjectMetadata) =
    left.identity == right.identity &&
    left.name == right.name &&
    left.default_namespace == right.default_namespace &&
    left.format_version == right.format_version &&
    left.created_at_utc == right.created_at_utc &&
    left.provenance == right.provenance

"""The immutable accepted-or-unverified semantic project state."""
struct CanonicalProject
    metadata::ProjectMetadata
    registry::SemanticSchemaRegistry
    units::UnitRegistry
    records::CanonicalList{CanonicalRecord}
    graphs::SemanticGraphs
    asset_library::AssetLibrary
    hierarchy::HierarchyModel
    control_system::ControlSystem
    event_scenarios::EventScenarioModel
    orchestration::OrchestrationModel
    drawings::DrawingWorkspace
    verification::ProjectVerificationState

    function CanonicalProject(
        metadata::ProjectMetadata,
        registry::SemanticSchemaRegistry,
        units::UnitRegistry,
        records::AbstractVector{CanonicalRecord},
        graphs::SemanticGraphs,
        asset_library::AssetLibrary,
        hierarchy::HierarchyModel,
        control_system::ControlSystem,
        event_scenarios::EventScenarioModel,
        orchestration::OrchestrationModel,
        verification::ProjectVerificationState,
        drawings::DrawingWorkspace = DrawingWorkspace(),
    )
        copied = sort!(collect(records); by = record -> record.identity.id.value)
        ids = getfield.(getfield.(copied, :identity), :id)
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_record_id, "canonical project repeats a record ID")
        return new(
            metadata,
            registry,
            units,
            CanonicalList{CanonicalRecord}(copied),
            graphs,
            asset_library,
            hierarchy,
            control_system,
            event_scenarios,
            orchestration,
            drawings,
            verification,
        )
    end
end

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, SemanticGraphs(), AssetLibrary(), HierarchyModel(), ControlSystem(), EventScenarioModel(), OrchestrationModel(), verification)

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs,
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, graphs, AssetLibrary(), HierarchyModel(), ControlSystem(), EventScenarioModel(), OrchestrationModel(), verification)

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs,
    asset_library::AssetLibrary,
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, graphs, asset_library, HierarchyModel(), ControlSystem(), EventScenarioModel(), OrchestrationModel(), verification)

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs,
    asset_library::AssetLibrary,
    hierarchy::HierarchyModel,
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, graphs, asset_library, hierarchy, ControlSystem(), EventScenarioModel(), OrchestrationModel(), verification)

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs,
    asset_library::AssetLibrary,
    hierarchy::HierarchyModel,
    control_system::ControlSystem,
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, graphs, asset_library, hierarchy, control_system, EventScenarioModel(), OrchestrationModel(), verification)

CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs,
    asset_library::AssetLibrary,
    hierarchy::HierarchyModel,
    control_system::ControlSystem,
    event_scenarios::EventScenarioModel,
    verification::ProjectVerificationState,
) = CanonicalProject(metadata, registry, units, records, graphs, asset_library, hierarchy, control_system, event_scenarios, OrchestrationModel(), verification)

Base.:(==)(left::CanonicalProject, right::CanonicalProject) =
    left.metadata == right.metadata &&
    left.registry == right.registry &&
    left.units == right.units &&
    left.records == right.records &&
    left.graphs == right.graphs &&
    left.asset_library == right.asset_library &&
    left.hierarchy == right.hierarchy &&
    left.control_system == right.control_system &&
    left.event_scenarios == right.event_scenarios &&
    left.orchestration == right.orchestration &&
    left.drawings == right.drawings &&
    left.verification == right.verification

function _validate_record(project::CanonicalProject, record::CanonicalRecord)
    schema = resolve_schema(project.registry, record.schema)
    declared_names = Set(field.name for field in schema.fields)
    for field in record.fields
        field.name in declared_names ||
            _semantic_fail(:unknown_canonical_field, "record $(record.identity.id.value) contains undeclared field $(field.name)")
        field.name == "id" && field.value != record.identity.id.value &&
            _semantic_fail(:record_identity_mismatch, "record id field differs from its immutable object identity")
        validate_field_value(schema_field(schema, field.name), field.value, project.units)
    end
    present_names = Set(field.name for field in record.fields)
    for field in schema.fields
        field.required && field.name ∉ present_names &&
            _semantic_fail(:missing_required_field, "record $(record.identity.id.value) omits required field $(field.name)")
    end
    return true
end

"""Validate all currently admitted semantic invariants without mutating the project."""
function validate_project(project::CanonicalProject)
    any(item -> item.namespace == project.metadata.default_namespace, project.registry.namespaces) ||
        _semantic_fail(:unknown_project_namespace, "project default namespace is not registered")
    for record in project.records
        _validate_record(project, record)
    end
    validate_graphs(project)
    validate_asset_library(project)
    validate_hierarchy(project)
    validate_control_system(project)
    validate_orchestration(project)
    validate_event_scenario_model(project)
    validate_drawing_workspace(project, project.drawings)
    return true
end

"""Return an immutable verified copy after complete semantic validation."""
function verified_project(project::CanonicalProject)
    validate_project(project)
    project.verification == ProjectVerified && return project
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
        project.drawings,
    )
end

"""Construct typed developer data without claiming it is validated or reusable for results."""
unsafe_project(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs = SemanticGraphs(),
    asset_library::AssetLibrary = AssetLibrary(),
    hierarchy::HierarchyModel = HierarchyModel(),
    control_system::ControlSystem = ControlSystem(),
    event_scenarios::EventScenarioModel = EventScenarioModel(),
    orchestration::OrchestrationModel = OrchestrationModel(),
    drawings::DrawingWorkspace = DrawingWorkspace(),
 ) = CanonicalProject(metadata, registry, units, records, graphs, asset_library, hierarchy, control_system, event_scenarios, orchestration, ProjectUnverified, drawings)

function CanonicalProject(
    metadata::ProjectMetadata,
    registry::SemanticSchemaRegistry,
    units::UnitRegistry,
    records::AbstractVector{CanonicalRecord},
    graphs::SemanticGraphs = SemanticGraphs(),
    asset_library::AssetLibrary = AssetLibrary(),
    hierarchy::HierarchyModel = HierarchyModel(),
    control_system::ControlSystem = ControlSystem(),
    event_scenarios::EventScenarioModel = EventScenarioModel(),
    orchestration::OrchestrationModel = OrchestrationModel(),
    drawings::DrawingWorkspace = DrawingWorkspace(),
)
    return verified_project(unsafe_project(metadata, registry, units, records, graphs, asset_library, hierarchy, control_system, event_scenarios, orchestration, drawings))
end

function project_record(project::CanonicalProject, id::ProjectId)
    index = findfirst(record -> record.identity.id == id, project.records)
    isnothing(index) && _semantic_fail(:unknown_record_id, "canonical project record does not exist")
    return project.records[index]
end

function _replace_project_record(project::CanonicalProject, replacement::CanonicalRecord)
    records = collect(project.records)
    index = findfirst(record -> record.identity.id == replacement.identity.id, records)
    isnothing(index) && _semantic_fail(:unknown_record_id, "canonical project record does not exist")
    records[index] = replacement
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        records,
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_project_metadata(project::CanonicalProject, metadata::ProjectMetadata)
    return CanonicalProject(
        metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_project_graphs(project::CanonicalProject, graphs::SemanticGraphs)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_asset_library(project::CanonicalProject, asset_library::AssetLibrary)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        asset_library,
        project.hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_hierarchy(project::CanonicalProject, hierarchy::HierarchyModel)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        hierarchy,
        project.control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_control_system(project::CanonicalProject, control_system::ControlSystem)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        control_system,
        project.event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_event_scenarios(project::CanonicalProject, event_scenarios::EventScenarioModel)
    return CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        collect(project.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
        project.control_system,
        event_scenarios,
        project.orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_orchestration(project::CanonicalProject, orchestration::OrchestrationModel)
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
        orchestration,
        ProjectUnverified,
        project.drawings,
    )
end

function _replace_project_drawings(project::CanonicalProject, drawings::DrawingWorkspace)
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
        ProjectUnverified,
        drawings,
    )
end
