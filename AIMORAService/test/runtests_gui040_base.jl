# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
using AIMORAService
using JSON3
using Sockets
using Test
using UUIDs

function test_endpoint(root::AbstractString)
    return Sys.iswindows() ?
           "\\\\.\\pipe\\aimora-service-test-" * string(uuid4()) :
           joinpath(root, "service.sock")
end

function connect_with_retry(endpoint::AbstractString; timeout_seconds::Real = 10)
    deadline = time() + timeout_seconds
    last_error = nothing
    while time() < deadline
        try
            return Sockets.connect(endpoint)
        catch error
            last_error = error
            sleep(0.02)
        end
    end
    last_error === nothing || @info "last local transport error" exception = last_error
    error("timed out connecting to the local service")
end

function request_message(
    request_id::AbstractString,
    method::AbstractString;
    parameters::AbstractDict = Dict{String,Any}(),
    protocol_version::AbstractString = PROTOCOL_VERSION,
)
    return Dict{String,Any}(
        "protocol_version" => String(protocol_version),
        "request_id" => String(request_id),
        "method" => String(method),
        "params" => Dict{String,Any}(
            String(key) => value for (key, value) in pairs(parameters)
        ),
    )
end

function send_request!(socket, message, limits::ServiceLimits = ServiceLimits())
    payload = collect(codeunits(JSON3.write(message)))
    write_frame(socket, Frame(CONTROL_FRAME, payload), limits)
    frame = read_frame(socket, limits)
    frame === nothing && error("service closed before returning a response")
    return decode_control_message(frame)
end

function bounded_send_request!(
    socket,
    message,
    limits::ServiceLimits = ServiceLimits();
    timeout_seconds::Real = 10,
)
    task = @async send_request!(socket, message, limits)
    status = timedwait(() -> istaskdone(task), timeout_seconds; pollint = 0.02)
    if status != :ok
        try
            close(socket)
        catch
        end
        error("timed out waiting for the local service response")
    end
    return fetch(task)
end

function bounded_read_frame(
    socket,
    limits::ServiceLimits = ServiceLimits();
    timeout_seconds::Real = 10,
)
    task = @async read_frame(socket, limits)
    status = timedwait(() -> istaskdone(task), timeout_seconds; pollint = 0.02)
    if status != :ok
        try
            close(socket)
        catch
        end
        error("timed out waiting for the local service frame")
    end
    return fetch(task)
end

@testset "AIMORAService framing" begin
    limits = ServiceLimits(
        max_control_frame_bytes = 256,
        max_binary_frame_bytes = 1024,
        max_pending_requests = 4,
        max_path_bytes = 512,
        max_project_bytes = 1024,
        max_artifact_bytes = 2048,
        max_window_bytes = 512,
        max_workers = 1,
    )
    @test isvalid(limits)

    control = Frame(CONTROL_FRAME, collect(codeunits("{\"ok\":true}")))
    encoded = encode_frame(control, limits)
    @test encoded[1:4] == FRAME_MAGIC
    decoded = read_frame(IOBuffer(encoded), limits)
    @test decoded !== nothing
    @test decoded.kind == CONTROL_FRAME
    @test decoded.payload == control.payload

    metadata = Dict{String,Any}(
        "dtype" => "uint8",
        "shape" => Any[4],
        "units" => "byte",
    )
    binary_frame = Frame(BINARY_FRAME, encode_binary_payload(metadata, UInt8[1, 2, 3, 4]))
    decoded_metadata, decoded_data = decode_binary_payload(
        read_frame(IOBuffer(encode_frame(binary_frame, limits)), limits),
    )
    @test decoded_metadata["dtype"] == "uint8"
    @test decoded_metadata["shape"] == Any[4]
    @test decoded_data == UInt8[1, 2, 3, 4]

    invalid_magic = copy(encoded)
    invalid_magic[1] = 0x00
    error = try
        read_frame(IOBuffer(invalid_magic), limits)
        nothing
    catch caught
        caught
    end
    @test error isa ServiceError
    @test error.code == "FRAME_INVALID"

    invalid_kind = copy(encoded)
    invalid_kind[5] = 0x7f
    error = try
        read_frame(IOBuffer(invalid_kind), limits)
        nothing
    catch caught
        caught
    end
    @test error isa ServiceError
    @test error.code == "FRAME_INVALID"

    oversized = Frame(CONTROL_FRAME, fill(UInt8(0x41), 257))
    @test_throws ServiceError encode_frame(oversized, limits)
end

@testset "AIMORAService authentication and path confinement" begin
    @test constant_time_equal(repeat("a", 64), repeat("a", 64))
    @test !constant_time_equal(repeat("a", 64), repeat("b", 64))
    @test !constant_time_equal("short", "longer")

    mktempdir() do root
        inside = joinpath(root, "inside.aimora")
        write(inside, "canonical project fixture")
        policy = PathPolicy([root], 4096)
        @test confine_existing_file(policy, inside) == realpath(inside)

        mktempdir() do outside_root
            outside = joinpath(outside_root, "outside.aimora")
            write(outside, "outside")
            error = try
                confine_existing_file(policy, outside)
                nothing
            catch caught
                caught
            end
            @test error isa ServiceError
            @test error.code == "PATH_NOT_ALLOWED"

            if !Sys.iswindows()
                link = joinpath(root, "escape.aimora")
                symlink(outside, link)
                @test_throws ServiceError confine_existing_file(policy, link)
            end
        end
    end
end

@testset "AIMORAService deterministic generated C++ bindings" begin
    service_root = normpath(joinpath(@__DIR__, ".."))
    schema_path = joinpath(service_root, "schema", "service_protocol.json")
    committed_header = joinpath(
        service_root,
        "generated",
        "cpp",
        "include",
        "aimora",
        "studio",
        "protocol",
        "generated",
        "service_protocol.hpp",
    )
    committed_source = joinpath(
        service_root,
        "generated",
        "cpp",
        "src",
        "service_protocol.cpp",
    )
    mktempdir() do generated_root
        generated_header = joinpath(generated_root, "service_protocol.hpp")
        generated_source = joinpath(generated_root, "service_protocol.cpp")
        digest = generate_cpp_bindings(schema_path, generated_header, generated_source)
        @test length(digest) == 64
        @test read(generated_header, String) == read(committed_header, String)
        @test read(generated_source, String) == read(committed_source, String)
    end
end

@testset "AIMORAService authenticated local integration" begin
    mktempdir() do root
        project_path = joinpath(root, "sample.aimora")
        artifact_path = joinpath(root, "waveform.bin")
        write(project_path, "name = \"GUI040 fixture\"\n")
        write(artifact_path, UInt8.(0:127))

        endpoint = test_endpoint(root)
        token = repeat("0123456789abcdef", 4)
        service_root = normpath(joinpath(@__DIR__, ".."))
        worker_script = joinpath(service_root, "bin", "aimora-worker-probe.jl")
        worker_command = vcat(
            String.(Base.julia_cmd().exec),
            ["--startup-file=no", "--history-file=no", worker_script],
        )
        limits = ServiceLimits(
            max_control_frame_bytes = 1024 * 1024,
            max_binary_frame_bytes = 4 * 1024 * 1024,
            max_pending_requests = 16,
            max_path_bytes = 4096,
            max_project_bytes = 1024 * 1024,
            max_artifact_bytes = 4 * 1024 * 1024,
            max_window_bytes = 1024 * 1024,
            max_workers = 1,
        )
        configuration = ServiceConfiguration(
            endpoint = endpoint,
            session_token = token,
            allowed_roots = [root],
            limits = limits,
            worker_command = worker_command,
        )
        ready_output = IOBuffer()
        server_task = @async serve(configuration; ready_io = ready_output)
        socket = connect_with_retry(endpoint)

        unauthenticated = bounded_send_request!(
            socket,
            request_message("before-auth", "service.ping"),
            limits,
        )
        @test unauthenticated["ok"] == false
        @test unauthenticated["error"]["code"] == "AUTHENTICATION_REQUIRED"

        wrong_version = bounded_send_request!(
            socket,
            request_message(
                "wrong-version",
                "service.hello";
                parameters = Dict("token" => token),
                protocol_version = "99.0",
            ),
            limits,
        )
        @test wrong_version["ok"] == false
        @test wrong_version["error"]["code"] == "PROTOCOL_VERSION_UNSUPPORTED"

        wrong_token = bounded_send_request!(
            socket,
            request_message(
                "wrong-token",
                "service.hello";
                parameters = Dict("token" => repeat("f", 64)),
            ),
            limits,
        )
        @test wrong_token["ok"] == false
        @test wrong_token["error"]["code"] == "AUTHENTICATION_FAILED"

        hello = bounded_send_request!(
            socket,
            request_message(
                "hello",
                "service.hello";
                parameters = Dict("token" => token),
            ),
            limits,
        )
        @test hello["ok"] == true
        @test hello["result"]["protocol_version"] == PROTOCOL_VERSION
        @test "result.binary-window" in hello["result"]["capabilities"]

        capabilities = bounded_send_request!(
            socket,
            request_message("capabilities", "service.capabilities"),
            limits,
        )
        @test capabilities["ok"] == true
        @test capabilities["result"]["limits"]["workers"] == 1

        opened_project = bounded_send_request!(
            socket,
            request_message(
                "project-open",
                "project.open";
                parameters = Dict("path" => project_path),
            ),
            limits,
        )
        @test opened_project["ok"] == true
        project_id = opened_project["result"]["project_id"]
        @test startswith(project_id, "project-")
        @test startswith(opened_project["result"]["revision"], "sha256:")
        @test !haskey(opened_project["result"], "path")

        described_project = bounded_send_request!(
            socket,
            request_message(
                "project-describe",
                "project.describe";
                parameters = Dict("project_id" => project_id),
            ),
            limits,
        )
        @test described_project["result"]["revision"] ==
              opened_project["result"]["revision"]

        mktempdir() do outside_root
            outside_path = joinpath(outside_root, "secret.aimora")
            write(outside_path, "private")
            denied = bounded_send_request!(
                socket,
                request_message(
                    "path-denied",
                    "project.open";
                    parameters = Dict("path" => outside_path),
                ),
                limits,
            )
            @test denied["ok"] == false
            @test denied["error"]["code"] == "PATH_NOT_ALLOWED"
            serialized = JSON3.write(denied)
            @test !occursin(outside_path, serialized)
            @test !occursin("ServiceError", serialized)
            @test !occursin("Stacktrace", serialized)
        end

        opened_artifact = bounded_send_request!(
            socket,
            request_message(
                "artifact-open",
                "artifact.open";
                parameters = Dict("path" => artifact_path),
            ),
            limits,
        )
        @test opened_artifact["ok"] == true
        artifact_id = opened_artifact["result"]["artifact_id"]

        window_response = bounded_send_request!(
            socket,
            request_message(
                "window",
                "result.window";
                parameters = Dict(
                    "artifact_id" => artifact_id,
                    "offset" => 16,
                    "length" => 32,
                ),
            ),
            limits,
        )
        @test window_response["ok"] == true
        @test window_response["result"]["binary_frame"] == true
        binary_frame = bounded_read_frame(socket, limits)
        binary_metadata, binary_data = decode_binary_payload(binary_frame)
        @test binary_metadata["artifact_id"] == artifact_id
        @test binary_metadata["offset"] == 16
        @test binary_metadata["length"] == 32
        @test binary_data == UInt8.(16:47)

        cancellation = bounded_send_request!(
            socket,
            request_message(
                "cancel-command",
                "request.cancel";
                parameters = Dict("target_request_id" => "cancelled-ping"),
            ),
            limits,
        )
        @test cancellation["result"]["cancelled"] == true
        cancelled = bounded_send_request!(
            socket,
            request_message("cancelled-ping", "service.ping"),
            limits,
        )
        @test cancelled["ok"] == false
        @test cancelled["error"]["code"] == "REQUEST_CANCELLED"

        started_worker = bounded_send_request!(
            socket,
            request_message("worker-start", "worker.start"),
            limits,
        )
        @test started_worker["ok"] == true
        worker_id = started_worker["result"]["worker_id"]
        worker_state = bounded_send_request!(
            socket,
            request_message(
                "worker-status",
                "worker.status";
                parameters = Dict("worker_id" => worker_id),
            ),
            limits,
        )
        @test worker_state["result"]["state"] == "running"
        worker_limit = bounded_send_request!(
            socket,
            request_message("worker-limit", "worker.start"),
            limits,
        )
        @test worker_limit["ok"] == false
        @test worker_limit["error"]["code"] == "WORKER_LIMIT_REACHED"
        stopped_worker = bounded_send_request!(
            socket,
            request_message(
                "worker-stop",
                "worker.stop";
                parameters = Dict("worker_id" => worker_id),
            ),
            limits,
        )
        @test stopped_worker["result"]["state"] == "stopped"

        closed_project = bounded_send_request!(
            socket,
            request_message(
                "project-close",
                "project.close";
                parameters = Dict("project_id" => project_id),
            ),
            limits,
        )
        @test closed_project["result"]["closed"] == true

        shutdown = bounded_send_request!(
            socket,
            request_message("shutdown", "service.shutdown"),
            limits,
        )
        @test shutdown["ok"] == true
        close(socket)
        shutdown_status = timedwait(() -> istaskdone(server_task), 10.0; pollint = 0.02)
        @test shutdown_status == :ok
        shutdown_status == :ok || error("local service did not stop within the bounded timeout")
        fetch(server_task)
        ready_text = String(take!(ready_output))
        @test occursin("AIMORA_SERVICE_READY\t1.0\t", ready_text)
        if !Sys.iswindows()
            @test !ispath(endpoint)
        end
    end
end
