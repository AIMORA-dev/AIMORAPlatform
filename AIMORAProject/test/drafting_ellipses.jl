# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DraftingEllipseTests
using AIMORAProject
using Test

@testset "bounded ellipse display preserves exact defining corners" begin
    point(x, y) = DrawingCoordinate(parse_exact_decimal(x), parse_exact_decimal(y))
    lower = point("-4", "-2")
    upper = point("4", "2")
    samples = drawing_ellipse_display_points(lower, upper)
    @test length(samples) == 129
    @test first(samples) == last(samples) == [4.0, 0.0]
    @test all(sample -> all(isfinite, sample), samples)
    @test all(sample -> abs((sample[1] / 4)^2 + (sample[2] / 2)^2 - 1) < 1e-12, samples)
    @test drawing_ellipse_display_points(upper, lower) == samples
    @test lower == point("-4", "-2")
    @test upper == point("4", "2")
    @test length(drawing_ellipse_display_points(lower, upper; segments_per_ellipse = 8)) == 9
    @test length(drawing_ellipse_display_points(lower, upper; segments_per_ellipse = 4096)) == 4097
    for budget in (0, 7, 4097)
        @test_throws SemanticValidationError drawing_ellipse_display_points(lower, upper;
            segments_per_ellipse = budget)
    end
    for opposite in (lower, point("-4", "2"), point("4", "-2"))
        @test_throws SemanticValidationError drawing_ellipse_display_points(lower, opposite)
    end
    translated = drawing_ellipse_display_points(point("6", "18"), point("14", "22"))
    @test all(index -> isapprox(translated[index][1], samples[index][1] + 10; atol = 1e-12) &&
        isapprox(translated[index][2], samples[index][2] + 20; atol = 1e-12), eachindex(samples))
end
end
