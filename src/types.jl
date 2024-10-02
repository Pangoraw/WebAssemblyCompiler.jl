using WasmCompiler:
    i32, i64, f32, f64, ValType,
    Inst, Module, InstOperands

export Externref

"""
    Externref()

A type representing an external object in the host system (JavaScript).
This object can be passed around, but no direct operations are supported.
The object can be passed back to JavaScript methods. 
To convert a Julia object to an `Externref`, use [`JS.object`](@ref). 
"""
struct Externref 
    dummy::Int32
end
Externref() = Int32(-1)

struct Box{T}
    x::T
end

wtypes() = Dict{Any, ValType}(
    Int64     => WC.i64,
    Int32     => WC.i32,
    UInt64    => WC.i64,
    UInt32    => WC.i32,
    UInt8     => WC.i32,
    Bool      => WC.i32,
    Float64   => WC.f64,
    Float32   => WC.f32,
    # Symbol    => BinaryenTypeStringref(),
    # String    => BinaryenTypeStringref(),
    Externref => WC.ExternRef(false),
    Any       => WC.EqRef(false),
)

const basictypes = [Int64, Int32, UInt64, UInt32, UInt8, Bool, Float64, Float32]

mutable struct CompilerContext
    ## module-level context
    mod::Module
    names::Dict{DataType, String}  # function signature to name
    sigs::Dict{String, DataType}   # name to function signature
    imports::Dict{String, Any}
    wtypes::Dict{Any, ValType}
    globals::IdDict{Any, Any}    
    objects::IdDict{Any, Any}
    ## function-level context
    ci::Core.CodeInfo
    body::Vector{InstOperands}
    locals::Vector{ValType}
    localidx::Int
    varmap::Dict{Int, Int}
    toplevel::Bool
    gfun::Any
    ## special context
    meta::Dict{Symbol, Any}
end

const experimentalwat = raw"""
(module

  (func $hash-string
    (param $s stringref) (result i64)
    (return (i64.extend_i32_s (string.hash (local.get $s)))))

  (func $string-eq
    (param $s1 stringref) (param $s2 stringref) (result i32)
    (return 
      (string.eq (local.get $s1) (local.get $s2))))
)
"""
# The approach above is nice, because WAT is easier to write than Binaryen code.
# But, the one above errors in NodeCall with the older version of V8. 
const wat = raw"""
(module
) 
"""

CompilerContext(ci::Core.CodeInfo; experimental = false) = begin
    @assert !experimental
    CompilerContext(Module(), Dict{DataType, String}(), Dict{String, DataType}(), Dict{String, Any}(), wtypes(), IdDict{Any, Any}(), IdDict{Any, Any}(),
                    ci, [], [], 1, Dict{Int, Int}(), true, nothing, Dict{Symbol, Any}())
end
CompilerContext(ctx::CompilerContext, ci::Core.CodeInfo; toplevel = false) =
    CompilerContext(ctx.mod, ctx.names, ctx.sigs, ctx.imports, ctx.wtypes, ctx.globals, ctx.objects,
                    ci, [], [], 1, Dict{Int, Int}(), toplevel, nothing, Dict{Symbol, Any}())

