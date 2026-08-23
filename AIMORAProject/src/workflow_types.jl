@enum WorkflowFailurePolicy::UInt8 begin
    WorkflowStopOnFailure = 0x01
    WorkflowSkipDependents = 0x02
    WorkflowContinueIndependent = 0x03
end

@enum WorkflowCachePolicy::UInt8 begin
    WorkflowUseValidCache = 0x01
    WorkflowRecompute = 0x02
    WorkflowCacheProhibited = 0x03
end

abstract type WorkflowInputSource end

"""A binding to one already accepted result with exact expected hashes."""
struct ExistingResultSource <: WorkflowInputSource
    result::ProjectReference
    contract::SemanticSchemaIdentity
    project_revision::ContentDigest
    scenario_hash::Union{Nothing,ContentDigest}
    study_request_hash::ContentDigest

    function ExistingResultSource(
        result::ProjectReference,
        contract::SemanticSchemaIdentity,
        project_revision::ContentDigest,
        scenario_hash::Union{Nothing,ContentDigest},
        study_request_hash::ContentDigest,
    )
        result.kind == ReferenceResult ||
            _semantic_fail(:invalid_workflow_result_source, "workflow result source requires a result reference")
        return new(result, contract, project_revision, scenario_hash, study_request_hash)
    end
end

Base.:(==)(left::ExistingResultSource, right::ExistingResultSource) =
    left.result == right.result && left.contract == right.contract &&
    left.project_revision == right.project_revision && left.scenario_hash == right.scenario_hash &&
    left.study_request_hash == right.study_request_hash

"""A binding to the future typed output of one explicit upstream workflow step."""
struct StepResultSource <: WorkflowInputSource
    step::ProjectId
    contract::SemanticSchemaIdentity
end

Base.:(==)(left::StepResultSource, right::StepResultSource) =
    left.step == right.step && left.contract == right.contract

const CanonicalWorkflowInputSource = Union{ExistingResultSource,StepResultSource}

struct WorkflowInputBinding
    name::String
    source::Union{Nothing,CanonicalWorkflowInputSource}
    required::Bool

    function WorkflowInputBinding(
        name::AbstractString,
        source::Union{Nothing,CanonicalWorkflowInputSource},
        required::Bool,
    )
        normalized = _portable_control_name(name, :invalid_workflow_input_name)
        required && isnothing(source) &&
            _semantic_fail(:missing_required_workflow_input, "required workflow input needs a source")
        return new(normalized, source, required)
    end
end

Base.:(==)(left::WorkflowInputBinding, right::WorkflowInputBinding) =
    left.name == right.name && left.source == right.source && left.required == right.required

struct WorkflowStep
    identity::ObjectIdentity
    study::ProjectReference
    depends_on::CanonicalList{ProjectId}
    inputs::CanonicalList{WorkflowInputBinding}
    provenance::ProvenanceSource

    function WorkflowStep(
        identity::ObjectIdentity,
        study::ProjectReference,
        depends_on::AbstractVector{ProjectId},
        inputs::AbstractVector{WorkflowInputBinding},
        provenance::ProvenanceSource,
    )
        study.kind == ReferenceStudy ||
            _semantic_fail(:invalid_workflow_study, "workflow step requires a study reference")
        dependency_copy = sort!(collect(depends_on); by = item -> item.value)
        length(dependency_copy) == length(unique(dependency_copy)) ||
            _semantic_fail(:duplicate_workflow_dependency, "workflow step repeats a dependency")
        input_copy = sort!(collect(inputs); by = item -> item.name)
        input_names = getfield.(input_copy, :name)
        length(input_names) == length(unique(input_names)) ||
            _semantic_fail(:duplicate_workflow_input, "workflow step repeats an input name")
        return new(
            identity,
            study,
            CanonicalList{ProjectId}(dependency_copy),
            CanonicalList{WorkflowInputBinding}(input_copy),
            provenance,
        )
    end
end

Base.:(==)(left::WorkflowStep, right::WorkflowStep) =
    left.identity == right.identity && left.study == right.study &&
    left.depends_on == right.depends_on && left.inputs == right.inputs &&
    left.provenance == right.provenance

"""One deterministic declarative workflow DAG; no step is executed by this package."""
struct WorkflowDefinition
    identity::ObjectIdentity
    steps::CanonicalList{WorkflowStep}
    failure::WorkflowFailurePolicy
    cache::WorkflowCachePolicy
    provenance::ProvenanceSource

    function WorkflowDefinition(
        identity::ObjectIdentity,
        steps::AbstractVector{WorkflowStep},
        failure::WorkflowFailurePolicy,
        cache::WorkflowCachePolicy,
        provenance::ProvenanceSource,
    )
        copied = sort!(collect(steps); by = item -> item.identity.id.value)
        isempty(copied) && _semantic_fail(:empty_workflow, "workflow requires at least one step")
        ids = getfield.(getfield.(copied, :identity), :id)
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_workflow_step, "workflow repeats a step identity")
        return new(identity, CanonicalList{WorkflowStep}(copied), failure, cache, provenance)
    end
end

Base.:(==)(left::WorkflowDefinition, right::WorkflowDefinition) =
    left.identity == right.identity && left.steps == right.steps &&
    left.failure == right.failure && left.cache == right.cache &&
    left.provenance == right.provenance
