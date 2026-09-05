# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
module DrawingValueHashTests
using AIMORAProject
using Test

@testset "exact decimal and drawing coordinate hashes respect value equality" begin
    for (literal, equivalent) in (("0.1", "1e-1"), ("0", "0.000"), ("-0", "-0.0"),
        ("123456789012345678901234567890.125", "123456789012345678901234567890.1250"),
        ("1e-10000", "1e-10000"), ("-2.5", "-25e-1"))
        left = parse_exact_decimal(literal)
        right = parse_exact_decimal(equivalent)
        @test left == right
        @test isequal(left, right)
        @test length(Set([left, right])) == 1
        @test get(Dict(left => :decimal), right, :missing) == :decimal
        first = DrawingCoordinate(left, parse_exact_decimal("3.125"))
        second = DrawingCoordinate(right, parse_exact_decimal("3125e-3"))
        @test first == second
        @test isequal(first, second)
        @test length(Set([first, second])) == 1
        @test get(Dict(first => :coordinate), second, :missing) == :coordinate
        for seed in (UInt(0), UInt(123), typemax(UInt))
            @test hash(left, seed) == hash(right, seed)
            @test hash(first, seed) == hash(second, seed)
        end
    end
    positive = parse_exact_decimal("0")
    negative = parse_exact_decimal("-0")
    @test positive != negative
    @test length(Set([positive, negative])) == 2
    @test length(Set([DrawingCoordinate(positive, positive), DrawingCoordinate(negative, positive)])) == 2
end
end
