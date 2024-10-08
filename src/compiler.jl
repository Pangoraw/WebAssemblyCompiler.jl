
export compile

"""
    compile(funs::Tuple...; filepath = "foo.wasm", jspath = filepath * ".js", names = nothing, validate = true, optimize = false, experimental = true)

Compile the methods defined by `funs`.
Each function definition to be compiled is a tuple with the first entry as the function followed by argument types.
Keyword arguments include:

* `filepath`--File path for the WebAssembly binary. The path will be created if it doesn't exist.
* `jspath`--File path for the extra JavaScript file that defines `jsexports` which are the JS functions imported into WebAssembly (those normally defined by [`@jscall`](@ref)). 
* `names`--A vector or other indexable object with names of functions that are compiled. It's length must equal the length of `funs`.
* `validate`--Apply Binaryen's validation tests.
* `optimize`--Apply Binaryen's default optimization passes (still shaky).
* `experimental`--Use experimental WebAssembly features.

`compile` also writes a WebAssembly text tile to the same path as `filepath` with an added ".wat" extension.

Examples:

    compile((exp, Float64), filepath = "exp.wasm", optimize = true)   
    compile((acos, Float64), (asin, Float64), filepath = "trigs.wasm", optimize = true)   

"""
function compile(funs::Tuple...; filepath = "foo.wasm", jspath = filepath * ".js", validate = true, optimize = false, experimental = false, names = nothing)
    mkpath(dirname(filepath))
    cis = Core.CodeInfo[]
    dummyci = code_typed(() -> nothing, Tuple{})[1].first
    ctx = CompilerContext(dummyci; experimental)
    debug(:offline) && _debug_ci(ctx)

    # BinaryenModuleSetFeatures(ctx.mod, BinaryenFeatureReferenceTypes() | BinaryenFeatureGC() | (experimental ? BinaryenFeatureStrings() : 0))
    # BinaryenModuleSetFeatures(ctx.mod, BinaryenFeatureAll())
    # BinaryenModuleAutoDrop(ctx.mod) # TODO

    # Create CodeInfo's, and fill in names first
    for (i, funtpl) in enumerate(funs)
        tt = length(funtpl) > 1 ? Base.to_tuple_type(funtpl[2:end]) : Tuple{}
        # isconcretetype(tt) || error("input type signature $tt for $(funtpl[1]) is not concrete")
        ci = code_typed(funtpl[1], tt, interp = StaticInterpreter())[1].first
        push!(cis, ci)
        if names === nothing
            name = string(funtpl[1])   # [1:min(end,20)]
        else
            name = string(names[i])
        end
        sig = ci.parent.specTypes
        ctx.sigs[name] = sig
        ctx.names[sig] = name
    # end
    # # Compile funs
    # for i in eachindex(cis)
        fun = funs[i][1]
        newctx = CompilerContext(ctx, cis[i], toplevel = true)
        if callablestruct(newctx)
            newctx.gfun = getglobal(newctx, fun) 
        end
        debug(:offline) && _debug_ci(newctx, ctx)
        compile_method(newctx, name, exported = true)
    end
    # BinaryenModuleAutoDrop(ctx.mod)
    # debug(:offline) && _debug_module(ctx)
    # debug(:inline) && BinaryenModulePrint(ctx.mod)
    display(WC.Wat(ctx.mod, false))
    validate && WC.validate(ctx.mod)
    # BinaryenSetShrinkLevel(0)
    # BinaryenSetOptimizeLevel(2)
    optimize && (ctx.mod = WC.optimize(ctx.mod))

    # out = BinaryenModuleAllocateAndWrite(ctx.mod, C_NULL)
    # write(filepath, unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(out.binary), (out.binaryBytes,)))
    # Libc.free(out.binary)
    # out = BinaryenModuleAllocateAndWriteText(ctx.mod)
    # write(filepath * ".wat", unsafe_string(out))
    # Libc.free(out)
    # BinaryenModuleDispose(ctx.mod)
    open(io -> WC.wwrite(io, ctx.mod), filepath, "w")

    jstext = "var jsexports = { js: {} };\n"
    imports = unique(values(ctx.imports))
    jstext *= join(["jsexports['js']['$v'] = $v;" for v in imports], "\n")
    write(jspath, jstext)
    nothing
end

function sigargs(ctx, sig)
    sigparams = collect(sig.parameters)
    jparams = [gettype(ctx, sigparams[1]), (gettype(ctx, sigparams[i]) for i in 2:length(sigparams) if argused(ctx, i))...]
    if ctx.toplevel || !callablestruct(ctx)
        jparams = jparams[2:end]
    end
    return jparams
end

function compile_method(ctx::CompilerContext, funname; sig = ctx.ci.parent.specTypes, exported = false)
    # funname = ctx.names[sig]
    sigparams = collect(sig.parameters)
    jparams = [gettype(ctx, sigparams[1]), (gettype(ctx, sigparams[i]) for i in 2:length(sigparams) if argused(ctx, i))...]
    # if ctx.toplevel || !callablestruct(ctx)
    #     jparams = jparams[2:end]
    # end

    ircode, _ = Base.code_ircode_by_type(sig) |> only

    body = compile_method_body(ctx, ircode)
    functype = WasmCompiler.FuncType(jparams, ctx.ci.rettype == Nothing ? [] : [gettype(ctx, ctx.ci.rettype)])
    if !any(f -> f.name == funname, ctx.mod.funcs)
        push!(
            ctx.mod.funcs,
            WC.Func(funname, functype, [functype.params..., ctx.locals...], body)
        )
        if exported
            num_exports = count(exp -> exp isa WC.FuncExport, ctx.mod.exports)
            push!(ctx.mod.exports, WC.FuncExport(funname, num_exports + length(ctx.mod.funcs)))
        end
    end
    return nothing
end

import Core.Compiler: block_for_inst, compute_basic_blocks

function compile_method_body(ctx::CompilerContext, ircode)
    ci = ctx.ci
    code = ci.code
    ctx.localidx += nargs(ctx)
    # cfg = Core.Compiler.compute_basic_blocks(code)
    cfg = ircode.cfg

    # Find and collect phis
    phis = Dict{Int, Any}()
    for (idx, block) in enumerate(cfg.blocks)
        for stmt in block.stmts
            node = code[stmt]
            !isa(node, Core.PhiNode) && break
            for (i, edge) in enumerate(node.edges)
                blocknum = block_for_inst(cfg, Int(edge))
                if !haskey(phis, blocknum)
                    phis[blocknum] = Pair{Int64, Any}[]
                end
                push!(phis[blocknum], stmt => node.values[i])
            end
            ctx.varmap[stmt] = ctx.localidx
            push!(ctx.locals, gettype(ctx, ctx.ci.ssavaluetypes[stmt]))
            ctx.localidx += 1
        end
    end
    # Create blocks
    rblocks = [
        compile_block(ctx, cfg, phis, idx) for idx in eachindex(cfg.blocks)
    ]
    # # Create branches
    # for (idx, block) in enumerate(cfg.blocks)
    #     terminator = code[last(block.stmts)]
    #     if isa(terminator, Core.ReturnNode)
    #         # return never has any successors, so no branches needed
    #     elseif isa(terminator, Core.GotoNode)
    #         toblock = block_for_inst(cfg, terminator.label)
    #         RelooperAddBranch(rblocks[idx], rblocks[toblock], C_NULL, C_NULL)
    #     elseif isa(terminator, Core.GotoIfNot)
    #         toblock = block_for_inst(cfg, terminator.dest)
    #         RelooperAddBranch(rblocks[idx], rblocks[idx + 1], _compile(ctx, terminator.cond), C_NULL)
    #         RelooperAddBranch(rblocks[idx], rblocks[toblock], C_NULL, C_NULL)
    #     elseif idx < length(cfg.blocks)
    #         RelooperAddBranch(rblocks[idx], rblocks[idx + 1], C_NULL, C_NULL)
    #     end
    # end
    # RelooperRenderAndDispose(relooper, rblocks[1], 0)
    WasmCompiler.reloop(rblocks, ircode)
end

