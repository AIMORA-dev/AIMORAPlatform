@enum EventDirection::UInt8 begin
    EventAnyDirection = 0x01
    EventRisingDirection = 0x02
    EventFallingDirection = 0x03
end

@enum EventRollbackPolicy::UInt8 begin
    EventRollbackRestoreAccepted = 0x01
    EventRollbackReplayDeterministically = 0x02
    EventRollbackProhibited = 0x03
end

@enum EventResetMode::UInt8 begin
    EventResetAssign = 0x01
    EventResetRelease = 0x02
    EventResetReinitialize = 0x03
end

abstract type EventTrigger end

"""An exact nonnegative duration from the study epoch."""
struct RelativeEventTrigger <: EventTrigger
    time::PhysicalValue{ScalarQuantity}
end

Base.:(==)(left::RelativeEventTrigger, right::RelativeEventTrigger) = left.time == right.time

"""An absolute UTC calendar instant; timezone conversion belongs to the format boundary."""
struct AbsoluteEventTrigger <: EventTrigger
    at_utc::DateTime
end

Base.:(==)(left::AbsoluteEventTrigger, right::AbsoluteEventTrigger) = left.at_utc == right.at_utc

"""One exact nonnegative tick on a declared sampled control task."""
struct SampledEventTrigger <: EventTrigger
    task::ProjectReference
    tick::Int

    function SampledEventTrigger(task::ProjectReference, tick::Integer)
        task.kind == ReferenceControlBlock ||
            _semantic_fail(:invalid_sampled_event_task, "sampled event task requires a control reference")
        normalized_tick = try
            Int(tick)
        catch
            _semantic_fail(:invalid_sampled_event_tick, "sampled event tick exceeds Int")
        end
        normalized_tick >= 0 ||
            _semantic_fail(:invalid_sampled_event_tick, "sampled event tick must be nonnegative")
        return new(task, normalized_tick)
    end
end

Base.:(==)(left::SampledEventTrigger, right::SampledEventTrigger) =
    left.task == right.task && left.tick == right.tick

"""One bounded directed event-surface declaration without an executable callback."""
struct ConditionEventTrigger <: EventTrigger
    surface::SemanticTypeId
    quantity::SemanticTypeId
    threshold::PhysicalValue{ScalarQuantity}
    hysteresis::PhysicalValue{ScalarQuantity}
    direction::EventDirection
    maximum_occurrences::Int

    function ConditionEventTrigger(
        surface::SemanticTypeId,
        quantity::SemanticTypeId,
        threshold::PhysicalValue{ScalarQuantity},
        hysteresis::PhysicalValue{ScalarQuantity},
        direction::EventDirection,
        maximum_occurrences::Integer,
    )
        bound = try
            Int(maximum_occurrences)
        catch
            _semantic_fail(:invalid_event_occurrence_bound, "condition event occurrence bound exceeds Int")
        end
        bound > 0 ||
            _semantic_fail(:invalid_event_occurrence_bound, "condition event requires a positive occurrence bound")
        return new(surface, quantity, threshold, hysteresis, direction, bound)
    end
end

Base.:(==)(left::ConditionEventTrigger, right::ConditionEventTrigger) =
    left.surface == right.surface && left.quantity == right.quantity &&
    left.threshold == right.threshold && left.hysteresis == right.hysteresis &&
    left.direction == right.direction && left.maximum_occurrences == right.maximum_occurrences

const CanonicalEventTrigger = Union{
    RelativeEventTrigger,
    AbsoluteEventTrigger,
    SampledEventTrigger,
    ConditionEventTrigger,
}

"""One explicitly targeted reset owned by an event declaration, not runtime state."""
struct EventResetDeclaration
    identity::ObjectIdentity
    target::ProjectReference
    mode::EventResetMode
    value::Union{Nothing,CanonicalFieldData}
    provenance::ProvenanceSource

    function EventResetDeclaration(
        identity::ObjectIdentity,
        target::ProjectReference,
        mode::EventResetMode,
        value::Union{Nothing,CanonicalFieldData},
        provenance::ProvenanceSource,
    )
        if mode == EventResetAssign
            isnothing(value) &&
                _semantic_fail(:missing_event_reset_value, "assign reset requires an explicit value")
        elseif !isnothing(value)
            _semantic_fail(:unexpected_event_reset_value, "release or reinitialize reset cannot carry a value")
        end
        owned_value = value isa String ? String(value) : value
        return new(identity, target, mode, owned_value, provenance)
    end
end

EventResetDeclaration(
    identity::ObjectIdentity,
    target::ProjectReference,
    mode::EventResetMode,
    value::Integer,
    provenance::ProvenanceSource,
) = EventResetDeclaration(identity, target, mode, BigInt(value), provenance)

EventResetDeclaration(
    identity::ObjectIdentity,
    target::ProjectReference,
    mode::EventResetMode,
    value::AbstractString,
    provenance::ProvenanceSource,
) = EventResetDeclaration(identity, target, mode, String(value), provenance)

Base.:(==)(left::EventResetDeclaration, right::EventResetDeclaration) =
    left.identity == right.identity && left.target == right.target && left.mode == right.mode &&
    left.value == right.value && left.provenance == right.provenance

"""A typed event request with exact ordering, reset, and rollback metadata."""
struct EventDeclaration
    identity::ObjectIdentity
    event_type::SemanticTypeId
    trigger::CanonicalEventTrigger
    priority::Int
    target::ProjectReference
    parameters::CanonicalList{CanonicalField}
    resets::CanonicalList{EventResetDeclaration}
    rollback::EventRollbackPolicy
    enabled::Bool
    provenance::ProvenanceSource

    function EventDeclaration(
        identity::ObjectIdentity,
        event_type::SemanticTypeId,
        trigger::CanonicalEventTrigger,
        priority::Integer,
        target::ProjectReference,
        parameters::AbstractVector{CanonicalField},
        resets::AbstractVector{EventResetDeclaration},
        rollback::EventRollbackPolicy,
        provenance::ProvenanceSource;
        enabled::Bool = true,
    )
        normalized_priority = try
            Int(priority)
        catch
            _semantic_fail(:invalid_event_priority, "event priority exceeds Int")
        end
        parameter_copy = sort!(collect(parameters); by = item -> item.name)
        parameter_names = getfield.(parameter_copy, :name)
        length(parameter_names) == length(unique(parameter_names)) ||
            _semantic_fail(:duplicate_event_parameter, "event repeats a parameter")
        reset_copy = sort!(collect(resets); by = item -> item.identity.id.value)
        reset_ids = getfield.(getfield.(reset_copy, :identity), :id)
        length(reset_ids) == length(unique(reset_ids)) ||
            _semantic_fail(:duplicate_event_reset, "event repeats a reset identity")
        return new(
            identity,
            event_type,
            trigger,
            normalized_priority,
            target,
            CanonicalList{CanonicalField}(parameter_copy),
            CanonicalList{EventResetDeclaration}(reset_copy),
            rollback,
            enabled,
            provenance,
        )
    end
end

Base.:(==)(left::EventDeclaration, right::EventDeclaration) =
    left.identity == right.identity && left.event_type == right.event_type &&
    left.trigger == right.trigger && left.priority == right.priority &&
    left.target == right.target && left.parameters == right.parameters &&
    left.resets == right.resets && left.rollback == right.rollback &&
    left.enabled == right.enabled && left.provenance == right.provenance

@enum ScenarioOperation::UInt8 begin
    ScenarioSet = 0x01
    ScenarioUnset = 0x02
    ScenarioAdd = 0x03
    ScenarioRemove = 0x04
    ScenarioEnable = 0x05
    ScenarioDisable = 0x06
    ScenarioConnect = 0x07
    ScenarioDisconnect = 0x08
    ScenarioReplaceProfile = 0x09
    ScenarioReplaceRealization = 0x0a
end

"""One stable-ID scenario mutation with explicit within-scenario precedence."""
struct ScenarioPatchDeclaration
    identity::ObjectIdentity
    operation::ScenarioOperation
    patch::ProjectPatch
    precedence::Int
    provenance::ProvenanceSource

    function ScenarioPatchDeclaration(
        identity::ObjectIdentity,
        operation::ScenarioOperation,
        patch::ProjectPatch,
        precedence::Integer,
        provenance::ProvenanceSource,
    )
        normalized_precedence = try
            Int(precedence)
        catch
            _semantic_fail(:invalid_scenario_precedence, "scenario patch precedence exceeds Int")
        end
        return new(identity, operation, patch, normalized_precedence, provenance)
    end
end

Base.:(==)(left::ScenarioPatchDeclaration, right::ScenarioPatchDeclaration) =
    left.identity == right.identity && left.operation == right.operation &&
    left.patch == right.patch && left.precedence == right.precedence &&
    left.provenance == right.provenance

"""An immutable scenario node whose parent and patches resolve by stable identity."""
struct ScenarioDefinition
    identity::ObjectIdentity
    parent::Union{Nothing,ProjectReference}
    patches::CanonicalList{ScenarioPatchDeclaration}
    provenance::ProvenanceSource

    function ScenarioDefinition(
        identity::ObjectIdentity,
        parent::Union{Nothing,ProjectReference},
        patches::AbstractVector{ScenarioPatchDeclaration},
        provenance::ProvenanceSource,
    )
        !isnothing(parent) && parent.kind != ReferenceScenario &&
            _semantic_fail(:invalid_scenario_parent, "scenario parent requires a scenario reference")
        patch_copy = sort!(collect(patches); by = item -> (item.precedence, item.identity.id.value))
        patch_ids = getfield.(getfield.(patch_copy, :identity), :id)
        length(patch_ids) == length(unique(patch_ids)) ||
            _semantic_fail(:duplicate_scenario_patch, "scenario repeats a patch identity")
        return new(identity, parent, CanonicalList{ScenarioPatchDeclaration}(patch_copy), provenance)
    end
end

Base.:(==)(left::ScenarioDefinition, right::ScenarioDefinition) =
    left.identity == right.identity && left.parent == right.parent &&
    left.patches == right.patches && left.provenance == right.provenance

"""The immutable event calendar and scenario inheritance graph owned by one project."""
struct EventScenarioModel
    events::CanonicalList{EventDeclaration}
    scenarios::CanonicalList{ScenarioDefinition}

    function EventScenarioModel(;
        events::AbstractVector{EventDeclaration} = EventDeclaration[],
        scenarios::AbstractVector{ScenarioDefinition} = ScenarioDefinition[],
    )
        event_copy = sort!(collect(events); by = item -> item.identity.id.value)
        event_ids = getfield.(getfield.(event_copy, :identity), :id)
        length(event_ids) == length(unique(event_ids)) ||
            _semantic_fail(:duplicate_event, "event model repeats an event identity")
        scenario_copy = sort!(collect(scenarios); by = item -> item.identity.id.value)
        scenario_ids = getfield.(getfield.(scenario_copy, :identity), :id)
        length(scenario_ids) == length(unique(scenario_ids)) ||
            _semantic_fail(:duplicate_scenario, "scenario model repeats a scenario identity")
        return new(
            CanonicalList{EventDeclaration}(event_copy),
            CanonicalList{ScenarioDefinition}(scenario_copy),
        )
    end
end

Base.:(==)(left::EventScenarioModel, right::EventScenarioModel) =
    left.events == right.events && left.scenarios == right.scenarios

function event_declaration(model::EventScenarioModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.events)
    isnothing(index) && _semantic_fail(:unknown_event, "event declaration does not exist")
    return model.events[index]
end

function scenario_definition(model::EventScenarioModel, id::ProjectId)
    index = findfirst(item -> item.identity.id == id, model.scenarios)
    isnothing(index) && _semantic_fail(:unknown_scenario, "scenario definition does not exist")
    return model.scenarios[index]
end
