function synthetic_record(fixture, index::Int)
    id = "bus.synthetic_" * lpad(string(index), 5, '0')
    nominal_voltage = project_record(fixture.project, ProjectId("bus.HV")).fields[3].value
    return CanonicalRecord(
        ObjectIdentity(ProjectId(id)),
        fixture.schema.identity,
        [
            CanonicalField("id", id),
            CanonicalField("mode", isodd(index) ? "PQ" : "PV"),
            CanonicalField("nominal_voltage", nominal_voltage),
            CanonicalField("priority", mod(index, 101)),
        ],
        fixture.provenance,
    )
end

@testset "deterministic canonical identity property corpus" begin
    for seed in 1:256
        id = ProjectId("asset.property_" * lpad(string(seed), 4, '0'))
        reference = ProjectReference(ReferenceAsset, id)
        decimal = parse_exact_decimal(string(seed, ".", lpad(string(mod(seed * 37, 1000)), 3, '0')))
        @test ProjectId(id.value) == id
        @test ProjectReference(ReferenceAsset, ProjectId(id.value)) == reference
        @test parse_exact_decimal(string(decimal)) == decimal
        @test hash(id) == hash(ProjectId(id.value))
    end
end

@testset "large synthetic project validation hashing and table scale budgets" begin
    fixture = canonical_project_fixture()
    warmup = CanonicalProject(
        fixture.metadata,
        fixture.registry,
        fixture.units,
        [synthetic_record(fixture, 1)],
    )
    validate_project(warmup)
    project_resolved_hash(warmup)
    collect(Tables.rows(record_table(project_snapshot(initial_revision(
        warmup,
        ContentDigest(repeat("1", 64)),
        project_resolved_hash(warmup),
        transaction_provenance(fixture, "action.scale_warmup", 43),
    )), fixture.schema.identity)))

    records = [synthetic_record(fixture, index) for index in 1:1_000]
    elapsed = @elapsed begin
        large = CanonicalProject(fixture.metadata, fixture.registry, fixture.units, records)
        @test validate_project(large)
        digest = project_resolved_hash(large)
        @test occursin(r"^[0-9a-f]{64}$", digest.sha256)
        revision = initial_revision(
            large,
            ContentDigest(repeat("2", 64)),
            digest,
            transaction_provenance(fixture, "action.large_synthetic", 44),
        )
        table = record_table(project_snapshot(revision), fixture.schema.identity)
        @test length(collect(Tables.rows(table))) == 1_000
    end
    @test elapsed < 30.0

    allocation = @allocated begin
        measured = CanonicalProject(fixture.metadata, fixture.registry, fixture.units, records)
        validate_project(measured)
        project_resolved_hash(measured)
    end
    @test allocation < 250_000_000
end

@testset "inert project loading rejects executable-looking data without side effects" begin
    fixture = canonical_project_fixture()
    serialized = AIMORAFormats.serialize_restricted_yaml(project_format_node(fixture.project))
    @test format_succeeded(serialized)
    source = String(collect(serialized.value.bytes))
    mktempdir() do directory
        sentinel = joinpath(directory, "must_not_exist")
        script = "write(" * repr(sentinel) * ", \"executed\")"
        escaped_script = replace(script, '\\' => "\\\\", '"' => "\\\"")
        malicious = replace(
            source,
            r"\}\s*$" => ",\"automation\":\"$(escaped_script)\"}\n",
        )
        path = joinpath(directory, "malicious.aimora.yaml")
        write(path, malicious)
        result = open_project(path)
        @test !format_succeeded(result)
        @test !isfile(sentinel)
        @test !isempty(result.diagnostics)
        @test all(diagnostic -> diagnostic.span.source_name == basename(path), result.diagnostics)
    end
end

@testset "mandatory semantic project target accounting" begin
    expected = Set(getfield.(MANDATORY_PROJECT_TARGETS, :id))
    @test length(expected) == length(MANDATORY_PROJECT_TARGETS)
    @test PASSED_PROJECT_TARGETS == expected
    @test all(target -> isfile(joinpath(@__DIR__, "..", target.owner)), MANDATORY_PROJECT_TARGETS)
    println("mandatory project targets: $(length(PASSED_PROJECT_TARGETS))/$(length(expected)) passed")
end
