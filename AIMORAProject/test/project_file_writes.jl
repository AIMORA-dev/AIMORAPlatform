using Test
using SHA
using AIMORAProject

@testset "project file replacement preserves existing destinations on failure" begin
    mktempdir() do directory
        path = joinpath(directory, "drawing.aimora.yaml")
        original = collect(codeunits("original project bytes\n"))
        updated = collect(codeunits("updated project bytes\n"))
        @test AIMORAProject._write_project_bytes(path, original; overwrite = false) == path
        @test read(path) == original
        @test_throws SemanticValidationError AIMORAProject._write_project_bytes(path, updated; overwrite = false)
        @test read(path) == original
        source = ContentDigest(bytes2hex(sha256(original)))
        @test AIMORAProject._write_project_bytes(path, updated; overwrite = true, expected_source = source) == path
        @test read(path) == updated

        entries = sort(readdir(directory))
        @test_throws SemanticValidationError AIMORAProject._write_project_bytes(path, original;
            overwrite = true, expected_source = source)
        @test read(path) == updated
        @test sort(readdir(directory)) == entries

        replacement_source = ContentDigest(bytes2hex(sha256(updated)))
        @test AIMORAProject._write_project_bytes(path, original;
            overwrite = true, expected_source = replacement_source) == path
        @test read(path) == original

        occupied = joinpath(directory, "occupied.aimora.yaml")
        mkdir(occupied)
        marker = joinpath(occupied, "retained.txt")
        write(marker, original)
        entries = sort(readdir(directory))
        @test_throws Base.IOError AIMORAProject._write_project_bytes(occupied, updated; overwrite = true)
        @test isdir(occupied)
        @test read(marker) == original
        @test sort(readdir(directory)) == entries
    end
end
