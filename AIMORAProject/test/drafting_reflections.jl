# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingReflectionTests
using AIMORAProject
using Test

@testset "axis reflection retains exact decimal geometry" begin
    point(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    original = point("0.1000000000000000000000000000000001", "-3.25")
    coordinate = parse_exact_decimal("0.2")
    vertical = AIMORAProject._reflected_drafting_point(original, :vertical, coordinate)
    @test vertical == point("0.2999999999999999999999999999999999", "-3.25")
    horizontal = AIMORAProject._reflected_drafting_point(original, :horizontal, coordinate)
    @test horizontal == point("0.1000000000000000000000000000000001", "3.65")
    for axis in (:horizontal, :vertical)
        reflected = AIMORAProject._reflected_drafting_point(original, axis, coordinate)
        @test AIMORAProject._reflected_drafting_point(reflected, axis, coordinate) == original
        fixed = point("0.2", "0.2")
        @test AIMORAProject._reflected_drafting_point(fixed, axis, coordinate) == fixed
    end
    @test_throws SemanticValidationError AIMORAProject._reflected_drafting_point(original, :diagonal, coordinate)
end
end
