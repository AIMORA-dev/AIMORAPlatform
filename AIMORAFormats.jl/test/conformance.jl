function deterministic_parse_signature(result)
    diagnostics = Tuple(
        (diagnostic.severity, diagnostic.code, diagnostic.message, diagnostic.span)
        for diagnostic in result.diagnostics
    )
    return (format_succeeded(result), diagnostics, result.value)
end

@testset "deterministic bounded grammar property corpus" begin
    alphabet = collect(codeunits("{}[],:# abcdef0123456789\"'-+.!?\n"))
    parse_restricted_yaml("warmup: true")
    parse_json("{\"warmup\":true}")
    working_directory = pwd()
    loaded_modules = copy(Base.loaded_modules)
    for seed in 1:512
        length = 1 + mod(seed * 37, 96)
        bytes = UInt8[
            alphabet[1 + mod(seed * 131 + index * 17 + index * index, Base.length(alphabet))]
            for index in 1:length
        ]
        yaml_first = parse_restricted_yaml(bytes; source_name = "property.yaml")
        yaml_second = parse_restricted_yaml(bytes; source_name = "property.yaml")
        json_first = parse_json(bytes; source_name = "property.json")
        json_second = parse_json(bytes; source_name = "property.json")
        @test deterministic_parse_signature(yaml_first) == deterministic_parse_signature(yaml_second)
        @test deterministic_parse_signature(json_first) == deterministic_parse_signature(json_second)
    end
    @test pwd() == working_directory
    @test Base.loaded_modules == loaded_modules
end

@testset "mandatory format target accounting" begin
    expected = Set(getfield.(MANDATORY_FORMAT_TARGETS, :id))
    @test length(expected) == length(MANDATORY_FORMAT_TARGETS)
    @test PASSED_FORMAT_TARGETS == expected
    @test all(target -> isfile(joinpath(@__DIR__, "..", target.owner)), MANDATORY_FORMAT_TARGETS)
    println("mandatory format targets: $(length(PASSED_FORMAT_TARGETS))/$(length(expected)) passed")
end
