struct AddEventDeclarationPatch <: ProjectPatch
    event::EventDeclaration
end

Base.:(==)(left::AddEventDeclarationPatch, right::AddEventDeclarationPatch) = left.event == right.event

struct RemoveEventDeclarationPatch <: ProjectPatch
    id::ProjectId
end

Base.:(==)(left::RemoveEventDeclarationPatch, right::RemoveEventDeclarationPatch) = left.id == right.id

struct ReplaceEventDeclarationPatch <: ProjectPatch
    event::EventDeclaration
end


Base.:(==)(left::ReplaceEventDeclarationPatch, right::ReplaceEventDeclarationPatch) = left.event == right.event

struct SetEventEnabledPatch <: ProjectPatch
    id::ProjectId
    enabled::Bool
end

Base.:(==)(left::SetEventEnabledPatch, right::SetEventEnabledPatch) =
    left.id == right.id && left.enabled == right.enabled

struct AddScenarioDefinitionPatch <: ProjectPatch
    scenario::ScenarioDefinition
end

Base.:(==)(left::AddScenarioDefinitionPatch, right::AddScenarioDefinitionPatch) =
    left.scenario == right.scenario

struct RemoveScenarioDefinitionPatch <: ProjectPatch
    id::ProjectId
end

Base.:(==)(left::RemoveScenarioDefinitionPatch, right::RemoveScenarioDefinitionPatch) = left.id == right.id

struct ReplaceScenarioDefinitionPatch <: ProjectPatch
    scenario::ScenarioDefinition
end

Base.:(==)(left::ReplaceScenarioDefinitionPatch, right::ReplaceScenarioDefinitionPatch) =
    left.scenario == right.scenario

function _event_scenario_with(
    model::EventScenarioModel;
    events = collect(model.events),
    scenarios = collect(model.scenarios),
)
    return EventScenarioModel(; events, scenarios)
end

_event_scenario_effect(owner::ProjectId) = CommandEffect(
    owner,
    DependencyInvalidation(owner, [InvalidateStudyResults, InvalidateWorkflowResults]),
)

function _replace_event(event::EventDeclaration; enabled::Bool = event.enabled)
    return EventDeclaration(
        event.identity,
        event.event_type,
        event.trigger,
        event.priority,
        event.target,
        collect(event.parameters),
        collect(event.resets),
        event.rollback,
        event.provenance;
        enabled,
    )
end

function _apply_patch(project::CanonicalProject, patch::AddEventDeclarationPatch)
    any(item -> item.identity.id == patch.event.identity.id, project.event_scenarios.events) &&
        _semantic_fail(:duplicate_event, "add-event patch targets an existing identity")
    events = vcat(collect(project.event_scenarios.events), [patch.event])
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; events))
    return updated, _event_scenario_effect(patch.event.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveEventDeclarationPatch)
    events = collect(project.event_scenarios.events)
    index = findfirst(item -> item.identity.id == patch.id, events)
    isnothing(index) && _semantic_fail(:unknown_event, "remove-event patch target does not exist")
    deleteat!(events, index)
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; events))
    return updated, _event_scenario_effect(patch.id)
end

function _apply_patch(project::CanonicalProject, patch::ReplaceEventDeclarationPatch)
    events = collect(project.event_scenarios.events)
    index = findfirst(item -> item.identity.id == patch.event.identity.id, events)
    isnothing(index) && _semantic_fail(:unknown_event, "replace-event patch target does not exist")
    events[index] == patch.event &&
        _semantic_fail(:no_effect_command, "replace-event patch does not change the event")
    events[index] = patch.event
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; events))
    return updated, _event_scenario_effect(patch.event.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::SetEventEnabledPatch)
    event = event_declaration(project.event_scenarios, patch.id)
    event.enabled == patch.enabled &&
        _semantic_fail(:no_effect_command, "set-event-enabled patch does not change the event")
    events = collect(project.event_scenarios.events)
    index = findfirst(item -> item.identity.id == patch.id, events)
    events[index] = _replace_event(event; enabled = patch.enabled)
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; events))
    return updated, _event_scenario_effect(patch.id)
end

function _apply_patch(project::CanonicalProject, patch::AddScenarioDefinitionPatch)
    any(item -> item.identity.id == patch.scenario.identity.id, project.event_scenarios.scenarios) &&
        _semantic_fail(:duplicate_scenario, "add-scenario patch targets an existing identity")
    scenarios = vcat(collect(project.event_scenarios.scenarios), [patch.scenario])
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; scenarios))
    return updated, _event_scenario_effect(patch.scenario.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveScenarioDefinitionPatch)
    any(item -> !isnothing(item.parent) && item.parent.target isa LocalReferenceTarget &&
        item.parent.target.id == patch.id, project.event_scenarios.scenarios) &&
        _semantic_fail(:scenario_has_children, "remove-scenario patch target has child scenarios")
    scenarios = collect(project.event_scenarios.scenarios)
    index = findfirst(item -> item.identity.id == patch.id, scenarios)
    isnothing(index) && _semantic_fail(:unknown_scenario, "remove-scenario patch target does not exist")
    deleteat!(scenarios, index)
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; scenarios))
    return updated, _event_scenario_effect(patch.id)
end

function _apply_patch(project::CanonicalProject, patch::ReplaceScenarioDefinitionPatch)
    scenarios = collect(project.event_scenarios.scenarios)
    index = findfirst(item -> item.identity.id == patch.scenario.identity.id, scenarios)
    isnothing(index) && _semantic_fail(:unknown_scenario, "replace-scenario patch target does not exist")
    scenarios[index] == patch.scenario &&
        _semantic_fail(:no_effect_command, "replace-scenario patch does not change the scenario")
    scenarios[index] = patch.scenario
    updated = _replace_event_scenarios(project, _event_scenario_with(project.event_scenarios; scenarios))
    return updated, _event_scenario_effect(patch.scenario.identity.id)
end

_inverse_patch(patch::AddEventDeclarationPatch, ::CanonicalProject) =
    RemoveEventDeclarationPatch(patch.event.identity.id)
_inverse_patch(patch::RemoveEventDeclarationPatch, project::CanonicalProject) =
    AddEventDeclarationPatch(event_declaration(project.event_scenarios, patch.id))
_inverse_patch(patch::ReplaceEventDeclarationPatch, project::CanonicalProject) =
    ReplaceEventDeclarationPatch(event_declaration(project.event_scenarios, patch.event.identity.id))
_inverse_patch(patch::SetEventEnabledPatch, project::CanonicalProject) =
    SetEventEnabledPatch(patch.id, event_declaration(project.event_scenarios, patch.id).enabled)
_inverse_patch(patch::AddScenarioDefinitionPatch, ::CanonicalProject) =
    RemoveScenarioDefinitionPatch(patch.scenario.identity.id)
_inverse_patch(patch::RemoveScenarioDefinitionPatch, project::CanonicalProject) =
    AddScenarioDefinitionPatch(scenario_definition(project.event_scenarios, patch.id))
_inverse_patch(patch::ReplaceScenarioDefinitionPatch, project::CanonicalProject) =
    ReplaceScenarioDefinitionPatch(scenario_definition(project.event_scenarios, patch.scenario.identity.id))

_patch_signature(patch::AddEventDeclarationPatch) = "add-event:" * patch.event.identity.id.value
_patch_signature(patch::RemoveEventDeclarationPatch) = "remove-event:" * patch.id.value
_patch_signature(patch::ReplaceEventDeclarationPatch) = "replace-event:" * patch.event.identity.id.value
_patch_signature(patch::SetEventEnabledPatch) =
    "set-event-enabled:" * patch.id.value * ":" * string(patch.enabled)
_patch_signature(patch::AddScenarioDefinitionPatch) = "add-scenario:" * patch.scenario.identity.id.value
_patch_signature(patch::RemoveScenarioDefinitionPatch) = "remove-scenario:" * patch.id.value
_patch_signature(patch::ReplaceScenarioDefinitionPatch) =
    "replace-scenario:" * patch.scenario.identity.id.value

_declared_patch_effect(::CanonicalProject, patch::AddEventDeclarationPatch) =
    _event_scenario_effect(patch.event.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveEventDeclarationPatch) =
    _event_scenario_effect(patch.id)
_declared_patch_effect(::CanonicalProject, patch::ReplaceEventDeclarationPatch) =
    _event_scenario_effect(patch.event.identity.id)
_declared_patch_effect(::CanonicalProject, patch::SetEventEnabledPatch) =
    _event_scenario_effect(patch.id)
_declared_patch_effect(::CanonicalProject, patch::AddScenarioDefinitionPatch) =
    _event_scenario_effect(patch.scenario.identity.id)
_declared_patch_effect(::CanonicalProject, patch::RemoveScenarioDefinitionPatch) =
    _event_scenario_effect(patch.id)
_declared_patch_effect(::CanonicalProject, patch::ReplaceScenarioDefinitionPatch) =
    _event_scenario_effect(patch.scenario.identity.id)
