@enum TransactionState::UInt8 begin
    TransactionOpen = 0x01
    TransactionValidated = 0x02
    TransactionCommitted = 0x03
    TransactionRolledBack = 0x04
end

"""An isolated mutable edit buffer whose accepted base and produced projects remain immutable."""
mutable struct ProjectTransaction
    base::ProjectRevision
    working::CanonicalProject
    commands::Vector{ProjectCommand}
    effects::Vector{CommandEffect}
    state::TransactionState
end

function begin_project_transaction(base::ProjectRevision)
    return ProjectTransaction(base, base.project, ProjectCommand[], CommandEffect[], TransactionOpen)
end

function _require_transaction_state(transaction::ProjectTransaction, accepted::Tuple)
    transaction.state in accepted ||
        _semantic_fail(:invalid_transaction_state, "transaction operation is invalid in its current state")
    return true
end

"""Provisionally apply one command; failure leaves both accepted and working states unchanged."""
function apply!(transaction::ProjectTransaction, command::ProjectCommand)
    _require_transaction_state(transaction, (TransactionOpen,))
    any(existing -> existing.id == command.id, transaction.commands) &&
        _semantic_fail(:duplicate_command_id, "transaction repeats a command ID")
    candidate, effect = _apply_command(transaction.working, command)
    push!(transaction.commands, command)
    push!(transaction.effects, effect)
    transaction.working = candidate
    return transaction
end

"""Validate the complete provisional project and mark only the transaction copy verified."""
function validate!(transaction::ProjectTransaction)
    _require_transaction_state(transaction, (TransactionOpen, TransactionValidated))
    transaction.state == TransactionValidated && return transaction
    candidate = verified_project(transaction.working)
    transaction.working = candidate
    transaction.state = TransactionValidated
    return transaction
end

"""Commit one validated transaction against the exact current base revision."""
function commit!(
    transaction::ProjectTransaction,
    current::ProjectRevision,
    source_hash::ContentDigest,
    resolved_hash::ContentDigest,
    provenance::RevisionProvenance,
)
    _require_transaction_state(transaction, (TransactionOpen, TransactionValidated))
    current == transaction.base ||
        _semantic_fail(:concurrent_base_mismatch, "transaction base is not the current project revision")
    isempty(transaction.commands) &&
        _semantic_fail(:empty_transaction, "transaction has no semantic commands")
    resolved_hash == current.resolved_hash &&
        _semantic_fail(:unchanged_resolved_hash, "changed project requires a new resolved content hash")
    transaction.state == TransactionOpen && validate!(transaction)
    commands = copy(transaction.commands)
    changed_owners = _unique_changed_owners(transaction.effects)
    invalidations = _unique_invalidations(transaction.effects)
    id = _revision_digest(current.id, source_hash, resolved_hash, provenance, commands)
    revision = ProjectRevision(
        id,
        current.id,
        source_hash,
        resolved_hash,
        transaction.working,
        CanonicalList{ProjectCommand}(commands),
        provenance,
        CanonicalList{ProjectId}(changed_owners),
        CanonicalList{DependencyInvalidation}(invalidations),
    )
    transaction.state = TransactionCommitted
    return revision
end

"""Discard every provisional command and restore the exact immutable base project."""
function rollback!(transaction::ProjectTransaction)
    _require_transaction_state(transaction, (TransactionOpen, TransactionValidated))
    transaction.working = transaction.base.project
    empty!(transaction.commands)
    empty!(transaction.effects)
    transaction.state = TransactionRolledBack
    return transaction.base
end

"""An immutable query boundary pinned to one exact project revision."""
struct ProjectSnapshot
    revision_id::ContentDigest
    project::CanonicalProject
end

project_snapshot(revision::ProjectRevision) = ProjectSnapshot(revision.id, revision.project)

query_records(snapshot::ProjectSnapshot) = CanonicalList{CanonicalRecord}(collect(snapshot.project.records))

function query_records(snapshot::ProjectSnapshot, schema::SemanticSchemaIdentity)
    records = CanonicalRecord[record for record in snapshot.project.records if record.schema == schema]
    return CanonicalList{CanonicalRecord}(records)
end

query_record(snapshot::ProjectSnapshot, id::ProjectId) = project_record(snapshot.project, id)
