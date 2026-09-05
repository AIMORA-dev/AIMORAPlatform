# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Versioned local process and protocol boundary between AIMORA Julia semantics and native clients."""
module AIMORAService

import Base: isvalid

using JSON3
import AIMORAProject
using Dates
using SHA
using Sockets
using UUIDs

include("types.jl")
include("framing.jl")
include("security.jl")
include("new_project_paths.jl")
include("workers.jl")
include("inspection.jl")
include("semantic_editing.jl")
include("server.jl")
include("drafting_session.jl")
include("project_creation.jl")
include("cli.jl")
include("generator.jl")

export BINARY_FRAME,
       CAPABILITIES,
       CONTROL_FRAME,
       FRAME_HEADER_BYTES,
       FRAME_MAGIC,
       PROTOCOL_VERSION,
       SERVICE_VERSION,
       WORKER_PROTOCOL_VERSION,
       Frame,
       FrameKind,
       InspectionProvider,
       SemanticEditProvider,
       PathPolicy,
       ServiceConfiguration,
       ServiceError,
       ServiceLimits,
       ServiceReply,
       confine_existing_file,
       constant_time_equal,
       decode_binary_payload,
       decode_control_message,
       encode_binary_payload,
       encode_control_message,
       encode_frame,
       generate_cpp_bindings,
       register_inspection_provider!,
       register_semantic_edit_provider!,
       read_frame,
       run_cli,
       serve,
       unregister_inspection_provider!,
       unregister_semantic_edit_provider!,
       write_frame

end
