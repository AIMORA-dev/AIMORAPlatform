@enum DecisionDomain::UInt8 begin
    DecisionContinuous = 0x01
    DecisionInteger = 0x02
    DecisionDiscrete = 0x03
end

@enum ObjectiveSense::UInt8 begin
    ObjectiveMinimize = 0x01
    ObjectiveMaximize = 0x02
end

@enum ExperimentExecutionOrder::UInt8 begin
    ExperimentSerial = 0x01
    ExperimentParallelDeterministic = 0x02
end

@enum ExperimentTerminationAction::UInt8 begin
    ExperimentTerminationError = 0x01
    ExperimentTerminationReport = 0x02
    ExperimentTerminationAcceptBest = 0x03
end

@enum ExperimentFailurePolicy::UInt8 begin
    ExperimentStopOnFailure = 0x01
    ExperimentContinueIndependent = 0x02
end

@enum ExperimentCachePolicy::UInt8 begin
    ExperimentUseValidCache = 0x01
    ExperimentRecompute = 0x02
    ExperimentCacheProhibited = 0x03
end

"""One declared project field which an experiment alone may vary."""
struct DecisionVariable
    identity::ObjectIdentity
    target::ProjectReference
    path::FieldPath
    unit::UnitId
    orientation::QuantityOrientation
    domain::DecisionDomain
    lower::Union{Nothing,PhysicalValue{ScalarQuantity}}
    upper::Union{Nothing,PhysicalValue{ScalarQuantity}}
    candidates::CanonicalList{CanonicalFieldData}
    provenance::ProvenanceSource

    function DecisionVariable(
        identity::ObjectIdentity,
        target::ProjectReference,
        path::FieldPath,
        unit::UnitId,
        orientation::QuantityOrientation,
        domain::DecisionDomain,
        lower::Union{Nothing,PhysicalValue{ScalarQuantity}},
        upper::Union{Nothing,PhysicalValue{ScalarQuantity}},
        candidates::AbstractVector{<:CanonicalFieldData},
        provenance::ProvenanceSource,
    )
        copied = CanonicalFieldData[
            item isa String ? String(item) : item for item in candidates
        ]
        return new(
            identity,
            target,
            path,
            unit,
            orientation,
            domain,
            lower,
            upper,
            CanonicalList{CanonicalFieldData}(copied),
            provenance,
        )
    end
end

Base.:(==)(left::DecisionVariable, right::DecisionVariable) =
    left.identity == right.identity && left.target == right.target &&
    left.path == right.path && left.unit == right.unit &&
    left.orientation == right.orientation && left.domain == right.domain &&
    left.lower == right.lower && left.upper == right.upper &&
    left.candidates == right.candidates && left.provenance == right.provenance

struct ResultSelector
    contract::SemanticSchemaIdentity
    path::FieldPath
    unit::UnitId
    orientation::QuantityOrientation
end

Base.:(==)(left::ResultSelector, right::ResultSelector) =
    left.contract == right.contract && left.path == right.path &&
    left.unit == right.unit && left.orientation == right.orientation

struct ObjectiveDeclaration
    identity::ObjectIdentity
    selector::ResultSelector
    function_identity::RegisteredFunctionIdentity
    sense::ObjectiveSense
    weight::ExactDecimal
    provenance::ProvenanceSource

    function ObjectiveDeclaration(
        identity::ObjectIdentity,
        selector::ResultSelector,
        function_identity::RegisteredFunctionIdentity,
        sense::ObjectiveSense,
        weight::ExactDecimal,
        provenance::ProvenanceSource,
    )
        ExactRational(0) < exact_rational(weight) ||
            _semantic_fail(:invalid_objective_weight, "objective weight must be positive")
        return new(identity, selector, function_identity, sense, weight, provenance)
    end
end

Base.:(==)(left::ObjectiveDeclaration, right::ObjectiveDeclaration) =
    left.identity == right.identity && left.selector == right.selector &&
    left.function_identity == right.function_identity && left.sense == right.sense &&
    left.weight == right.weight && left.provenance == right.provenance

struct ConstraintDeclaration
    identity::ObjectIdentity
    selector::ResultSelector
    function_identity::RegisteredFunctionIdentity
    lower::Union{Nothing,PhysicalValue{ScalarQuantity}}
    upper::Union{Nothing,PhysicalValue{ScalarQuantity}}
    provenance::ProvenanceSource

    function ConstraintDeclaration(
        identity::ObjectIdentity,
        selector::ResultSelector,
        function_identity::RegisteredFunctionIdentity,
        lower::Union{Nothing,PhysicalValue{ScalarQuantity}},
        upper::Union{Nothing,PhysicalValue{ScalarQuantity}},
        provenance::ProvenanceSource,
    )
        isnothing(lower) && isnothing(upper) &&
            _semantic_fail(:empty_experiment_constraint, "constraint requires a lower or upper bound")
        return new(identity, selector, function_identity, lower, upper, provenance)
    end
end

Base.:(==)(left::ConstraintDeclaration, right::ConstraintDeclaration) =
    left.identity == right.identity && left.selector == right.selector &&
    left.function_identity == right.function_identity && left.lower == right.lower &&
    left.upper == right.upper && left.provenance == right.provenance

struct ExperimentSolverDeclaration
    implementation::RegisteredFunctionIdentity
    options::CanonicalList{CanonicalField}

    function ExperimentSolverDeclaration(
        implementation::RegisteredFunctionIdentity,
        options::AbstractVector{CanonicalField},
    )
        copied = sort!(collect(options); by = item -> item.name)
        names = getfield.(copied, :name)
        length(names) == length(unique(names)) ||
            _semantic_fail(:duplicate_experiment_solver_option, "experiment solver repeats an option")
        return new(implementation, CanonicalList{CanonicalField}(copied))
    end
end

Base.:(==)(left::ExperimentSolverDeclaration, right::ExperimentSolverDeclaration) =
    left.implementation == right.implementation && left.options == right.options

"""Finite stopping and explicit convergence, stagnation, and infeasibility contracts."""
struct ExperimentStoppingCriteria
    maximum_iterations::Int
    maximum_evaluations::Int
    tolerance::ExactDecimal
    stagnation_iterations::Int
    convergence::RegisteredFunctionIdentity
    on_stagnation::ExperimentTerminationAction
    on_infeasible::ExperimentTerminationAction

    function ExperimentStoppingCriteria(
        maximum_iterations::Integer,
        maximum_evaluations::Integer,
        tolerance::ExactDecimal,
        stagnation_iterations::Integer,
        convergence::RegisteredFunctionIdentity,
        on_stagnation::ExperimentTerminationAction,
        on_infeasible::ExperimentTerminationAction,
    )
        iterations = try
            Int(maximum_iterations)
        catch
            _semantic_fail(:invalid_experiment_iteration_bound, "experiment iteration bound exceeds Int")
        end
        evaluations = try
            Int(maximum_evaluations)
        catch
            _semantic_fail(:invalid_experiment_evaluation_bound, "experiment evaluation bound exceeds Int")
        end
        stagnation = try
            Int(stagnation_iterations)
        catch
            _semantic_fail(:invalid_experiment_stagnation_bound, "experiment stagnation bound exceeds Int")
        end
        iterations > 0 ||
            _semantic_fail(:invalid_experiment_iteration_bound, "experiment iteration bound must be positive")
        evaluations > 0 ||
            _semantic_fail(:invalid_experiment_evaluation_bound, "experiment evaluation bound must be positive")
        0 < stagnation <= iterations ||
            _semantic_fail(:invalid_experiment_stagnation_bound, "stagnation bound must be in [1, maximum_iterations]")
        ExactRational(0) < exact_rational(tolerance) ||
            _semantic_fail(:invalid_experiment_tolerance, "experiment tolerance must be positive")
        return new(
            iterations,
            evaluations,
            tolerance,
            stagnation,
            convergence,
            on_stagnation,
            on_infeasible,
        )
    end
end

Base.:(==)(left::ExperimentStoppingCriteria, right::ExperimentStoppingCriteria) =
    left.maximum_iterations == right.maximum_iterations &&
    left.maximum_evaluations == right.maximum_evaluations &&
    left.tolerance == right.tolerance &&
    left.stagnation_iterations == right.stagnation_iterations &&
    left.convergence == right.convergence && left.on_stagnation == right.on_stagnation &&
    left.on_infeasible == right.on_infeasible

struct ExperimentExecution
    order::ExperimentExecutionOrder
    workers::Int
    seed::UInt64
    rng::SemanticTypeId

    function ExperimentExecution(
        order::ExperimentExecutionOrder,
        workers::Integer,
        seed::Integer,
        rng::SemanticTypeId,
    )
        worker_count = try
            Int(workers)
        catch
            _semantic_fail(:invalid_experiment_workers, "experiment worker count exceeds Int")
        end
        worker_count > 0 ||
            _semantic_fail(:invalid_experiment_workers, "experiment requires at least one worker")
        order == ExperimentSerial && worker_count != 1 &&
            _semantic_fail(:serial_experiment_workers, "serial experiment requires exactly one worker")
        order == ExperimentParallelDeterministic && worker_count < 2 &&
            _semantic_fail(:parallel_experiment_workers, "parallel experiment requires at least two workers")
        normalized_seed = try
            UInt64(seed)
        catch
            _semantic_fail(:invalid_experiment_seed, "experiment seed must fit UInt64")
        end
        return new(order, worker_count, normalized_seed, rng)
    end
end

Base.:(==)(left::ExperimentExecution, right::ExperimentExecution) =
    left.order == right.order && left.workers == right.workers &&
    left.seed == right.seed && left.rng == right.rng

struct ExperimentCheckpoint
    schema::SemanticTypeId
    every_evaluations::Int
    retain::Int
    resume::Bool

    function ExperimentCheckpoint(
        schema::SemanticTypeId,
        every_evaluations::Integer,
        retain::Integer,
        resume::Bool,
    )
        every = try
            Int(every_evaluations)
        catch
            _semantic_fail(:invalid_experiment_checkpoint_interval, "checkpoint interval exceeds Int")
        end
        retained = try
            Int(retain)
        catch
            _semantic_fail(:invalid_experiment_checkpoint_retention, "checkpoint retention exceeds Int")
        end
        every > 0 ||
            _semantic_fail(:invalid_experiment_checkpoint_interval, "checkpoint interval must be positive")
        retained > 0 ||
            _semantic_fail(:invalid_experiment_checkpoint_retention, "checkpoint retention must be positive")
        return new(schema, every, retained, resume)
    end
end

Base.:(==)(left::ExperimentCheckpoint, right::ExperimentCheckpoint) =
    left.schema == right.schema && left.every_evaluations == right.every_evaluations &&
    left.retain == right.retain && left.resume == right.resume

struct ExperimentPolicies
    failure::ExperimentFailurePolicy
    cache::ExperimentCachePolicy
end

Base.:(==)(left::ExperimentPolicies, right::ExperimentPolicies) =
    left.failure == right.failure && left.cache == right.cache

function _ordered_variables(variables::AbstractVector{DecisionVariable})
    copied = sort!(collect(variables); by = item -> item.identity.id.value)
    ids = getfield.(getfield.(copied, :identity), :id)
    length(ids) == length(unique(ids)) ||
        _semantic_fail(:duplicate_decision_variable, "experiment repeats a decision variable")
    return CanonicalList{DecisionVariable}(copied)
end

function _ordered_objectives(objectives::AbstractVector{ObjectiveDeclaration})
    copied = sort!(collect(objectives); by = item -> item.identity.id.value)
    ids = getfield.(getfield.(copied, :identity), :id)
    length(ids) == length(unique(ids)) ||
        _semantic_fail(:duplicate_objective, "experiment repeats an objective")
    return CanonicalList{ObjectiveDeclaration}(copied)
end

function _ordered_constraints(constraints::AbstractVector{ConstraintDeclaration})
    copied = sort!(collect(constraints); by = item -> item.identity.id.value)
    ids = getfield.(getfield.(copied, :identity), :id)
    length(ids) == length(unique(ids)) ||
        _semantic_fail(:duplicate_experiment_constraint, "experiment repeats a constraint")
    return CanonicalList{ConstraintDeclaration}(copied)
end

function _workflow_reference(reference::ProjectReference)
    reference.kind == ReferenceWorkflow ||
        _semantic_fail(:invalid_experiment_workflow, "experiment evaluation requires a workflow reference")
    return reference
end

abstract type ExperimentDeclaration end

struct ParameterSweepExperiment <: ExperimentDeclaration
    identity::ObjectIdentity
    variables::CanonicalList{DecisionVariable}
    evaluation::ProjectReference
    execution::ExperimentExecution
    checkpoint::ExperimentCheckpoint
    policies::ExperimentPolicies
    provenance::ProvenanceSource

    function ParameterSweepExperiment(
        identity::ObjectIdentity,
        variables::AbstractVector{DecisionVariable},
        evaluation::ProjectReference,
        execution::ExperimentExecution,
        checkpoint::ExperimentCheckpoint,
        policies::ExperimentPolicies,
        provenance::ProvenanceSource,
    )
        ordered = _ordered_variables(variables)
        isempty(ordered) && _semantic_fail(:empty_parameter_sweep, "parameter sweep requires variables")
        all(variable -> !isempty(variable.candidates), ordered) ||
            _semantic_fail(:unbounded_parameter_sweep, "parameter sweep variable requires finite candidates")
        return new(identity, ordered, _workflow_reference(evaluation), execution, checkpoint, policies, provenance)
    end
end

Base.:(==)(left::ParameterSweepExperiment, right::ParameterSweepExperiment) =
    left.identity == right.identity && left.variables == right.variables &&
    left.evaluation == right.evaluation && left.execution == right.execution &&
    left.checkpoint == right.checkpoint && left.policies == right.policies &&
    left.provenance == right.provenance

struct BoundedIterationExperiment <: ExperimentDeclaration
    identity::ObjectIdentity
    variables::CanonicalList{DecisionVariable}
    update::RegisteredFunctionIdentity
    evaluation::ProjectReference
    stopping::ExperimentStoppingCriteria
    execution::ExperimentExecution
    checkpoint::ExperimentCheckpoint
    policies::ExperimentPolicies
    provenance::ProvenanceSource

    function BoundedIterationExperiment(
        identity::ObjectIdentity,
        variables::AbstractVector{DecisionVariable},
        update::RegisteredFunctionIdentity,
        evaluation::ProjectReference,
        stopping::ExperimentStoppingCriteria,
        execution::ExperimentExecution,
        checkpoint::ExperimentCheckpoint,
        policies::ExperimentPolicies,
        provenance::ProvenanceSource,
    )
        ordered = _ordered_variables(variables)
        isempty(ordered) && _semantic_fail(:empty_bounded_iteration, "bounded iteration requires variables")
        return new(
            identity,
            ordered,
            update,
            _workflow_reference(evaluation),
            stopping,
            execution,
            checkpoint,
            policies,
            provenance,
        )
    end
end

Base.:(==)(left::BoundedIterationExperiment, right::BoundedIterationExperiment) =
    left.identity == right.identity && left.variables == right.variables &&
    left.update == right.update && left.evaluation == right.evaluation &&
    left.stopping == right.stopping && left.execution == right.execution &&
    left.checkpoint == right.checkpoint && left.policies == right.policies &&
    left.provenance == right.provenance

struct CalibrationExperiment <: ExperimentDeclaration
    identity::ObjectIdentity
    variables::CanonicalList{DecisionVariable}
    objectives::CanonicalList{ObjectiveDeclaration}
    constraints::CanonicalList{ConstraintDeclaration}
    evaluation::ProjectReference
    solver::ExperimentSolverDeclaration
    stopping::ExperimentStoppingCriteria
    execution::ExperimentExecution
    checkpoint::ExperimentCheckpoint
    policies::ExperimentPolicies
    provenance::ProvenanceSource

    function CalibrationExperiment(
        identity::ObjectIdentity,
        variables::AbstractVector{DecisionVariable},
        objectives::AbstractVector{ObjectiveDeclaration},
        constraints::AbstractVector{ConstraintDeclaration},
        evaluation::ProjectReference,
        solver::ExperimentSolverDeclaration,
        stopping::ExperimentStoppingCriteria,
        execution::ExperimentExecution,
        checkpoint::ExperimentCheckpoint,
        policies::ExperimentPolicies,
        provenance::ProvenanceSource,
    )
        ordered_variables = _ordered_variables(variables)
        ordered_objectives = _ordered_objectives(objectives)
        isempty(ordered_variables) && _semantic_fail(:empty_calibration_variables, "calibration requires variables")
        isempty(ordered_objectives) && _semantic_fail(:empty_calibration_objectives, "calibration requires objectives")
        return new(
            identity,
            ordered_variables,
            ordered_objectives,
            _ordered_constraints(constraints),
            _workflow_reference(evaluation),
            solver,
            stopping,
            execution,
            checkpoint,
            policies,
            provenance,
        )
    end
end

Base.:(==)(left::CalibrationExperiment, right::CalibrationExperiment) =
    left.identity == right.identity && left.variables == right.variables &&
    left.objectives == right.objectives && left.constraints == right.constraints &&
    left.evaluation == right.evaluation && left.solver == right.solver &&
    left.stopping == right.stopping && left.execution == right.execution &&
    left.checkpoint == right.checkpoint && left.policies == right.policies &&
    left.provenance == right.provenance

struct UncertainInput
    variable::DecisionVariable
    uncertainty::QuantityUncertainty
end

Base.:(==)(left::UncertainInput, right::UncertainInput) =
    left.variable == right.variable && left.uncertainty == right.uncertainty

struct UncertaintyExperiment <: ExperimentDeclaration
    identity::ObjectIdentity
    inputs::CanonicalList{UncertainInput}
    samples::Int
    sampler::RegisteredFunctionIdentity
    evaluation::ProjectReference
    execution::ExperimentExecution
    checkpoint::ExperimentCheckpoint
    policies::ExperimentPolicies
    provenance::ProvenanceSource

    function UncertaintyExperiment(
        identity::ObjectIdentity,
        inputs::AbstractVector{UncertainInput},
        samples::Integer,
        sampler::RegisteredFunctionIdentity,
        evaluation::ProjectReference,
        execution::ExperimentExecution,
        checkpoint::ExperimentCheckpoint,
        policies::ExperimentPolicies,
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(inputs); by = item -> item.variable.identity.id.value)
        isempty(copied) && _semantic_fail(:empty_uncertainty_inputs, "uncertainty experiment requires inputs")
        ids = [item.variable.identity.id for item in copied]
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_uncertainty_input, "uncertainty experiment repeats an input")
        sample_count = try
            Int(samples)
        catch
            _semantic_fail(:invalid_uncertainty_sample_count, "uncertainty sample count exceeds Int")
        end
        sample_count > 0 ||
            _semantic_fail(:invalid_uncertainty_sample_count, "uncertainty sample count must be positive")
        return new(
            identity,
            CanonicalList{UncertainInput}(copied),
            sample_count,
            sampler,
            _workflow_reference(evaluation),
            execution,
            checkpoint,
            policies,
            provenance,
        )
    end
end

Base.:(==)(left::UncertaintyExperiment, right::UncertaintyExperiment) =
    left.identity == right.identity && left.inputs == right.inputs &&
    left.samples == right.samples && left.sampler == right.sampler &&
    left.evaluation == right.evaluation && left.execution == right.execution &&
    left.checkpoint == right.checkpoint && left.policies == right.policies &&
    left.provenance == right.provenance

struct OptimizationExperiment <: ExperimentDeclaration
    identity::ObjectIdentity
    variables::CanonicalList{DecisionVariable}
    objectives::CanonicalList{ObjectiveDeclaration}
    constraints::CanonicalList{ConstraintDeclaration}
    evaluation::ProjectReference
    solver::ExperimentSolverDeclaration
    stopping::ExperimentStoppingCriteria
    execution::ExperimentExecution
    checkpoint::ExperimentCheckpoint
    policies::ExperimentPolicies
    provenance::ProvenanceSource

    function OptimizationExperiment(
        identity::ObjectIdentity,
        variables::AbstractVector{DecisionVariable},
        objectives::AbstractVector{ObjectiveDeclaration},
        constraints::AbstractVector{ConstraintDeclaration},
        evaluation::ProjectReference,
        solver::ExperimentSolverDeclaration,
        stopping::ExperimentStoppingCriteria,
        execution::ExperimentExecution,
        checkpoint::ExperimentCheckpoint,
        policies::ExperimentPolicies,
        provenance::ProvenanceSource,
    )
        ordered_variables = _ordered_variables(variables)
        ordered_objectives = _ordered_objectives(objectives)
        isempty(ordered_variables) && _semantic_fail(:empty_optimization_variables, "optimization requires variables")
        isempty(ordered_objectives) && _semantic_fail(:empty_optimization_objectives, "optimization requires objectives")
        return new(
            identity,
            ordered_variables,
            ordered_objectives,
            _ordered_constraints(constraints),
            _workflow_reference(evaluation),
            solver,
            stopping,
            execution,
            checkpoint,
            policies,
            provenance,
        )
    end
end

Base.:(==)(left::OptimizationExperiment, right::OptimizationExperiment) =
    left.identity == right.identity && left.variables == right.variables &&
    left.objectives == right.objectives && left.constraints == right.constraints &&
    left.evaluation == right.evaluation && left.solver == right.solver &&
    left.stopping == right.stopping && left.execution == right.execution &&
    left.checkpoint == right.checkpoint && left.policies == right.policies &&
    left.provenance == right.provenance
