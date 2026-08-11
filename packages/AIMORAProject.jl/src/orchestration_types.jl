"""Immutable study, result, workflow, and experiment declarations owned by one project."""
struct OrchestrationModel
    study_schemas::CanonicalList{StudyRequestSchema}
    studies::CanonicalList{StudyRequest}
    result_contracts::CanonicalList{ResultContract}
    results::CanonicalList{ResultDeclaration}
    workflows::CanonicalList{WorkflowDefinition}
    experiments::CanonicalList{ExperimentDeclaration}

    function OrchestrationModel(;
        study_schemas::AbstractVector{StudyRequestSchema} = StudyRequestSchema[],
        studies::AbstractVector{StudyRequest} = StudyRequest[],
        result_contracts::AbstractVector{ResultContract} = ResultContract[],
        results::AbstractVector{ResultDeclaration} = ResultDeclaration[],
        workflows::AbstractVector{WorkflowDefinition} = WorkflowDefinition[],
        experiments::AbstractVector{<:ExperimentDeclaration} = ExperimentDeclaration[],
    )
        schema_copy = sort!(collect(study_schemas); by = item -> (
            item.identity.namespace.value,
            item.identity.name.value,
            item.identity.version,
        ))
        schema_keys = [(item.identity.namespace, item.identity.name, item.identity.version) for item in schema_copy]
        length(schema_keys) == length(unique(schema_keys)) ||
            _semantic_fail(:duplicate_study_schema, "orchestration model repeats a study schema")
        study_copy = sort!(collect(studies); by = item -> item.identity.id.value)
        result_contract_copy = sort!(collect(result_contracts); by = item -> (
            item.identity.namespace.value,
            item.identity.name.value,
            item.identity.version,
        ))
        contract_keys = [
            (item.identity.namespace, item.identity.name, item.identity.version)
            for item in result_contract_copy
        ]
        length(contract_keys) == length(unique(contract_keys)) ||
            _semantic_fail(:duplicate_result_contract, "orchestration model repeats a result contract")
        schema_identities = vcat(
            [item.identity for item in schema_copy],
            [item.identity for item in result_contract_copy],
        )
        schema_uuids = [item.uuid for item in schema_identities]
        length(schema_uuids) == length(unique(schema_uuids)) ||
            _semantic_fail(:orchestration_schema_uuid_collision, "orchestration schemas repeat one UUID")
        schema_keys_all = [(item.namespace, item.name, item.version) for item in schema_identities]
        length(schema_keys_all) == length(unique(schema_keys_all)) ||
            _semantic_fail(:orchestration_schema_identity_collision, "study and result schemas share one identity")
        result_copy = sort!(collect(results); by = item -> item.identity.id.value)
        workflow_copy = sort!(collect(workflows); by = item -> item.identity.id.value)
        experiment_copy = sort!(ExperimentDeclaration[item for item in experiments]; by = item -> item.identity.id.value)
        for (items, code, message) in (
            (study_copy, :duplicate_study, "orchestration model repeats a study identity"),
            (result_copy, :duplicate_result, "orchestration model repeats a result identity"),
            (workflow_copy, :duplicate_workflow, "orchestration model repeats a workflow identity"),
            (experiment_copy, :duplicate_experiment, "orchestration model repeats an experiment identity"),
        )
            ids = [item.identity.id for item in items]
            length(ids) == length(unique(ids)) || _semantic_fail(code, message)
        end
        return new(
            CanonicalList{StudyRequestSchema}(schema_copy),
            CanonicalList{StudyRequest}(study_copy),
            CanonicalList{ResultContract}(result_contract_copy),
            CanonicalList{ResultDeclaration}(result_copy),
            CanonicalList{WorkflowDefinition}(workflow_copy),
            CanonicalList{ExperimentDeclaration}(experiment_copy),
        )
    end
end

Base.:(==)(left::OrchestrationModel, right::OrchestrationModel) =
    left.study_schemas == right.study_schemas && left.studies == right.studies &&
    left.result_contracts == right.result_contracts && left.results == right.results &&
    left.workflows == right.workflows && left.experiments == right.experiments

function study_schema(model::OrchestrationModel, identity::SemanticSchemaIdentity)
    index = findfirst(item -> item.identity == identity, model.study_schemas)
    isnothing(index) && _semantic_fail(:unknown_study_schema, "study request schema is not registered")
    return model.study_schemas[index]
end

function study_request(model::OrchestrationModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.studies)
    isnothing(index) && _semantic_fail(:unknown_study, "study request does not exist")
    return model.studies[index]
end

function result_contract(model::OrchestrationModel, identity::SemanticSchemaIdentity)
    index = findfirst(item -> item.identity == identity, model.result_contracts)
    isnothing(index) && _semantic_fail(:unknown_result_contract, "result contract is not registered")
    return model.result_contracts[index]
end

function result_declaration(model::OrchestrationModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.results)
    isnothing(index) && _semantic_fail(:unknown_result, "result declaration does not exist")
    return model.results[index]
end

function workflow_definition(model::OrchestrationModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.workflows)
    isnothing(index) && _semantic_fail(:unknown_workflow, "workflow definition does not exist")
    return model.workflows[index]
end

function experiment_declaration(model::OrchestrationModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.experiments)
    isnothing(index) && _semantic_fail(:unknown_experiment, "experiment declaration does not exist")
    return model.experiments[index]
end
