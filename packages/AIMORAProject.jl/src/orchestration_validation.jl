function _registered_orchestration_type(project::CanonicalProject, type::SemanticTypeId, code::Symbol)
    any(item -> item.namespace == type.namespace, project.registry.namespaces) ||
        _semantic_fail(code, "orchestration type namespace is not registered")
    return true
end

function _validate_registered_function(project::CanonicalProject, identity::RegisteredFunctionIdentity)
    return _registered_orchestration_type(project, identity.package, :unknown_registered_function_namespace)
end

function _validate_orchestration_value(project::CanonicalProject, value::CanonicalFieldData)
    if value isa PhysicalValue
        validate_quantity(project.units, value)
    elseif value isa ProjectReference && value.target isa LocalReferenceTarget
        _validate_local_reference(project, value)
    end
    return true
end

function _validate_declared_fields(
    project::CanonicalProject,
    specifications::CanonicalList{SchemaField},
    values::CanonicalList{CanonicalField},
    unknown_code::Symbol,
    missing_code::Symbol,
)
    supplied = Set(item.name for item in values)
    for value in values
        index = findfirst(item -> item.name == value.name, specifications)
        isnothing(index) && _semantic_fail(unknown_code, "orchestration request supplies an owner-unrelated field")
        validate_field_value(specifications[index], value.value, project.units)
    end
    for specification in specifications
        specification.required && specification.name ∉ supplied &&
            _semantic_fail(missing_code, "orchestration request omits a required owner field")
    end
    return true
end

function _study_output_contract_ids(study::StudyRequest)
    return Set(output.contract for output in study.outputs)
end

function _validate_study_output(project::CanonicalProject, output::StudyOutputRequest)
    contract = result_contract(project.orchestration, output.contract)
    _registered_orchestration_type(project, output.quantity, :unknown_study_output_quantity_namespace)
    unit = lookup_unit(project.units, output.unit)
    compatible = any(contract.fields) do field
        if field.kind == SchemaQuantity
            constraint = only(item for item in field.constraints if item isa QuantityConstraint)
            return unit.dimension == constraint.dimension && output.orientation in constraint.orientations
        end
        return field.kind in (SchemaDecimal, SchemaInteger) &&
            unit.dimension == dimensionless() && output.orientation == OrientationScalar
    end
    compatible ||
        _semantic_fail(:study_output_contract_mismatch, "study output unit/orientation is absent from its result contract")
    output.target.target isa LocalReferenceTarget && _validate_local_reference(project, output.target)
    return true
end

function _validate_study_request(project::CanonicalProject, study::StudyRequest)
    schema = study_schema(project.orchestration, study.schema)
    study.representation in schema.representations ||
        _semantic_fail(:study_representation_mismatch, "study representation is outside its owner schema")
    study.fidelity in schema.fidelities ||
        _semantic_fail(:study_fidelity_mismatch, "study fidelity is outside its owner schema")
    _validate_declared_fields(
        project,
        schema.settings,
        study.settings,
        :unknown_study_setting,
        :missing_study_setting,
    )
    _validate_declared_fields(
        project,
        schema.initialization,
        study.initialization,
        :unknown_study_initialization,
        :missing_study_initialization,
    )
    _registered_orchestration_type(project, study.method.method, :unknown_study_method_namespace)
    _validate_registered_function(project, study.method.implementation)
    foreach(option -> _validate_orchestration_value(project, option.value), study.method.options)
    if !isnothing(study.scenario)
        study.scenario.target isa LocalReferenceTarget ||
            _semantic_fail(:external_study_scenario, "study scenario must be project-local")
        isempty(study.scenario.path.tokens) ||
            _semantic_fail(:study_scenario_path, "study scenario cannot select a subfield")
        scenario_definition(project.event_scenarios, study.scenario.target.id)
    end
    for reference in study.events
        reference.target isa LocalReferenceTarget ||
            _semantic_fail(:external_study_event, "study event must be project-local")
        isempty(reference.path.tokens) ||
            _semantic_fail(:study_event_path, "study event cannot select a subfield")
        event_declaration(project.event_scenarios, reference.target.id)
    end
    foreach(output -> _validate_study_output(project, output), study.outputs)
    for prerequisite in study.prerequisites
        prerequisite.upstream.target isa LocalReferenceTarget ||
            _semantic_fail(:external_study_prerequisite, "study prerequisite must be project-local")
        isempty(prerequisite.upstream.path.tokens) ||
            _semantic_fail(:study_prerequisite_path, "study prerequisite cannot select a subfield")
        upstream = study_request(project.orchestration, prerequisite.upstream.target.id)
        upstream.identity.id == study.identity.id &&
            _semantic_fail(:self_study_prerequisite, "study cannot depend on itself")
        prerequisite.required_contract in _study_output_contract_ids(upstream) ||
            _semantic_fail(:study_prerequisite_contract_mismatch, "upstream study does not declare the required result contract")
    end
    return true
end

function _validate_study_graph(model::OrchestrationModel)
    vertices = ProjectId[item.identity.id for item in model.studies]
    edges = Tuple{ProjectId,ProjectId}[]
    for study in model.studies, prerequisite in study.prerequisites
        prerequisite.upstream.target isa LocalReferenceTarget || continue
        push!(edges, (prerequisite.upstream.target.id, study.identity.id))
    end
    _has_directed_cycle(vertices, edges) &&
        _semantic_fail(:study_prerequisite_cycle, "study prerequisite graph contains a cycle")
    return true
end

function _expected_study_scenario_hash(project::CanonicalProject, study::StudyRequest)
    isnothing(study.scenario) && return nothing
    return scenario_content_hash(project, study.scenario.target.id)
end

function _validate_result_declaration(
    project::CanonicalProject,
    result::ResultDeclaration,
    scenario_source::CanonicalProject,
)
    result_contract(project.orchestration, result.contract)
    result.producer.target isa LocalReferenceTarget ||
        _semantic_fail(:external_result_producer, "result producer must be project-local")
    isempty(result.producer.path.tokens) ||
        _semantic_fail(:result_producer_path, "result producer cannot select a subfield")
    producer = study_request(project.orchestration, result.producer.target.id)
    result.contract in _study_output_contract_ids(producer) ||
        _semantic_fail(:incompatible_result_contract, "result contract is not an output of its producer")
    result.project_revision == producer.project_revision ||
        _semantic_fail(:stale_result_project_revision, "result project revision differs from its producer request")
    result.study_request_hash == study_request_hash(producer) ||
        _semantic_fail(:stale_result_study_request, "result study hash differs from its current producer request")
    result.scenario_hash == _expected_study_scenario_hash(scenario_source, producer) ||
        _semantic_fail(:stale_result_scenario, "result scenario hash differs from its producer request")
    return true
end

function _validate_existing_result_source(project::CanonicalProject, source::ExistingResultSource)
    source.result.target isa LocalReferenceTarget ||
        _semantic_fail(:external_workflow_result, "workflow result input must be project-local")
    isempty(source.result.path.tokens) ||
        _semantic_fail(:workflow_result_path, "workflow result input cannot select a subfield")
    result = result_declaration(project.orchestration, source.result.target.id)
    source.contract == result.contract ||
        _semantic_fail(:incompatible_result_contract, "workflow input contract differs from the accepted result")
    source.project_revision == result.project_revision ||
        _semantic_fail(:stale_result_project_revision, "workflow input project revision differs from the accepted result")
    source.scenario_hash == result.scenario_hash ||
        _semantic_fail(:stale_result_scenario, "workflow input scenario hash differs from the accepted result")
    source.study_request_hash == result.study_request_hash ||
        _semantic_fail(:stale_result_study_request, "workflow input study hash differs from the accepted result")
    return true
end

function _workflow_step(workflow::WorkflowDefinition, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, workflow.steps)
    isnothing(index) && _semantic_fail(:unknown_workflow_step, "workflow dependency references a missing step")
    return workflow.steps[index]
end

function _validate_workflow_step_source(
    project::CanonicalProject,
    workflow::WorkflowDefinition,
    step::WorkflowStep,
    source::StepResultSource,
)
    source.step in step.depends_on ||
        _semantic_fail(:undeclared_workflow_input_dependency, "step result input requires an explicit dependency")
    upstream_step = _workflow_step(workflow, source.step)
    upstream_study = study_request(project.orchestration, upstream_step.study.target.id)
    source.contract in _study_output_contract_ids(upstream_study) ||
        _semantic_fail(:workflow_step_contract_mismatch, "upstream step study does not declare the input contract")
    return true
end

function _workflow_has_prerequisite(
    project::CanonicalProject,
    workflow::WorkflowDefinition,
    step::WorkflowStep,
    prerequisite::StudyPrerequisite,
)
    upstream_id = prerequisite.upstream.target.id
    for dependency in step.depends_on
        dependency_step = _workflow_step(workflow, dependency)
        dependency_step.study.target.id == upstream_id && return true
    end
    for input in step.inputs
        input.source isa ExistingResultSource || continue
        result = result_declaration(project.orchestration, input.source.result.target.id)
        result.producer.target.id == upstream_id && return true
    end
    return false
end

function _validate_workflow(project::CanonicalProject, workflow::WorkflowDefinition)
    step_ids = ProjectId[item.identity.id for item in workflow.steps]
    edges = Tuple{ProjectId,ProjectId}[]
    for step in workflow.steps
        step.study.target isa LocalReferenceTarget ||
            _semantic_fail(:external_workflow_study, "workflow step study must be project-local")
        isempty(step.study.path.tokens) ||
            _semantic_fail(:workflow_study_path, "workflow step study cannot select a subfield")
        study = study_request(project.orchestration, step.study.target.id)
        for dependency in step.depends_on
            _workflow_step(workflow, dependency)
            dependency == step.identity.id &&
                _semantic_fail(:self_workflow_dependency, "workflow step cannot depend on itself")
            push!(edges, (dependency, step.identity.id))
        end
        for input in step.inputs
            isnothing(input.source) && continue
            if input.source isa ExistingResultSource
                _validate_existing_result_source(project, input.source)
            else
                _validate_workflow_step_source(project, workflow, step, input.source)
            end
        end
        for prerequisite in study.prerequisites
            prerequisite.automatic || continue
            _workflow_has_prerequisite(project, workflow, step, prerequisite) ||
                _semantic_fail(:missing_automatic_prerequisite, "workflow omits an explicitly automatic study prerequisite")
        end
    end
    _has_directed_cycle(step_ids, edges) &&
        _semantic_fail(:workflow_cycle, "workflow step graph contains a cycle")
    return true
end

function _validate_decision_quantity(
    project::CanonicalProject,
    variable::DecisionVariable,
    value::PhysicalValue{ScalarQuantity},
    ;
    allow_uncertainty::Bool = false,
)
    validate_quantity(project.units, value)
    (allow_uncertainty || isnothing(value.uncertainty)) ||
        _semantic_fail(:uncertain_decision_bound, "decision bounds and candidates cannot carry uncertainty")
    value.quantity.unit == variable.unit && value.quantity.orientation == variable.orientation &&
        isnothing(value.quantity.base) ||
        _semantic_fail(:decision_variable_contract_mismatch, "decision value differs from its declared unit/orientation")
    return exact_rational(value.quantity.value)
end

function _decision_target_value(project::CanonicalProject, variable::DecisionVariable)
    variable.target.target isa LocalReferenceTarget ||
        _semantic_fail(:external_decision_target, "decision variable target must be project-local")
    id = variable.target.target.id
    path = string(variable.path)
    if variable.target.kind == ReferenceAsset
        asset_index = findfirst(item -> item.identity.id == id, project.asset_library.assets)
        if !isnothing(asset_index)
            normalized = startswith(path, "common.") ? path[8:end] : path
            property_index = findfirst(item -> string(item.path) == normalized, project.asset_library.assets[asset_index].common)
            isnothing(property_index) &&
                _semantic_fail(:unknown_decision_path, "decision variable asset path does not exist")
            return project.asset_library.assets[asset_index].common[property_index].value
        end
        record = project_record(project, id)
        length(variable.path.segments) == 1 ||
            _semantic_fail(:unknown_decision_path, "record decision path must name one schema field")
        field_name = first(variable.path.segments).value
        field = _field_by_name(record, field_name)
        isnothing(field) && _semantic_fail(:unknown_decision_path, "decision variable record path does not exist")
        return field.value
    elseif variable.target.kind == ReferenceControlBlock
        for network in project.control_system.networks
            index = findfirst(item -> item.identity.id == id, network.blocks)
            isnothing(index) && continue
            length(variable.path.segments) == 1 ||
                _semantic_fail(:unknown_decision_path, "control decision path must name one parameter")
            name = first(variable.path.segments).value
            parameter = findfirst(item -> item.name == name, network.blocks[index].parameters)
            isnothing(parameter) && _semantic_fail(:unknown_decision_path, "control decision parameter does not exist")
            return network.blocks[index].parameters[parameter].value
        end
        _semantic_fail(:unknown_decision_target, "decision variable control target does not exist")
    elseif variable.target.kind == ReferenceStudy
        study = study_request(project.orchestration, id)
        length(variable.path.segments) == 1 ||
            _semantic_fail(:unknown_decision_path, "study decision path must name one setting")
        name = first(variable.path.segments).value
        setting = findfirst(item -> item.name == name, study.settings)
        isnothing(setting) && _semantic_fail(:unknown_decision_path, "study decision setting does not exist")
        return study.settings[setting].value
    end
    _semantic_fail(:invalid_decision_target, "decision variable target must be an asset, control block, or study")
end

function _validate_decision_variable(project::CanonicalProject, variable::DecisionVariable)
    isempty(variable.target.path.tokens) ||
        _semantic_fail(:decision_target_path, "decision variable uses its dedicated field path, not a reference subpath")
    unit = lookup_unit(project.units, variable.unit)
    current = _decision_target_value(project, variable)
    current isa PhysicalValue{ScalarQuantity} ||
        _semantic_fail(:nonquantity_decision_target, "decision variable target must currently contain a scalar quantity")
    current_value = _validate_decision_quantity(project, variable, current; allow_uncertainty = true)
    lower = isnothing(variable.lower) ? nothing : _validate_decision_quantity(project, variable, variable.lower)
    upper = isnothing(variable.upper) ? nothing : _validate_decision_quantity(project, variable, variable.upper)
    !isnothing(lower) && !isnothing(upper) && upper < lower &&
        _semantic_fail(:invalid_decision_bounds, "decision variable lower bound exceeds upper bound")
    variable.domain in (DecisionContinuous, DecisionInteger) &&
        (isnothing(lower) || isnothing(upper)) &&
        _semantic_fail(:missing_decision_bounds, "continuous or integer decision variable requires finite bounds")
    if variable.domain == DecisionInteger
        current_value.denominator == 1 ||
            _semantic_fail(:noninteger_decision_value, "integer decision variable has a noninteger current value")
        (isnothing(lower) || lower.denominator == 1) && (isnothing(upper) || upper.denominator == 1) ||
            _semantic_fail(:noninteger_decision_bound, "integer decision variable has a noninteger bound")
    end
    candidate_signatures = String[]
    for candidate in variable.candidates
        candidate isa PhysicalValue{ScalarQuantity} ||
            _semantic_fail(:nonquantity_decision_candidate, "decision candidate must be a scalar physical value")
        value = _validate_decision_quantity(project, variable, candidate)
        variable.domain == DecisionInteger && value.denominator != 1 &&
            _semantic_fail(:noninteger_decision_candidate, "integer decision candidate is not integral")
        !isnothing(lower) && value < lower &&
            _semantic_fail(:decision_candidate_out_of_bounds, "decision candidate is below its lower bound")
        !isnothing(upper) && upper < value &&
            _semantic_fail(:decision_candidate_out_of_bounds, "decision candidate is above its upper bound")
        push!(candidate_signatures, _scenario_value_signature(candidate))
    end
    length(candidate_signatures) == length(unique(candidate_signatures)) ||
        _semantic_fail(:duplicate_decision_candidate, "decision variable repeats a candidate")
    variable.domain == DecisionDiscrete && isempty(variable.candidates) &&
        _semantic_fail(:empty_discrete_decision_domain, "discrete decision variable requires candidates")
    unit.per_unit &&
        _semantic_fail(:per_unit_decision_variable, "decision variable requires an explicit physical unit")
    return true
end

function _result_selector_field(project::CanonicalProject, selector::ResultSelector)
    contract = result_contract(project.orchestration, selector.contract)
    length(selector.path.segments) == 1 ||
        _semantic_fail(:unsupported_result_selector_path, "result selector currently requires one declared field")
    name = first(selector.path.segments).value
    index = findfirst(item -> item.name == name, contract.fields)
    isnothing(index) && _semantic_fail(:unknown_result_selector, "result selector field is absent from its contract")
    field = contract.fields[index]
    unit = lookup_unit(project.units, selector.unit)
    if field.kind == SchemaQuantity
        constraint = only(item for item in field.constraints if item isa QuantityConstraint)
        unit.dimension == constraint.dimension && selector.orientation in constraint.orientations ||
            _semantic_fail(:result_selector_contract_mismatch, "result selector unit/orientation differs from its contract")
    elseif field.kind == SchemaDecimal
        unit.dimension == dimensionless() && selector.orientation == OrientationScalar ||
            _semantic_fail(:result_selector_contract_mismatch, "decimal result selector must be scalar dimensionless")
    else
        _semantic_fail(:non_numeric_result_selector, "objective or constraint selector must target a numeric result field")
    end
    return field
end

function _validate_selector_bound(
    project::CanonicalProject,
    selector::ResultSelector,
    value::PhysicalValue{ScalarQuantity},
)
    validate_quantity(project.units, value)
    value.quantity.unit == selector.unit && value.quantity.orientation == selector.orientation &&
        isnothing(value.quantity.base) ||
        _semantic_fail(:constraint_bound_contract_mismatch, "constraint bound differs from its result selector")
    return exact_rational(value.quantity.value)
end

function _validate_objective(project::CanonicalProject, objective::ObjectiveDeclaration)
    _result_selector_field(project, objective.selector)
    _validate_registered_function(project, objective.function_identity)
    return true
end

function _validate_constraint(project::CanonicalProject, constraint::ConstraintDeclaration)
    _result_selector_field(project, constraint.selector)
    _validate_registered_function(project, constraint.function_identity)
    lower = isnothing(constraint.lower) ? nothing : _validate_selector_bound(project, constraint.selector, constraint.lower)
    upper = isnothing(constraint.upper) ? nothing : _validate_selector_bound(project, constraint.selector, constraint.upper)
    !isnothing(lower) && !isnothing(upper) && upper < lower &&
        _semantic_fail(:invalid_constraint_bounds, "constraint lower bound exceeds upper bound")
    return true
end

function _experiment_workflow(project::CanonicalProject, reference::ProjectReference)
    reference.target isa LocalReferenceTarget ||
        _semantic_fail(:external_experiment_workflow, "experiment workflow must be project-local")
    isempty(reference.path.tokens) ||
        _semantic_fail(:experiment_workflow_path, "experiment workflow cannot select a subfield")
    return workflow_definition(project.orchestration, reference.target.id)
end

function _validate_experiment_common(
    project::CanonicalProject,
    variables,
    evaluation::ProjectReference,
    execution::ExperimentExecution,
    checkpoint::ExperimentCheckpoint,
)
    foreach(variable -> _validate_decision_variable(project, variable), variables)
    _experiment_workflow(project, evaluation)
    _registered_orchestration_type(project, execution.rng, :unknown_experiment_rng_namespace)
    _registered_orchestration_type(project, checkpoint.schema, :unknown_experiment_checkpoint_namespace)
    return true
end

function _validate_checkpoint_bound(checkpoint::ExperimentCheckpoint, maximum_evaluations::Integer)
    checkpoint.every_evaluations <= maximum_evaluations ||
        _semantic_fail(:unreachable_experiment_checkpoint, "checkpoint interval exceeds the bounded evaluation count")
    return true
end

function _validate_stopping(project::CanonicalProject, stopping::ExperimentStoppingCriteria)
    return _validate_registered_function(project, stopping.convergence)
end

function _validate_solver(project::CanonicalProject, solver::ExperimentSolverDeclaration)
    _validate_registered_function(project, solver.implementation)
    foreach(option -> _validate_orchestration_value(project, option.value), solver.options)
    return true
end

function _validate_experiment(project::CanonicalProject, experiment::ExperimentDeclaration)
    if experiment isa ParameterSweepExperiment
        _validate_experiment_common(
            project,
            experiment.variables,
            experiment.evaluation,
            experiment.execution,
            experiment.checkpoint,
        )
        evaluations = prod(BigInt(length(variable.candidates)) for variable in experiment.variables)
        _validate_checkpoint_bound(experiment.checkpoint, evaluations)
    elseif experiment isa BoundedIterationExperiment
        _validate_experiment_common(project, experiment.variables, experiment.evaluation, experiment.execution, experiment.checkpoint)
        _validate_registered_function(project, experiment.update)
        _validate_stopping(project, experiment.stopping)
        _validate_checkpoint_bound(experiment.checkpoint, experiment.stopping.maximum_evaluations)
    elseif experiment isa UncertaintyExperiment
        variables = DecisionVariable[input.variable for input in experiment.inputs]
        _validate_experiment_common(project, variables, experiment.evaluation, experiment.execution, experiment.checkpoint)
        _validate_registered_function(project, experiment.sampler)
        _validate_checkpoint_bound(experiment.checkpoint, experiment.samples)
        for input in experiment.inputs
            probe = PhysicalValue(
                ScalarQuantity(parse_exact_decimal("0.0"), input.variable.unit, input.variable.orientation),
                input.variable.provenance;
                uncertainty = input.uncertainty,
            )
            validate_quantity(project.units, probe)
        end
    else
        _validate_experiment_common(project, experiment.variables, experiment.evaluation, experiment.execution, experiment.checkpoint)
        foreach(objective -> _validate_objective(project, objective), experiment.objectives)
        foreach(constraint -> _validate_constraint(project, constraint), experiment.constraints)
        _validate_solver(project, experiment.solver)
        _validate_stopping(project, experiment.stopping)
        _validate_checkpoint_bound(experiment.checkpoint, experiment.stopping.maximum_evaluations)
    end
    return true
end

function _experiment_owner_ids(experiment::ExperimentDeclaration)
    ids = ProjectId[experiment.identity.id]
    if experiment isa UncertaintyExperiment
        append!(ids, [item.variable.identity.id for item in experiment.inputs])
    else
        append!(ids, [item.identity.id for item in experiment.variables])
    end
    if experiment isa Union{CalibrationExperiment,OptimizationExperiment}
        append!(ids, [item.identity.id for item in experiment.objectives])
        append!(ids, [item.identity.id for item in experiment.constraints])
    end
    return ids
end

function _orchestration_owner_ids(model::OrchestrationModel)
    ids = ProjectId[]
    for study in model.studies
        push!(ids, study.identity.id)
        append!(ids, [item.identity.id for item in study.outputs])
        append!(ids, [item.identity.id for item in study.prerequisites])
    end
    append!(ids, [item.identity.id for item in model.results])
    for workflow in model.workflows
        push!(ids, workflow.identity.id)
        append!(ids, [item.identity.id for item in workflow.steps])
    end
    for experiment in model.experiments
        append!(ids, _experiment_owner_ids(experiment))
    end
    return ids
end

function _orchestration_graph_owner_ids(model::OrchestrationModel)
    return vcat(
        ProjectId[item.identity.id for item in model.studies],
        ProjectId[item.identity.id for item in model.results],
        ProjectId[item.identity.id for item in model.workflows],
        ProjectId[item.identity.id for item in model.experiments],
    )
end

"""Validate typed studies, result freshness, workflow DAGs, and bounded experiments without execution."""
function validate_orchestration(
    project::CanonicalProject;
    scenario_source::CanonicalProject = project,
)
    model = project.orchestration
    registered_namespaces = Set(item.namespace for item in project.registry.namespaces)
    for schema in model.study_schemas
        schema.identity.namespace in registered_namespaces ||
            _semantic_fail(:unknown_study_schema_namespace, "study schema namespace is not registered")
    end
    for contract in model.result_contracts
        contract.identity.namespace in registered_namespaces ||
            _semantic_fail(:unknown_result_contract_namespace, "result contract namespace is not registered")
    end
    owner_ids = _orchestration_owner_ids(model)
    length(owner_ids) == length(unique(owner_ids)) ||
        _semantic_fail(:duplicate_orchestration_identity, "orchestration model repeats an owner identity")
    other_ids = Set(vcat(
        [project.metadata.identity.id],
        [item.identity.id for item in project.records],
        _graph_element_ids(project.graphs),
        [item.identity.id for item in project.asset_library.assets],
        [item.identity.id for item in project.asset_library.profiles],
        [item.identity.id for item in project.asset_library.curves],
        [item.identity.id for item in project.asset_library.matrices],
        [item.identity.id for item in project.asset_library.measurements],
        [item.identity.id for item in project.hierarchy.instances],
        _control_owner_ids(project.control_system),
        _event_scenario_owner_ids(project.event_scenarios),
    ))
    isempty(intersect(other_ids, Set(owner_ids))) ||
        _semantic_fail(:orchestration_identity_collision, "orchestration owner collides with other project semantics")
    foreach(study -> _validate_study_request(project, study), model.studies)
    _validate_study_graph(model)
    foreach(result -> _validate_result_declaration(project, result, scenario_source), model.results)
    foreach(workflow -> _validate_workflow(project, workflow), model.workflows)
    foreach(experiment -> _validate_experiment(project, experiment), model.experiments)
    return true
end
