using Test
using AIMORAService

@testset "native local listener endpoint normalization" begin
    pipe = "\\\\.\\pipe\\aimora-drawing"
    @test AIMORAService._local_listener_endpoint("aimora-drawing"; windows = true) == pipe
    @test AIMORAService._local_listener_endpoint(pipe; windows = true) == pipe
    @test AIMORAService._local_listener_endpoint("/tmp/aimora.sock"; windows = false) ==
        "/tmp/aimora.sock"
    @test AIMORAService._local_listener_endpoint("aimora-drawing"; windows = false) ==
        "aimora-drawing"
    expected = Sys.iswindows() ? pipe : "aimora-drawing"
    @test AIMORAService._local_listener_endpoint("aimora-drawing") == expected
end
