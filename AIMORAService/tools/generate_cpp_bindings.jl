#!/usr/bin/env julia
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

using AIMORAService

length(ARGS) == 3 || error(
    "usage: generate_cpp_bindings.jl SCHEMA HEADER SOURCE",
)

AIMORAService.generate_cpp_bindings(ARGS[1], ARGS[2], ARGS[3])
