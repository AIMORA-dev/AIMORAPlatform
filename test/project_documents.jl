function write_project_test_file(root::String, path::String, content::AbstractString)
    absolute = joinpath(root, split(path, '/')...)
    mkpath(dirname(absolute))
    write(absolute, content)
    return absolute
end

function project_test_sha256(path::String)
    return bytes2hex(sha256(read(path)))
end

function project_resolution_failure(
    path::String,
    code::Symbol;
    policy::ProjectResolutionPolicy = ProjectResolutionPolicy(),
)
    result = resolve_project_documents(path; policy)
    @test !format_succeeded(result)
    diagnostic = only(result.diagnostics)
    @test diagnostic.code == code
    return diagnostic
end

function project_mapping_value(node::FormatNode, key::String)
    node.value isa FormatMapping || error("project test node is not a mapping")
    return only(entry.value for entry in node.value.entries if entry.key.value.value == key)
end

@testset "compact project resolution and artifact verification" begin
    mktempdir() do directory
        artifact_path = write_project_test_file(directory, "data/samples.bin", "AIMORA samples")
        artifact_digest = project_test_sha256(artifact_path)
        project_path = write_project_test_file(
            directory,
            "source-load.aimora.yaml",
            """format: {name: aimora-case, version: 1.0.0}
project: {id: source-load}
assets:
  - id: source.grid
  - id: load.rl
waveforms:
  \$artifact:
    path: data/samples.bin
    format: binary
    sha256: $(artifact_digest)
    size_bytes: 14
""",
        )
        loaded_modules = copy(Base.loaded_modules)
        result = resolve_project_documents(project_path)
        @test format_succeeded(result)
        project = result.value
        @test project.source_kind == ProjectCompactSource
        @test project.root_path == "source-load.aimora.yaml"
        @test length(project.documents) == 1
        @test getfield.(collect(project.files), :path) ==
              ["data/samples.bin", "source-load.aimora.yaml"]
        artifact = only(file for file in project.files if file.role == ProjectArtifactResource)
        @test artifact.sha256 == artifact_digest
        @test artifact.size_bytes == 14
        @test occursin(r"^[0-9a-f]{64}$", project.source_sha256)
        @test occursin(r"^[0-9a-f]{64}$", project.resolved_sha256)
        @test project.resolved_sha256 == canonical_json_sha256(project.root).value
        @test isnothing(project.checksum_manifest)
        @test isempty(project.ignored_derived_paths)
        @test Base.loaded_modules == loaded_modules
        @test all(!isabspath(file.path) for file in project.files)

        compact = serialize_compact_project(project)
        @test format_succeeded(compact)
        repeated_path = write_project_test_file(
            directory,
            "roundtrip.aimora.yaml",
            String(collect(compact.value.bytes)),
        )
        repeated = resolve_project_documents(repeated_path)
        @test format_succeeded(repeated)
        @test repeated.value.resolved_sha256 == project.resolved_sha256
        @test repeated.value.source_sha256 != project.source_sha256

        package_directory = joinpath(directory, "promoted")
        write_project_test_file(
            package_directory,
            "project.aimora.yaml",
            String(collect(compact.value.bytes)),
        )
        write_project_test_file(package_directory, "data/samples.bin", "AIMORA samples")
        promoted = resolve_project_documents(package_directory)
        @test format_succeeded(promoted)
        @test promoted.value.resolved_sha256 == project.resolved_sha256
    end

    mktempdir() do directory
        path = write_project_test_file(
            directory,
            "missing.aimora.yaml",
            """project: {id: missing}
data:
  \$artifact: {path: data/missing.bin, format: binary, sha256: $(repeat("a", 64))}
""",
        )
        diagnostic = project_resolution_failure(path, :project_resource_missing)
        @test diagnostic.span.source_name == "missing.aimora.yaml"
        @test diagnostic.span.start.line == 3
    end

    for (declared_size, digest, code) in [
        (4, repeat("a", 64), :project_artifact_size_mismatch),
        (3, repeat("a", 64), :project_artifact_sha256_mismatch),
    ]
        mktempdir() do directory
            write_project_test_file(directory, "data/value.bin", "abc")
            path = write_project_test_file(
                directory,
                "bad-artifact.aimora.yaml",
                """project: {id: bad-artifact}
data:
  \$artifact:
    path: data/value.bin
    format: binary
    sha256: $(digest)
    size_bytes: $(declared_size)
""",
            )
            project_resolution_failure(path, code)
        end
    end

    mktempdir() do directory
        artifact_path = write_project_test_file(directory, "data/value.bin", "abc")
        digest = project_test_sha256(artifact_path)
        path = write_project_test_file(
            directory,
            "conflict.aimora.yaml",
            """project: {id: conflict}
first: {\$artifact: {path: data/value.bin, format: binary, sha256: $(digest)}}
second: {\$artifact: {path: data/value.bin, format: binary, sha256: $(repeat("a", 64))}}
""",
        )
        project_resolution_failure(path, :conflicting_project_artifact)
    end

    mktempdir() do directory
        artifact_path = write_project_test_file(directory, "other/value.bin", "abc")
        digest = project_test_sha256(artifact_path)
        path = write_project_test_file(
            directory,
            "outside-data.aimora.yaml",
            """project: {id: outside-data}
value: {\$artifact: {path: other/value.bin, format: binary, sha256: $(digest)}}
""",
        )
        project_resolution_failure(path, :artifact_outside_data_directory)
    end
end

@testset "directory includes resolve to canonical compact-equivalent data" begin
    mktempdir() do directory
        root_path = write_project_test_file(
            directory,
            "project.aimora.yaml",
            """format: {name: aimora-project, version: 1.0.0}
project: {id: split-grid}
nodes: {\$include: model/nodes.yaml}
assets: {\$include: model/assets.yaml}
scenario: {\$include: scenarios/base.yaml}
""",
        )
        nodes_path = write_project_test_file(
            directory,
            "model/nodes.yaml",
            "- {id: node.hv}\n- {id: node.lv}\n",
        )
        assets_path = write_project_test_file(
            directory,
            "model/assets.yaml",
            "- {id: transformer.t1, from: node.hv, to: node.lv}\n",
        )
        scenario_path = write_project_test_file(
            directory,
            "scenarios/base.yaml",
            "{id: scenario.base, enabled: true}\n",
        )
        write_project_test_file(directory, "results/invalid.yaml", "this: [is: not: parsed")
        write_project_test_file(directory, ".aimora-cache/broken.yaml", "{not yaml")
        checksums = join([
            "$(project_test_sha256(root_path))  project.aimora.yaml",
            "$(project_test_sha256(nodes_path))  model/nodes.yaml",
            "$(project_test_sha256(assets_path))  model/assets.yaml",
            "$(project_test_sha256(scenario_path))  scenarios/base.yaml",
        ], "\n") * "\n"
        write_project_test_file(directory, "checksums.sha256", checksums)

        directory_result = resolve_project_documents(directory)
        @test format_succeeded(directory_result)
        project = directory_result.value
        @test project.source_kind == ProjectDirectorySource
        @test getfield.(collect(project.documents), :path) == [
            "model/assets.yaml",
            "model/nodes.yaml",
            "project.aimora.yaml",
            "scenarios/base.yaml",
        ]
        @test collect(project.ignored_derived_paths) == [".aimora-cache/", "results/"]
        @test length(project.checksum_manifest.records) == 4
        @test project_mapping_value(project.root, "nodes").value isa FormatSequence
        @test project_mapping_value(project.root, "scenario").value isa FormatMapping
        first_node = project_mapping_value(project.root, "nodes").value.elements[1]
        @test first_node.span.source_name == "model/nodes.yaml"

        repeated_directory = resolve_project_documents(directory)
        @test repeated_directory.value.source_sha256 == project.source_sha256
        @test repeated_directory.value.resolved_sha256 == project.resolved_sha256
        package_root = normpath(joinpath(@__DIR__, ".."))
        child_script = join([
            "using AIMORAFormats",
            "result = resolve_project_documents($(repr(directory)))",
            "result.value === nothing && error(result.diagnostics)",
            "print(result.value.source_sha256, '\\n', result.value.resolved_sha256)",
        ], "; ")
        child_command = `$(Base.julia_cmd()) --startup-file=no --project=$(package_root) -e $(child_script)`
        @test read(child_command, String) ==
              string(project.source_sha256, '\n', project.resolved_sha256)

        rm(joinpath(directory, "results"); recursive = true)
        rm(joinpath(directory, ".aimora-cache"); recursive = true)
        without_cache = resolve_project_documents(directory)
        @test format_succeeded(without_cache)
        @test without_cache.value.source_sha256 == project.source_sha256
        @test without_cache.value.resolved_sha256 == project.resolved_sha256

        compact_result = serialize_compact_project(project)
        @test format_succeeded(compact_result)
        compact_path = write_project_test_file(
            directory,
            "split-grid.aimora.yaml",
            String(collect(compact_result.value.bytes)),
        )
        compact_project = resolve_project_documents(compact_path)
        @test format_succeeded(compact_project)
        @test compact_project.value.resolved_sha256 == project.resolved_sha256
        @test compact_project.value.source_sha256 != project.source_sha256
    end
end

@testset "directory data-only open never executes scripts or derived files" begin
    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            "project: {id: inert-automation}\n",
        )
        write_project_test_file(
            directory,
            "scripts/danger.jl",
            "module ProjectResolverMustNeverLoad\nerror(\"must not execute\")\nend\n",
        )
        write_project_test_file(
            directory,
            "locks/plugin-lock.toml",
            "entrypoint = \"ProjectResolverMustNeverLoad:run\"\n",
        )
        write_project_test_file(directory, "symbols/local.svg", "<svg></svg>\n")
        write_project_test_file(directory, "results/result.yaml", "{unterminated")
        loaded_modules = copy(Base.loaded_modules)
        result = resolve_project_documents(directory)
        @test format_succeeded(result)
        @test !isdefined(Main, :ProjectResolverMustNeverLoad)
        @test Base.loaded_modules == loaded_modules
        @test Set(file.role for file in result.value.files) == Set([
            ProjectAuthoritativeDocument,
            ProjectAuthoritativeResource,
        ])
        compact = serialize_compact_project(result.value)
        @test !format_succeeded(compact)
        @test only(compact.diagnostics).code == :noninline_authoritative_resource
        @test only(compact.diagnostics).span.source_name == "locks/plugin-lock.toml"
    end
end

@testset "project include diagnostics reject ambiguity and hidden ownership" begin
    include_failures = [
        ("{\$include: model/missing.yaml}", :included_project_document_missing),
        ("{\$include: ../outside.yaml}", :project_path_traversal),
        ("{\$include: /absolute.yaml}", :absolute_project_path),
        ("{\$include: 'https://example.com/model.yaml'}", :absolute_project_path),
        ("{\$include: 'model/*.yaml'}", :nonportable_project_path),
        ("{\$include: data/CON.bin}", :reserved_project_path),
        ("{\$include: results/cache.yaml}", :derived_project_include_prohibited),
        ("{\$include: project.aimora.yaml}", :project_root_reinclude_prohibited),
        ("{\$include: data/value.toml}", :included_project_path_not_document),
        ("{\$include: 3}", :include_path_kind_mismatch),
        ("{\$include: model/value.yaml, merge: true}", :include_envelope_unknown_field),
    ]
    for (include_text, code) in include_failures
        mktempdir() do directory
            write_project_test_file(
                directory,
                "project.aimora.yaml",
                "project: {id: include-failure}\nvalue: $(include_text)\n",
            )
            write_project_test_file(directory, "model/value.yaml", "{value: 1}\n")
            write_project_test_file(directory, "data/value.toml", "value = 1\n")
            diagnostic = project_resolution_failure(directory, code)
            code == :included_project_document_missing && begin
                @test diagnostic.span.source_name == "project.aimora.yaml"
                @test diagnostic.span.start.line == 2
            end
        end
    end

    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            "project: {id: cycle}\nvalue: {\$include: model/a.yaml}\n",
        )
        write_project_test_file(directory, "model/a.yaml", "{\$include: model/b.yaml}\n")
        write_project_test_file(directory, "model/b.yaml", "{\$include: model/a.yaml}\n")
        project_resolution_failure(directory, :project_include_cycle)
    end

    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            """project: {id: duplicate-owner}
first: {\$include: model/shared.yaml}
second: {\$include: model/shared.yaml}
""",
        )
        write_project_test_file(directory, "model/shared.yaml", "{value: 1}\n")
        project_resolution_failure(directory, :duplicate_project_document_ownership)
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: orphan}\n")
        write_project_test_file(directory, "model/orphan.yaml", "{value: 1}\n")
        project_resolution_failure(directory, :unowned_authoritative_document)
    end

    mktempdir() do directory
        path = write_project_test_file(
            directory,
            "compact.aimora.yaml",
            "project: {id: compact}\nvalue: {\$include: model/value.yaml}\n",
        )
        write_project_test_file(directory, "model/value.yaml", "{value: 1}\n")
        project_resolution_failure(path, :compact_project_include_prohibited)
    end
end

@testset "project paths, roots, collisions, and derived boundaries" begin
    mktempdir() do directory
        project_resolution_failure(directory, :project_root_missing)
        write_project_test_file(directory, "project.yaml", "project: {id: alternate}\n")
        project_resolution_failure(directory, :unknown_project_file)
    end

    mktempdir() do directory
        path = write_project_test_file(directory, "project.yaml", "project: {id: compact}\n")
        project_resolution_failure(path, :compact_project_suffix_required)
    end

    for paths in (["model/A.yaml", "model/a.yaml"], ["model/é.yaml", "model/e\u0301.yaml"])
        mktempdir() do directory
            write_project_test_file(directory, "project.aimora.yaml", "project: {id: collision}\n")
            for path in paths
                write_project_test_file(directory, path, "{value: 1}\n")
            end
            project_resolution_failure(directory, :project_path_collision)
        end
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: unknown}\n")
        write_project_test_file(directory, "unknown/file.yaml", "{value: 1}\n")
        project_resolution_failure(directory, :unknown_project_directory)
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: unknown}\n")
        write_project_test_file(directory, "notes.txt", "not admitted\n")
        project_resolution_failure(directory, :unknown_project_file)
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: git-metadata}\n")
        write_project_test_file(directory, ".git", "gitdir: ../worktrees/project\n")
        @test format_succeeded(resolve_project_documents(directory))
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "- not\n- a mapping\n")
        project_resolution_failure(directory, :project_document_root_kind)
    end

    if !Sys.iswindows()
        mktempdir() do base
            directory = joinpath(base, "project")
            mkpath(joinpath(directory, "model"))
            write_project_test_file(directory, "project.aimora.yaml", "project: {id: symlink}\n")
            outside = write_project_test_file(base, "outside.yaml", "{value: 1}\n")
            symlink(outside, joinpath(directory, "model", "linked.yaml"))
            project_resolution_failure(directory, :project_symlink_prohibited)
        end
    end
end

@testset "checksum manifests are strict and cannot promote derived data" begin
    manifest_failures = [
        ("$(repeat("A", 64))  project.aimora.yaml\n", :invalid_project_checksum_line),
        ("$(repeat("a", 64)) project.aimora.yaml\n", :invalid_project_checksum_line),
        ("$(repeat("a", 64))  checksums.sha256\n", :recursive_project_checksum),
        ("$(repeat("a", 64))  missing.yaml\n", :project_checksum_target_missing),
        ("$(repeat("a", 64))  results/cache.bin\n", :derived_project_checksum_prohibited),
        ("$(repeat("a", 64))  project.aimora.yaml\n", :project_checksum_mismatch),
        (
            "$(repeat("a", 64))  project.aimora.yaml\n$(repeat("b", 64))  project.aimora.yaml\n",
            :duplicate_project_checksum,
        ),
    ]
    for (manifest, code) in manifest_failures
        mktempdir() do directory
            write_project_test_file(directory, "project.aimora.yaml", "project: {id: checksum}\n")
            write_project_test_file(directory, "checksums.sha256", manifest)
            project_resolution_failure(directory, code)
        end
    end


    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: empty-checksum}\n")
        write_project_test_file(directory, "checksums.sha256", "\r")
        result = resolve_project_documents(directory)
        @test format_succeeded(result)
        @test isempty(result.value.checksum_manifest.records)
    end
end

@testset "project resolution resource limits are deterministic" begin
    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            "project: {id: file-limit}\nvalue: {\$include: model/value.yaml}\n",
        )
        write_project_test_file(directory, "model/value.yaml", "{value: 1}\n")
        project_resolution_failure(
            directory,
            :project_file_limit;
            policy = ProjectResolutionPolicy(max_files = 1),
        )
    end

    mktempdir() do directory
        path = write_project_test_file(
            directory,
            "large.aimora.yaml",
            "project: {id: document-limit}\n",
        )
        project_resolution_failure(
            path,
            :project_document_too_large;
            policy = ProjectResolutionPolicy(
                format_policy = FormatInputPolicy(max_document_bytes = 8),
            ),
        )
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: total}\n")
        project_resolution_failure(
            directory,
            :project_authoritative_bytes_limit;
            policy = ProjectResolutionPolicy(max_authoritative_bytes = 8),
        )
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "project: {id: hash}\n")
        write_project_test_file(directory, "scripts/large.jl", repeat("x", 20))
        project_resolution_failure(
            directory,
            :project_hashed_resource_too_large;
            policy = ProjectResolutionPolicy(max_hashed_resource_bytes = 8),
        )
    end

    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            "project: {id: depth}\nvalue: {\$include: model/a.yaml}\n",
        )
        write_project_test_file(directory, "model/a.yaml", "{\$include: model/b.yaml}\n")
        write_project_test_file(directory, "model/b.yaml", "{\$include: model/c.yaml}\n")
        write_project_test_file(directory, "model/c.yaml", "{value: 1}\n")
        project_resolution_failure(
            directory,
            :project_include_depth_limit;
            policy = ProjectResolutionPolicy(
                format_policy = FormatInputPolicy(max_nesting_depth = 3),
            ),
        )
    end

    mktempdir() do directory
        write_project_test_file(
            directory,
            "project.aimora.yaml",
            "project: {\$include: model/values.yaml}\n",
        )
        write_project_test_file(directory, "model/values.yaml", "[1, 2, 3, 4]\n")
        project_resolution_failure(
            directory,
            :collection_too_large;
            policy = ProjectResolutionPolicy(
                format_policy = FormatInputPolicy(max_collection_items = 4),
            ),
        )
    end

    mktempdir() do directory
        root_path = write_project_test_file(directory, "project.aimora.yaml", "{}\n")
        first_path = write_project_test_file(directory, "README.md", "first\n")
        second_path = write_project_test_file(directory, "LICENCE", "second\n")
        write_project_test_file(
            directory,
            "checksums.sha256",
            """$(project_test_sha256(root_path))  project.aimora.yaml
$(project_test_sha256(first_path))  README.md
$(project_test_sha256(second_path))  LICENCE
""",
        )
        project_resolution_failure(
            directory,
            :project_checksum_record_limit;
            policy = ProjectResolutionPolicy(
                format_policy = FormatInputPolicy(max_collection_items = 2),
            ),
        )
    end

    mktempdir() do directory
        write_project_test_file(directory, "project.aimora.yaml", "{}\n")
        write_project_test_file(
            directory,
            "checksums.sha256",
            "$(repeat("a", 64))  project.aimora.yaml\n",
        )
        project_resolution_failure(
            directory,
            :project_checksum_line_too_large;
            policy = ProjectResolutionPolicy(
                format_policy = FormatInputPolicy(max_scalar_bytes = 70),
            ),
        )
    end


    mktempdir() do directory
        artifact_path = write_project_test_file(directory, "data/value.bin", "abc")
        digest = project_test_sha256(artifact_path)
        path = write_project_test_file(
            directory,
            "artifact-limit.aimora.yaml",
            """project: {id: artifact-limit}
value: {\$artifact: {path: data/value.bin, format: binary, sha256: $(digest)}}
""",
        )
        project_resolution_failure(
            path,
            :project_file_limit;
            policy = ProjectResolutionPolicy(max_files = 1),
        )
    end

    @test only(resolve_project_documents("").diagnostics).code == :empty_project_input_path
    @test only(resolve_project_documents("bad\0path").diagnostics).code ==
          :nonportable_project_input_path

    @test_throws ArgumentError ProjectResolutionPolicy(max_files = 0)
    @test_throws ArgumentError ProjectResolutionPolicy(max_authoritative_bytes = 0)
    @test_throws ArgumentError ProjectResolutionPolicy(max_hashed_resource_bytes = 0)
end
