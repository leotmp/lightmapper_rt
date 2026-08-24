
#+feature using-stmt
#+vet !unused-imports

package lightmapper_rt

import intr "base:intrinsics"
import "core:slice"
import "core:fmt"
import "core:log"
import "core:thread"

import "no_gfx_api/gpu"
import oidn "oidn_odin_bindings"

Handle :: struct { idx: u32, gen: u32 }
Mesh_Handle :: distinct Handle
Lightmap_UV_Handle :: distinct Handle

Context :: struct
{
    oidn_device: oidn.Device,

    shaders: Shaders,

    desc_pool: ^gpu.Descriptor_Pool,
    linear_sampler_id: u32,
    point_sampler_id: u32,

    // Upload resources
    bvh_scratch_arena: gpu.Arena,  // GPU local
    upload_arena: gpu.Arena,  // CPU mapped

    // Global resources
    meshes: Resource_Pool(Mesh_Handle, Mesh),
    lm_uvs: Resource_Pool(Lightmap_UV_Handle, LM_UVs),
}

init :: proc(ctx: ^Context, desc_pool: ^gpu.Descriptor_Pool)
{
    ctx.oidn_device = create_oidn_context()
    ctx.shaders = shaders_create()
    ctx.bvh_scratch_arena = gpu.arena_create(mem_type = gpu.Memory.GPU)
    ctx.upload_arena = gpu.arena_create()
    ctx.desc_pool = desc_pool
    ctx.linear_sampler_id = gpu.desc_pool_alloc_sampler(desc_pool, gpu.sampler_descriptor({}))
    ctx.point_sampler_id = gpu.desc_pool_alloc_sampler(desc_pool, gpu.sampler_descriptor({ min_filter = .Nearest, mag_filter = .Nearest }))
    pool_init(&ctx.meshes)
    pool_init(&ctx.lm_uvs)
}

cleanup :: proc(ctx: ^Context)
{
    gpu.wait_idle()

    mesh_alive_list := pool_get_alive_list(&ctx.meshes, context.allocator)
    defer delete(mesh_alive_list)
    for &res in mesh_alive_list {
        mesh_destroy(&res.info)
    }

    lm_uvs_alive_list := pool_get_alive_list(&ctx.lm_uvs, context.allocator)
    defer delete(lm_uvs_alive_list)
    for &res in lm_uvs_alive_list {
        lm_uvs_destroy(&res.info)
    }

    shaders_destroy(&ctx.shaders)
    gpu.arena_destroy(&ctx.bvh_scratch_arena)
    gpu.arena_destroy(&ctx.upload_arena)
    ctx^ = {}
}

Mesh_Desc :: struct
{
    // Must stay alive until the removal of this Mesh_Handle.
    positions_gpu: gpu.slice_t([3]f32),
    normals_gpu:   gpu.slice_t([3]f32),
    uvs_gpu:       gpu.slice_t([2]f32),
    indices_gpu:   gpu.slice_t(u32),
}

add_mesh :: proc(using ctx: ^Context, cmd_buf: gpu.Command_Buffer, desc: Mesh_Desc) -> Mesh_Handle
{
    bvh := build_blas(&bvh_scratch_arena,
                      cmd_buf,
                      desc.positions_gpu,
                      desc.indices_gpu,
                      u32(gpu.slice_len(desc.indices_gpu)),
                      u32(gpu.slice_len(desc.positions_gpu)))

    res := pool_add(&meshes, Mesh {
        positions = desc.positions_gpu,
        normals   = desc.normals_gpu,
        uvs       = desc.uvs_gpu,
        indices   = desc.indices_gpu,
        bvh       = bvh,
    })

    return res
}

remove_mesh :: proc(ctx: ^Context, handle: ^Mesh_Handle)
{
    mesh := pool_get(&ctx.meshes, handle^)
    mesh_destroy(&mesh)
    pool_remove(&ctx.meshes, handle^)
    handle^ = {}
}

Lightmap_UVs_Desc :: struct
{
    // Temporary, can be changed/freed after this call.
    positions_cpu: [][3]f32,
    normals_cpu:   [][3]f32,
    lm_uvs_cpu:    [][2]f32,
    indices_cpu:   []u32,

    // Must stay alive until the removal of this Lightmap_UV_Handle.
    lm_uvs_gpu:    gpu.slice_t([2]f32),
}

add_lightmap_uvs :: proc(ctx: ^Context, cmd_buf: gpu.Command_Buffer, desc: Lightmap_UVs_Desc) -> Lightmap_UV_Handle
{
    seams_cpu := compute_seams(desc.positions_cpu, desc.normals_cpu, desc.lm_uvs_cpu, desc.indices_cpu)

    seams_staging := gpu.arena_alloc(&ctx.upload_arena, Seam, len(seams_cpu))
    copy(seams_staging.cpu, seams_cpu[:])

    seams := gpu.mem_alloc(Seam, len(seams_cpu), gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, seams, seams_staging)

    res := pool_add(&ctx.lm_uvs, LM_UVs {
        uvs = desc.lm_uvs_gpu,
        seams = seams,
    })
    return res
}

remove_lightmap_uvs :: proc(ctx: ^Context, handle: ^Lightmap_UV_Handle)
{
    lm_uvs := pool_get(&ctx.lm_uvs, handle^)
    lm_uvs_destroy(&lm_uvs)
    pool_remove(&ctx.lm_uvs, handle^)
    handle^ = {}
}

Bake :: struct
{
    ctx: ^Context,
    gbufs: GBuffers,
    instances: [dynamic]Instance,
    lights: Lights,
    scene_gpu: Scene_GPU,
    lightmap_size: u32,
    lightmap: gpu.Texture,  // Not owned
    lightmap_rw_id: u32,
    lightmap_id: u32,
    gbufs_id: u32,

    pathtrace_output: gpu.Owned_Texture,
    pathtrace_output_rw_id: u32,
    tmp_tex: gpu.Owned_Texture,
    tmp_tex_id: u32,
    tmp_tex_rw_id: u32,

    // OIDN
    shared_buf_vk: External_Buf,
    shared_buf_oidn: oidn.Buffer,
    shared_sem_oidn: oidn.Semaphore,
    shared_sem_nogfx: gpu.Semaphore,
    denoise_tile_idx: u32,
    bake_sem_value: u64,
    filter: oidn.Filter,

    accum_counter: u32,
    max_samples: u32,
}

Bake_Params :: struct
{
    
}

Instance :: struct
{
    mesh_handle: Mesh_Handle,
    // You might want different instances of the same mesh to have a completely different set of UVs.
    lm_uvs_handle: Lightmap_UV_Handle,
    transform: matrix[4, 4]f32,
    lm_uvs_offset: [2]f32,
    lm_uvs_scale: [2]f32,

    // Material properties
    albedo_tex_id: u32,
    albedo: [3]f32,
}

Lights :: struct
{
    sun_dir: [3]f32,
    sun_radius: f32,       // Radians
    sun_emission: [3]f32,  // NOTE: This is total emission across the sun's surface
}

bake_begin :: proc(ctx: ^Context, #any_int lightmap_size: i64, samples: u32, lightmap: gpu.Texture, instances: []Instance, lights: Lights) -> Bake
{
    return bake_begin_impl(ctx, lightmap_size, samples, lightmap, instances, lights)
}

bake_scene_changed :: proc(bake: ^Bake, instances: []Instance, lights: Lights) -> bool
{
    return bake.lights != lights
}

bake_reset :: proc(bake: ^Bake)
{
    bake.accum_counter = 0
}

bake_progress :: proc(bake: ^Bake) -> f32
{
    return f32(bake.accum_counter) / f32(bake.max_samples)
}

bake_iteration :: proc(bake: ^Bake, frame_arena: ^gpu.Arena, instances: []Instance, lights: Lights, fix_seams: bool, denoise_on_preview: bool)
{
    bake_iteration_impl(bake, frame_arena, instances, lights, fix_seams, denoise_on_preview)
}

bake_is_done :: proc(bake: ^Bake) -> bool
{
    return bake.accum_counter >= bake.max_samples
}

bake_destroy :: proc(bake: ^Bake)
{
    gpu.semaphore_destroy(bake.shared_sem_nogfx)
    gbufs_destroy(&bake.gbufs)
    gpu.texture_free_and_destroy(&bake.pathtrace_output)
    gpu.texture_free_and_destroy(&bake.tmp_tex)
    scene_destroy(&bake.scene_gpu)
    external_buf_destroy(&bake.shared_buf_vk)
    bake^ = {}
}

// For debug visualizations

bake_debug_get_gbuffer_world_pos :: proc(bake: ^Bake) -> gpu.Texture
{
    return bake.gbufs.world_pos
}

bake_debug_get_gbuffer_world_normals :: proc(bake: ^Bake) -> gpu.Texture
{
    return bake.gbufs.world_normals
}

bake_debug_ground_truth :: proc(bake: ^Bake, cmd_buf: gpu.Command_Buffer, frame_arena: ^gpu.Arena, camera_to_world: matrix[4, 4]f32, output_rw_id: u32, resolution: [2]f32, accum_counter: u32)
{
    pathtrace(bake, cmd_buf, frame_arena, .First_Person, camera_to_world, output_rw_id, resolution, accum_counter, bake.lights)
}
