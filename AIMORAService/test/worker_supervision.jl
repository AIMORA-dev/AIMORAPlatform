# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
using Test

function gui040_worker_command(service_root::AbstractString)
    worker_script = joinpath(service_root, "bin", "aimora-worker-probe.jl")
    return vcat(
        String.(Base.julia_cmd().exec),
        ["--startup-file=no", "--history-file=no", worker_script],
    )
end

@testset "AIMORAService authenticated worker supervision and recovery" begin
    service_root = normpath(joinpath(@__DIR__, ".."))
    supervisor = AIMORAService.WorkerSupervisor(
        gui040_worker_command(service_root),
        1;
        maximum_recoveries = 1,
        start_timeout_seconds = 5.0,
        stop_timeout_seconds = 1.0,
    )

    try
        started = AIMORAService.start_worker!(supervisor)
        @test started["state"] == "running"
        @test started["worker_protocol_version"] == WORKER_PROTOCOL_VERSION
        @test occursin(r"^[0-9a-f]{64}$", started["manifest_sha256"])
        @test started["generation"] == 1
        @test started["recoveries"] == 0
        @test started["recovered"] == false
        @test started["recovery_exhausted"] == false

        worker_id = started["worker_id"]
        record = supervisor.workers[worker_id]
        first_process = record.process
        kill(first_process)
        @test timedwait(
            () -> Base.process_exited(first_process),
            5.0;
            pollint = 0.02,
        ) == :ok

        recovered = AIMORAService.worker_status(supervisor, worker_id)
        @test recovered["state"] == "running"
        @test recovered["recovered"] == true
        @test recovered["generation"] == 2
        @test recovered["recoveries"] == 1
        @test recovered["manifest_sha256"] == started["manifest_sha256"]

        second_process = record.process
        kill(second_process)
        @test timedwait(
            () -> Base.process_exited(second_process),
            5.0;
            pollint = 0.02,
        ) == :ok

        exhausted = AIMORAService.worker_status(supervisor, worker_id)
        @test exhausted["state"] == "failed"
        @test exhausted["recovered"] == false
        @test exhausted["recovery_exhausted"] == true
        @test exhausted["generation"] == 2
        @test exhausted["recoveries"] == 1
    finally
        AIMORAService.stop_all_workers!(supervisor)
    end
    @test isempty(supervisor.workers)

    mktempdir() do root
        bad_script = joinpath(root, "bad-worker.jl")
        write(
            bad_script,
            raw"""
ready_path = ENV["AIMORA_WORKER_READY_FILE"]
temporary_path = ready_path * ".tmp-" * string(getpid())
record = "AIMORA_STUDY_WORKER_READY\t1.0.0\t" * repeat("a", 64) * "\t" * repeat("0", 64) * "\n"
open(temporary_path, "w") do io
    write(io, record)
    flush(io)
end
mv(temporary_path, ready_path; force = false)
while true
    sleep(0.25)
end
""",
        )
        bad_command = vcat(
            String.(Base.julia_cmd().exec),
            ["--startup-file=no", "--history-file=no", bad_script],
        )
        bad_supervisor = AIMORAService.WorkerSupervisor(
            bad_command,
            1;
            maximum_recoveries = 0,
            start_timeout_seconds = 5.0,
            stop_timeout_seconds = 1.0,
        )
        try
            failure = try
                AIMORAService.start_worker!(bad_supervisor)
                nothing
            catch error
                error
            end
            @test failure isa ServiceError
            @test failure.code == "WORKER_UNAVAILABLE"
        finally
            AIMORAService.stop_all_workers!(bad_supervisor)
        end
        @test isempty(bad_supervisor.workers)
    end
end
