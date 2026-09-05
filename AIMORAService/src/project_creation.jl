# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
_new_drawing_project_id(identity::UUID) = AIMORAProject.ProjectId("project.p" * replace(string(identity), "-" => ""))

function _create_drawing_project!(state::ServiceState, parameters::AbstractDict)
    all(key -> key in ("path", "name"), keys(parameters)) || throw(ServiceError(
        "INVALID_REQUEST", "New Drawing accepts only a destination path and project name."))
    requested_path = _required_string(parameters, "path";
        maximum_bytes = state.configuration.limits.max_path_bytes)
    name = _required_string(parameters, "name"; maximum_bytes = 1024)
    path = confine_new_project_file(state.path_policy, requested_path)
    endswith(lowercase(path), ".aimora.yaml") || throw(ServiceError(
        "INVALID_REQUEST", "New drawings use the .aimora.yaml file extension."))
    length(state.projects) < state.configuration.limits.max_pending_requests || throw(ServiceError(
        "RESOURCE_TOO_LARGE", "Too many project references are open."))
    identity = uuid4()
    licence = AIMORAProject.LicenceIdentity("LicenseRef-User", "Rights defined by the project owner")
    source = AIMORAProject.ProvenanceSource(AIMORAProject.ProjectId("source.new.drawing"),
        "User-created drawing; rights are defined by the project owner.", licence)
    namespace = AIMORAProject.NamespaceId("user.project" * replace(string(identity), "-" => ""))
    registry = AIMORAProject.SemanticSchemaRegistry([
        AIMORAProject.NamespaceRegistration(namespace, identity, licence, source)])
    metadata = AIMORAProject.ProjectMetadata(
        AIMORAProject.ObjectIdentity(_new_drawing_project_id(identity)),
        name, namespace, v"1.0.0", now(UTC), source)
    project = AIMORAProject.new_drawing_project(metadata, registry)
    mktempdir(dirname(path); prefix = ".aimora-create-") do staging_root
        staged = joinpath(staging_root, "drawing.aimora.yaml")
        AIMORAProject.save_project(staged, project)
        bounded_file_size(staged, state.configuration.limits.max_project_bytes)
        confine_new_project_file(state.path_policy, path)
        try
            # Hard-link publication is atomic and cannot replace an existing destination.
            Base.Filesystem.hardlink(staged, path)
        catch
            (ispath(path) || islink(path)) && throw(ServiceError(
                "PROJECT_ALREADY_EXISTS", "The destination was created by another writer."))
            throw(ServiceError("PROJECT_CREATE_FAILED", "The filesystem could not publish the new project safely."))
        end
    end
    return _open_project!(state, Dict("path" => path, "mode" => "drafting"))
end
