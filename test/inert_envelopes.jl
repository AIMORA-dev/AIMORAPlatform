function parse_inert_yaml(parser::Function, text::String; source_name::String = "envelope.yaml")
    document = parse_restricted_yaml(text; source_name)
    format_succeeded(document) || return document
    return parser(document.value)
end

function serialized_inert_text(result::FormatSerializationResult)
    @test format_succeeded(result)
    return String(collect(result.value.bytes))
end

@testset "portable inert references and JSON Pointers" begin
    local_reference = parse_portable_reference(
        "asset:line.L1#/terminals/from~1side/~0name";
        source_name = "reference.txt",
    )
    @test format_succeeded(local_reference)
    @test local_reference.value.target == "asset:line.L1"
    @test !local_reference.value.external
    @test collect(local_reference.value.pointer.tokens) == ["terminals", "from/side", "~name"]
    @test local_reference.value.span == SourceSpan(
        "reference.txt",
        SourcePosition(1, 1, 1),
        SourcePosition(43, 1, 43),
    )

    external = parse_portable_reference("aimora://catalog/generic/line@2.1.0#")
    @test format_succeeded(external)
    @test external.value.external
    @test isempty(external.value.pointer.tokens)

    envelope = parse_inert_yaml(
        parse_reference_envelope,
        "{\$ref: 'asset:line.L1#/terminals/from~1side/~0name'}",
    )
    @test format_succeeded(envelope)
    @test serialized_inert_text(serialize_reference_envelope(envelope.value)) ==
          "{\"\$ref\":\"asset:line.L1#/terminals/from~1side/~0name\"}"

    invalid = Dict(
        "asset:line.L1#not-a-pointer" => :invalid_json_pointer,
        "asset:line.L1#/bad~2escape" => :invalid_json_pointer_escape,
        "asset:line.L1#/trailing~" => :invalid_json_pointer_escape,
        "asset:line.L1#/#/extra" => :invalid_portable_reference,
        "https://example.com/model" => :invalid_portable_reference,
        "aimora://catalog/../secret" => :invalid_portable_reference,
        "aimora://catalog" => :invalid_portable_reference,
        "asset:1invalid" => :invalid_portable_reference,
    )
    for (text, code) in invalid
        result = parse_portable_reference(text; source_name = "bad-reference.txt")
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
        @test only(result.diagnostics).span.source_name == "bad-reference.txt"
    end

    unknown = parse_inert_yaml(
        parse_reference_envelope,
        "{\$ref: 'asset:line.L1', resolve: true}",
    )
    @test !format_succeeded(unknown)
    @test only(unknown.diagnostics).code == :unknown_inert_envelope_field
    @test only(unknown.diagnostics).span.start.column == 25

    duplicate = parse_restricted_yaml("{\$ref: a, \$ref: b}"; source_name = "duplicate.yaml")
    @test !format_succeeded(duplicate)
    @test only(duplicate.diagnostics).code == :duplicate_mapping_key
end

@testset "artifact and inheritance envelopes remain inert" begin
    digest = repeat("a", 64)
    artifact_text = """\$artifact:
  path: data/waveforms/disturbance_001.cfg
  format: comtrade-cfg@1999
  sha256: $(digest)
  size_bytes: 4096
  schema: comtrade.cfg@1999
  table: disturbance
  unit: kV
  ordering: [A, B, C, N]
  media_type: application/x-comtrade
"""
    artifact = parse_inert_yaml(parse_artifact_envelope, artifact_text)
    @test format_succeeded(artifact)
    descriptor = artifact.value
    @test descriptor.path == "data/waveforms/disturbance_001.cfg"
    @test descriptor.format == "comtrade-cfg@1999"
    @test descriptor.sha256 == digest
    @test descriptor.size_bytes == 4096
    @test descriptor.schema == "comtrade.cfg@1999"
    @test descriptor.table == "disturbance"
    @test descriptor.unit == "kV"
    @test collect(descriptor.ordering) == ["A", "B", "C", "N"]
    @test descriptor.media_type == "application/x-comtrade"

    serialized = serialized_inert_text(serialize_artifact_envelope(descriptor))
    reparsed_document = parse_json(serialized; source_name = "artifact.json")
    @test format_succeeded(reparsed_document)
    reparsed = parse_artifact_envelope(reparsed_document.value)
    @test format_succeeded(reparsed)
    @test reparsed.value.path == descriptor.path
    @test reparsed.value.sha256 == descriptor.sha256
    @test collect(reparsed.value.ordering) == collect(descriptor.ordering)

    inheritance_text = """extends:
  catalog: generic.transformer_40mva
  version: 3.2.1
  sha256: $(repeat("b", 64))
  facets: [thermal, reliability.failure]
"""
    inheritance = parse_inert_yaml(parse_extends_envelope, inheritance_text)
    @test format_succeeded(inheritance)
    @test inheritance.value.catalog == "generic.transformer_40mva"
    @test inheritance.value.version == v"3.2.1"
    @test collect(inheritance.value.facets) == ["thermal", "reliability.failure"]
    @test occursin(
        "\"version\":\"3.2.1\"",
        serialized_inert_text(serialize_extends_envelope(inheritance.value)),
    )

    artifact_failures = [
        ("/absolute.bin", digest, "[A]", :absolute_artifact_path),
        ("../escape.bin", digest, "[A]", :artifact_path_traversal),
        ("data//file.bin", digest, "[A]", :artifact_path_traversal),
        ("https://example.com/file", digest, "[A]", :absolute_artifact_path),
        ("data/file.bin", uppercase(digest), "[A]", :invalid_artifact_sha256),
        ("data/file.bin", digest[1:63], "[A]", :invalid_artifact_sha256),
        ("data/file.bin", digest, "[]", :empty_artifact_ordering),
    ]
    for (path, hash, ordering, code) in artifact_failures
        result = parse_inert_yaml(
            parse_artifact_envelope,
            """\$artifact:
  path: '$(path)'
  format: binary
  sha256: '$(hash)'
  ordering: $(ordering)
""",
        )
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
    end

    unknown = parse_inert_yaml(
        parse_artifact_envelope,
        """\$artifact:
  path: data/file.bin
  format: binary
  sha256: $(digest)
  fetch: true
""",
    )
    @test !format_succeeded(unknown)
    @test only(unknown.diagnostics).code == :unknown_inert_envelope_field

    @test_throws MethodError ArtifactEnvelope(
        "../bad",
        "binary",
        digest,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        nothing,
        descriptor.span,
    )
    @test_throws MethodError ExtendsEnvelope(
        "bad catalog",
        v"1.0.0",
        nothing,
        nothing,
        inheritance.value.span,
    )
end

@testset "bounded patches and registered function identities" begin
    value_operations = Set(["set", "add", "connect", "replace_profile", "replace_realization"])
    operation_names = [
        "set",
        "unset",
        "add",
        "remove",
        "enable",
        "disable",
        "connect",
        "disconnect",
        "replace_profile",
        "replace_realization",
    ]
    for operation in operation_names
        value = operation in value_operations ? "\nvalue: {amount: 8.5, unit: MW}" : ""
        result = parse_inert_yaml(
            parse_patch_envelope,
            """op: $(operation)
target: {\$ref: 'asset:load.main'}
path: common.p_set$(value)
""",
        )
        @test format_succeeded(result)
        @test isnothing(result.value.value) == !(operation in value_operations)
        serialized = serialized_inert_text(serialize_patch_envelope(result.value))
        @test occursin("\"op\":\"$(operation)\"", serialized)
        @test occursin("\"target\":{\"\$ref\":\"asset:load.main\"}", serialized)
    end

    patch_failures = [
        ("op: mutate\ntarget: {\$ref: asset:load.main}\npath: common.p", :unknown_patch_operation),
        ("op: set\ntarget: {\$ref: asset:load.main}\npath: common.p", :missing_patch_value),
        ("op: remove\ntarget: {\$ref: asset:load.main}\npath: common.p\nvalue: 1", :unexpected_patch_value),
        ("op: set\ntarget: {\$ref: asset:load.main}\npath: ../common\nvalue: 1", :invalid_patch_path),
        ("op: set\ntarget: asset:load.main\npath: common.p\nvalue: 1", :inert_envelope_kind_mismatch),
    ]
    for (text, code) in patch_failures
        result = parse_inert_yaml(parse_patch_envelope, text)
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
    end

    function_text = """plugin: aimora.optimization.extensions
package_uuid: 12345678-1234-5678-9abc-def012345678
version: 1.2.0
symbol: Objectives.total_lifecycle_cost
git_tree_sha1: $(repeat("c", 40))
"""
    identity = parse_inert_yaml(parse_registered_function_identity, function_text)
    @test format_succeeded(identity)
    @test identity.value.package_uuid == UUID("12345678-1234-5678-9abc-def012345678")
    @test identity.value.version == v"1.2.0"
    @test identity.value.symbol == "Objectives.total_lifecycle_cost"
    identity_json = serialized_inert_text(serialize_registered_function_identity(identity.value))
    @test occursin("\"package_uuid\":\"12345678-1234-5678-9abc-def012345678\"", identity_json)

    function_failures = [
        (replace(function_text, "12345678-1234-5678-9abc-def012345678" => "not-a-uuid"), :invalid_registered_function_uuid),
        (replace(function_text, "1.2.0" => "latest"), :invalid_semantic_version),
        (replace(function_text, "Objectives.total_lifecycle_cost" => "anonymous -> value"), :invalid_registered_function_symbol),
        (replace(function_text, repeat("c", 40) => repeat("C", 40)), :invalid_registered_function_tree_hash),
    ]
    for (text, code) in function_failures
        result = parse_inert_yaml(parse_registered_function_identity, text)
        @test !format_succeeded(result)
        @test only(result.diagnostics).code == code
    end

    @test_throws MethodError RegisteredFunctionIdentity(
        "plugin",
        UUID("12345678-1234-5678-9abc-def012345678"),
        v"1.0.0",
        "symbol",
        nothing,
        identity.value.span,
    )
end

@testset "inert envelope parsing has zero external side effects" begin
    working_directory = pwd()
    loaded_modules = copy(Base.loaded_modules)
    artifact = parse_inert_yaml(
        parse_artifact_envelope,
        """\$artifact:
  path: data/this-file-does-not-exist.bin
  format: binary
  sha256: $(repeat("d", 64))
""",
    )
    reference = parse_portable_reference("aimora://catalog/host/path@1.0.0")
    identity = parse_inert_yaml(
        parse_registered_function_identity,
        """plugin: NeverLoadedPlugin
package_uuid: 12345678-1234-5678-9abc-def012345678
version: 1.0.0
symbol: NeverLoadedModule.callback
""",
    )
    @test format_succeeded(artifact)
    @test format_succeeded(reference)
    @test format_succeeded(identity)
    @test pwd() == working_directory
    @test Base.loaded_modules == loaded_modules
    @test !isdefined(Main, :NeverLoadedModule)

    limited = parse_portable_reference(
        "asset:line.L1";
        policy = FormatInputPolicy(max_scalar_bytes = 4),
    )
    @test !format_succeeded(limited)
    @test only(limited.diagnostics).code == :reference_too_large
end
