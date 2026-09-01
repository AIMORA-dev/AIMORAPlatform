#!/usr/bin/env julia
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

using AIMORAService

exit(AIMORAService.run_cli(copy(ARGS)))
