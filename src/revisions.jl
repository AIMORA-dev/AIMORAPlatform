"""Audit provenance for one deterministic project revision."""
struct RevisionProvenance
    action::ProjectId
    actor::Union{Nothing,GlobalId}
    recorded_at_utc::DateTime
    source::ProvenanceSource
end

RevisionProvenance(
    action::ProjectId,
    recorded_at_utc::DateTime,
    source::ProvenanceSource;
    actor::Union{Nothing,GlobalId} = nothing,
) = RevisionProvenance(action, actor, recorded_at_utc, source)

Base.:(==)(left::RevisionProvenance, right::RevisionProvenance) =
    left.action == right.action &&
    left.actor == right.actor &&
    left.recorded_at_utc == right.recorded_at_utc &&
    left.source == right.source

@enum InvalidationScope::UInt8 begin
    InvalidateStudyResults = 0x01
    InvalidateWorkflowResults = 0x02
    InvalidateViews = 0x03
    InvalidateAllResults = 0x04
end

"""A typed signal that accepted downstream artifacts may be stale."""
struct DependencyInvalidation
    owner::ProjectId
    scopes::CanonicalList{InvalidationScope}

    function DependencyInvalidation(owner::ProjectId, scopes::AbstractVector{InvalidationScope})
        copied = sort!(collect(scopes); by = UInt8)
        isempty(copied) && _semantic_fail(:empty_dependency_invalidation, "dependency invalidation requires a scope")
        length(copied) == length(unique(copied)) ||
            _semantic_fail(:duplicate_dependency_invalidation, "dependency invalidation repeats a scope")
        return new(owner, CanonicalList{InvalidationScope}(copied))
    end
end

Base.:(==)(left::DependencyInvalidation, right::DependencyInvalidation) =
    left.owner == right.owner && left.scopes == right.scopes

struct CommandEffect
    changed_owner::ProjectId
    invalidation::DependencyInvalidation
end

Base.:(==)(left::CommandEffect, right::CommandEffect) =
    left.changed_owner == right.changed_owner && left.invalidation == right.invalidation

abstract type ProjectPatch end

struct AddRecordPatch <: ProjectPatch
    record::CanonicalRecord
end

Base.:(==)(left::AddRecordPatch, right::AddRecordPatch) = left.record == right.record

struct RemoveRecordPatch <: ProjectPatch
    owner::ProjectId
end

Base.:(==)(left::RemoveRecordPatch, right::RemoveRecordPatch) = left.owner == right.owner

struct SetRecordFieldPatch <: ProjectPatch
    owner::ProjectId
    field::CanonicalField
end

Base.:(==)(left::SetRecordFieldPatch, right::SetRecordFieldPatch) =
    left.owner == right.owner && left.field == right.field

struct UnsetRecordFieldPatch <: ProjectPatch
    owner::ProjectId
    field_name::String

    function UnsetRecordFieldPatch(owner::ProjectId, field_name::AbstractString)
        normalized = String(field_name)
        occursin(r"^[a-z][a-z0-9_]*$", normalized) ||
            _semantic_fail(:invalid_canonical_field_name, "canonical field name is not lowercase portable text")
        return new(owner, normalized)
    end
end


Base.:(==)(left::UnsetRecordFieldPatch, right::UnsetRecordFieldPatch) =
    left.owner == right.owner && left.field_name == right.field_name

struct SetProjectNamePatch <: ProjectPatch
    name::String

    function SetProjectNamePatch(name::AbstractString)
        normalized = String(name)
        isempty(strip(normalized)) && _semantic_fail(:invalid_project_name, "project name must not be empty")
        occursin('\0', normalized) && _semantic_fail(:invalid_project_name, "project name contains NUL")
        return new(normalized)
    end
end


Base.:(==)(left::SetProjectNamePatch, right::SetProjectNamePatch) = left.name == right.name

"""A deliberately noninvertible developer patch that always returns unverified data."""
struct UnsafeReplaceRecordsPatch <: ProjectPatch
    records::CanonicalList{CanonicalRecord}

    function UnsafeReplaceRecordsPatch(records::AbstractVector{CanonicalRecord})
        copied = sort!(collect(records); by = record -> record.identity.id.value)
        ids = getfield.(getfield.(copied, :identity), :id)
        length(ids) == length(unique(ids)) ||
            _semantic_fail(:duplicate_record_id, "unsafe replacement repeats a record ID")
        return new(CanonicalList{CanonicalRecord}(copied))
    end
end

Base.:(==)(left::UnsafeReplaceRecordsPatch, right::UnsafeReplaceRecordsPatch) =
    left.records == right.records

"""One ordered, replayable semantic command with a stable local audit identity."""
struct ProjectCommand
    id::ProjectId
    patch::ProjectPatch
end

Base.:(==)(left::ProjectCommand, right::ProjectCommand) = left.id == right.id && left.patch == right.patch

const _RECORD_INVALIDATION_SCOPES = [InvalidateStudyResults, InvalidateWorkflowResults]

_record_effect(owner::ProjectId) =
    CommandEffect(owner, DependencyInvalidation(owner, _RECORD_INVALIDATION_SCOPES))

function _apply_patch(project::CanonicalProject, patch::AddRecordPatch)
    any(record -> record.identity.id == patch.record.identity.id, project.records) &&
        _semantic_fail(:duplicate_record_id, "add-record patch targets an existing ID")
    _validate_record(project, patch.record)
    records = vcat(collect(project.records), [patch.record])
    updated = CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        records,
        project.graphs,
        project.asset_library,
        project.hierarchy,
        ProjectUnverified,
    )
    return updated, _record_effect(patch.record.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveRecordPatch)
    records = collect(project.records)
    index = findfirst(record -> record.identity.id == patch.owner, records)
    isnothing(index) && _semantic_fail(:unknown_record_id, "remove-record patch target does not exist")
    deleteat!(records, index)
    updated = CanonicalProject(
        project.metadata,
        project.registry,
        project.units,
        records,
        project.graphs,
        project.asset_library,
        project.hierarchy,
        ProjectUnverified,
    )
    return updated, _record_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::SetRecordFieldPatch)
    record = project_record(project, patch.owner)
    schema = resolve_schema(project.registry, record.schema)
    declared = schema_field(schema, patch.field.name)
    patch.field.name == "id" && patch.field.value != record.identity.id.value &&
        _semantic_fail(:record_identity_mismatch, "record id field differs from its immutable object identity")
    validate_field_value(declared, patch.field.value, project.units)
    fields = collect(record.fields)
    index = findfirst(field -> field.name == patch.field.name, fields)
    !isnothing(index) && fields[index] == patch.field &&
        _semantic_fail(:no_effect_command, "set-field patch does not change the record")
    if isnothing(index)
        push!(fields, patch.field)
    else
        fields[index] = patch.field
    end
    replacement = CanonicalRecord(record.identity, record.schema, fields, record.provenance)
    return _replace_project_record(project, replacement), _record_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::UnsetRecordFieldPatch)
    record = project_record(project, patch.owner)
    fields = collect(record.fields)
    index = findfirst(field -> field.name == patch.field_name, fields)
    isnothing(index) && _semantic_fail(:unknown_canonical_field, "unset-field patch target does not exist")
    deleteat!(fields, index)
    replacement = CanonicalRecord(record.identity, record.schema, fields, record.provenance)
    return _replace_project_record(project, replacement), _record_effect(patch.owner)
end

function _apply_patch(project::CanonicalProject, patch::SetProjectNamePatch)
    project.metadata.name == patch.name &&
        _semantic_fail(:no_effect_command, "set-project-name patch does not change the project")
    metadata = ProjectMetadata(
        project.metadata.identity,
        patch.name,
        project.metadata.default_namespace,
        project.metadata.format_version,
        project.metadata.created_at_utc,
        project.metadata.provenance,
    )
    owner = project.metadata.identity.id
    effect = CommandEffect(owner, DependencyInvalidation(owner, [InvalidateViews]))
    return _replace_project_metadata(project, metadata), effect
end

function _apply_patch(project::CanonicalProject, patch::UnsafeReplaceRecordsPatch)
    collect(project.records) == collect(patch.records) &&
        _semantic_fail(:no_effect_command, "unsafe replacement does not change project records")
    updated = unsafe_project(
        project.metadata,
        project.registry,
        project.units,
        collect(patch.records),
        project.graphs,
        project.asset_library,
        project.hierarchy,
    )
    owner = project.metadata.identity.id
    effect = CommandEffect(owner, DependencyInvalidation(owner, [InvalidateAllResults, InvalidateViews]))
    return updated, effect
end

function _apply_command(project::CanonicalProject, command::ProjectCommand)
    return _apply_patch(project, command.patch)
end

function _field_by_name(record::CanonicalRecord, name::String)
    index = findfirst(field -> field.name == name, record.fields)
    return isnothing(index) ? nothing : record.fields[index]
end

function _inverse_patch(patch::AddRecordPatch, project::CanonicalProject)
    any(record -> record.identity.id == patch.record.identity.id, project.records) &&
        _semantic_fail(:invalid_command_inverse, "cannot invert add-record against an occupied ID")
    return RemoveRecordPatch(patch.record.identity.id)
end

function _inverse_patch(patch::RemoveRecordPatch, project::CanonicalProject)
    return AddRecordPatch(project_record(project, patch.owner))
end

function _inverse_patch(patch::SetRecordFieldPatch, project::CanonicalProject)
    record = project_record(project, patch.owner)
    previous = _field_by_name(record, patch.field.name)
    return isnothing(previous) ?
        UnsetRecordFieldPatch(patch.owner, patch.field.name) :
        SetRecordFieldPatch(patch.owner, previous)
end

function _inverse_patch(patch::UnsetRecordFieldPatch, project::CanonicalProject)
    record = project_record(project, patch.owner)
    previous = _field_by_name(record, patch.field_name)
    isnothing(previous) && _semantic_fail(:invalid_command_inverse, "cannot invert unset-field without a prior field")
    return SetRecordFieldPatch(patch.owner, previous)
end

_inverse_patch(::SetProjectNamePatch, project::CanonicalProject) = SetProjectNamePatch(project.metadata.name)
_inverse_patch(::UnsafeReplaceRecordsPatch, ::CanonicalProject) =
    _semantic_fail(:noninvertible_command, "unsafe record replacement has no automatic inverse")

"""Return deterministic undo commands in reverse application order."""
const ProjectCommandSequence = Union{AbstractVector{ProjectCommand},CanonicalList{ProjectCommand}}

function inverse_commands(
    base::CanonicalProject,
    commands::ProjectCommandSequence,
)
    working = base
    inverses = ProjectCommand[]
    seen = Set{ProjectId}()
    for command in commands
        command.id in seen && _semantic_fail(:duplicate_command_id, "command sequence repeats an ID")
        push!(seen, command.id)
        inverse = _inverse_patch(command.patch, working)
        push!(inverses, ProjectCommand(ProjectId("undo." * command.id.value), inverse))
        working, _ = _apply_command(working, command)
    end
    reverse!(inverses)
    return CanonicalList{ProjectCommand}(inverses)
end

"""Replay an ordered command sequence into a new immutable verified project."""
function replay_commands(base::CanonicalProject, commands::ProjectCommandSequence)
    working = base
    seen = Set{ProjectId}()
    for command in commands
        command.id in seen && _semantic_fail(:duplicate_command_id, "command sequence repeats an ID")
        push!(seen, command.id)
        working, _ = _apply_command(working, command)
    end
    return verified_project(working)
end

function _patch_signature(patch::ProjectPatch)
    if patch isa AddRecordPatch
        return "add:" * patch.record.identity.id.value
    elseif patch isa RemoveRecordPatch
        return "remove:" * patch.owner.value
    elseif patch isa SetRecordFieldPatch
        return "set:" * patch.owner.value * ":" * patch.field.name
    elseif patch isa UnsetRecordFieldPatch
        return "unset:" * patch.owner.value * ":" * patch.field_name
    elseif patch isa SetProjectNamePatch
        return "project-name"
    end
    return "unsafe-replace-records"
end

function _provenance_signature(provenance::RevisionProvenance)
    source = provenance.source
    actor = isnothing(provenance.actor) ? "" : provenance.actor.uri
    source_uri = isnothing(source.source_uri) ? "" : source.source_uri.uri
    source_hash = something(source.source_sha256, "")
    source_version = something(source.source_version, "")
    return join((
        provenance.action.value,
        actor,
        Dates.format(provenance.recorded_at_utc, dateformat"yyyy-mm-ddTHH:MM:SS.sss"),
        source.id.value,
        source.citation,
        source_uri,
        source_hash,
        source_version,
        source.licence.id,
    ), '\0')
end

function _revision_digest(
    parent::Union{Nothing,ContentDigest},
    source_hash::ContentDigest,
    resolved_hash::ContentDigest,
    provenance::RevisionProvenance,
    commands::AbstractVector{ProjectCommand},
)
    parts = String[
        "aimora-project-revision-v1",
        isnothing(parent) ? "" : parent.sha256,
        source_hash.sha256,
        resolved_hash.sha256,
        _provenance_signature(provenance),
    ]
    for command in commands
        push!(parts, command.id.value * "\0" * _patch_signature(command.patch))
    end
    return ContentDigest(bytes2hex(SHA.sha256(join(parts, '\n'))))
end

function _declared_command_effect(project::CanonicalProject, command::ProjectCommand)
    return _declared_patch_effect(project, command.patch)
end

function _declared_patch_effect(project::CanonicalProject, patch::ProjectPatch)
    if patch isa AddRecordPatch
        return _record_effect(patch.record.identity.id)
    elseif patch isa RemoveRecordPatch
        return _record_effect(patch.owner)
    elseif patch isa SetRecordFieldPatch
        return _record_effect(patch.owner)
    elseif patch isa UnsetRecordFieldPatch
        return _record_effect(patch.owner)
    elseif patch isa SetProjectNamePatch
        owner = project.metadata.identity.id
        return CommandEffect(owner, DependencyInvalidation(owner, [InvalidateViews]))
    end
    owner = project.metadata.identity.id
    return CommandEffect(owner, DependencyInvalidation(owner, [InvalidateAllResults, InvalidateViews]))
end

function _unique_changed_owners(effects::AbstractVector{CommandEffect})
    owners = unique(effect.changed_owner for effect in effects)
    sort!(owners; by = owner -> owner.value)
    return owners
end

function _unique_invalidations(effects::AbstractVector{CommandEffect})
    invalidations = DependencyInvalidation[]
    for effect in effects
        effect.invalidation in invalidations || push!(invalidations, effect.invalidation)
    end
    sort!(invalidations; by = item -> (item.owner.value, Tuple(UInt8(scope) for scope in item.scopes)))
    return invalidations
end

"""An immutable project revision bound to exact source and resolved content identities."""
struct ProjectRevision
    id::ContentDigest
    parent::Union{Nothing,ContentDigest}
    source_hash::ContentDigest
    resolved_hash::ContentDigest
    project::CanonicalProject
    commands::CanonicalList{ProjectCommand}
    provenance::RevisionProvenance
    changed_owners::CanonicalList{ProjectId}
    invalidations::CanonicalList{DependencyInvalidation}

    function ProjectRevision(
        id::ContentDigest,
        parent::Union{Nothing,ContentDigest},
        source_hash::ContentDigest,
        resolved_hash::ContentDigest,
        project::CanonicalProject,
        commands::CanonicalList{ProjectCommand},
        provenance::RevisionProvenance,
        changed_owners::CanonicalList{ProjectId},
        invalidations::CanonicalList{DependencyInvalidation},
    )
        command_vector = collect(commands)
        command_ids = getfield.(command_vector, :id)
        length(command_ids) == length(unique(command_ids)) ||
            _semantic_fail(:duplicate_command_id, "project revision repeats a command ID")
        isnothing(parent) == isempty(command_vector) ||
            _semantic_fail(:invalid_revision_parent, "only an initial revision may omit both parent and commands")
        expected_id = _revision_digest(parent, source_hash, resolved_hash, provenance, command_vector)
        id == expected_id ||
            _semantic_fail(:invalid_revision_digest, "project revision digest does not match its declared inputs")
        effects = CommandEffect[_declared_command_effect(project, command) for command in command_vector]
        collect(changed_owners) == _unique_changed_owners(effects) ||
            _semantic_fail(:invalid_changed_owners, "project revision changed-owner set is incomplete or noncanonical")
        collect(invalidations) == _unique_invalidations(effects) ||
            _semantic_fail(:invalid_revision_invalidations, "project revision invalidations are incomplete or noncanonical")
        return new(
            id,
            parent,
            source_hash,
            resolved_hash,
            project,
            commands,
            provenance,
            changed_owners,
            invalidations,
        )
    end
end

Base.:(==)(left::ProjectRevision, right::ProjectRevision) =
    left.id == right.id &&
    left.parent == right.parent &&
    left.source_hash == right.source_hash &&
    left.resolved_hash == right.resolved_hash &&
    left.project == right.project &&
    left.commands == right.commands &&
    left.provenance == right.provenance &&
    left.changed_owners == right.changed_owners &&
    left.invalidations == right.invalidations

function initial_revision(
    project::CanonicalProject,
    source_hash::ContentDigest,
    resolved_hash::ContentDigest,
    provenance::RevisionProvenance,
)
    commands = ProjectCommand[]
    id = _revision_digest(nothing, source_hash, resolved_hash, provenance, commands)
    return ProjectRevision(
        id,
        nothing,
        source_hash,
        resolved_hash,
        project,
        CanonicalList{ProjectCommand}(),
        provenance,
        CanonicalList{ProjectId}(),
        CanonicalList{DependencyInvalidation}(),
    )
end

can_reuse_results(revision::ProjectRevision) = revision.project.verification == ProjectVerified

struct RevisionConflict
    owner::ProjectId
    left_revision::ContentDigest
    right_revision::ContentDigest
end

Base.:(==)(left::RevisionConflict, right::RevisionConflict) =
    left.owner == right.owner &&
    left.left_revision == right.left_revision &&
    left.right_revision == right.right_revision

"""Detect deterministic owner-level conflicts between two direct children of one base."""
function detect_revision_conflicts(
    base::ProjectRevision,
    left::ProjectRevision,
    right::ProjectRevision,
)
    left.parent == base.id && right.parent == base.id ||
        _semantic_fail(:revision_parent_mismatch, "conflict detection requires two direct children of the base revision")
    overlapping = sort!(collect(intersect(Set(left.changed_owners), Set(right.changed_owners))); by = id -> id.value)
    return CanonicalList{RevisionConflict}([
        RevisionConflict(owner, left.id, right.id) for owner in overlapping
    ])
end
