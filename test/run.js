export async function run(x) {
    const response = await fetch('arraycopy.wasm');
    const bytes = await response.arrayBuffer();
    const { instance } = await WebAssembly.instantiate(bytes, {Math: {
                sin: x => Math.sin(x), 
                cos: x => Math.cos(x), 
                tan: x => Math.tan(x), 
                acos: x => Math.acos(x), 
                },
             console: {
                log: x => console.log(x),
                error: x => console.error(x),
             },
             ext: {
                twox: x => 2*x
                }});

    const { f1 } = instance.exports;

    return f1(x)

}

