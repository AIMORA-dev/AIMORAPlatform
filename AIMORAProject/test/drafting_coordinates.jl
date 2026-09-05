using Test
using AIMORAProject

@testset "exact Cartesian drafting input" begin
    coordinate(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    anchor = coordinate("0.1000000000000000000000000000000001", "-0.2")
    @test resolve_drafting_cartesian("@1,0.3", anchor) ==
        coordinate("1.1000000000000000000000000000000001", "0.1")
    @test resolve_drafting_cartesian(" 2.5 , -3e-2 ", anchor) == coordinate("2.5", "-0.03")
    @test resolve_drafting_cartesian("@-0.1000000000000000000000000000000001,0.2", anchor) ==
        coordinate("0", "0")
    @test resolve_drafting_cartesian("@1e-100,0", coordinate("1e-100", "2e-100")) ==
        coordinate("2e-100", "2e-100")
    first = resolve_drafting_cartesian("@0.1,0.2", anchor)
    @test resolve_drafting_cartesian("@-0.1,-0.2", first) == anchor
    for invalid in ("", "1", "1,2,3", "@", "@5<90")
        @test_throws SemanticValidationError resolve_drafting_cartesian(invalid, anchor)
    end
end
