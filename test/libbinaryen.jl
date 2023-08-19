@testitem "LibBinaryen" begin
    using Binaryen.LibBinaryen
    using NodeCall
    NodeCall.initialize(node_args = ["--experimental-wasm-gc"]);

    # adapted from https://github.com/WebAssembly/binaryen/blob/main/test/example/c-api-hello-world.c
    # Apache License
    mod = BinaryenModuleCreate()
  
    # Create a function type for  i32 (i32, i32)
    ii = [BinaryenTypeInt32(), BinaryenTypeInt32()]
    params = BinaryenTypeCreate(ii, 2)
    results = BinaryenTypeInt32()
  
    # Get the 0 and 1 arguments, and add them
    x = BinaryenLocalGet(mod, 0, BinaryenTypeInt32())
    y = BinaryenLocalGet(mod, 1, BinaryenTypeInt32())
    add = BinaryenBinary(mod, BinaryenAddInt32(), x, y)
  
    # Create the add function
    # Note: no additional local variables
    # Note: no basic blocks here, we are an AST. The function body is just an
    # expression node.
    adder = BinaryenAddFunction(mod, "adder", params, results, C_NULL, 0, add)
    BinaryenAddFunctionExport(mod, "adder", "adder")
    # Print it out
    # BinaryenModulePrint(mod)
    out = BinaryenModuleAllocateAndWrite(mod, C_NULL)
    
    write("t.wasm", unsafe_wrap(Vector{UInt8}, Ptr{UInt8}(out.binary), (out.binaryBytes,)))
    Libc.free(out.binary)  

    # Clean up the mod, which owns all the objects we created above
    BinaryenModuleDispose(mod)

    js = """
    var funs = {};
    (async () => {
        const fs = require('fs');
        const wasmBuffer = fs.readFileSync('t.wasm');
        const {instance} = await WebAssembly.instantiate(wasmBuffer);
        funs.adder = instance.exports.adder;
    })();
    """

    p = node_eval(js)
    @await p
    @test node"funs.adder(5,6)" == 11

    run(`$(Binaryen.Bin.wasmdis()) t.wasm -o t.wat`)
    wat = read("t.wat", String)
    @test contains(wat, raw"func $0 (param $0 i32) (param $1 i32) (result i32)")

end