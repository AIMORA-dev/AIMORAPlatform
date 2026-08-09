@enum ProjectSourceKind::UInt8 begin
    ProjectCompactSource = 0x01
    ProjectDirectorySource = 0x02
end

@enum ProjectFileRole::UInt8 begin
    ProjectAuthoritativeDocument = 0x01
    ProjectAuthoritativeResource = 0x02
    ProjectArtifactResource = 0x03
    ProjectImportResource = 0x04
    ProjectDocumentationResource = 0x05
    ProjectDerivedResource = 0x06
    ProjectChecksumResource = 0x07
end

const _PROJECT_AUTHORITATIVE_DOCUMENT_DIRECTORIES = Set([
    "model",
    "scenarios",
    "studies",
    "workflows",
    "controls",
    "definitions",
    "views",
    "symbols",
    "provenance",
])
const _PROJECT_AUTHORITATIVE_RESOURCE_DIRECTORIES = Set([
    "locks",
    "scripts",
    "automation",
])
const _PROJECT_ARTIFACT_DIRECTORIES = Set(["data"])
const _PROJECT_IMPORT_DIRECTORIES = Set(["imports"])
const _PROJECT_DERIVED_DIRECTORIES = Set(["results", ".aimora-cache"])
const _PROJECT_ALLOWED_DIRECTORIES = union(
    _PROJECT_AUTHORITATIVE_DOCUMENT_DIRECTORIES,
    _PROJECT_AUTHORITATIVE_RESOURCE_DIRECTORIES,
    _PROJECT_ARTIFACT_DIRECTORIES,
    _PROJECT_IMPORT_DIRECTORIES,
    _PROJECT_DERIVED_DIRECTORIES,
)
const _PROJECT_WINDOWS_RESERVED_NAMES = Set(vcat(
    ["CON", "PRN", "AUX", "NUL"],
    ["COM$(index)" for index in 1:9],
    ["LPT$(index)" for index in 1:9],
))

struct ProjectResolutionPolicy
    format_policy::FormatInputPolicy
    max_files::Int
    max_authoritative_bytes::Int
    max_hashed_resource_bytes::Int

    function ProjectResolutionPolicy(;
        format_policy::FormatInputPolicy = FormatInputPolicy(),
        max_files::Integer = 100_000,
        max_authoritative_bytes::Integer = 512 * 1024 * 1024,
        max_hashed_resource_bytes::Integer = 4 * 1024 * 1024 * 1024,
    )
        max_files > 0 || throw(ArgumentError("project file limit must be positive"))
        max_authoritative_bytes > 0 ||
            throw(ArgumentError("project authoritative-byte limit must be positive"))
        max_hashed_resource_bytes > 0 ||
            throw(ArgumentError("project hashed-resource limit must be positive"))
        limits = (max_files, max_authoritative_bytes, max_hashed_resource_bytes)
        all(limit -> limit <= typemax(Int), limits) ||
            throw(OverflowError("project resolution limit exceeds Int"))
        return new(format_policy, Int.(limits)...)
    end
end

struct ProjectChecksumRecord
    path::String
    sha256::String
    span::SourceSpan
end

Base.:(==)(left::ProjectChecksumRecord, right::ProjectChecksumRecord) =
    left.path == right.path && left.sha256 == right.sha256 && left.span == right.span

struct ProjectChecksumManifest
    source::SourceDocument
    records::FormatItemList{ProjectChecksumRecord}

    function ProjectChecksumManifest(
        source::SourceDocument,
        records::AbstractVector{ProjectChecksumRecord},
        ::Val{:parsed_project_checksum_manifest},
    )
        return new(source, FormatItemList(records))
    end
end

Base.:(==)(left::ProjectChecksumManifest, right::ProjectChecksumManifest) =
    left.source == right.source && left.records == right.records

struct ProjectDocumentRecord
    path::String
    source_sha256::String
    document::ParsedFormatDocument
end

Base.:(==)(left::ProjectDocumentRecord, right::ProjectDocumentRecord) =
    left.path == right.path &&
    left.source_sha256 == right.source_sha256 &&
    left.document == right.document

struct ProjectFileRecord
    path::String
    role::ProjectFileRole
    size_bytes::Int
    sha256::Union{Nothing,String}
end

Base.:(==)(left::ProjectFileRecord, right::ProjectFileRecord) =
    left.path == right.path &&
    left.role == right.role &&
    left.size_bytes == right.size_bytes &&
    left.sha256 == right.sha256

struct ResolvedProjectDocuments
    source_kind::ProjectSourceKind
    root_path::String
    root::FormatNode
    documents::FormatItemList{ProjectDocumentRecord}
    files::FormatItemList{ProjectFileRecord}
    ignored_derived_paths::FormatItemList{String}
    checksum_manifest::Union{Nothing,ProjectChecksumManifest}
    source_sha256::String
    resolved_sha256::String

    function ResolvedProjectDocuments(
        source_kind::ProjectSourceKind,
        root_path::String,
        root::FormatNode,
        documents::AbstractVector{ProjectDocumentRecord},
        files::AbstractVector{ProjectFileRecord},
        ignored_derived_paths::AbstractVector{String},
        checksum_manifest::Union{Nothing,ProjectChecksumManifest},
        source_sha256::String,
        resolved_sha256::String,
        ::Val{:resolved_project_documents},
    )
        return new(
            source_kind,
            root_path,
            root,
            FormatItemList(documents),
            FormatItemList(files),
            FormatItemList(ignored_derived_paths),
            checksum_manifest,
            source_sha256,
            resolved_sha256,
        )
    end
end

Base.:(==)(left::ResolvedProjectDocuments, right::ResolvedProjectDocuments) =
    left.source_kind == right.source_kind &&
    left.root_path == right.root_path &&
    left.root == right.root &&
    left.documents == right.documents &&
    left.files == right.files &&
    left.ignored_derived_paths == right.ignored_derived_paths &&
    left.checksum_manifest == right.checksum_manifest &&
    left.source_sha256 == right.source_sha256 &&
    left.resolved_sha256 == right.resolved_sha256

const ProjectResolutionResult = FormatResult{ResolvedProjectDocuments}

struct _ProjectResolutionFailure <: Exception
    diagnostic::FormatDiagnostic
end

function _project_fail(
    code::Symbol,
    message::AbstractString,
    span::Union{Nothing,SourceSpan} = nothing,
)
    throw(_ProjectResolutionFailure(
        FormatDiagnostic(DiagnosticError, code, String(message), span),
    ))
end

function _project_path_span(path::String)
    position = SourcePosition(1, 1, 1)
    return SourceSpan(path, position, position)
end

function _project_path_key(path::String)
    return lowercase(Unicode.normalize(path; compose = true, stable = true))
end

function _project_portable_path(path::String, span::SourceSpan)
    isempty(path) && _project_fail(:empty_project_path, "project path must not be empty", span)
    isvalid(path) || _project_fail(
        :nonportable_project_path,
        "project path is not valid Unicode",
        span,
    )
    startswith(path, '/') &&
        _project_fail(:absolute_project_path, "project path must be relative", span)
    occursin('\\', path) && _project_fail(
        :nonportable_project_path,
        "project path must use forward slashes",
        span,
    )
    occursin(':', path) && _project_fail(
        :absolute_project_path,
        "project path must not contain a drive or URI scheme",
        span,
    )
    occursin(r"[\x00-\x1f\x7f<>\"|?*]", path) && _project_fail(
        :nonportable_project_path,
        "project path contains a prohibited portable-path character",
        span,
    )
    segments = split(path, '/'; keepempty = true)
    any(segment -> isempty(segment) || segment == "." || segment == "..", segments) &&
        _project_fail(
            :project_path_traversal,
            "project path contains an empty, current, or parent segment",
            span,
        )
    for segment in segments
        (endswith(segment, ' ') || endswith(segment, '.')) && _project_fail(
            :nonportable_project_path,
            "project path segment must not end with a space or dot",
            span,
        )
        stem = uppercase(first(split(segment, '.'; limit = 2)))
        stem in _PROJECT_WINDOWS_RESERVED_NAMES && _project_fail(
            :reserved_project_path,
            "project path contains a platform-reserved segment",
            span,
        )
    end
    return path
end

function _project_contained_path(root::String, portable_path::String, span::SourceSpan)
    _project_portable_path(portable_path, span)
    candidate = normpath(joinpath(root, split(portable_path, '/')...))
    root_prefix = string(root, Base.Filesystem.path_separator)
    (candidate == root || startswith(candidate, root_prefix)) || _project_fail(
        :project_path_escape,
        "project path escapes the project root",
        span,
    )
    return candidate
end

mutable struct _ProjectFileCandidate
    path::String
    absolute_path::String
    role::ProjectFileRole
    size_bytes::Int
    sha256::Union{Nothing,String}
end

function _project_is_yaml(path::String)
    return endswith(lowercase(path), ".yaml")
end

function _project_classify_path(path::String)
    path == "project.aimora.yaml" && return ProjectAuthoritativeDocument
    path == "checksums.sha256" && return ProjectChecksumResource
    segments = split(path, '/')
    length(segments) == 1 && begin
        name = only(segments)
        lowercase(name) in (".gitignore", ".gitattributes", ".gitmodules") &&
            return ProjectDocumentationResource
        (endswith(lowercase(name), ".md") ||
         uppercase(name) in ("LICENSE", "LICENCE", "COPYING")) &&
            return ProjectDocumentationResource
        name in ("schema-lock.json", "catalog-lock.toml", "plugin-lock.toml") &&
            return ProjectAuthoritativeResource
        return nothing
    end
    owner = first(segments)
    if owner in _PROJECT_AUTHORITATIVE_DOCUMENT_DIRECTORIES
        _project_is_yaml(path) && return ProjectAuthoritativeDocument
        (endswith(lowercase(path), ".md") ||
         (owner == "symbols" && endswith(lowercase(path), ".svg"))) &&
            return ProjectAuthoritativeResource
        owner == "provenance" && return ProjectAuthoritativeResource
        return nothing
    elseif owner in _PROJECT_AUTHORITATIVE_RESOURCE_DIRECTORIES
        return ProjectAuthoritativeResource
    elseif owner in _PROJECT_ARTIFACT_DIRECTORIES
        return ProjectArtifactResource
    elseif owner in _PROJECT_IMPORT_DIRECTORIES
        return ProjectImportResource
    elseif owner in _PROJECT_DERIVED_DIRECTORIES
        return ProjectDerivedResource
    end
    return nothing
end

function _project_discover_directory(root::String, policy::ProjectResolutionPolicy)
    candidates = Dict{String,_ProjectFileCandidate}()
    canonical_paths = Dict{String,String}()
    ignored = String[]
    file_count = 0
    for (directory, directories, files) in walkdir(root; follow_symlinks = false)
        sort!(directories)
        sort!(files)
        relative_directory = relpath(directory, root)
        at_root = relative_directory == "."
        retained_directories = String[]
        for name in directories
            absolute = joinpath(directory, name)
            relative = replace(relpath(absolute, root), '\\' => '/')
            islink(absolute) && _project_fail(
                :project_symlink_prohibited,
                "project directory contains a symbolic link",
                _project_path_span(relative),
            )
            if at_root && name == ".git"
                continue
            elseif at_root && name in _PROJECT_DERIVED_DIRECTORIES
                push!(ignored, string(name, '/'))
                continue
            elseif at_root && !(name in _PROJECT_ALLOWED_DIRECTORIES)
                _project_fail(
                    :unknown_project_directory,
                    "project root contains unknown directory $(name)",
                    _project_path_span(name),
                )
            end
            span = _project_path_span(relative)
            _project_portable_path(relative, span)
            key = _project_path_key(relative)
            if haskey(canonical_paths, key)
                _project_fail(
                    :project_path_collision,
                    "project paths $(canonical_paths[key]) and $(relative) collide by case or Unicode normalization",
                    span,
                )
            end
            canonical_paths[key] = relative
            push!(retained_directories, name)
        end
        empty!(directories)
        append!(directories, retained_directories)
        for name in files
            at_root && name == ".git" && continue
            file_count += 1
            file_count <= policy.max_files || _project_fail(
                :project_file_limit,
                "project exceeds the configured file-count limit",
            )
            absolute = joinpath(directory, name)
            relative = replace(relpath(absolute, root), '\\' => '/')
            span = _project_path_span(relative)
            islink(absolute) && _project_fail(
                :project_symlink_prohibited,
                "project contains a symbolic-link file",
                span,
            )
            isfile(absolute) || _project_fail(
                :project_regular_file_required,
                "project entry is not a regular file",
                span,
            )
            _project_portable_path(relative, span)
            key = _project_path_key(relative)
            if haskey(canonical_paths, key)
                _project_fail(
                    :project_path_collision,
                    "project paths $(canonical_paths[key]) and $(relative) collide by case or Unicode normalization",
                    span,
                )
            end
            canonical_paths[key] = relative
            role = _project_classify_path(relative)
            isnothing(role) && _project_fail(
                :unknown_project_file,
                "project contains an unclassified file $(relative)",
                span,
            )
            size = stat(absolute).size
            size <= typemax(Int) || _project_fail(
                :project_file_too_large,
                "project file size exceeds the host integer range",
                span,
            )
            candidates[relative] = _ProjectFileCandidate(
                relative,
                absolute,
                role,
                Int(size),
                nothing,
            )
        end
    end
    sort!(ignored)
    return candidates, ignored
end

function _project_read_source(
    candidate::_ProjectFileCandidate,
    policy::ProjectResolutionPolicy,
)
    candidate.size_bytes <= policy.format_policy.max_document_bytes || _project_fail(
        :project_document_too_large,
        "project document exceeds the configured document limit",
        _project_path_span(candidate.path),
    )
    isfile(candidate.absolute_path) && !islink(candidate.absolute_path) || _project_fail(
        :project_resource_missing,
        "project document $(candidate.path) is no longer a regular file",
        _project_path_span(candidate.path),
    )
    bytes = try
        read(candidate.absolute_path)
    catch error
        if error isa SystemError || error isa IOError
            _project_fail(
                :project_resource_unreadable,
                "project document $(candidate.path) cannot be read",
                _project_path_span(candidate.path),
            )
        end
        rethrow()
    end
    length(bytes) == candidate.size_bytes || _project_fail(
        :project_file_changed_during_resolution,
        "project document $(candidate.path) changed during resolution",
        _project_path_span(candidate.path),
    )
    source = source_document(bytes; source_name = candidate.path, policy = policy.format_policy)
    format_succeeded(source) || throw(_ProjectResolutionFailure(first(source.diagnostics)))
    candidate.sha256 = source.value.provenance.content_sha256
    return source.value
end

function _project_parse_document(
    candidate::_ProjectFileCandidate,
    policy::ProjectResolutionPolicy,
)
    source = _project_read_source(candidate, policy)
    parsed = parse_restricted_yaml(source; policy = policy.format_policy)
    format_succeeded(parsed) || throw(_ProjectResolutionFailure(first(parsed.diagnostics)))
    return parsed.value
end

function _project_parse_checksum_manifest(
    candidate::_ProjectFileCandidate,
    policy::ProjectResolutionPolicy,
)
    source = _project_read_source(candidate, policy)
    records = ProjectChecksumRecord[]
    seen = Set{String}()
    offset = 1
    for raw_line in split(source.text, '\n'; keepempty = true)
        line = endswith(raw_line, '\r') ? chop(raw_line; tail = 1) : raw_line
        line_bytes = ncodeunits(raw_line)
        if !isempty(line)
            ncodeunits(line) <= policy.format_policy.max_scalar_bytes || _project_fail(
                :project_checksum_line_too_large,
                "checksum manifest line exceeds the configured scalar limit",
                source_span(source, offset, offset + line_bytes),
            )
            matched = match(r"^([0-9a-f]{64})  (.+)$", line)
            span = source_span(source, offset, offset + line_bytes)
            isnothing(matched) && _project_fail(
                :invalid_project_checksum_line,
                "checksum line must contain lowercase SHA-256, two spaces, and a portable path",
                span,
            )
            digest = String(matched.captures[1])
            path = String(matched.captures[2])
            _project_portable_path(path, span)
            path == "checksums.sha256" && _project_fail(
                :recursive_project_checksum,
                "checksum manifest must not checksum itself",
                span,
            )
            path_key = _project_path_key(path)
            path_key in seen && _project_fail(
                :duplicate_project_checksum,
                "checksum manifest repeats path $(path)",
                span,
            )
            push!(seen, path_key)
            length(records) < policy.format_policy.max_collection_items || _project_fail(
                :project_checksum_record_limit,
                "checksum manifest exceeds the configured record limit",
                span,
            )
            push!(records, ProjectChecksumRecord(path, digest, span))
        end
        offset += line_bytes + 1
    end
    sort!(records; by = record -> record.path)
    return ProjectChecksumManifest(
        source,
        records,
        Val(:parsed_project_checksum_manifest),
    )
end

function _project_hash_file!(
    candidate::_ProjectFileCandidate,
    policy::ProjectResolutionPolicy,
    span::Union{Nothing,SourceSpan} = nothing,
)
    candidate.size_bytes <= policy.max_hashed_resource_bytes || _project_fail(
        :project_hashed_resource_too_large,
        "project resource exceeds the configured hashing limit",
        span,
    )
    isfile(candidate.absolute_path) && !islink(candidate.absolute_path) || _project_fail(
        :project_resource_missing,
        "project resource $(candidate.path) is no longer a regular file",
        span,
    )
    stat(candidate.absolute_path).size == candidate.size_bytes || _project_fail(
        :project_file_changed_during_resolution,
        "project resource $(candidate.path) changed during resolution",
        span,
    )
    digest = try
        bytes2hex(open(sha256, candidate.absolute_path))
    catch error
        if error isa SystemError || error isa IOError
            _project_fail(
                :project_resource_unreadable,
                "project resource $(candidate.path) cannot be read",
                span,
            )
        end
        rethrow()
    end
    candidate.sha256 = digest
    return digest
end

mutable struct _ProjectResolutionState
    source_kind::ProjectSourceKind
    root_directory::String
    policy::ProjectResolutionPolicy
    candidates::Dict{String,_ProjectFileCandidate}
    parsed_documents::Dict{String,ParsedFormatDocument}
    inclusion_owner::Dict{String,SourceSpan}
    inclusion_stack::Vector{String}
end

function _project_include_entry(node::FormatNode)
    node.value isa FormatMapping || return nothing
    entries = node.value.entries
    index = findfirst(entry -> entry.key.value.value == "\$include", entries)
    isnothing(index) && return nothing
    length(entries) == 1 || _project_fail(
        :include_envelope_unknown_field,
        "\$include envelope must contain no sibling fields",
        node.span,
    )
    entry = entries[index]
    entry.value.value isa FormatString || _project_fail(
        :include_path_kind_mismatch,
        "\$include value must be a project-relative string path",
        entry.value.span,
    )
    return entry
end

function _project_resolve_node(
    state::_ProjectResolutionState,
    node::FormatNode,
    owner_path::String,
)
    include_entry = _project_include_entry(node)
    if !isnothing(include_entry)
        state.source_kind == ProjectDirectorySource || _project_fail(
            :compact_project_include_prohibited,
            "compact projects cannot reference additional authoritative documents",
            include_entry.value.span,
        )
        path = include_entry.value.value.value
        _project_portable_path(path, include_entry.value.span)
        if startswith(path, "results/") || startswith(path, ".aimora-cache/")
            _project_fail(
                :derived_project_include_prohibited,
                "derived project files cannot own authoritative included data",
                include_entry.value.span,
            )
        end
        candidate = get(state.candidates, path, nothing)
        isnothing(candidate) && _project_fail(
            :included_project_document_missing,
            "included project document $(path) does not exist",
            include_entry.value.span,
        )
        candidate.role == ProjectAuthoritativeDocument || _project_fail(
            :included_project_path_not_document,
            "\$include target $(path) is not an authoritative YAML document",
            include_entry.value.span,
        )
        path == "project.aimora.yaml" && _project_fail(
            :project_root_reinclude_prohibited,
            "project root cannot be included as a child document",
            include_entry.value.span,
        )
        path in state.inclusion_stack && _project_fail(
            :project_include_cycle,
            "project include cycle reaches $(path)",
            include_entry.value.span,
        )
        length(state.inclusion_stack) < state.policy.format_policy.max_nesting_depth ||
            _project_fail(
                :project_include_depth_limit,
                "project include chain exceeds the configured nesting limit",
                include_entry.value.span,
            )
        if haskey(state.inclusion_owner, path)
            _project_fail(
                :duplicate_project_document_ownership,
                "authoritative document $(path) is included more than once",
                include_entry.value.span,
            )
        end
        state.inclusion_owner[path] = include_entry.value.span
        document = get!(state.parsed_documents, path) do
            _project_parse_document(candidate, state.policy)
        end
        push!(state.inclusion_stack, path)
        try
            return _project_resolve_node(state, document.root, path)
        finally
            pop!(state.inclusion_stack)
        end
    elseif node.value isa FormatMapping
        entries = FormatMappingEntry[]
        for entry in node.value.entries
            value = _project_resolve_node(state, entry.value, owner_path)
            push!(entries, FormatMappingEntry(entry.key, value))
        end
        return FormatNode(FormatMapping(entries), node.span)
    elseif node.value isa FormatSequence
        elements = FormatNode[
            _project_resolve_node(state, child, owner_path)
            for child in node.value.elements
        ]
        return FormatNode(FormatSequence(elements), node.span)
    end
    return node
end

function _project_verify_contained_regular_file(
    root::String,
    path::String,
    span::SourceSpan,
)
    absolute = _project_contained_path(root, path, span)
    ispath(absolute) || _project_fail(
        :project_resource_missing,
        "project resource $(path) does not exist",
        span,
    )
    islink(absolute) && _project_fail(
        :project_symlink_prohibited,
        "project resource $(path) is a symbolic link",
        span,
    )
    isfile(absolute) || _project_fail(
        :project_regular_file_required,
        "project resource $(path) is not a regular file",
        span,
    )
    resolved = realpath(absolute)
    root_prefix = string(root, Base.Filesystem.path_separator)
    startswith(resolved, root_prefix) || _project_fail(
        :project_path_escape,
        "project resource resolves outside the project root",
        span,
    )
    return absolute
end

function _project_collect_artifacts!(
    state::_ProjectResolutionState,
    node::FormatNode,
    artifacts::Dict{String,ArtifactEnvelope},
)
    if node.value isa FormatMapping
        has_artifact = any(entry -> entry.key.value.value == "\$artifact", node.value.entries)
        if has_artifact
            result = parse_artifact_envelope(node; policy = state.policy.format_policy)
            format_succeeded(result) ||
                throw(_ProjectResolutionFailure(first(result.diagnostics)))
            descriptor = result.value
            if haskey(artifacts, descriptor.path)
                previous = artifacts[descriptor.path]
                (previous.sha256 == descriptor.sha256 &&
                 previous.size_bytes == descriptor.size_bytes) || _project_fail(
                    :conflicting_project_artifact,
                    "artifact $(descriptor.path) has conflicting digest or size declarations",
                    node.span,
                )
            else
                artifacts[descriptor.path] = descriptor
            end
            return nothing
        end
        for entry in node.value.entries
            _project_collect_artifacts!(state, entry.value, artifacts)
        end
    elseif node.value isa FormatSequence
        for child in node.value.elements
            _project_collect_artifacts!(state, child, artifacts)
        end
    end
    return nothing
end

function _project_verify_artifacts!(
    state::_ProjectResolutionState,
    root::FormatNode,
)
    artifacts = Dict{String,ArtifactEnvelope}()
    _project_collect_artifacts!(state, root, artifacts)
    for path in sort!(collect(keys(artifacts)))
        descriptor = artifacts[path]
        segments = split(path, '/')
        first(segments) in _PROJECT_ARTIFACT_DIRECTORIES || _project_fail(
            :artifact_outside_data_directory,
            "artifact path $(path) must be owned by data/",
            descriptor.span,
        )
        absolute = _project_verify_contained_regular_file(
            state.root_directory,
            path,
            descriptor.span,
        )
        size = stat(absolute).size
        size <= typemax(Int) || _project_fail(
            :project_file_too_large,
            "artifact file size exceeds the host integer range",
            descriptor.span,
        )
        if !isnothing(descriptor.size_bytes) && descriptor.size_bytes != size
            _project_fail(
                :project_artifact_size_mismatch,
                "artifact $(path) size differs from its declaration",
                descriptor.span,
            )
        end
        if !haskey(state.candidates, path) && length(state.candidates) >= state.policy.max_files
            _project_fail(
                :project_file_limit,
                "project exceeds the configured file-count limit",
                descriptor.span,
            )
        end
        candidate = get!(state.candidates, path) do
            _ProjectFileCandidate(
                path,
                absolute,
                ProjectArtifactResource,
                Int(size),
                nothing,
            )
        end
        candidate.role == ProjectArtifactResource || _project_fail(
            :artifact_resource_role_mismatch,
            "artifact $(path) is not classified as a data resource",
            descriptor.span,
        )
        digest = _project_hash_file!(candidate, state.policy, descriptor.span)
        digest == descriptor.sha256 || _project_fail(
            :project_artifact_sha256_mismatch,
            "artifact $(path) SHA-256 differs from its declaration",
            descriptor.span,
        )
    end
    return artifacts
end

function _project_verify_checksum_manifest!(
    state::_ProjectResolutionState,
    manifest::ProjectChecksumManifest,
)
    for record in manifest.records
        if startswith(record.path, "results/") || startswith(record.path, ".aimora-cache/")
            _project_fail(
                :derived_project_checksum_prohibited,
                "checksum manifest must not make derived files authoritative",
                record.span,
            )
        end
        candidate = get(state.candidates, record.path, nothing)
        isnothing(candidate) && _project_fail(
            :project_checksum_target_missing,
            "checksum target $(record.path) does not exist in the project",
            record.span,
        )
        candidate.role == ProjectDerivedResource && _project_fail(
            :derived_project_checksum_prohibited,
            "checksum manifest must not make derived files authoritative",
            record.span,
        )
        digest = isnothing(candidate.sha256) ?
            _project_hash_file!(candidate, state.policy, record.span) : candidate.sha256
        digest == record.sha256 || _project_fail(
            :project_checksum_mismatch,
            "checksum target $(record.path) differs from the manifest",
            record.span,
        )
    end
    return nothing
end

function _project_hash_authoritative_resources!(
    candidates::Dict{String,_ProjectFileCandidate},
    policy::ProjectResolutionPolicy,
)
    total = 0
    for path in sort!(collect(keys(candidates)))
        candidate = candidates[path]
        if candidate.role in (
            ProjectAuthoritativeDocument,
            ProjectAuthoritativeResource,
            ProjectChecksumResource,
        )
            total <= policy.max_authoritative_bytes - candidate.size_bytes || _project_fail(
                :project_authoritative_bytes_limit,
                "project exceeds the configured authoritative-byte limit",
                _project_path_span(path),
            )
            total += candidate.size_bytes
            isnothing(candidate.sha256) && _project_hash_file!(candidate, policy)
        end
    end
    return nothing
end

function _project_source_hash(
    candidates::Dict{String,_ProjectFileCandidate},
)
    output = IOBuffer()
    for path in sort!(collect(keys(candidates)))
        candidate = candidates[path]
        candidate.role in (
            ProjectDocumentationResource,
            ProjectImportResource,
            ProjectDerivedResource,
        ) && continue
        isnothing(candidate.sha256) && continue
        print(output, UInt8(candidate.role), '\0', path, '\0', candidate.sha256, '\0')
    end
    return bytes2hex(sha256(take!(output)))
end

function _project_final_records(candidates::Dict{String,_ProjectFileCandidate})
    records = ProjectFileRecord[]
    for path in sort!(collect(keys(candidates)))
        candidate = candidates[path]
        push!(records, ProjectFileRecord(
            path,
            candidate.role,
            candidate.size_bytes,
            candidate.sha256,
        ))
    end
    return records
end

function _project_resolve_directory(
    input_path::String,
    policy::ProjectResolutionPolicy,
)
    directory = isdir(input_path) ? input_path : dirname(input_path)
    islink(directory) && _project_fail(
        :project_symlink_prohibited,
        "project root directory must not be a symbolic link",
    )
    root_directory = realpath(directory)
    candidates, ignored = _project_discover_directory(root_directory, policy)
    root_candidate = get(candidates, "project.aimora.yaml", nothing)
    isnothing(root_candidate) && _project_fail(
        :project_root_missing,
        "directory project requires project.aimora.yaml",
        _project_path_span("project.aimora.yaml"),
    )
    root_document = _project_parse_document(root_candidate, policy)
    root_document.root.value isa FormatMapping || _project_fail(
        :project_document_root_kind,
        "project root document must have a mapping root",
        root_document.root.span,
    )
    parsed = Dict("project.aimora.yaml" => root_document)
    state = _ProjectResolutionState(
        ProjectDirectorySource,
        root_directory,
        policy,
        candidates,
        parsed,
        Dict{String,SourceSpan}(),
        ["project.aimora.yaml"],
    )
    resolved_root = _project_resolve_node(state, root_document.root, "project.aimora.yaml")
    resolved_diagnostics = validate_format_tree(resolved_root, policy.format_policy)
    isempty(resolved_diagnostics) ||
        throw(_ProjectResolutionFailure(first(resolved_diagnostics)))
    orphaned = sort!([
        path for (path, candidate) in candidates
        if candidate.role == ProjectAuthoritativeDocument &&
           path != "project.aimora.yaml" &&
           !haskey(state.inclusion_owner, path)
    ])
    isempty(orphaned) || _project_fail(
        :unowned_authoritative_document,
        "authoritative YAML document $(first(orphaned)) is not included by the project root",
        _project_path_span(first(orphaned)),
    )
    _project_verify_artifacts!(state, resolved_root)
    manifest = if haskey(candidates, "checksums.sha256")
        parsed_manifest = _project_parse_checksum_manifest(
            candidates["checksums.sha256"],
            policy,
        )
        _project_verify_checksum_manifest!(state, parsed_manifest)
        parsed_manifest
    else
        nothing
    end
    _project_hash_authoritative_resources!(candidates, policy)
    canonical_hash = canonical_json_sha256(resolved_root; policy = policy.format_policy)
    format_succeeded(canonical_hash) ||
        throw(_ProjectResolutionFailure(first(canonical_hash.diagnostics)))
    documents = ProjectDocumentRecord[
        ProjectDocumentRecord(
            path,
            parsed[path].source.provenance.content_sha256,
            parsed[path],
        )
        for path in sort!(collect(keys(parsed)))
    ]
    return ResolvedProjectDocuments(
        ProjectDirectorySource,
        "project.aimora.yaml",
        resolved_root,
        documents,
        _project_final_records(candidates),
        ignored,
        manifest,
        _project_source_hash(candidates),
        canonical_hash.value,
        Val(:resolved_project_documents),
    )
end

function _project_resolve_compact(
    input_path::String,
    policy::ProjectResolutionPolicy,
)
    islink(input_path) && _project_fail(
        :project_symlink_prohibited,
        "compact project file must not be a symbolic link",
    )
    isfile(input_path) || _project_fail(
        :compact_project_missing,
        "compact project path is not a regular file",
    )
    name = basename(input_path)
    endswith(lowercase(name), ".aimora.yaml") || _project_fail(
        :compact_project_suffix_required,
        "compact project file must end in .aimora.yaml",
        _project_path_span(name),
    )
    _project_portable_path(name, _project_path_span(name))
    root_directory = realpath(dirname(input_path))
    size = stat(input_path).size
    size <= typemax(Int) || _project_fail(
        :project_file_too_large,
        "compact project size exceeds the host integer range",
        _project_path_span(name),
    )
    candidate = _ProjectFileCandidate(
        name,
        realpath(input_path),
        ProjectAuthoritativeDocument,
        Int(size),
        nothing,
    )
    document = _project_parse_document(candidate, policy)
    document.root.value isa FormatMapping || _project_fail(
        :project_document_root_kind,
        "compact project document must have a mapping root",
        document.root.span,
    )
    candidates = Dict(name => candidate)
    state = _ProjectResolutionState(
        ProjectCompactSource,
        root_directory,
        policy,
        candidates,
        Dict(name => document),
        Dict{String,SourceSpan}(),
        [name],
    )
    resolved_root = _project_resolve_node(state, document.root, name)
    resolved_diagnostics = validate_format_tree(resolved_root, policy.format_policy)
    isempty(resolved_diagnostics) ||
        throw(_ProjectResolutionFailure(first(resolved_diagnostics)))
    _project_verify_artifacts!(state, resolved_root)
    _project_hash_authoritative_resources!(candidates, policy)
    canonical_hash = canonical_json_sha256(resolved_root; policy = policy.format_policy)
    format_succeeded(canonical_hash) ||
        throw(_ProjectResolutionFailure(first(canonical_hash.diagnostics)))
    documents = [ProjectDocumentRecord(
        name,
        document.source.provenance.content_sha256,
        document,
    )]
    return ResolvedProjectDocuments(
        ProjectCompactSource,
        name,
        resolved_root,
        documents,
        _project_final_records(candidates),
        String[],
        nothing,
        _project_source_hash(candidates),
        canonical_hash.value,
        Val(:resolved_project_documents),
    )
end

"""Resolve a compact or directory project into an inert deterministic document set."""
function resolve_project_documents(
    path::AbstractString;
    policy::ProjectResolutionPolicy = ProjectResolutionPolicy(),
)
    try
        requested_path = String(path)
        isempty(requested_path) && _project_fail(
            :empty_project_input_path,
            "project input path must not be empty",
        )
        occursin('\0', requested_path) && _project_fail(
            :nonportable_project_input_path,
            "project input path must not contain NUL",
        )
        input = abspath(requested_path)
        if isdir(input) || basename(input) == "project.aimora.yaml"
            return ProjectResolutionResult(_project_resolve_directory(input, policy))
        end
        return ProjectResolutionResult(_project_resolve_compact(input, policy))
    catch error
        if error isa _ProjectResolutionFailure
            return ProjectResolutionResult(nothing, [error.diagnostic])
        elseif error isa SystemError || error isa IOError
            diagnostic = FormatDiagnostic(
                DiagnosticError,
                :project_filesystem_error,
                "project filesystem operation failed without producing a resolved document set",
            )
            return ProjectResolutionResult(nothing, [diagnostic])
        end
        rethrow()
    end
end

"""Serialize a resolved project as one restricted-YAML document when all authoritative resources are inlineable."""
function serialize_compact_project(
    project::ResolvedProjectDocuments;
    policy::FormatInputPolicy = FormatInputPolicy(),
)
    noninline = sort!([
        file.path for file in project.files
        if file.role == ProjectAuthoritativeResource
    ])
    if !isempty(noninline)
        diagnostic = FormatDiagnostic(
            DiagnosticError,
            :noninline_authoritative_resource,
            "authoritative resource $(first(noninline)) cannot be represented inside compact YAML",
            _project_path_span(first(noninline)),
        )
        return FormatSerializationResult(nothing, [diagnostic])
    end
    return serialize_restricted_yaml(project.root; policy)
end
