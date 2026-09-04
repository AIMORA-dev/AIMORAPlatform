using Test
using TOML

include(joinpath(@__DIR__, "..", "src", "AIMORASymbols.jl"))
using .AIMORASymbols

const SYMBOL_ROOT = normpath(joinpath(@__DIR__, ".."))
const EXPECTED_IDS = Set([
    "converter.ac_dc", "load.static", "machine.induction_motor", "machine.synchronous_generator",
    "measurement.current_transformer", "measurement.voltage_transformer", "network.cable", "network.overhead_line",
    "passive.shunt_capacitor", "passive.shunt_reactor", "power.busbar", "power.ground", "power.source", "power.terminal",
    "protection.fuse", "protection.surge_arrester", "storage.battery", "switching.circuit_breaker",
    "switching.disconnector", "transformer.two_winding",
])

@testset "canonical primitive-vector symbol library" begin
    library = load_library(SYMBOL_ROOT)
    @test library.id == "aimora-public-symbols"
    @test library.version == "0.1.0"
    @test Set(keys(library.symbols)) == EXPECTED_IDS
    @test length(library.symbols) == 20

    primitive_types = Set{DataType}()
    targets = (RetainedSceneTarget(), ReferenceGeometryTarget(), PdfVectorTarget(), DxfBlockTarget())
    for symbol in values(library.symbols)
        @test symbol.license == "PolyForm-Noncommercial-1.0.0"
        @test symbol.provenance == "AIMORA original"
        @test symbol.rotations == [0, 90, 180, 270]
        @test !isempty(symbol.accessibility)
        @test !isempty(symbol.ports)
        @test Set(anchor.role for anchor in symbol.anchors) == Set(["placement", "label"])
        @test select_variant(symbol; level_of_detail = "compact").level_of_detail == "compact"
        @test select_variant(symbol; state = "unknown", level_of_detail = "unknown").state == symbol.default_state
        union!(primitive_types, typeof.(select_variant(symbol).primitives))
        compiled = [compile_symbol(symbol, target) for target in targets]
        @test length(unique(geometry_signature.(compiled))) == 1
        @test [item.target for item in compiled] == [:retained_scene, :reference_geometry, :pdf_vector, :dxf_block]
    end
    @test primitive_types == Set([LinePrimitive, PolylinePrimitive, ArcPrimitive, CirclePrimitive, EllipsePrimitive, PolygonPrimitive])

    breaker = library.symbols["switching.circuit_breaker"]
    @test select_variant(breaker; state = "open").state == "open"
    @test select_variant(breaker; state = "closed").state == "closed"
    @test geometry_signature(compile_symbol(breaker, RetainedSceneTarget(); state = "open")) != geometry_signature(compile_symbol(breaker, RetainedSceneTarget(); state = "closed"))

    first_record = TOML.parsefile(joinpath(SYMBOL_ROOT, "metadata", "library.toml"))["symbols"][1]
    first_path = joinpath(SYMBOL_ROOT, first_record["path"])
    @test load_symbol(first_path).canonical_hash == load_symbol(first_path).canonical_hash
    mktempdir() do directory
        malformed = joinpath(directory, "malformed.toml")
        source = read(first_path, String)
        write(malformed, replace(source, "AIMORA original" => "unknown provenance"))
        @test_throws ArgumentError load_symbol(malformed)
        write(malformed, replace(source, "PolyForm-Noncommercial-1.0.0" => "proprietary"))
        @test_throws ArgumentError load_symbol(malformed)
        write(malformed, replace(source, "bounds=[\"-10\",\"-10\",\"10\",\"10\"]" => "bounds=[-10.0,-10.0,10.0,10.0]"))
        @test_throws ArgumentError load_symbol(malformed)
    end
    @test isempty([path for (root, _, files) in walkdir(SYMBOL_ROOT) for path in joinpath.(root, files) if endswith(lowercase(path), ".svg")])
end
