"""Transactional integration for canonical drawing records."""

_drawing_effect(owner::ProjectId) =
    CommandEffect(owner, DependencyInvalidation(owner, [InvalidateViews]))

function _apply_patch(project::CanonicalProject, patch::AddDrawingRecordPatch)
    workspace = _add_drawing_record(project.drawings, patch.record)
    return _replace_project_drawings(project, workspace), _drawing_effect(patch.record.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::ReplaceDrawingRecordPatch)
    workspace = _replace_drawing_record(project.drawings, patch.record)
    return _replace_project_drawings(project, workspace), _drawing_effect(patch.record.identity.id)
end

function _apply_patch(project::CanonicalProject, patch::RemoveDrawingRecordPatch)
    workspace = _remove_drawing_record(project.drawings, patch.owner)
    return _replace_project_drawings(project, workspace), _drawing_effect(patch.owner)
end

function _inverse_patch(patch::AddDrawingRecordPatch, project::CanonicalProject)
    patch.record.identity.id in drawing_workspace_ids(project.drawings) &&
        _semantic_fail(
            :invalid_command_inverse,
            "cannot invert drawing add against an occupied ID",
        )
    return RemoveDrawingRecordPatch(patch.record.identity.id)
end

_inverse_patch(patch::RemoveDrawingRecordPatch, project::CanonicalProject) =
    AddDrawingRecordPatch(drawing_record(project.drawings, patch.owner))

_inverse_patch(patch::ReplaceDrawingRecordPatch, project::CanonicalProject) =
    ReplaceDrawingRecordPatch(drawing_record(project.drawings, patch.record.identity.id))

