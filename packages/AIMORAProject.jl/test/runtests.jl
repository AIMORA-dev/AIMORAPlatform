using Test
using AIMORAProject

@testset "canonical project package boundary" begin
    @test nameof(AIMORAProject) === :AIMORAProject
end
