# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingRotationTests
using AIMORAProject
using Test

@testset "quarter rotations preserve exact pivot and return geometry after four turns" begin
    point(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    pivot = point("1.25", "-2.5")
    original = point("2.2500000000000000000000000000000001", "0.5")
    rotated = AIMORAProject._quarter_rotated_drafting_point(original, pivot)
    @test rotated == point("-1.75", "-1.4999999999999999999999999999999999")
    @test AIMORAProject._quarter_rotated_drafting_point(pivot, pivot) == pivot
    for _ in 1:3
        rotated = AIMORAProject._quarter_rotated_drafting_point(rotated, pivot)
    end
    @test rotated == original
    @test original == point("2.2500000000000000000000000000000001", "0.5")
end
end
