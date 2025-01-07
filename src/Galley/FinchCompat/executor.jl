mutable struct GalleyOptimizer
    estimator
    verbose
end

Base.:(==)(a::GalleyOptimizer, b::GalleyOptimizer) = a.verbose == b.verbose && a.estimator == b.estimator
Base.hash(a::GalleyOptimizer, h::UInt) = hash(GalleyOptimizer, hash(a.verbose, hash(a.estimator, h)))

GalleyOptimizer(; verbose = false, estimator=DCStats) = GalleyOptimizer(estimator, verbose)

function (ctx::GalleyOptimizer)(prgm)
    finch_mode = ctx.verbose ? :safe : :fast
    verbosity = ctx.verbose ? 3 : 0
    produce_node = prgm.bodies[end]
    output_vars = [Alias(a.name) for a in produce_node.args]
    galley_prgm = Plan(finch_hl_to_galley(normalize_hl(prgm))...)
    tns_inits, instance_prgm = galley(galley_prgm, ST=ctx.estimator, output_aliases=output_vars, verbose=verbosity, output_program_instance=true)
    timer_idx = 1
    julia_prgm = :()
    if operation(instance_prgm) == Finch.block
        for body in instance_prgm.bodies
            if ctx.verbose 
                timer_symbol = Symbol("t_$timer_idx")
                julia_prgm = :($julia_prgm;
                                $timer_symbol = time(); 
                                @finch mode=$(QuoteNode(finch_mode)) begin $(finch_unparse_program(nothing, body)) end;
                                println("Kernel ", $timer_idx, " Runtime: $(time() - $timer_symbol)"))
                timer_idx += 1
            else
                julia_prgm = :($julia_prgm; @finch mode=$(QuoteNode(finch_mode)) begin $(finch_unparse_program(nothing, body)) end)
            
            end
        end
    else
        julia_prgm = :(@finch mode=$(QuoteNode(finch_mode)) begin $(finch_unparse_program(nothing, instance_prgm)) end)
    end
    for init in tns_inits
        julia_prgm = :($init; $julia_prgm)
    end
    julia_prgm = :($julia_prgm; return Tuple([$([v.name for v in output_vars]...)]))
    julia_prgm
end

function Finch.set_options(ctx::GalleyOptimizer; estimator=DCStats, verbose=false)
    ctx.estimator=estimator
    ctx.verbose=verbose
    return ctx
end

"""
    get_stats_dict(ctx::GalleyOptimizer, prgm)

Returns a dictionary mapping the location of input tensors in the program to their statistics objects.
"""
function get_stats_dict(ctx::GalleyOptimizer, prgm)
    deferred_prgm = Finch.defer_tables(:prgm, prgm)
    expr_stats_dict = Dict()
    for node in PostOrderDFS(deferred_prgm)
        if node.kind == table
            expr_stats_dict[node.tns.ex] = ctx.estimator(node.tns.imm, [i.name for i in node.idxs])
        end
    end
    return expr_stats_dict
end

"""
    AdaptiveExecutor(ctx::GalleyOptimizer, verbose=false)

Executes a logic program by compiling it with the given compiler `ctx`. Compiled
codes are cached for each program structure. It first checks the cache for a plan that
was compiled for similar inputs and only compiles if it doesn't find one.
"""

@kwdef struct AdaptiveExecutor
    ctx::GalleyOptimizer
    threshold
    verbose
end

Base.:(==)(a::AdaptiveExecutor, b::AdaptiveExecutor) = a.ctx == b.ctx && a.threshold == b.threshold && a.verbose == b.verbose
Base.hash(a::AdaptiveExecutor, h::UInt) = hash(AdaptiveExecutor, hash(a.ctx, hash(a.threshold, hash(a.verbose, h))))

AdaptiveExecutor(ctx::GalleyOptimizer; threshold = 2, verbose = false) = AdaptiveExecutor(ctx, threshold, verbose)
function Finch.set_options(ctx::AdaptiveExecutor; threshold = 2, verbose = ctx.verbose, tag=:global, kwargs...)
    AdaptiveExecutor(Finch.set_options(ctx.ctx; verbose=verbose, kwargs...), threshold, verbose)
end

galley_codes = Dict()
function (ctx::AdaptiveExecutor)(prgm)
    cur_stats_dict = get_stats_dict(ctx.ctx, prgm)
    stats_list = get!(galley_codes, (ctx.ctx, ctx.threshold, Finch.get_structure(prgm)), [])
    valid_match = nothing
    for (stats_dict, f_code) in stats_list
        if all(issimilar(cur_stats, stats_dict[cur_expr], ctx.threshold) for (cur_expr, cur_stats) in cur_stats_dict)
            valid_match = f_code
            break
        end
    end
    if isnothing(valid_match)
        thunk = Finch.logic_executor_code(ctx.ctx, prgm)
        valid_match = (eval(thunk), thunk)
        push!(stats_list, (cur_stats_dict, valid_match))
    end
    (f, code) = valid_match
    if ctx.verbose
        println("Executing:")
        display(code)
    end
    return Base.invokelatest(f, prgm)
end

"""
    AdaptiveExecutorCode(ctx)

Return the code that would normally be used by the AdaptiveExecutor to run a program.
"""
struct AdaptiveExecutorCode
    ctx
end

function (ctx::AdaptiveExecutorCode)(prgm)
    return Finch.logic_executor_code(ctx.ctx, prgm)
end

"""
    galley_scheduler(verbose = false, estimator=DCStats)

The galley scheduler uses the sparsity patterns of the inputs to optimize the computation.
The first set of inputs given to galley is used to optimize, and the `estimator` is used to
estimate the sparsity of intermediate computations during optimization.
"""
galley_scheduler(;threshold=2, verbose=false) = AdaptiveExecutor(GalleyOptimizer(;verbose=verbose); threshold=threshold, verbose=verbose)

