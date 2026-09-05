# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

@info "AIMORAService GUI040 test phase" phase = "framing-authentication-local-integration"
include("runtests_gui040_base.jl")

@info "AIMORAService GUI040 test phase" phase = "worker-supervision-recovery"
include("worker_supervision.jl")

@info "AIMORAService inspector test phase" phase = "schema-transaction-history"
include("inspector_transactions.jl")

@info "AIMORAService semantic edit test phase" phase = "stable-identity-transaction"
include("semantic_editing.jl")
include("drafting_session.jl")
include("drafting_arrangements.jl")
include("drafting_text.jl")
include("drafting_explode.jl")
include("drafting_layers.jl")

@info "AIMORAService GUI040 test phase" phase = "complete"

include("local_listener_endpoints.jl")

include("protocol_schema_consistency.jl")
