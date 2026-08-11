using Test
using AIMORAReporting

@testset "semantic reporting package boundary" begin
    @test nameof(AIMORAReporting) === :AIMORAReporting
end
