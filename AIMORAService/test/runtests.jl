# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

@info "AIMORAService GUI040 test phase" phase = "framing-authentication-local-integration"
include("runtests_gui040_base.jl")

@info "AIMORAService GUI040 test phase" phase = "worker-supervision-recovery"
include("worker_supervision.jl")

@info "AIMORAService GUI040 test phase" phase = "complete"
