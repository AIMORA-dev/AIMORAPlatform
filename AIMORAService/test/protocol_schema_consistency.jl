using Test
using AIMORAService
using JSON3

@testset "service runtime matches canonical protocol schema" begin
    schema = JSON3.read(read(joinpath(@__DIR__, "..", "schema", "service_protocol.json"), String))
    @test AIMORAService.PROTOCOL_VERSION == schema.protocol_version
    @test AIMORAService.SERVICE_VERSION == schema.service_version
    @test AIMORAService.FRAME_MAGIC == collect(codeunits(String(schema.frame.magic)))
    @test AIMORAService.FRAME_HEADER_BYTES == schema.frame.header_bytes
    declared_capabilities = Set(String(method.capability) for method in schema.methods)
    @test issubset(declared_capabilities, Set(AIMORAService.CAPABILITIES))
    @test length(AIMORAService.CAPABILITIES) == length(unique(AIMORAService.CAPABILITIES))
end
