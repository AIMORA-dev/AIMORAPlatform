using Test
using AIMORAFormats

@testset "open-text format package boundary" begin
    @test nameof(AIMORAFormats) === :AIMORAFormats
end
