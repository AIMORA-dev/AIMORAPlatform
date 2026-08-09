function _registered_semantic_namespace(project::CanonicalProject, type::SemanticTypeId, code::Symbol)
    any(item -> item.namespace == type.namespace, project.registry.namespaces) ||
        _semantic_fail(code, "event or scenario type namespace is not registered")
    return true
end

function _event_reference_exists(project::CanonicalProject, reference::ProjectReference)
    reference.target isa GlobalReferenceTarget && return true
    id = reference.target.id
    if reference.kind == ReferenceAsset
        _asset_or_record_exists(project, id) ||
            _semantic_fail(:dangling_event_target, "event asset target does not exist")
    elseif reference.kind == ReferenceNode
        _find_node(project.graphs, id)
    elseif reference.kind == ReferenceControlBlock
        id in Set(_control_owner_ids(project.control_system)) ||
            _semantic_fail(:dangling_event_target, "event control target does not exist")
    elseif reference.kind == ReferenceEvent
        event_declaration(project.event_scenarios, id)
    elseif reference.kind == ReferenceProfile
        any(item -> item.identity.id == id, project.asset_library.profiles) ||
            _semantic_fail(:dangling_event_target, "event profile target does not exist")
    else
        _semantic_fail(:invalid_event_target, "event reference kind is outside physical, control, event, and profile semantics")
    end
    return true
end

function _validate_event_field(project::CanonicalProject, value::CanonicalFieldData)
    if value isa PhysicalValue
        validate_quantity(project.units, value)
    elseif value isa ProjectReference
        _event_reference_exists(project, value)
    end
    return true
end

function _validate_condition_trigger(project::CanonicalProject, trigger::ConditionEventTrigger)
    _registered_semantic_namespace(project, trigger.surface, :unknown_event_surface_namespace)
    _registered_semantic_namespace(project, trigger.quantity, :unknown_event_quantity_namespace)
    validate_quantity(project.units, trigger.threshold)
    validate_quantity(project.units, trigger.hysteresis)
    isnothing(trigger.threshold.uncertainty) && isnothing(trigger.hysteresis.uncertainty) ||
        _semantic_fail(:uncertain_event_surface, "condition event threshold and hysteresis cannot carry uncertainty")
    threshold = trigger.threshold.quantity
    hysteresis = trigger.hysteresis.quantity
    threshold.unit == hysteresis.unit && threshold.orientation == hysteresis.orientation &&
        threshold.base == hysteresis.base ||
        _semantic_fail(:event_hysteresis_contract_mismatch, "condition event hysteresis differs from its threshold contract")
    ExactRational(0) <= exact_rational(hysteresis.value) ||
        _semantic_fail(:negative_event_hysteresis, "condition event hysteresis must be nonnegative")
    return true
end

function _validate_event_trigger(project::CanonicalProject, trigger::CanonicalEventTrigger)
    if trigger isa RelativeEventTrigger
        ExactRational(0) <= _time_value(project, trigger.time) ||
            _semantic_fail(:negative_relative_event_time, "relative event time must be nonnegative")
    elseif trigger isa SampledEventTrigger
        trigger.task.target isa LocalReferenceTarget ||
            _semantic_fail(:external_sampled_event_task, "sampled event task must be project-local")
        trigger.task.target.id in Set(_control_owner_ids(project.control_system)) ||
            _semantic_fail(:dangling_sampled_event_task, "sampled event task does not exist")
        isempty(trigger.task.path.tokens) ||
            _semantic_fail(:sampled_event_task_path, "sampled event task reference cannot select a subfield")
    elseif trigger isa ConditionEventTrigger
        _validate_condition_trigger(project, trigger)
    end
    return true
end

function _validate_event_reset(project::CanonicalProject, reset::EventResetDeclaration)
    reset.target.kind in (ReferenceAsset, ReferenceControlBlock) ||
        _semantic_fail(:invalid_event_reset_target, "event reset requires an asset or control-state target")
    isempty(reset.target.path.tokens) &&
        _semantic_fail(:missing_event_reset_path, "event reset must identify an explicit state or property path")
    _event_reference_exists(project, reset.target)
    !isnothing(reset.value) && _validate_event_field(project, reset.value)
    return true
end

function _validate_event(project::CanonicalProject, event::EventDeclaration)
    _registered_semantic_namespace(project, event.event_type, :unknown_event_type_namespace)
    event.target.kind in (ReferenceAsset, ReferenceNode, ReferenceControlBlock, ReferenceEvent) ||
        _semantic_fail(:invalid_event_target, "event target must be physical, control, or event semantics")
    _event_reference_exists(project, event.target)
    _validate_event_trigger(project, event.trigger)
    foreach(parameter -> _validate_event_field(project, parameter.value), event.parameters)
    foreach(reset -> _validate_event_reset(project, reset), event.resets)
    return true
end

function _reference_signature(reference::ProjectReference)
    target = reference.target isa LocalReferenceTarget ?
        "local:" * reference.target.id.value : "global:" * reference.target.id.uri
    path = join((token.value for token in reference.path.tokens), "/")
    return string(UInt8(reference.kind), ":", target, ":", path)
end

function _exact_time_signature(value::ExactRational)
    return string(value.numerator, "/", value.denominator, value.negative_zero ? ":negative-zero" : "")
end

function _event_trigger_signature(project::CanonicalProject, trigger::CanonicalEventTrigger)
    if trigger isa RelativeEventTrigger
        return "relative:" * _exact_time_signature(_time_value(project, trigger.time))
    elseif trigger isa AbsoluteEventTrigger
        return "absolute:" * Dates.format(trigger.at_utc, dateformat"yyyy-mm-ddTHH:MM:SS.sss")
    elseif trigger isa SampledEventTrigger
        return "sampled:" * _reference_signature(trigger.task) * ":" * string(trigger.tick)
    end
    condition = trigger::ConditionEventTrigger
    return "condition:" * condition.surface.namespace.value * ":" * condition.surface.name.value * ":" *
        string(condition.surface.version) * ":" * _scenario_value_signature(condition.threshold) * ":" *
        string(UInt8(condition.direction))
end

function _event_order_key(project::CanonicalProject, event::EventDeclaration)
    category = event.trigger isa RelativeEventTrigger ? 0x01 :
        event.trigger isa AbsoluteEventTrigger ? 0x02 :
        event.trigger isa SampledEventTrigger ? 0x03 : 0x04
    return (category, _event_trigger_signature(project, event.trigger), event.priority, event.identity.id.value)
end

"""Return enabled events in deterministic calendar, priority, and stable-ID order."""
function ordered_events(project::CanonicalProject)
    events = EventDeclaration[event for event in project.event_scenarios.events if event.enabled]
    sort!(events; by = event -> _event_order_key(project, event))
    return CanonicalList{EventDeclaration}(events)
end

function _validate_event_conflicts(project::CanonicalProject)
    seen = Set{Tuple{String,String,Int}}()
    for event in ordered_events(project)
        key = (
            _event_trigger_signature(project, event.trigger),
            _reference_signature(event.target),
            event.priority,
        )
        key in seen &&
            _semantic_fail(:conflicting_events, "enabled events share one trigger, target, and priority")
        push!(seen, key)
    end
    return true
end

function _scenario_patch_operation_valid(declaration::ScenarioPatchDeclaration)
    patch = declaration.patch
    patch isa UnsafeReplaceRecordsPatch &&
        _semantic_fail(:scenario_runtime_writeback_prohibited, "scenario cannot contain unsafe or runtime-state replacement")
    patch isa Union{AddScenarioDefinitionPatch,RemoveScenarioDefinitionPatch,ReplaceScenarioDefinitionPatch} &&
        _semantic_fail(:scenario_graph_mutation_prohibited, "scenario cannot mutate its own inheritance graph")
    operation = declaration.operation
    valid = if operation == ScenarioSet
        patch isa Union{SetRecordFieldPatch,SetAssetCommonPropertyPatch,SetInstanceParameterPatch,ReplaceEventDeclarationPatch,ReplaceControlNetworkPatch}
    elseif operation == ScenarioUnset
        patch isa Union{UnsetRecordFieldPatch,UnsetAssetCommonPropertyPatch,UnsetInstanceParameterPatch}
    elseif operation == ScenarioAdd
        patch isa Union{
            AddRecordPatch,
            AddAssetPatch,
            AddStudyRealizationPatch,
            AddAssetDataPatch,
            AddGraphElementPatch,
            AddReusableDefinitionPatch,
            AddDefinitionInstancePatch,
            AddDefinitionMigrationPatch,
            AddControlBlockSchemaPatch,
            AddControlNetworkPatch,
            AddEventDeclarationPatch,
        }
    elseif operation == ScenarioRemove
        patch isa Union{
            RemoveRecordPatch,
            RemoveAssetPatch,
            RemoveStudyRealizationPatch,
            RemoveAssetDataPatch,
            RemoveGraphElementPatch,
            RemoveReusableDefinitionPatch,
            RemoveDefinitionInstancePatch,
            RemoveDefinitionMigrationPatch,
            RemoveControlBlockSchemaPatch,
            RemoveControlNetworkPatch,
            RemoveEventDeclarationPatch,
        }
    elseif operation in (ScenarioEnable, ScenarioDisable)
        expected = operation == ScenarioEnable
        if patch isa SetEventEnabledPatch
            patch.enabled == expected
        elseif patch isa SetRecordFieldPatch
            patch.field.name == "enabled" && patch.field.value === expected
        elseif patch isa SetAssetCommonPropertyPatch
            last(patch.property.path.segments).value in ("enabled", "in_service") &&
                patch.property.value === expected
        else
            false
        end
    elseif operation == ScenarioConnect
        patch isa ConnectGraphPatch
    elseif operation == ScenarioDisconnect
        patch isa DisconnectGraphPatch
    elseif operation == ScenarioReplaceProfile
        patch isa SetAssetCommonPropertyPatch && patch.property.value isa ProjectReference &&
            patch.property.value.kind == ReferenceProfile
    else
        patch isa ReplaceStudyRealizationPatch
    end
    valid || _semantic_fail(:scenario_operation_patch_mismatch, "scenario operation does not match its typed project patch")
    return true
end

function _scenario_patch_owner(patch::ProjectPatch)
    if patch isa Union{AddRecordPatch,AddAssetPatch}
        return patch isa AddRecordPatch ? patch.record.identity.id : patch.asset.identity.id
    elseif patch isa Union{RemoveRecordPatch,RemoveAssetPatch,SetRecordFieldPatch,UnsetRecordFieldPatch,
        SetAssetCommonPropertyPatch,UnsetAssetCommonPropertyPatch,AddStudyRealizationPatch,
        RemoveStudyRealizationPatch,ReplaceStudyRealizationPatch}
        return patch.owner
    elseif patch isa AddAssetDataPatch
        return patch.element.identity.id
    elseif patch isa RemoveAssetDataPatch
        return patch.id
    elseif patch isa AddGraphElementPatch
        return patch.element.identity.id
    elseif patch isa RemoveGraphElementPatch
        return patch.id
    elseif patch isa ConnectGraphPatch
        return patch.connection.identity.id
    elseif patch isa DisconnectGraphPatch
        return patch.id
    elseif patch isa Union{AddReusableDefinitionPatch,AddDefinitionInstancePatch}
        return patch isa AddReusableDefinitionPatch ? patch.definition.identity.id : patch.instance.identity.id
    elseif patch isa Union{RemoveReusableDefinitionPatch,RemoveDefinitionInstancePatch}
        return patch.id
    elseif patch isa Union{SetInstanceParameterPatch,UnsetInstanceParameterPatch}
        return patch.instance
    elseif patch isa AddDefinitionMigrationPatch
        return patch.migration.definition
    elseif patch isa RemoveDefinitionMigrationPatch
        return patch.definition
    elseif patch isa AddControlBlockSchemaPatch
        return patch.schema.identity.name
    elseif patch isa RemoveControlBlockSchemaPatch
        return patch.identity.name
    elseif patch isa Union{AddControlNetworkPatch,ReplaceControlNetworkPatch}
        return patch.network.identity.id
    elseif patch isa RemoveControlNetworkPatch
        return patch.id
    elseif patch isa Union{AddEventDeclarationPatch,ReplaceEventDeclarationPatch}
        return patch.event.identity.id
    elseif patch isa Union{RemoveEventDeclarationPatch,SetEventEnabledPatch}
        return patch.id
    end
    _semantic_fail(:unsupported_scenario_patch, "scenario patch has no stable semantic owner")
end

function _scenario_mutation_key(declaration::ScenarioPatchDeclaration)
    patch = declaration.patch
    owner = _scenario_patch_owner(patch).value
    suffix = if patch isa Union{SetRecordFieldPatch,UnsetRecordFieldPatch}
        patch isa SetRecordFieldPatch ? patch.field.name : patch.field_name
    elseif patch isa Union{SetAssetCommonPropertyPatch,UnsetAssetCommonPropertyPatch}
        string(patch isa SetAssetCommonPropertyPatch ? patch.property.path : patch.path)
    elseif patch isa Union{SetInstanceParameterPatch,UnsetInstanceParameterPatch}
        patch isa SetInstanceParameterPatch ? patch.value.name : patch.parameter
    elseif patch isa Union{AddStudyRealizationPatch,ReplaceStudyRealizationPatch}
        patch.realization.id.value
    elseif patch isa RemoveStudyRealizationPatch
        patch.realization.value
    elseif patch isa SetEventEnabledPatch
        "enabled"
    else
        "owner"
    end
    return owner * ":" * suffix
end

function _validate_scenario_declaration(model::EventScenarioModel, scenario::ScenarioDefinition)
    if !isnothing(scenario.parent)
        scenario.parent.target isa LocalReferenceTarget ||
            _semantic_fail(:external_scenario_parent, "scenario parent must be project-local")
        isempty(scenario.parent.path.tokens) ||
            _semantic_fail(:scenario_parent_path, "scenario parent cannot select a subfield")
        scenario_definition(model, scenario.parent.target.id)
    end
    seen = Set{Tuple{Int,String}}()
    for declaration in scenario.patches
        _scenario_patch_operation_valid(declaration)
        key = (declaration.precedence, _scenario_mutation_key(declaration))
        key in seen &&
            _semantic_fail(:ambiguous_scenario_precedence, "scenario patches mutate one owner/path at the same precedence")
        push!(seen, key)
    end
    return true
end

function _validate_scenario_graph(model::EventScenarioModel)
    vertices = ProjectId[item.identity.id for item in model.scenarios]
    edges = Tuple{ProjectId,ProjectId}[]
    for scenario in model.scenarios
        isnothing(scenario.parent) && continue
        push!(edges, (scenario.parent.target.id, scenario.identity.id))
    end
    _has_directed_cycle(vertices, edges) &&
        _semantic_fail(:scenario_parent_cycle, "scenario inheritance contains a cycle")
    return true
end

function _event_scenario_owner_ids(model::EventScenarioModel)
    ids = ProjectId[]
    for event in model.events
        push!(ids, event.identity.id)
        append!(ids, [reset.identity.id for reset in event.resets])
    end
    for scenario in model.scenarios
        push!(ids, scenario.identity.id)
        append!(ids, [patch.identity.id for patch in scenario.patches])
    end
    return ids
end

"""Validate event calendars, scenario inheritance, typed patches, and materialized variants."""
function validate_event_scenario_model(project::CanonicalProject)
    model = project.event_scenarios
    owner_ids = _event_scenario_owner_ids(model)
    length(owner_ids) == length(unique(owner_ids)) ||
        _semantic_fail(:duplicate_event_scenario_identity, "event/scenario model repeats an owner identity")
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
    ))
    isempty(intersect(other_ids, Set(owner_ids))) ||
        _semantic_fail(:event_scenario_identity_collision, "event/scenario owner collides with other project semantics")
    foreach(event -> _validate_event(project, event), model.events)
    _validate_event_conflicts(project)
    foreach(scenario -> _validate_scenario_declaration(model, scenario), model.scenarios)
    _validate_scenario_graph(model)
    patch_ids = ProjectId[
        patch.identity.id for scenario in model.scenarios for patch in scenario.patches
    ]
    length(patch_ids) == length(unique(patch_ids)) ||
        _semantic_fail(:duplicate_scenario_patch_identity, "scenario graph repeats a patch identity")
    foreach(scenario -> _resolve_scenario(project, scenario.identity.id; require_verified = false), model.scenarios)
    return true
end
