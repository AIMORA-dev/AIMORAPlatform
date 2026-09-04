"""Exact transitive semantic consumers and invalidation scopes for changed owners."""
struct DependencyImpact
    roots::CanonicalList{ProjectId}
    downstream::CanonicalList{ProjectId}
    invalidations::CanonicalList{DependencyInvalidation}
end

Base.:(==)(left::DependencyImpact, right::DependencyImpact) =
    left.roots == right.roots && left.downstream == right.downstream &&
    left.invalidations == right.invalidations

function _add_dependency!(adjacency::Dict{ProjectId,Set{ProjectId}}, upstream::ProjectId, downstream::ProjectId)
    push!(get!(adjacency, upstream, Set{ProjectId}()), downstream)
    get!(adjacency, downstream, Set{ProjectId}())
    return adjacency
end

function _reference_owner(reference::ProjectReference)
    return reference.target isa LocalReferenceTarget ? reference.target.id : nothing
end

function _semantic_dependency_graph(project::CanonicalProject)
    adjacency = Dict{ProjectId,Set{ProjectId}}()
    for dependency in project.graphs.workflow_dependencies
        _add_dependency!(adjacency, dependency.upstream, dependency.downstream)
    end
    for reference in project.graphs.cross_references
        target = _reference_owner(reference.target)
        isnothing(target) || _add_dependency!(adjacency, target, reference.source)
    end
    for event in project.event_scenarios.events
        target = _reference_owner(event.target)
        isnothing(target) || _add_dependency!(adjacency, target, event.identity.id)
    end
    for scenario in project.event_scenarios.scenarios
        !isnothing(scenario.parent) && _add_dependency!(
            adjacency,
            scenario.parent.target.id,
            scenario.identity.id,
        )
        for declaration in scenario.patches
            _add_dependency!(adjacency, _scenario_patch_owner(declaration.patch), scenario.identity.id)
        end
    end
    for study in project.orchestration.studies
        !isnothing(study.scenario) && _add_dependency!(
            adjacency,
            study.scenario.target.id,
            study.identity.id,
        )
        for event in study.events
            _add_dependency!(adjacency, event.target.id, study.identity.id)
        end
        for output in study.outputs
            target = _reference_owner(output.target)
            isnothing(target) || _add_dependency!(adjacency, target, study.identity.id)
        end
        for prerequisite in study.prerequisites
            _add_dependency!(adjacency, prerequisite.upstream.target.id, study.identity.id)
        end
    end
    for result in project.orchestration.results
        _add_dependency!(adjacency, result.producer.target.id, result.identity.id)
    end
    for workflow in project.orchestration.workflows
        for step in workflow.steps
            _add_dependency!(adjacency, step.study.target.id, workflow.identity.id)
            for input in step.inputs
                isnothing(input.source) && continue
                input.source isa ExistingResultSource && _add_dependency!(
                    adjacency,
                    input.source.result.target.id,
                    workflow.identity.id,
                )
            end
        end
    end
    for experiment in project.orchestration.experiments
        _add_dependency!(adjacency, experiment.evaluation.target.id, experiment.identity.id)
        variables = experiment isa UncertaintyExperiment ?
            DecisionVariable[input.variable for input in experiment.inputs] : collect(experiment.variables)
        for variable in variables
            _add_dependency!(adjacency, variable.target.target.id, experiment.identity.id)
        end
    end
    return adjacency
end

function _downstream_owners(adjacency::Dict{ProjectId,Set{ProjectId}}, roots::Vector{ProjectId})
    visited = Set(roots)
    downstream = Set{ProjectId}()
    queue = sort!(copy(roots); by = item -> item.value)
    while !isempty(queue)
        owner = popfirst!(queue)
        for consumer in sort!(collect(get(adjacency, owner, Set{ProjectId}())); by = item -> item.value)
            consumer in visited && continue
            push!(visited, consumer)
            push!(downstream, consumer)
            push!(queue, consumer)
        end
    end
    return sort!(collect(downstream); by = item -> item.value)
end

function _owner_invalidation_scopes(project::CanonicalProject, owner::ProjectId)
    if any(item -> item.identity.id == owner, project.orchestration.workflows) ||
        any(item -> item.identity.id == owner, project.orchestration.experiments)
        return [InvalidateWorkflowResults]
    elseif any(item -> item.identity.id == owner, project.orchestration.results)
        return [InvalidateWorkflowResults]
    elseif any(item -> item.identity.id == owner, project.graphs.view_projections)
        return [InvalidateViews]
    end
    return [InvalidateStudyResults, InvalidateWorkflowResults]
end

function dependency_impact(project::CanonicalProject, changed::AbstractVector{ProjectId})
    roots = sort!(unique(collect(changed)); by = item -> item.value)
    isempty(roots) && _semantic_fail(:empty_dependency_roots, "dependency impact requires changed owners")
    downstream = _downstream_owners(_semantic_dependency_graph(project), roots)
    invalidations = DependencyInvalidation[
        DependencyInvalidation(owner, _owner_invalidation_scopes(project, owner))
        for owner in downstream
    ]
    return DependencyImpact(
        CanonicalList{ProjectId}(roots),
        CanonicalList{ProjectId}(downstream),
        CanonicalList{DependencyInvalidation}(invalidations),
    )
end

dependency_impact(project::CanonicalProject, owner::ProjectId) = dependency_impact(project, [owner])

function _cached_result_ids(model::OrchestrationModel)
    accepted_inputs = Set{ProjectId}()
    for workflow in model.workflows, step in workflow.steps, input in step.inputs
        input.source isa ExistingResultSource || continue
        input.source.result.target isa LocalReferenceTarget &&
            push!(accepted_inputs, input.source.result.target.id)
    end
    return ProjectId[
        result.identity.id for result in model.results
        if result.identity.id ∉ accepted_inputs
    ]
end

"""Reconstruct a verified project without removable cached results; accepted upstream inputs remain."""
function without_result_cache(project::CanonicalProject)
    cached = Set(_cached_result_ids(project.orchestration))
    isempty(cached) && return project
    retained = ResultDeclaration[
        result for result in project.orchestration.results
        if result.identity.id ∉ cached
    ]
    model = OrchestrationModel(
        study_schemas = collect(project.orchestration.study_schemas),
        studies = collect(project.orchestration.studies),
        result_contracts = collect(project.orchestration.result_contracts),
        results = retained,
        workflows = collect(project.orchestration.workflows),
        experiments = collect(project.orchestration.experiments),
    )
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
        model,
        project.drawings,
    )
end
