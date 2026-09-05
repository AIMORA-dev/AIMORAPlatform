# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Resolve a new file destination without creating it or permitting replacement of an existing entry."""
function confine_new_project_file(policy::PathPolicy, requested_path::AbstractString)
    isabspath(requested_path) && !occursin('\0', requested_path) &&
        ncodeunits(requested_path) <= policy.max_path_bytes || throw(ServiceError(
            "PATH_NOT_ALLOWED", "A new project requires a bounded absolute path."))
    filename = basename(requested_path)
    !isempty(filename) && !(filename in (".", "..")) && !occursin(':', filename) &&
        !occursin(r"[. ]$", filename) && !occursin(r"[\x00-\x1f<>\"|?*]", filename) || throw(ServiceError(
            "PATH_NOT_ALLOWED", "The new project filename is not portable."))
    stem = uppercase(first(split(filename, '.'; limit = 2)))
    !(stem in ("CON", "PRN", "AUX", "NUL") || occursin(r"^(COM|LPT)[1-9]$", stem)) ||
        throw(ServiceError("PATH_NOT_ALLOWED", "Device names cannot be project filenames."))
    parent = dirname(requested_path)
    isdir(parent) || throw(ServiceError("RESOURCE_NOT_FOUND", "The destination directory does not exist."))
    canonical_path = joinpath(realpath(parent), filename)
    ncodeunits(canonical_path) <= policy.max_path_bytes &&
        any(root -> _path_is_inside(canonical_path, root), policy.allowed_roots) || throw(ServiceError(
            "PATH_NOT_ALLOWED", "The destination is outside allowed roots or exceeds the path limit."))
    !(ispath(canonical_path) || islink(canonical_path)) || throw(ServiceError(
        "PROJECT_ALREADY_EXISTS", "New Drawing cannot replace an existing filesystem entry."))
    return canonical_path
end
