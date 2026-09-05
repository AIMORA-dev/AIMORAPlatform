# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
export plan_drafting_text_replacement

"""Replace unbound drafting label text atomically, preserving identities, anchors, layers and styles."""
function plan_drafting_text_replacement(project::CanonicalProject, action::ProjectId,
    selection::AbstractVector{ProjectId}, text::AbstractString)
    0 < length(selection) <= 100_000 || _semantic_fail(
        :invalid_drafting_batch_size, "Text editing requires one to 100000 labels.")
    length(unique(selection)) == length(selection) || _semantic_fail(
        :duplicate_drafting_owner, "Text editing cannot contain duplicate labels.")
    !isempty(strip(text)) && ncodeunits(text) <= 65536 &&
        !any(character -> character in ('\n', '\r', '\0'), text) || _semantic_fail(
            :invalid_drafting_text, "Provide one nonempty line of at most 65536 UTF-8 bytes.")
    replacements = CanonicalDrawingRecord[]
    view = nothing
    for id in selection
        record = _require_drafting_record(drawing_record(project.drawings, id))
        record isa DrawingLabel || _semantic_fail(:non_text_drafting_selection,
            "Select only unbound drafting labels to edit text.")
        isnothing(view) && (view = record.view)
        record.view == view || _semantic_fail(:cross_view_drafting_text,
            "Edit labels within one drawing view.")
        record.text == text && continue
        push!(replacements, DrawingLabel(record.identity, record.view, record.layer, record.anchor,
            String(text), record.provenance; style = record.style))
    end
    isempty(replacements) && _semantic_fail(:no_effect_command, "The selected labels already contain this text.")
    return plan_drafting_edit(project, action; replacements)
end
