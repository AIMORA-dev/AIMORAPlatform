using Test
using AIMORAService

@testset "public service package boundary" begin
    @test nameof(AIMORAService) === :AIMORAService
end
