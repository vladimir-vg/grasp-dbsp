.PHONY: test

test:
	@rm -rf test_suite_graphs
	RENDER_DOT=1 rebar3 ct
