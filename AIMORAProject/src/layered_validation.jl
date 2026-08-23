@enum ProjectValidationLayer::UInt8 begin
    ValidationIdentitySchema = 0x01
    ValidationReferencesTopology = 0x02
    ValidationAssetsRealizations = 0x03
    ValidationHierarchyControls = 0x04
    ValidationStudiesWorkflows = 0x05
    ValidationEventsScenarios = 0x06
end

struct LayerValidationResult
    layer::ProjectValidationLayer
    passed::Bool
    error_code::Union{Nothing,Symbol}
    message::String

    function LayerValidationResult(
        layer::ProjectValidationLayer,
        passed::Bool,
        error_code::Union{Nothing,Symbol},
        message::AbstractString,
    )
        passed == isnothing(error_code) ||
            _semantic_fail(:validation_layer_result_mismatch, "layer result pass state differs from its error")
        return new(layer, passed, error_code, String(message))
    end
end

Base.:(==)(left::LayerValidationResult, right::LayerValidationResult) =
    left.layer == right.layer && left.passed == right.passed &&
    left.error_code == right.error_code && left.message == right.message

function _validate_identity_schema_layer(project::CanonicalProject)
    any(item -> item.namespace == project.metadata.default_namespace, project.registry.namespaces) ||
        _semantic_fail(:unknown_project_namespace, "project default namespace is not registered")
    foreach(record -> _validate_record(project, record), project.records)
    return true
end

function _layer_result(layer::ProjectValidationLayer, operation)
    try
        operation()
        return LayerValidationResult(layer, true, nothing, "")
    catch error
        error isa SemanticValidationError || rethrow()
        return LayerValidationResult(layer, false, error.code, error.message)
    end
end

"""Run all semantic validation layers and return typed deterministic diagnostics."""
function validate_project_layers(project::CanonicalProject)
    checks = (
        (ValidationIdentitySchema, () -> _validate_identity_schema_layer(project)),
        (ValidationReferencesTopology, () -> validate_graphs(project)),
        (ValidationAssetsRealizations, () -> validate_asset_library(project)),
        (ValidationHierarchyControls, () -> begin
            validate_hierarchy(project)
            validate_control_system(project)
        end),
        (ValidationStudiesWorkflows, () -> validate_orchestration(project)),
        (ValidationEventsScenarios, () -> validate_event_scenario_model(project)),
    )
    return CanonicalList{LayerValidationResult}(
        LayerValidationResult[_layer_result(layer, operation) for (layer, operation) in checks],
    )
end
