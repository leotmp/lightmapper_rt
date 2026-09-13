
package xatlas

import "core:c"

CUSTOM_FORK :: true

// Odin bindings for XAtlas. Has most C++ Quality Of Life things.
// Unless otherwise specified, default values are 0/nil/false.

ChartType :: enum c.int
{
    Planar = 0,
    Ortho,
    LSCM,
    Piecewise,
    Invalid
}

// A group of connected faces, belonging to a single atlas.
Chart :: struct
{
    faceArray: [^]u32,
    atlasIndex: u32,  // Sub-atlas index.
    faceCount: u32,
    type: ChartType,
    material: u32,
}

// Output vertex.
Vertex :: struct
{
    atlasIndex: i32,  // Sub-atlas index. -1 if the vertex doesn't exist in any atlas.
    chartIndex: i32,  // -1 if the vertex doesn't exist in any chart.
    uv: [2]f32,  // Not normalized - values are in Atlas width and height range.
    xref: u32,  // Index of input vertex from which this output vertex originated.
}

// Output mesh.
Mesh :: struct
{
    chartArray: [^]Chart,
    indexArray: [^]u32,
    vertexArray: [^]Vertex,
    chartCount: u32,
    indexCount: u32,
    vertexCount: u32,
}

when CUSTOM_FORK
{
    MeshInstance :: struct
    {
        meshIndex: u32,
        chartTransformBase: u32,
    }
}

ImageChartIndexMask:   u32 : 0x1FFFFFFF
ImageHasChardIndexBit: u32 : 0x80000000
ImageIsBilinearBit:    u32 : 0x40000000
ImageIsPaddingBit:     u32 : 0x20000000

when CUSTOM_FORK
{
    ChartTransform :: struct
    {
        mat: [4]f32,  // 2x2
        offset: [2]f32,
        atlasIndex: u32,
    }
}

// Empty on creation. Populated after charts are packed.
when CUSTOM_FORK
{
    Atlas :: struct
    {
        image: [^]u32,
        meshes: [^]Mesh,  // The output meshes, corresponding to each AddMesh call.
        utilization: ^f32,  // Normalized atlas texel utilization array. E.g. a value of 0.8 means 20% empty space. atlasCount in length.
        width: u32,  // Atlas width in texels.
        height: u32,  // Atlas height in texels.
        atlasCount: u32,  // Number of sub-atlases. Equal to 0 unless PackOptions resolution is changed from default (0).
        chartCount: u32,  // Total number of charts in all meshes.
        meshCount: u32,  // Number of output meshes. Equal to the number of times AddMesh was called.
        texelsPerUnit: f32,  // Equal to PackOptions texelsPerUnit if texelsPerUnit > 0, otherwise an estimated value to match PackOptions resolution.

        meshInstances: [^]MeshInstance,
        meshInstanceCount: u32,
        chartTransforms: [^]ChartTransform,
        chartTransformCount: u32,
    }
}
else
{
    Atlas :: struct
    {
        image: [^]u32,
        meshes: [^]Mesh,  // The output meshes, corresponding to each AddMesh call.
        utilization: ^f32,  // Normalized atlas texel utilization array. E.g. a value of 0.8 means 20% empty space. atlasCount in length.
        width: u32,  // Atlas width in texels.
        height: u32,  // Atlas height in texels.
        atlasCount: u32,  // Number of sub-atlases. Equal to 0 unless PackOptions resolution is changed from default (0).
        chartCount: u32,  // Total number of charts in all meshes.
        meshCount: u32,  // Number of output meshes. Equal to the number of times AddMesh was called.
        texelsPerUnit: f32,  // Equal to PackOptions texelsPerUnit if texelsPerUnit > 0, otherwise an estimated value to match PackOptions resolution.
    }
}

IndexFormat :: enum c.int
{
    UInt16,
    UInt32,
}

MeshDecl :: struct
{
    vertexPositionData: rawptr,
    vertexNormalData: rawptr,  // optional
    vertexUvData: rawptr,  // optional. The input UVs are provided as a hint to the chart generator.
    indexData: rawptr,  // optional

    // Optional. Must be faceCount in length.
    // Don't atlas faces set to true. Ignored faces still exist in the output meshes, Vertex uv is set to (0, 0) and Vertex atlasIndex to -1.
    faceIgnoreData: [^]bool,

    // Optional. Must be faceCount in length.
    // Only faces with the same material will be assigned to the same chart.
    faceMaterialData: [^]u32,

    // Optional. Must be faceCount in length.
    // Polygon / n-gon support. Faces are assumed to be triangles if this is null.
    faceVertexCount: [^]u8,

    vertexCount: u32,
    vertexPositionStride: u32,
    vertexNormalStride: u32,  // optional
    vertexUvStride: u32,  // optional
    indexCount: u32,
    indexOffset: i32,  // optional. Add this offset to all indices.
    faceCount: u32,  // Optional if faceVertexCount is null. Otherwise assumed to be indexCount / 3.
    indexFormat: IndexFormat,

    // Vertex positions within epsilon distance of each other are considered colocal.
    epsilon: f32,  // default: 1.192092896e-07F
}

AddMeshError :: enum c.int
{
    SUCCESS,  // No error.
    ERROR,  // Unspecified error.
    INDEXOUTOFRANGE,  // An index is >= MeshDecl vertexCount.
    INVALIDFACEVERTEXCOUNT,  // Must be >= 3.
    INVALIDINDEXCOUNT,  // Not evenly divisible by 3 - expecting triangles.
}

UvMeshDecl :: struct
{
    vertexUvData: rawptr,
    indexData: rawptr,  // optional
    faceMaterialData: [^]u32,  // Optional. Overlapping UVs should be assigned a different material. Must be indexCount / 3 in length.
    vertexCount: u32,
    vertexStride: u32,
    indexCount: u32,
    indexOffset: i32,  // optional. Add this offset to all indices.
    indexFormat: IndexFormat,
}

// Custom parameterization function. texcoords initial values are an orthogonal parameterization.
ParameterizeFunc :: #type proc "c"(positions: [^]f32, texcoords: [^]f32, vertexCount: u32, indices: [^]u32, indexCount: u32) -> rawptr

ChartOptions :: struct
{
    paramFunc: ParameterizeFunc,

    maxChartArea: f32,  // Don't grow charts to be larger than this. 0 means no limit.
    maxBoundaryLength: f32,  // Don't grow charts to have a longer boundary than this. 0 means no limit.

    // Weights determine chart growth. Higher weights mean higher cost for that metric.
    normalDeviationWeight: f32,  // default: 2.0, Angle between face and average chart normal.
    roundnessWeight: f32,  // default: 0.01
    straightnessWeight: f32,  // default: 6.0
    normalSeamWeight: f32,  // default: 4.0 If > 1000, normal seams are fully respected.
    textureSeamWeight: f32,  // default: 0.5

    maxCost: f32,  // default: 2.0, If total of all metrics * weights > maxCost, don't grow chart. Lower values result in more charts.
    maxIterations: u32,  // default: 1, Number of iterations of the chart growing and seeding phases. Higher values result in better charts.

    useInputMeshUvs: c.bool,  // Use MeshDecl::vertexUvData for charts.
    fixWinding: c.bool,  // Enforce consistent texture coordinate winding.
}

PackOptions :: struct
{
    // Charts larger than this will be scaled down. 0 means no limit.
    maxChartSize: u32,

    // Number of pixels to pad charts with.
    padding: u32,

    // Unit to texel scale. e.g. a 1x1 quad with texelsPerUnit of 32 will take up approximately 32x32 texels in the atlas.
    // If 0, an estimated value will be calculated to approximately match the given resolution.
    // If resolution is also 0, the estimated value will approximately match a 1024x1024 atlas.
    texelsPerUnit: f32,

    // If 0, generate a single atlas with texelsPerUnit determining the final resolution.
    // If not 0, and texelsPerUnit is not 0, generate one or more atlases with that exact resolution.
    // If not 0, and texelsPerUnit is 0, texelsPerUnit is estimated to approximately match the resolution.
    resolution: u32,

    // Leave space around charts for texels that would be sampled by bilinear filtering.
    bilinear: c.bool,  // default: true

    // Align charts to 4x4 blocks. Also improves packing speed, since there are fewer possible chart locations to consider.
    blockAlign: c.bool,

    // Slower, but gives the best result. If false, use random chart placement.
    bruteForce: c.bool,

    // Create Atlas::image
    createImage: c.bool,

    // Rotate charts to the axis of their convex hull.
    rotateChartsToAxis: c.bool,  // default: true

    // Rotate charts to improve packing.
    rotateCharts: c.bool,  // default: true
}

// Progress tracking.
ProgressCategory :: enum c.int
{
    ADDMESH,
    COMPUTECHARTS,
    PACKCHARTS,
    BUILDOUTPUTMESHES,
}

// May be called from any thread. Return false to cancel.
ProgressFunc :: #type proc "c"(category: ProgressCategory, progress: c.int, userData: rawptr) -> c.bool

// Custom memory allocation.
ReallocFunc :: #type proc "c"(ptr: rawptr, size: c.size_t) -> rawptr
FreeFunc :: #type proc "c"(ptr: rawptr)

// Custom print function.
PrintFunc :: #type proc "c"(str: cstring, #c_vararg args: ..any) -> c.int

@(private)
LIB :: (
         "xatlas.lib" when ODIN_OS == .Windows
    else "xatlas.o"   when ODIN_OS == .Linux
    else ""
)

when LIB != "" {
    when !#exists(LIB) {
        #panic("Could not find the compiled XAtlas library.")
    }
}

foreign import xatlas_clib { LIB }

@(default_calling_convention="c", link_prefix="xatlas")
foreign xatlas_clib
{
    // Create an empty atlas.
    Create :: proc() -> ^Atlas ---

    Destroy :: proc(atlas: ^Atlas) ---

    // Add a mesh to the atlas. MeshDecl data is copied, so it can be freed after AddMesh returns.
    @(require_results)
    AddMesh :: proc(atlas: ^Atlas, #by_ptr meshDecl: MeshDecl, meshCountHint: u32) -> AddMeshError ---

    when CUSTOM_FORK
    {
        AddMeshInstance :: proc(atlas: ^Atlas, meshIndex: u32, scale: f32 = 1.0) -> u32 ---
    }

    // Wait for AddMesh async processing to finish. ComputeCharts / Generate call this internally.
    AddMeshJoin :: proc(atlas: ^Atlas) ---

    @(require_results)
    AddUvMesh :: proc(atlas: ^Atlas, #by_ptr decl: UvMeshDecl) -> AddMeshError ---

    // Call after all AddMesh calls. Can be called multiple times to recompute charts with different options.
    ComputeCharts :: proc(atlas: ^Atlas, #by_ptr chartOptions: ChartOptions) ---

    // Call after ComputeCharts. Can be called multiple times to re-pack charts with different options.
    PackCharts :: proc(atlas: ^Atlas, #by_ptr packOptions: PackOptions) ---

    // Equivalent to calling ComputeCharts and PackCharts in sequence. Can be called multiple times to regenerate with different options.
    Generate :: proc(atlas: ^Atlas, #by_ptr chartOptions: ChartOptions, #by_ptr packOptions: PackOptions) ---

    SetProgressCallback :: proc(atlas: ^Atlas, progressFunc: ProgressFunc = nil, progressUserData: rawptr = nil) ---
    SetAlloc :: proc(reallocFunc: ReallocFunc, freeFunc: FreeFunc = nil) ---
    SetPrint :: proc(print: PrintFunc, verbose: c.bool) ---

    // Helper functions for error messages.
    AddMeshErrorString :: proc(error: AddMeshError) -> cstring ---
    ProgressCategoryString :: proc(category: ProgressCategory) -> cstring ---

    // Helper functions for setting default values as they are defined in C++.
    MeshDeclInit :: proc(meshDecl: ^MeshDecl) ---
    UvMeshDeclInit :: proc(uvMeshDecl: ^UvMeshDecl) ---
    ChartOptionsInit :: proc(chartOptions: ^ChartOptions) ---
    PackOptionsInit :: proc(packOptions: ^PackOptions) ---
}

StringForEnum :: proc { AddMeshErrorString, ProgressCategoryString }

// Odin-style procedures for struct defaults
make_mesh_decl :: #force_inline proc() -> MeshDecl
{
    res: MeshDecl
    MeshDeclInit(&res)
    return res
}

make_uv_mesh_decl :: #force_inline proc() -> UvMeshDecl
{
    res: UvMeshDecl
    UvMeshDeclInit(&res)
    return res
}

make_chart_options :: #force_inline proc() -> ChartOptions
{
    res: ChartOptions
    ChartOptionsInit(&res)
    return res
}

make_pack_options :: #force_inline proc() -> PackOptions
{
    res: PackOptions
    PackOptionsInit(&res)
    return res
}
