JULIA ?= julia

.PHONY: check test example clean

check:
	$(JULIA) --startup-file=no check.jl

test: check
	$(JULIA) --startup-file=no --project=. -e 'using Pkg; Pkg.test()'

example: test
	$(JULIA) --startup-file=no --project=. examples/complete_report/run.jl examples/complete_report/outputs

clean:
	rm -rf examples/complete_report/outputs
