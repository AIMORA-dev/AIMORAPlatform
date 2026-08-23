using Test
using AIMORALayout

@testset "deterministic layout package boundary" begin
    @test nameof(AIMORALayout) === :AIMORALayout
end
