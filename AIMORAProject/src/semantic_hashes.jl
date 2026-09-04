@enum SemanticHashLayer::UInt8 begin
    HashResolvedProject = 0x01
    HashPhysicalModel = 0x02
    HashViewModel = 0x03
end

"""External execution identities kept separate from physical and view semantics."""
struct ExecutionDependencySignatures
    automation_environment::ContentDigest
    plugin_lock::ContentDigest
    script_environment::ContentDigest
end

Base.:(==)(left::ExecutionDependencySignatures, right::ExecutionDependencySignatures) =
    left.automation_environment == right.automation_environment &&
    left.plugin_lock == right.plugin_lock &&
    left.script_environment == right.script_environment

"""Named deterministic identities for one canonical project revision."""
struct ProjectSemanticHashes
    source::ContentDigest
    resolved::ContentDigest
    physics::ContentDigest
    view::ContentDigest
    execution::ExecutionDependencySignatures
end

"""Complete cache/reuse identity for one study evaluation and its upstream results."""
struct ResultDependencySignature
    physics::ContentDigest
    scenario::Union{Nothing,ContentDigest}
    study::ContentDigest
    automation_environment::ContentDigest
    plugin_lock::ContentDigest
    script_environment::ContentDigest
    upstream::CanonicalList{ContentDigest}

    function ResultDependencySignature(
        physics::ContentDigest,
        scenario::Union{Nothing,ContentDigest},
        study::ContentDigest,
        execution::ExecutionDependencySignatures,
        upstream::AbstractVector{ContentDigest},
    )
        copied = sort!(collect(upstream); by = item -> item.sha256)
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_result_dependency, "result dependency signature repeats an upstream hash")
        return new(
            physics,
            scenario,
            study,
            execution.automation_environment,
            execution.plugin_lock,
            execution.script_environment,
            CanonicalList{ContentDigest}(copied),
        )
    end
end

Base.:(==)(left::ResultDependencySignature, right::ResultDependencySignature) =
    left.physics == right.physics && left.scenario == right.scenario &&
    left.study == right.study &&
    left.automation_environment == right.automation_environment &&
    left.plugin_lock == right.plugin_lock && left.script_environment == right.script_environment &&
    left.upstream == right.upstream

Base.:(==)(left::ProjectSemanticHashes, right::ProjectSemanticHashes) =
    left.source == right.source && left.resolved == right.resolved &&
    left.physics == right.physics && left.view == right.view &&
    left.execution == right.execution

_semantic_digest(domain::String, signature::String) =
    ContentDigest(bytes2hex(SHA.sha256(domain * "\n" * signature)))

function _dimension_signature(dimension::DimensionVector)
    return join(string.(dimension.exponents), ',')
end

function _canonical_scalar_signature(
    project::CanonicalProject,
    quantity::ScalarQuantity;
    difference::Bool = false,
)
    unit = lookup_unit(project.units, quantity.unit)
    if unit.per_unit
        return "pu:" * _scenario_value_signature(quantity.value) * ":" *
            _scenario_value_signature(quantity.base) * ":" * string(UInt8(quantity.orientation))
    end
    value = exact_rational(quantity.value) * unit.scale
    difference || (value += unit.offset)
    return join((
        "si",
        _scenario_value_signature(value),
        _dimension_signature(unit.dimension),
        string(UInt8(quantity.orientation)),
        _scenario_value_signature(quantity.base),
    ), ':')
end

_canonical_quantity_signature(project::CanonicalProject, quantity::ScalarQuantity) =
    _canonical_scalar_signature(project, quantity)

function _canonical_quantity_signature(project::CanonicalProject, quantity::ComplexQuantity)
    unit = lookup_unit(project.units, quantity.unit)
    unit.affine == UnitLinear ||
        _semantic_fail(:complex_affine_quantity, "complex semantic quantity cannot use an affine unit")
    real = exact_rational(quantity.real) * unit.scale
    imag = exact_rational(quantity.imag) * unit.scale
    return join((
        "complex-si",
        _scenario_value_signature(real),
        _scenario_value_signature(imag),
        _dimension_signature(unit.dimension),
        string(UInt8(quantity.orientation)),
        _scenario_value_signature(quantity.base),
    ), ':')
end

function _canonical_uncertainty_signature(project::CanonicalProject, uncertainty::QuantityUncertainty)
    deviation = isnothing(uncertainty.standard_deviation) ? "" :
        _canonical_scalar_signature(project, uncertainty.standard_deviation; difference = true)
    lower = isnothing(uncertainty.lower) ? "" : _canonical_scalar_signature(project, uncertainty.lower)
    upper = isnothing(uncertainty.upper) ? "" : _canonical_scalar_signature(project, uncertainty.upper)
    return join((
        string(UInt8(uncertainty.kind)),
        deviation,
        lower,
        upper,
        _scenario_value_signature(uncertainty.confidence),
    ), ':')
end

function _semantic_signature(project::CanonicalProject, value, layer::SemanticHashLayer)
    if value isa PhysicalValue
        uncertainty = isnothing(value.uncertainty) ? "" :
            _canonical_uncertainty_signature(project, value.uncertainty)
        return "physical:" * _canonical_quantity_signature(project, value.quantity) *
            ":uncertainty:" * uncertainty * ":provenance:" *
            (layer == HashPhysicalModel ? "excluded" : _scenario_value_signature(value.provenance))
    elseif value isa ScalarQuantity
        return _canonical_scalar_signature(project, value)
    elseif value isa ComplexQuantity
        return _canonical_quantity_signature(project, value)
    elseif value isa QuantityUncertainty
        return _canonical_uncertainty_signature(project, value)
    elseif value isa ProvenanceSource
        return layer == HashPhysicalModel ? "provenance:excluded" : _scenario_value_signature(value)
    elseif value isa ObjectIdentity && layer == HashPhysicalModel
        return "identity:" * value.id.value
    elseif value isa ArtifactIdentity && layer == HashPhysicalModel
        return join((
            "artifact",
            value.id.value,
            value.sha256,
            _scenario_value_signature(value.schema),
        ), ':')
    elseif value isa CanonicalList || value isa AbstractVector || value isa Tuple
        return "list:[" * join((_semantic_signature(project, item, layer) for item in value), ',') * "]"
    elseif value isa Union{Nothing,Bool,Integer,AbstractString,Symbol,Enum,UUID,VersionNumber,DateTime}
        return _scenario_value_signature(value)
    end
    type = typeof(value)
    isstructtype(type) ||
        _semantic_fail(:unsupported_semantic_hash_value, "semantic hash encountered mutable or executable data")
    parts = String[]
    for name in fieldnames(type)
        layer == HashPhysicalModel && name in (:provenance, :access) && continue
        push!(parts, String(name) * "=" * _semantic_signature(project, getfield(value, name), layer))
    end
    return "struct:" * string(nameof(type)) * "{" * join(parts, ',') * "}"
end

function _view_record_ids(project::CanonicalProject)
    return Set(projection.view for projection in project.graphs.view_projections)
end

function _graphs_without_views(graphs::SemanticGraphs)
    return SemanticGraphs(
        nodes = collect(graphs.nodes),
        ports = collect(graphs.ports),
        physical_connections = collect(graphs.physical_connections),
        signal_connections = collect(graphs.signal_connections),
        workflow_dependencies = collect(graphs.workflow_dependencies),
        cross_references = collect(graphs.cross_references),
    )
end

function _orchestration_without_results(model::OrchestrationModel)
    return OrchestrationModel(
        study_schemas = collect(model.study_schemas),
        studies = collect(model.studies),
        result_contracts = collect(model.result_contracts),
        workflows = collect(model.workflows),
        experiments = collect(model.experiments),
    )
end

function semantic_canonical_form(project::CanonicalProject, layer::SemanticHashLayer)
    if layer == HashPhysicalModel
        view_ids = _view_record_ids(project)
        payload = (
            records = CanonicalRecord[item for item in project.records if item.identity.id ∉ view_ids],
            graphs = _graphs_without_views(project.graphs),
            assets = project.asset_library,
            hierarchy = project.hierarchy,
            controls = project.control_system,
            events = project.event_scenarios.events,
        )
        return _semantic_signature(project, payload, layer)
    elseif layer == HashViewModel
        view_ids = _view_record_ids(project)
        payload = (
            records = CanonicalRecord[item for item in project.records if item.identity.id in view_ids],
            projections = project.graphs.view_projections,
            drawings = project.drawings,
        )
        return _semantic_signature(project, payload, layer)
    end
    payload = (
        metadata = project.metadata,
        registry = project.registry,
        units = project.units,
        records = project.records,
        graphs = project.graphs,
        assets = project.asset_library,
        hierarchy = project.hierarchy,
        controls = project.control_system,
        events_scenarios = project.event_scenarios,
        orchestration = _orchestration_without_results(project.orchestration),
        drawings = project.drawings,
    )
    return _semantic_signature(project, payload, layer)
end

project_resolved_hash(project::CanonicalProject) =
    _semantic_digest("aimora-project-resolved-v1", semantic_canonical_form(project, HashResolvedProject))

project_physics_hash(project::CanonicalProject) =
    _semantic_digest("aimora-project-physics-v1", semantic_canonical_form(project, HashPhysicalModel))

project_view_hash(project::CanonicalProject) =
    _semantic_digest("aimora-project-view-v1", semantic_canonical_form(project, HashViewModel))

function project_semantic_hashes(
    project::CanonicalProject,
    source::ContentDigest,
    execution::ExecutionDependencySignatures,
)
    return ProjectSemanticHashes(
        source,
        project_resolved_hash(project),
        project_physics_hash(project),
        project_view_hash(project),
        execution,
    )
end

study_request_hash(project::CanonicalProject, study::StudyRequest) =
    _semantic_digest("aimora-study-request-semantic-v1", _semantic_signature(project, study, HashResolvedProject))

study_request_hash(project::CanonicalProject, id::ProjectId) =
    study_request_hash(project, study_request(project.orchestration, id))

result_dependency_hash(project::CanonicalProject, result::ResultDeclaration) =
    _semantic_digest("aimora-result-dependency-v1", _semantic_signature(project, result, HashResolvedProject))

function result_dependency_signature(
    project::CanonicalProject,
    study::StudyRequest,
    execution::ExecutionDependencySignatures,
    upstream::AbstractVector{ContentDigest},
)
    scenario = isnothing(study.scenario) ? nothing :
        scenario_content_hash(project, study.scenario.target.id)
    return ResultDependencySignature(
        project_physics_hash(project),
        scenario,
        study_request_hash(project, study),
        execution,
        upstream,
    )
end

result_dependency_signature(
    project::CanonicalProject,
    id::ProjectId,
    execution::ExecutionDependencySignatures,
    upstream::AbstractVector{ContentDigest},
) = result_dependency_signature(project, study_request(project.orchestration, id), execution, upstream)

result_dependency_hash(signature::ResultDependencySignature) =
    _semantic_digest("aimora-result-reuse-v1", _scenario_value_signature(signature))
