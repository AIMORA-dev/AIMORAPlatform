# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
struct DraftingHistoryEntry
    forward::AIMORAProject.CanonicalList{AIMORAProject.ProjectCommand}
    backward::AIMORAProject.CanonicalList{AIMORAProject.ProjectCommand}
    retained_bytes::Int
    function DraftingHistoryEntry(forward, backward)
        saved_forward = AIMORAProject.CanonicalList{AIMORAProject.ProjectCommand}(collect(forward))
        saved_backward = AIMORAProject.CanonicalList{AIMORAProject.ProjectCommand}(collect(backward))
        return new(saved_forward, saved_backward, Base.summarysize((saved_forward, saved_backward)))
    end
end

mutable struct DraftingHistory
    undo::Vector{DraftingHistoryEntry}
    redo::Vector{DraftingHistoryEntry}
    retained_bytes::Int
    maximum_entries::Int
    maximum_bytes::Int
end

function DraftingHistory(; maximum_entries::Int = 128, maximum_bytes::Int = 16 * 1024 * 1024)
    maximum_entries > 0 && maximum_bytes > 0 || throw(ArgumentError("Drafting history budgets must be positive."))
    return DraftingHistory(DraftingHistoryEntry[], DraftingHistoryEntry[], 0, maximum_entries, maximum_bytes)
end

function _remember_drafting_edit!(history::DraftingHistory, entry::DraftingHistoryEntry)
    for discarded in history.redo
        history.retained_bytes -= discarded.retained_bytes
    end
    empty!(history.redo)
    if entry.retained_bytes > history.maximum_bytes
        empty!(history.undo)
        history.retained_bytes = 0
        return false
    end
    while !isempty(history.undo) && (length(history.undo) >= history.maximum_entries ||
        history.retained_bytes > history.maximum_bytes - entry.retained_bytes)
        history.retained_bytes -= popfirst!(history.undo).retained_bytes
    end
    push!(history.undo, entry)
    history.retained_bytes += entry.retained_bytes
    return true
end
