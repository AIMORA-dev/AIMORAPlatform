@testset "immutable canonical identities and rename invariants" begin
    id = ProjectId("transformer.T1")
    @test string(id) == "transformer.T1"
    @test id == ProjectId(join(["transformer", "T1"], '.'))
    @test hash(id) == hash(ProjectId("transformer.T1"))
    namespace = NamespaceId("vendor.controls")
    @test string(namespace) == "vendor.controls"
    global_id = GlobalId(UUID("4d7745cc-1d47-4ab2-a863-81210f27c7aa"))
    @test string(global_id) == "urn:uuid:4d7745cc-1d47-4ab2-a863-81210f27c7aa"

    identity = ObjectIdentity(id; uid = global_id)
    named = IdentifiedName(identity, "Main Transformer")
    renamed = rename(named, "North Transformer")
    @test renamed.identity == named.identity
    @test renamed.identity.id == id
    @test renamed.identity.uid == global_id
    @test renamed.name == "North Transformer"
    @test named.name == "Main Transformer"

    input = [ProjectId("asset.A"), ProjectId("asset.B")]
    immutable = CanonicalList(input)
    input[1] = ProjectId("asset.changed")
    @test immutable[1] == ProjectId("asset.A")
    @test collect(immutable) == [ProjectId("asset.A"), ProjectId("asset.B")]
    @test_throws MethodError setindex!(immutable, ProjectId("asset.C"), 1)
end

@testset "identity and global URI grammar rejects ambiguity" begin
    for value in ("", ".asset", "asset.", "1asset", "asset..A", "asset/A", "asset A")
        @test semantic_error_code(() -> ProjectId(value)) == :invalid_project_id
    end
    for value in ("Aimora", "vendor.Controls", "vendor..controls", "vendor/controls", "1vendor")
        @test semantic_error_code(() -> NamespaceId(value)) == :invalid_namespace_id
    end
    for value in ("relative/path", "https://bad path", "1scheme:value", "https:\0bad")
        @test semantic_error_code(() -> GlobalId(value)) == :invalid_global_id
    end
    @test semantic_error_code(() -> IdentifiedName(ObjectIdentity(ProjectId("asset.A")), "  ")) == :invalid_display_name
end

@testset "typed stable references and decoded JSON Pointer paths" begin
    path = ReferencePath("/terminals/from~1A/~0status/")
    @test [token.value for token in path.tokens] == ["terminals", "from/A", "~status", ""]
    @test ReferencePath(ReferenceToken[
        ReferenceToken("terminals"),
        ReferenceToken("from/A"),
        ReferenceToken("~status"),
        ReferenceToken(""),
    ]) == path
    local_reference = ProjectReference(ReferenceAsset, ProjectId("line.L1"); path)
    @test local_reference.target == LocalReferenceTarget(ProjectId("line.L1"))
    @test local_reference.kind == ReferenceAsset
    external_reference = ProjectReference(
        ReferenceCatalog,
        GlobalId("aimora://catalog/generic/line@2.1.0"),
    )
    @test external_reference.target == GlobalReferenceTarget(GlobalId("aimora://catalog/generic/line@2.1.0"))
    @test isempty(external_reference.path.tokens)

    for pointer in ("terminals/from", "/bad~", "/bad~2escape")
        @test semantic_error_code(() -> ReferencePath(pointer)) == :invalid_reference_path
    end
end

@testset "versioned semantic type identities" begin
    type_id = SemanticTypeId(NamespaceId("aimora"), ProjectId("asset.transformer"), v"1.2.0")
    @test type_id == SemanticTypeId(NamespaceId("aimora"), ProjectId("asset.transformer"), v"1.2.0")
    @test semantic_error_code(() -> SemanticTypeId(NamespaceId("aimora"), ProjectId("asset.transformer"), v"0.1.0")) == :invalid_type_version
end
