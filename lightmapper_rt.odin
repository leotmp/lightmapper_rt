
#+feature using-stmt
#+vet !unused-imports

package test

import "core:math/linalg"
import "core:math"
import intr "base:intrinsics"
import "core:slice"
import "core:fmt"
import "core:c"
import "core:log"
import "base:runtime"
import "core:sort"
import "core:sync"
import "core:mem"
import vmem "core:mem/virtual"

import vk "vendor:vulkan"
import "no_gfx_api/gpu"
import oidn "../oidn_odin_bindings"

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
    ctx.bvh_scratch_arena = gpu.arena_init(mem_type = gpu.Memory.GPU)
    ctx.upload_arena = gpu.arena_init()
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
    filter: oidn.Filter,

    accum_counter: u32,
    max_samples: u32,
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
    assert(lightmap_size > 0)

    bake: Bake
    bake.ctx = ctx
    bake.gbufs = gbufs_create(lightmap_size)
    bake.instances = slice.clone_to_dynamic(instances)
    bake.lights = lights
    bake.lightmap_size = u32(lightmap_size)
    bake.lightmap = lightmap
    bake.max_samples = samples

    bake.lightmap_rw_id = gpu.desc_pool_alloc_texture_rw(ctx.desc_pool, gpu.texture_rw_view_descriptor(lightmap, {}))
    bake.lightmap_id = gpu.desc_pool_alloc_texture(ctx.desc_pool, gpu.texture_view_descriptor(bake.lightmap, {}))

    bake.pathtrace_output = gpu.texture_alloc_and_create({
        format = .RGBA16_Float,
        dimensions = { u32(lightmap_size), u32(lightmap_size), 1 },
        usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
    })
    bake.pathtrace_output_rw_id = gpu.desc_pool_alloc_texture_rw(ctx.desc_pool, gpu.texture_rw_view_descriptor(bake.pathtrace_output, {}))

    bake.tmp_tex = gpu.texture_alloc_and_create({
        format = .RGBA16_Float,
        dimensions = { u32(lightmap_size), u32(lightmap_size), 1 },
        usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
    })
    bake.tmp_tex_id = gpu.desc_pool_alloc_texture(ctx.desc_pool, gpu.texture_view_descriptor(bake.tmp_tex, {}))
    bake.tmp_tex_rw_id = gpu.desc_pool_alloc_texture_rw(ctx.desc_pool, gpu.texture_rw_view_descriptor(bake.tmp_tex, {}))

    bake.shared_buf_vk = create_vk_external_buffer_for_oidn(u32(lightmap_size * lightmap_size * 2 * 4))  // TODO: What about other formats?
    bake.shared_buf_oidn = oidn_shared_buffer_from_vk_buffer(ctx.oidn_device, bake.shared_buf_vk)
    bake.filter = oidn_create_lightmap_filter(ctx.oidn_device, bake.shared_buf_oidn, bake.shared_buf_oidn, u32(lightmap_size), .FAST)

    cmd_buf := gpu.commands_begin(.Main)

    meshes_gpu := gpu.arena_alloc(&ctx.upload_arena, Mesh_Shader, len(ctx.meshes.resources))
    for &mesh, i in meshes_gpu.cpu {
        mesh.positions = ctx.meshes.resources[i].info.positions.gpu.ptr
        mesh.normals   = ctx.meshes.resources[i].info.normals.gpu.ptr
        mesh.uvs       = ctx.meshes.resources[i].info.uvs.gpu.ptr
        mesh.indices   = ctx.meshes.resources[i].info.indices.gpu.ptr
    }
    bake.scene_gpu.meshes_shader = gpu.mem_alloc(Mesh_Shader, len(ctx.meshes.resources), gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, bake.scene_gpu.meshes_shader, meshes_gpu)

    instances_gpu := gpu.arena_alloc(&ctx.upload_arena, Instance_Shader, len(instances))
    for &instance, i in instances_gpu.cpu {
        instance = {
            mesh_idx = instances[i].mesh_handle.idx,
            albedo_tex_id = instances[i].albedo_tex_id,
        }
    }
    bake.scene_gpu.instances = gpu.mem_alloc(Instance_Shader, len(instances), gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, bake.scene_gpu.instances, instances_gpu)
    gpu.cmd_barrier(cmd_buf, .All, .All)

    bake.scene_gpu.instances_bvh = upload_bvh_instances(&ctx.upload_arena, cmd_buf, instances, ctx.meshes.resources[:])
    gpu.cmd_barrier(cmd_buf, .Transfer, .Build_BVH)
    bake.scene_gpu.bvh = build_tlas(&ctx.upload_arena, cmd_buf, bake.scene_gpu.instances_bvh, u32(len(instances)))
    gpu.cmd_barrier(cmd_buf, .Build_BVH, .All)

    bake.scene_gpu.bvh_id = gpu.desc_pool_alloc_bvh(ctx.desc_pool, gpu.bvh_descriptor(bake.scene_gpu.bvh))

    resolution := [2]f32 { f32(lightmap_size), f32(lightmap_size) }
    gbufs_render(cmd_buf, &ctx.upload_arena, &bake.gbufs, ctx.shaders, instances, ctx.meshes.resources[:], ctx.lm_uvs.resources[:], resolution)
    gpu.cmd_barrier(cmd_buf, .All, .All, {})

    bake.gbufs_id = gpu.desc_pool_alloc_texture_rw(ctx.desc_pool, []gpu.Texture_Descriptor {
        gpu.texture_rw_view_descriptor(bake.gbufs.world_pos, {}),
        gpu.texture_rw_view_descriptor(bake.gbufs.world_normals, {}),
    })

    gpu.queue_submit(.Main, { cmd_buf })
    return bake
}

bake_scene_changed :: proc(bake: ^Bake, instances: []Instance, lights: Lights) -> bool
{
    return bake.lights != lights
}

bake_reset :: proc(bake: ^Bake)
{
    bake.accum_counter = 0
}

bake_iteration :: proc(bake: ^Bake, frame_arena: ^gpu.Arena, instances: []Instance, lights: Lights, fix_seams: bool)
{
    //if !fix_seams && bake.accum_counter >= bake.max_samples do return

    delete(bake.instances)
    bake.instances = slice.clone_to_dynamic(instances)
    bake.lights = lights

    cmd_buf := gpu.commands_begin(.Main)

    resolution := [2]f32 { f32(bake.lightmap_size), f32(bake.lightmap_size) }
    if bake.accum_counter < bake.max_samples
    {
        gpu.cmd_barrier(cmd_buf, .All, .All, {})  // TODO
        pathtrace(bake, cmd_buf, frame_arena, .Lightmap, {}, bake.pathtrace_output_rw_id, 4096, bake.accum_counter, bake.lights)  // TODO
        gpu.cmd_barrier(cmd_buf, .All, .All, {})  // TODO

        // if denoise
        //if bake.accum_counter == bake.max_samples - 1
        when false
        {
            oidn_copy_to_shared_buf(cmd_buf, bake.shared_buf_vk, bake.pathtrace_output)
            gpu.queue_submit(.Main, { cmd_buf })
            gpu.queue_wait_idle(.Main)

            oidn_run_lightmap_filter(bake.ctx.oidn_device, bake.filter)

            cmd_buf = gpu.commands_begin(.Main)
            oidn_copy_from_shared_buf(cmd_buf, bake.pathtrace_output, bake.shared_buf_vk)
            gpu.cmd_barrier(cmd_buf, .All, .All)
        }
    }

    gpu.cmd_blit_texture(cmd_buf, bake.pathtrace_output, bake.tmp_tex,  { {} }, { {} }, .Linear)
    gpu.cmd_blit_texture(cmd_buf, bake.pathtrace_output, bake.lightmap, { {} }, { {} }, .Linear)
    gpu.cmd_barrier(cmd_buf, .All, .All)

    dilate(bake, cmd_buf, frame_arena, resolution)
    gpu.cmd_barrier(cmd_buf, .All, .All)

    if fix_seams
    {
        smooth_seams(bake, cmd_buf, frame_arena, bake.instances[:], bake.ctx.meshes.resources[:], bake.ctx.lm_uvs.resources[:], resolution)
        gpu.cmd_barrier(cmd_buf, .All, .All)
    }

    bake.accum_counter = min(bake.max_samples, bake.accum_counter + 1)
    gpu.queue_submit(.Main, { cmd_buf })
}

bake_is_done :: proc(bake: ^Bake) -> bool
{
    return bake.accum_counter >= bake.max_samples
}

bake_destroy :: proc(bake: ^Bake)
{
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

/////////////////////////////
// Internal

LM_UVs :: struct
{
    uvs: gpu.slice_t([2]f32),
    seams: gpu.slice_t(Seam)
}

lm_uvs_destroy :: proc(lm_uvs: ^LM_UVs)
{
    gpu.mem_free(lm_uvs.seams)
    lm_uvs^ = {}
}

Seam :: struct
{
    line_a: [2]u32,
    line_b: [2]u32,
}

Scene_GPU :: struct #all_or_none
{
    bvh: gpu.Owned_BVH,
    bvh_id: u32,
    instances_bvh: gpu.slice_t(gpu.BVH_Instance),

    // Shader view
    instances: gpu.slice_t(Instance_Shader),
    meshes_shader: gpu.slice_t(Mesh_Shader),
}

scene_destroy :: proc(scene: ^Scene_GPU)
{
    gpu.bvh_free_and_destroy(&scene.bvh)
    gpu.mem_free(scene.instances_bvh)
    gpu.mem_free(scene.instances)
    gpu.mem_free(scene.meshes_shader)
    scene^ = {}
}

Scene_Shader :: struct
{
    instances: rawptr,
    meshes: rawptr,
    lights: Lights_Shader,
}

Lights_Shader :: struct
{
    dir_light_dir: [3]f32,
    dir_light_angle: f32,
    dir_light_emission: [3]f32,
}

Mesh :: struct
{
    positions: gpu.slice_t([3]f32),
    normals: gpu.slice_t([3]f32),
    uvs: gpu.slice_t([2]f32),
    indices: gpu.slice_t(u32),
    bvh: gpu.Owned_BVH,  // Owned
}

mesh_destroy :: proc(mesh: ^Mesh)
{
    gpu.bvh_free_and_destroy(&mesh.bvh)
    mesh^ = {}
}

Instance_Shader :: struct
{
    mesh_idx: u32,
    albedo_tex_id: u32,
}

Mesh_Shader :: struct
{
    positions: rawptr,
    normals: rawptr,
    uvs: rawptr,
    indices: rawptr,
}

Shaders :: struct
{
    uv_space: gpu.Shader,
    gbuffers: gpu.Shader,
    pathtrace: gpu.Shader,
    smooth_seams_vert: gpu.Shader,
    smooth_seams_frag: gpu.Shader,
    dilate: gpu.Shader,
}

shaders_create :: proc() -> Shaders
{
    res: Shaders
    res.uv_space = gpu.shader_create(#load("shaders/uv_space.vert.spv", []u32), .Vertex)
    res.gbuffers = gpu.shader_create(#load("shaders/gbuffers.frag.spv", []u32), .Fragment)
    res.pathtrace = gpu.shader_create_compute(#load("shaders/pathtrace.comp.spv", []u32), 8, 8, 1)
    res.smooth_seams_vert = gpu.shader_create(#load("shaders/smooth_seams.vert.spv", []u32), .Vertex)
    res.smooth_seams_frag = gpu.shader_create(#load("shaders/smooth_seams.frag.spv", []u32), .Fragment)
    res.dilate = gpu.shader_create_compute(#load("shaders/dilate.comp.spv", []u32), 8, 8, 1)
    return res
}

shaders_destroy :: proc(shaders: ^Shaders)
{
    gpu.shader_destroy(shaders.uv_space)
    gpu.shader_destroy(shaders.gbuffers)
    gpu.shader_destroy(shaders.pathtrace)
    gpu.shader_destroy(shaders.smooth_seams_vert)
    gpu.shader_destroy(shaders.smooth_seams_frag)
    gpu.shader_destroy(shaders.dilate)
    shaders^ = {}
}

GBuffers :: struct
{
    world_pos: gpu.Owned_Texture,
    world_normals: gpu.Owned_Texture,
}

gbufs_create :: proc(#any_int lightmap_size: i64) -> GBuffers
{
    gbufs: GBuffers
    gbufs.world_pos = gpu.texture_alloc_and_create({
        dimensions = { u32(lightmap_size), u32(lightmap_size), 1 },
        format = .RGBA32_Float,
        usage = { .Color_Attachment, .Sampled, .Storage },
    })
    gbufs.world_normals = gpu.texture_alloc_and_create({
        dimensions = { u32(lightmap_size), u32(lightmap_size), 1 },
        format = .RGBA8_Unorm,
        usage = { .Color_Attachment, .Sampled, .Storage }
    })
    return gbufs
}

gbufs_destroy :: proc(gbufs: ^GBuffers)
{
    gpu.texture_free_and_destroy(&gbufs.world_pos)
    gpu.texture_free_and_destroy(&gbufs.world_normals)
    gbufs^ = {}
}

gbufs_render :: proc(cmd_buf: gpu.Command_Buffer, upload_arena: ^gpu.Arena, gbufs: ^GBuffers, shaders: Shaders, instances: []Instance, meshes: []Resource(Mesh), lm_uvs: []Resource(LM_UVs), resolution: [2]f32)
{
    gpu.cmd_scoped_render_pass(cmd_buf, {
        color_attachments = {
            { texture = gbufs.world_pos, clear_color = { 0, 0, 0, 0 } },
            { texture = gbufs.world_normals, clear_color = { 0, 0, 0, 0 } }
        }
    })

    gpu.cmd_set_shaders(cmd_buf, shaders.uv_space, shaders.gbuffers)
    gpu.cmd_set_raster_state(cmd_buf, { cull_mode = .None })

    // Render the entire scene
    for instance in instances
    {
        mesh := meshes[instance.mesh_handle.idx]
        lightmap_uvs := lm_uvs[instance.lm_uvs_handle.idx].info.uvs

        Vertex_Data :: struct #all_or_none {
            pos: rawptr,
            normals: rawptr,
            uvs: rawptr,
            lightmap_uvs: rawptr,
            resolution: [2]f32,
            model_to_world: [16]f32,
            model_to_world_normals: [16]f32,
        }
        vert_data := gpu.arena_alloc(upload_arena, Vertex_Data)
        vert_data.cpu^ = Vertex_Data {
            pos = mesh.info.positions.gpu.ptr,
            normals = mesh.info.normals.gpu.ptr,
            uvs = mesh.info.uvs.gpu.ptr,
            lightmap_uvs = lightmap_uvs.gpu.ptr,
            resolution = resolution,
            model_to_world = intr.matrix_flatten(instance.transform),
            model_to_world_normals = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
        }

        gpu.cmd_draw_indexed(cmd_buf, vert_data, {}, mesh.info.indices, instance_count = 25)
    }
}

Pathtrace_Mode :: enum
{
    Lightmap,
    First_Person,
}

pathtrace :: proc(bake: ^Bake, cmd_buf: gpu.Command_Buffer, frame_arena: ^gpu.Arena, mode: Pathtrace_Mode, camera_to_world: matrix[4, 4]f32, texture_rw_id: u32, resolution: [2]f32, accum_counter: u32, lights: Lights)
{
    Compute_Data :: struct #all_or_none {
        output_texture_id: u32,
        tlas_id: u32,
        linear_sampler: u32,
        scene: Scene_Shader,
        resolution: [2]f32,
        accum_counter: u32,
        is_lightmap: b32,
        camera_to_world: [16]f32,
        gbufs_id: u32,
    }

    sun_solid_angle := 2 * math.PI * (1 - math.cos(lights.sun_radius))

    compute_data := gpu.arena_alloc(frame_arena, Compute_Data)
    compute_data.cpu^ = {
        output_texture_id = texture_rw_id,
        tlas_id = bake.scene_gpu.bvh_id,
        linear_sampler = bake.ctx.linear_sampler_id,
        scene = {
            instances = bake.scene_gpu.instances.gpu.ptr,
            meshes = bake.scene_gpu.meshes_shader.gpu.ptr,
            lights = {
                dir_light_dir   = lights.sun_dir,
                dir_light_angle = lights.sun_radius,
                dir_light_emission = lights.sun_emission / sun_solid_angle,
            }
        },
        accum_counter = accum_counter,
        is_lightmap = mode == .Lightmap,
        resolution = resolution,
        camera_to_world = intr.matrix_flatten(camera_to_world),
        gbufs_id = bake.gbufs_id,
    }

    gpu.cmd_set_compute_shader(cmd_buf, bake.ctx.shaders.pathtrace)
    gpu.cmd_set_desc_pool(cmd_buf, bake.ctx.desc_pool^)

    num_groups_x := (u32(resolution.x) + 8 - 1) / 8
    num_groups_y := (u32(resolution.y) + 8 - 1) / 8
    num_groups_z := u32(1)
    gpu.cmd_dispatch(cmd_buf, compute_data.gpu, num_groups_x, num_groups_y, num_groups_z)

    gpu.cmd_barrier(cmd_buf, .Compute, .Fragment_Shader, {})
    gpu.cmd_barrier(cmd_buf, .Compute, .Compute, {})
}

build_blas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, positions: gpu.slice_t([3]f32), indices: gpu.slice_t(u32), idx_count: u32, vert_count: u32) -> gpu.Owned_BVH
{
    assert(idx_count % 3 == 0)

    desc := gpu.BLAS_Desc {
        hint = .Prefer_Fast_Trace,
        shapes = {
            gpu.BVH_Mesh_Desc {
                vertex_stride = size_of(positions.cpu[0]),
                max_vertex = vert_count - 1,
                tri_count = idx_count / 3,
            }
        }
    }
    bvh := gpu.bvh_alloc_and_create(desc)
    scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
    gpu.cmd_build_blas(cmd_buf, bvh, scratch, { gpu.BVH_Mesh { verts = positions.gpu.ptr, indices = indices.gpu.ptr } })
    return bvh
}

build_tlas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: gpu.gpuptr, instance_count: u32) -> gpu.Owned_BVH
{
    desc := gpu.TLAS_Desc {
        hint = .Prefer_Fast_Trace,
        instance_count = instance_count
    }
    bvh := gpu.bvh_alloc_and_create(desc)
    scratch := gpu.bvh_alloc_build_scratch_buffer(bvh_scratch_arena, desc)
    gpu.cmd_build_tlas(cmd_buf, bvh, scratch, instances)
    return bvh
}

upload_bvh_instances :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, instances: []Instance, meshes: []Resource(Mesh)) -> gpu.slice_t(gpu.BVH_Instance)
{
    instances_staging := gpu.arena_alloc(upload_arena, gpu.BVH_Instance, len(instances))
    for &instance, i in instances_staging.cpu
    {
        instance = {
            transform = transform_to_gpu_transform(instances[i].transform),
            blas_root = gpu.bvh_root_ptr(meshes[instances[i].mesh_handle.idx].info.bvh),
            disable_culling = true,
            flip_facing = true,
            mask = 1,
        }
    }
    instances_local := gpu.mem_alloc(gpu.BVH_Instance, len(instances), mem_type = gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, instances_local, instances_staging)
    return instances_local
}

transform_to_gpu_transform :: proc(transform: matrix[4, 4]f32) -> [12]f32
{
    transform_row_major := intr.transpose(transform)
    flattened := linalg.matrix_flatten(transform_row_major)
    return [12]f32 { flattened[0], flattened[1], flattened[2], flattened[3], flattened[4], flattened[5], flattened[6], flattened[7], flattened[8], flattened[9], flattened[10], flattened[11], }
}

// Seam smoothing

compute_seams :: proc(positions: [][3]f32, normals: [][3]f32, lm_uvs: [][2]f32, indices: []u32) -> [dynamic]Seam
{
    assert(len(positions) == len(normals) && len(normals) == len(lm_uvs))

    // Collect edges
    Edge :: [2]u32
    edges: [dynamic]Edge
    defer delete(edges)

    for i := 0; i < len(indices); i += 3
    {
        append(&edges, Edge { indices[i + 0], indices[i + 1] })
        append(&edges, Edge { indices[i + 1], indices[i + 2] })
        append(&edges, Edge { indices[i + 2], indices[i + 0] })
    }

    // Sort edges (for faster comparisons)
    for &edge in edges
    {
        p0 := positions[edge[0]]
        p1 := positions[edge[1]]
        if p0.x > p1.x || (p0.x == p1.x && p0.y > p1.y) || (p0.x == p1.x && p0.y == p1.y && p0.z > p1.z) {
            edge[0], edge[1] = edge[1], edge[0]
        }
    }

    // Build acceleration structure for nearest neighbor searches
    {
        Collection :: struct
        {
            edges: []Edge,
            positions: [][3]f32,
        }

        collection := Collection { edges[:], positions }

        interface := sort.Interface {
            collection = rawptr(&collection),
            len = proc(it: sort.Interface) -> int {
                c := (^Collection)(it.collection)
                return len(c.edges)
            },
            less = proc(it: sort.Interface, i, j: int) -> bool {
                c := (^Collection)(it.collection)
                return c.positions[c.edges[i][0]].x < c.positions[c.edges[j][0]].x
            },
            swap = proc(it: sort.Interface, i, j: int) {
                c := (^Collection)(it.collection)
                c.edges[i], c.edges[j] = c.edges[j], c.edges[i]
            },
        }

        sort.sort(interface)
    }

    res: [dynamic]Seam
    EPSILON :: 0.00001
    for i in 0..<len(edges)
    {
        pos0_x := min(positions[edges[i][0]].x, positions[edges[i][1]].x)

        for j in i+1..<len(edges)
        {
            pos1_x := min(positions[edges[j][0]].x, positions[edges[j][1]].x)
            if abs(pos1_x - pos0_x) > EPSILON do break

            // Check first vertex
            same_pos := linalg.length(positions[edges[i][0]] - positions[edges[j][0]]) < EPSILON
            if !same_pos do continue
            same_normal := linalg.length(normals[edges[i][0]] - normals[edges[j][0]]) < EPSILON
            if !same_normal do continue
            same_lm_uv := linalg.length(lm_uvs[edges[i][0]] - lm_uvs[edges[j][0]]) < EPSILON
            if same_lm_uv do continue

            // Check second vertex
            same_pos = linalg.length(positions[edges[i][1]] - positions[edges[j][1]]) < EPSILON
            if !same_pos do continue
            same_normal = linalg.length(normals[edges[i][1]] - normals[edges[j][1]]) < EPSILON
            if !same_normal do continue
            same_lm_uv = linalg.length(lm_uvs[edges[i][1]] - lm_uvs[edges[j][1]]) < EPSILON
            if same_lm_uv do continue

            // Edges could be aligned and share a segment even though uv verts are not the same
            if edges_share_segment(lm_uvs, edges[i], edges[j], EPSILON) do continue

            // Found a seam
            append(&res, Seam { edges[i], edges[j] })
        }
    }

    return res

    edges_share_segment :: proc(uvs: [][2]f32, edge0: Edge, edge1: Edge, eps: f32) -> bool
    {
        a := uvs[edge0[0]]
        b := uvs[edge0[1]]
        c := uvs[edge1[0]]
        d := uvs[edge1[1]]

        ab_dir := linalg.normalize(b - a)
        ac_dir := linalg.normalize(c - a)
        ad_dir := linalg.normalize(d - a)

        // Check if aligned
        if abs(linalg.dot(ab_dir, ac_dir) - 1) > eps ||
           abs(linalg.dot(ab_dir, ad_dir) - 1) > eps {
            return false
        }

        // Project verts to ab_dir
        a_p := linalg.dot(ab_dir, a)
        b_p := linalg.dot(ab_dir, b)
        c_p := linalg.dot(ab_dir, c)
        d_p := linalg.dot(ab_dir, d)

        // Sort verts
        if a_p > b_p do a_p, b_p = b_p, a_p
        if c_p > d_p do c_p, d_p = d_p, c_p

        // Check interval overlap
        if c_p > a_p && d_p < b_p do return true
        if a_p > c_p && b_p < d_p do return true
        if c_p > a_p && c_p < b_p do return true
        if d_p > a_p && d_p < b_p do return true

        return false
    }
}

smooth_seams :: proc(bake: ^Bake, cmd_buf: gpu.Command_Buffer, frame_arena: ^gpu.Arena, instances: []Instance, meshes: []Resource(Mesh), lm_uvs: []Resource(LM_UVs), resolution: [2]f32)
{
    textures := [2]gpu.Texture { bake.tmp_tex, bake.lightmap }
    texture_ids := [2]u32 { bake.tmp_tex_id, bake.lightmap_id }

    for smooth_iter in 0..<20
    {
        tex_input  := texture_ids[smooth_iter % 2]
        tex_output := textures[(smooth_iter + 1) % 2]

        for i in 0..<2
        {
            a_to_b := i % 2 == 0

            {
                gpu.cmd_scoped_render_pass(cmd_buf, {
                    color_attachments = {
                        { texture = tex_output, load_op = .Load },
                    }
                })

                gpu.cmd_set_shaders(cmd_buf, bake.ctx.shaders.smooth_seams_vert, bake.ctx.shaders.smooth_seams_frag)
                gpu.cmd_set_blend_state(cmd_buf, {
                    enable = true,
                    color_op = .Add,
                    src_color_factor = .Src_Alpha,
                    dst_color_factor = .One_Minus_Src_Alpha,
                    alpha_op = .Add,
                    src_alpha_factor = .One,
                    dst_alpha_factor = .One_Minus_Src_Alpha,
                    color_write_mask = gpu.Color_Components_All,
                })
                gpu.cmd_set_desc_pool(cmd_buf, bake.ctx.desc_pool^)

                // Render the entire scene
                for instance in instances
                {
                    lightmap_uvs := lm_uvs[instance.lm_uvs_handle.idx].info.uvs
                    seams := lm_uvs[instance.lm_uvs_handle.idx].info.seams

                    Vertex_Data :: struct #all_or_none {
                        lm_uvs: rawptr,
                        seams: rawptr,
                        resolution: [2]f32,
                        a_to_b: b32,
                    }
                    vert_data := gpu.arena_alloc(frame_arena, Vertex_Data)
                    vert_data.cpu^ = Vertex_Data {
                        lm_uvs = lightmap_uvs.gpu.ptr,
                        seams = seams.gpu.ptr,
                        resolution = resolution,
                        a_to_b = b32(a_to_b),
                    }
                    Frag_Data :: struct #all_or_none {
                        tex: u32,
                        sampler: u32,
                    }
                    frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
                    frag_data.cpu^ = Frag_Data {
                        tex = tex_input,
                        sampler = bake.ctx.point_sampler_id,
                    }
                    gpu.cmd_draw(cmd_buf, vert_data, frag_data, u32(gpu.slice_len(seams)) * 6)
                }
            }
        }

        gpu.cmd_barrier(cmd_buf, .Raster_Color_Out, .Fragment_Shader)
    }

    gpu.cmd_barrier(cmd_buf, .All, .All)
}

// Lightmap dilation

dilate :: proc(bake: ^Bake, cmd_buf: gpu.Command_Buffer, frame_arena: ^gpu.Arena, resolution: [2]f32)
{
    gpu.cmd_set_compute_shader(cmd_buf, bake.ctx.shaders.dilate)

    Data :: struct #all_or_none {
        output: u32,
        input: u32,
    }
    data := gpu.arena_alloc(frame_arena, Data)
    data.cpu^ = Data {
        output = bake.lightmap_rw_id,
        input = bake.tmp_tex_rw_id,
    }
    gpu.cmd_set_desc_pool(cmd_buf, bake.ctx.desc_pool^)

    num_groups_x := (u32(resolution.x) + 8 - 1) / 8
    num_groups_y := (u32(resolution.y) + 8 - 1) / 8
    gpu.cmd_dispatch(cmd_buf, data, num_groups_x, num_groups_y, 1)
}

// OIDN interop:

create_oidn_context :: proc() -> oidn.Device
{
    vk_phys_device := gpu.vk_get_physical_device()

    id_props := vk.PhysicalDeviceIDProperties {
        sType = .PHYSICAL_DEVICE_ID_PROPERTIES
    }
    props := vk.PhysicalDeviceProperties2 {
        sType = .PHYSICAL_DEVICE_PROPERTIES_2,
        pNext = &id_props,
    }
    vk.GetPhysicalDeviceProperties2(vk_phys_device, &props)

    device: oidn.Device
    if device == nil && id_props.deviceLUIDValid {
        device = oidn.NewDeviceByLUID(&id_props.deviceLUID[0])
    }
    if device == nil {
        device = oidn.NewDeviceByUUID(&id_props.deviceUUID[0])
    }

    oidn.SetDeviceErrorFunction(device, oidn_error_callback, nil)
    oidn.CommitDevice(device)

    oidn_check(device)

    return device
}

External_Buf :: struct
{
    linux_handle: c.int,
    win_handle: vk.HANDLE,
    buf: vk.Buffer,
    mem: vk.DeviceMemory,
    size: vk.DeviceSize,
}

external_buf_destroy :: proc(buf: ^External_Buf)
{
    vk_device := gpu.vk_get_device()
    vk.DestroyBuffer(vk_device, buf.buf, nil)
    vk.FreeMemory(vk_device, buf.mem, nil)
    buf^ = {}
}

create_vk_external_buffer_for_oidn :: proc(size: u32) -> External_Buf
{
    res: External_Buf
    res.size = vk.DeviceSize(size)

    vk_device := gpu.vk_get_device()
    vk_phys_device := gpu.vk_get_physical_device()

    next: rawptr
    when ODIN_OS == .Windows
    {
        next = &vk.ExternalMemoryBufferCreateInfo {
            sType = .EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
            handleTypes = { .OPAQUE_WIN32 },
        }
    }
    else when ODIN_OS == .Linux
    {
        next = &vk.ExternalMemoryBufferCreateInfo {
            sType = .EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
            handleTypes = { .OPAQUE_FD },
        }
    }
    else do #panic("Unsupported OS.")

    buf_ci := vk.BufferCreateInfo {
        sType = .BUFFER_CREATE_INFO,
        pNext = next,
        size = vk.DeviceSize(size),
        usage = { .TRANSFER_DST, .TRANSFER_SRC, .STORAGE_BUFFER },
        sharingMode = .EXCLUSIVE,
    }
    vk.CreateBuffer(vk_device, &buf_ci, nil, &res.buf)

    mem_reqs: vk.MemoryRequirements
    vk.GetBufferMemoryRequirements(vk_device, res.buf, &mem_reqs)

    next = nil
    when ODIN_OS == .Windows
    {
        next = &vk.ExportMemoryAllocateInfo {
            sType = .EXPORT_MEMORY_ALLOCATE_INFO,
            pNext = next,
            handleTypes = { .OPAQUE_WIN32 },
        }
    }
    else when ODIN_OS == .Linux
    {
        next = &vk.ExportMemoryAllocateInfo {
            sType = .EXPORT_MEMORY_ALLOCATE_INFO,
            pNext = next,
            handleTypes = { .OPAQUE_FD },
        }
    }
    else do #panic("Unsupported OS.")

    allocInfo := vk.MemoryAllocateInfo {
        sType = .MEMORY_ALLOCATE_INFO,
        pNext = next,
        allocationSize = mem_reqs.size,
        memoryTypeIndex = vk_find_mem_type(vk_phys_device, mem_reqs.memoryTypeBits, { .DEVICE_LOCAL }),
    }
    vk.AllocateMemory(vk_device, &allocInfo, nil, &res.mem);

    vk.BindBufferMemory(vk_device, res.buf, res.mem, 0)

    when ODIN_OS == .Windows
    {
        get_fd_info := vk.MemoryGetWin32HandleInfoKHR {
            sType = .MEMORY_GET_WIN32_HANDLE_INFO_KHR,
            memory = res.mem,
            handleType = { .OPAQUE_WIN32 },
        }
        vk_check(vk.GetMemoryWin32HandleKHR(vk_device, &get_fd_info, &res.win_handle))
    }
    else when ODIN_OS == .Linux
    {
        get_fd_info := vk.MemoryGetFdInfoKHR {
            sType = .GET_FD_INFO_KHR,
            memory = res.buf.mem,
            handleType = { .OPAQUE_FD },
        }
        vk_check(vk.GetMemoryFdKHR(device, &get_fd_info, &res.linux_handle))
    }
    else do #panic("Unsupported OS.")

    return res
}

vk_find_mem_type :: proc(phys_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32
{
    mem_properties: vk.PhysicalDeviceMemoryProperties
    vk.GetPhysicalDeviceMemoryProperties(phys_device, &mem_properties)
    for i in 0..<mem_properties.memoryTypeCount
    {
        if (type_filter & (1 << i) != 0) &&
           (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
            return i
        }
    }

    panic("Vulkan Error: Could not find suitable memory type!")
}

vk_check :: proc(result: vk.Result, location := #caller_location)
{
    if result != .SUCCESS {
        fatal_error("Vulkan failure: %", result, location = location)
    }
}

fatal_error :: proc(fmt: string, args: ..any, location := #caller_location)
{
    when ODIN_DEBUG {
        log.fatal(fmt, args, location = location)
        runtime.panic("")
    } else {
        log.panicf(fmt, args, location = location)
    }
}

oidn_shared_buffer_from_vk_buffer :: proc(device: oidn.Device, buf: External_Buf) -> oidn.Buffer
{
    when ODIN_OS == .Windows
    {
        return oidn.NewSharedBufferFromWin32Handle(device, { .OPAQUE_WIN32 }, buf.win_handle, nil, c.size_t(buf.size))
    }
    else when ODIN_OS == .Linux
    {
        return oidn.NewSharedBufferFromFD(device, { .OPAQUE_FD }, buf.linux_handle, buf.buf.size)
    }
    else do #panic("Unsupported OS.")
}

oidn_run_lightmap_filter :: proc(device: oidn.Device, filter: oidn.Filter)
{
    oidn.ExecuteFilter(filter)
    oidn.SyncDevice(device)
    oidn_check(device)
}

oidn_check :: proc(device: oidn.Device)
{
    msg: cstring
    if oidn.GetDeviceError(device, &msg) != .NONE
    {
        log.error(msg)
        panic("")
    }
}

oidn_error_callback :: proc "c"(user_ptr: rawptr, code: oidn.Error, message: cstring)
{
    context = runtime.default_context()
    log.error(message)
}

oidn_copy_to_shared_buf :: proc(cmd_buf: gpu.Command_Buffer, dst: External_Buf, src: gpu.Texture)
{
    vk_image := gpu.vk_get_image(src)
    vk_cmd_buf := gpu.vk_get_command_buffer(cmd_buf)

    vk.CmdCopyImageToBuffer2(vk_cmd_buf, &vk.CopyImageToBufferInfo2 {
        sType = .COPY_IMAGE_TO_BUFFER_INFO_2,
        pNext = nil,
        srcImage = vk_image,
        srcImageLayout = .GENERAL,
        dstBuffer = dst.buf,
        regionCount = 1,
        pRegions = &vk.BufferImageCopy2 {
            sType = .BUFFER_IMAGE_COPY_2,
            bufferRowLength = 0,
            bufferImageHeight = 0,
            imageSubresource = vk.ImageSubresourceLayers {
                aspectMask = { .COLOR },
                layerCount = 1,
            },
            imageExtent = vk.Extent3D {
                width = src.dimensions.x,
                height = src.dimensions.y,
                depth = 1,
            },
        },
    })
}

oidn_copy_from_shared_buf :: proc(cmd_buf: gpu.Command_Buffer, dst: gpu.Texture, src: External_Buf)
{
    vk_image := gpu.vk_get_image(dst)
    vk_cmd_buf := gpu.vk_get_command_buffer(cmd_buf)

    vk.CmdCopyBufferToImage2(vk_cmd_buf, &vk.CopyBufferToImageInfo2 {
        sType = .COPY_BUFFER_TO_IMAGE_INFO_2,
        pNext = nil,
        srcBuffer = src.buf,
        dstImage = vk_image,
        dstImageLayout = .GENERAL,
        regionCount = 1,
        pRegions = &vk.BufferImageCopy2 {
            sType = .BUFFER_IMAGE_COPY_2,
            bufferRowLength = 0,
            bufferImageHeight = 0,
            imageSubresource = vk.ImageSubresourceLayers {
                aspectMask = { .COLOR },
                layerCount = 1,
            },
            imageExtent = vk.Extent3D {
                width = dst.dimensions.x,
                height = dst.dimensions.y,
                depth = 1,
            },
        },
    })
}

oidn_create_lightmap_filter :: proc(oidn_device: oidn.Device, color: oidn.Buffer, output: oidn.Buffer, lightmap_size: u32, quality: oidn.Quality) -> oidn.Filter  // TODO: support different sizes in x and y
{
    filter := oidn.NewFilter(oidn_device, "RTLightmap")
    // TODO: Different formats?
    oidn.SetFilterImage(filter, "color", color, .HALF3, auto_cast lightmap_size, auto_cast lightmap_size, pixelByteStride = 2 * 4)
    oidn.SetFilterImage(filter, "output", output, .HALF3, auto_cast lightmap_size, auto_cast lightmap_size, pixelByteStride = 2 * 4)
    oidn.SetFilterInt(filter, "quality", i32(quality))
    oidn.CommitFilter(filter)
    oidn_check(oidn_device)
    return filter
}

// Pool data type
// Implementation of a thread-safe resource pool to be used for resource handles
Resource_Pool :: struct($Handle_T: typeid, $Info_T: typeid) where size_of(Handle_T) == 8
{
    arena: vmem.Arena,  // Makes pointers to elements stable.
    resources: [dynamic]Resource(Info_T),  // Uses 'arena'. Allocation is never moved so no need to lock on read.
    freelist: [dynamic]u32,
    lock: sync.Atomic_Mutex,
    init: bool,
}

Resource :: struct($T: typeid)
{
    info: T,
    alive: bool,
    gen: u32,
}

Resource_Key :: struct
{
    idx: u32,
    gen: u32,
}

pool_init :: proc(pool: ^Resource_Pool($Handle_T, $Info_T))
{
    pool.init = true

    err := vmem.arena_init_static(&pool.arena, mem.Gigabyte)
    ensure(err == nil)
    pool.resources = make([dynamic]Resource(Info_T), allocator = vmem.arena_allocator(&pool.arena))

    // Reserve element 0 for the nil handle.
    pool_add(pool, Info_T {})
}

pool_get_alive_list :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), arena: runtime.Allocator) -> []Resource(Info_T)
{
    res := make([dynamic]Resource(Info_T), allocator = arena)
    for i in 1..<len(pool.resources)
    {
        el := intr.volatile_load(&pool.resources[i])
        if el.alive do append(&res, el)
    }

    return res[:]
}

pool_get :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T) -> Info_T
{
    assert(pool.init)
    assert(handle != {})
    key := transmute(Resource_Key) handle

    el := intr.volatile_load(&pool.resources[key.idx])
    assert(key.gen == el.gen)
    return el.info
}

pool_add :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), info: Info_T) -> Handle_T
{
    assert(pool.init)
    sync.guard(&pool.lock)

    free_idx: u32
    if len(pool.freelist) > 0 {
        free_idx = pop(&pool.freelist)
    } else {
        append(&pool.resources, Resource(Info_T) {})
        free_idx = u32(len(pool.resources)) - 1
    }

    pool.resources[free_idx].info = info
    gen := pool.resources[free_idx].gen
    pool.resources[free_idx].alive = true

    key := Resource_Key { idx = free_idx, gen = gen }
    return transmute(Handle_T) key
}

pool_remove :: proc(pool: ^Resource_Pool($Handle_T, $Info_T), handle: Handle_T)
{
    assert(pool.init)
    assert(handle != {})
    sync.guard(&pool.lock)

    key := transmute(Resource_Key) handle

    el := &pool.resources[key.idx]
    el.alive = false
    assert(key.gen == el.gen)

    el.gen += 1
    append(&pool.freelist, key.idx)
}

pool_destroy :: proc(pool: ^Resource_Pool($Handle_T, $Info_T))
{
    assert(pool.init)
    sync.guard(&pool.lock)

    delete(pool.resources)
    delete(pool.freelist)
    vmem.arena_destroy(&pool.arena)

    pool.resources = {}
    pool.freelist = nil
    pool.init = false
}
