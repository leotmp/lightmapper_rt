

#+vet !unused-variables
#+vet !unused-imports

package main

import intr "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:image"
import "core:image/png"
import "core:image/jpeg"
import log "core:log"
import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:thread"
import "core:sys/info"
import "core:os"

import sdl "vendor:sdl3"

import shared "../shared"
import gltf2 "../shared/gltf2"

import vk "vendor:vulkan"
import "../../no_gfx_api/gpu"

import lm "../../"

Frames_In_Flight :: 3
Example_Name_Format :: "Right-click + WASD for first-person controls. Left click to toggle texture type. Current: %v"

// How many textures to load in a single batch / command buffer
Loader_Chunk_Size :: 16

// Index used for the color target texture
COLOR_TARGET_IDX: u32 = 0
POSTPROCESS_TARGET_IDX: u32 = 0
POSTPROCESS_TARGET_RW_IDX: u32 = 0

LM_TARGET_SIZE :: 4096

// Textures can be loaded/unloaded on different threads, so we need to synchronize access to loaded_textures, image_to_texture and image_uploaded
mutex: sync.Mutex
// Every texture from loaded_textures array needs to be freed when we are done
loaded_textures: [dynamic]gpu.Owned_Texture
// Enables asynchronous cancellation of texture loading
cancel_loading_textures: bool
// Cache for image_index -> texture mapping, reused across texture loading chunks
image_to_texture: map[int]struct {
    texture:     gpu.Owned_Texture,
    texture_idx: u32,
}
image_uploaded: map[int]^sync.One_Shot_Event

upload_sem: gpu.Semaphore
upload_sem_val: u64

main :: proc()
{
    shared.CAM_POS = { -7.581631, 1.1906259, 0.25928685 }
	shared.CAM_ANGLE = { 1.570796, 0.3665192 }

    cmd_args := os.args
    glb_path := "assets/Sponza.glb"
    if len(cmd_args) > 1 {
        glb_path = cmd_args[1]
    }

    ok_i := sdl.Init({.VIDEO})
    assert(ok_i)

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0 // 10fps

    window_flags :: sdl.WindowFlags { .HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE, .MAXIMIZED }
    window := sdl.CreateWindow("lightmapper_rt SIMPLE", 1000, 1000, window_flags)
    ensure(window != nil)

    window_size_x: i32
    window_size_y: i32
    sdl.GetWindowSize(window, &window_size_x, &window_size_y)

    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_EXTENSION_NAME)
    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME)
    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)
    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME)
    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME)
    gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)
    ok := gpu.init()
    ensure(ok)
    defer gpu.cleanup()

    gpu.swapchain_create_from_sdl(window, Frames_In_Flight)

    vert_shader_lit := gpu.shader_create(#load("../demo/shaders/lit.vert.spv", []u32), .Vertex)
    frag_shader_lit := gpu.shader_create(#load("../demo/shaders/lit.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_lit)
        gpu.shader_destroy(frag_shader_lit)
    }

    vert_shader_uv_debug_viz := gpu.shader_create(#load("../demo/shaders/uv_debug_viz.vert.spv", []u32), .Vertex)
    frag_shader_uv_debug_viz := gpu.shader_create(#load("../demo/shaders/uv_debug_viz.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_uv_debug_viz)
        gpu.shader_destroy(frag_shader_uv_debug_viz)
    }

    vert_shader_tonemap := gpu.shader_create(#load("../demo/shaders/tonemap.vert.spv", []u32), .Vertex)
    frag_shader_tonemap := gpu.shader_create(#load("../demo/shaders/tonemap.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_tonemap)
        gpu.shader_destroy(frag_shader_tonemap)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    upload_sem = gpu.semaphore_create()
    defer gpu.semaphore_destroy(upload_sem)

    upload_cmd_buf := gpu.commands_begin(.Main)

    fsq_verts, fsq_indices := create_fullscreen_quad(
        &upload_arena,
        upload_cmd_buf,
    )
    defer {
        gpu.mem_free(fsq_verts)
        gpu.mem_free(fsq_indices)
    }

    desc_pool := gpu.desc_pool_create()
    defer gpu.desc_pool_destroy(&desc_pool)

    magenta_texture := create_magenta_texture(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&magenta_texture)
    magenta_texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(magenta_texture, {}))

    white_texture := create_white_texture(&upload_arena, upload_cmd_buf)
    defer gpu.texture_free_and_destroy(&white_texture)
    white_texture_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(white_texture, {}))

    glb_contents, err_r := os.read_entire_file_from_path(glb_path, allocator = context.allocator)
    ensure(err_r == nil)
    defer delete(glb_contents)

    gltf_scene, texture_infos, gltf_data, lm_size := shared.load_scene_gltf(glb_contents, magenta_texture_id, white_texture_id, false, LM_TARGET_SIZE, &desc_pool)
    defer {
        shared.destroy_scene(&gltf_scene)
        gltf2.unload(gltf_data)
    }
    defer {
        // Clean up loaded textures
        sync.guard(&mutex)
        for &tex in loaded_textures {
            gpu.texture_free_and_destroy(&tex)
        }
    }

    // Spawn and wait for loading threads
    {
        worker_threads: [dynamic]^thread.Thread
        /*
        defer {
            cancel_loading_textures = true
            for t in worker_threads {
                thread.terminate(t, 0)
            }
        }
        */

        Texture_Loader_Data :: struct {
            texture_infos: []shared.Gltf_Texture_Info,
            gltf_data:     ^gltf2.Data,
            scene:         ^shared.Scene,
            desc_pool:     ^gpu.Descriptor_Pool,
            logger:        log.Logger,
            current_chunk: ^int,
        }
        loader_data := Texture_Loader_Data {
            texture_infos = texture_infos,
            gltf_data     = gltf_data,
            scene         = &gltf_scene,
            desc_pool     = &desc_pool,
            logger        = console_logger,
            current_chunk = new(int),
        }

        texture_loader_thread_proc :: proc(thread: ^thread.Thread) {
            data := cast(^Texture_Loader_Data)thread.data
            context.logger = data.logger

            for !cancel_loading_textures {
                current_chunk_start := sync.atomic_add(data.current_chunk, Loader_Chunk_Size)
                current_chunk_end := min(current_chunk_start + Loader_Chunk_Size, len(data.texture_infos))

                if current_chunk_start >= len(data.texture_infos) {
                    break
                }

                log.debugf("Creating texture loader for chunk %v of %v", current_chunk_start, len(data.texture_infos))

                load_scene_textures_from_gltf(
                    data.texture_infos[current_chunk_start:current_chunk_end],
                    data.gltf_data,
                    data.scene,
                    data.desc_pool,
                )
            }
        }

        _, num_async_worker_threads, ok_cpu := info.cpu_core_count()
        ensure(ok_cpu)
        for i := 0; i < num_async_worker_threads; i += 1 {
            texture_loader_thread := thread.create(texture_loader_thread_proc)
            texture_loader_thread.data = &loader_data
            thread.start(texture_loader_thread)
            append(&worker_threads, texture_loader_thread)
        }

        for worker_thread in worker_threads {
            thread.join(worker_thread)
        }
    }

    lm_ctx: lm.Context
    lm.init(&lm_ctx, &desc_pool)
    defer lm.cleanup(&lm_ctx)

    scene := upload_scene(gltf_scene, &lm_ctx, &upload_arena, upload_cmd_buf, false)
    defer scene_destroy(&scene)

    anisotropy := min(16.0, gpu.device_limits().max_anisotropy)
    sampler_linear_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({ max_anisotropy = anisotropy }))
    // Lightmap samplers
    lm_sampler_linear_id  := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))

    color_target, postprocess_target, depth_target := create_target_textures(u32(window_size_x), u32(window_size_y), &desc_pool)
    defer {
        gpu.texture_free_and_destroy(&color_target)
        gpu.texture_free_and_destroy(&postprocess_target)
        gpu.texture_free_and_destroy(&depth_target)
    }

    gpu.cmd_barrier(upload_cmd_buf, .Transfer, .All)
    gpu.queue_submit(.Main, {upload_cmd_buf})

    lightmap := gpu.texture_alloc_and_create({
        format = .RGBA16_Float,
        dimensions = { u32(lm_size.x), u32(lm_size.y), 1 },
        usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
    })
    defer gpu.texture_free_and_destroy(&lightmap)

    settings := make_settings_default()

    lm_instances := make([]lm.Instance, len(gltf_scene.instances), allocator = context.temp_allocator)
    for &lm_instance, i in lm_instances
    {
        instance := gltf_scene.instances[i]
        mesh := scene.meshes[gltf_scene.instances[i].mesh_idx]
        gltf_mesh := gltf_scene.meshes[gltf_scene.instances[i].mesh_idx]
        lm_instance = lm.Instance {
            mesh_handle = mesh.lm_mesh_handle,
            lm_uvs_handle = mesh.lm_uv_handle,
            transform = instance.transform,
            lm_uvs_offset = 0,
            lm_uvs_scale = { 1.0, 1.0 },

            lm_chart_base = instance.lm_chart_base,

            albedo_tex_id = gltf_mesh.base_color_map,
            albedo = { 1.0, 1.0, 1.0 },
        }
    }
    lm_charts := make([]lm.Chart, len(gltf_scene.lm_charts), allocator = context.temp_allocator)
    for &lm_chart, i in lm_charts
    {
        chart := gltf_scene.lm_charts[i]
        lm_chart = lm.Chart {
            x = chart.x,
            y = chart.y,
            offset = chart.offset,
        }
    }
    bake := lm.bake_begin(&lm_ctx, lm_size, 3000, lightmap, lm_instances, lm_charts, settings.lights)
    defer lm.bake_destroy(&bake)

    lightmap_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(lightmap, {}))

    now_ts := sdl.GetPerformanceCounter()

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    for true
    {
        proceed := shared.handle_window_events(window)
        if !proceed do break

        old_window_size_x := window_size_x
        old_window_size_y := window_size_y
        sdl.GetWindowSize(window, &window_size_x, &window_size_y)
        if .MINIMIZED in sdl.GetWindowFlags(window) || window_size_x <= 0 || window_size_y <= 0
        {
            sdl.Delay(16)
            continue
        }

        if next_frame > Frames_In_Flight {
            gpu.semaphore_wait(frame_sem, next_frame - Frames_In_Flight)
        }
        if old_window_size_x != window_size_x || old_window_size_y != window_size_y
        {
            gpu.queue_wait_idle(.Main)
            gpu.swapchain_resize({u32(window_size_x), u32(window_size_y)})

            gpu.texture_free_and_destroy(&color_target)
            gpu.texture_free_and_destroy(&postprocess_target)
            gpu.texture_free_and_destroy(&depth_target)
            color_target, postprocess_target, depth_target = create_target_textures(u32(window_size_x), u32(window_size_y), &desc_pool)
        }

        swapchain := gpu.swapchain_acquire_next() // Blocks CPU until at least one frame is available.
        if swapchain == {} {
            gpu.swapchain_resize({u32(window_size_x), u32(window_size_y)})
            continue
        }

        last_ts := now_ts
        now_ts = sdl.GetPerformanceCounter()
        delta_time := min(max_delta_time, f32(f64((now_ts - last_ts) * 1000) / f64(ts_freq)) / 1000.0)

        world_to_view := shared.first_person_camera_view(delta_time)
        aspect_ratio := f32(window_size_x) / f32(window_size_y)
        view_to_proj := linalg.matrix4_perspective_f32(math.RAD_PER_DEG * 59.0, aspect_ratio, 0.1, 1000.0, false)

        frame_arena := &frame_arenas[next_frame % Frames_In_Flight]
        gpu.arena_free_all(frame_arena)

        cmd_buf := gpu.commands_begin(.Main)

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

        lm_instances := make([]lm.Instance, len(gltf_scene.instances), allocator = context.temp_allocator)
        for &lm_instance, i in lm_instances
        {
            instance := gltf_scene.instances[i]
            mesh := scene.meshes[gltf_scene.instances[i].mesh_idx]
            gltf_mesh := gltf_scene.meshes[gltf_scene.instances[i].mesh_idx]
            lm_instance = lm.Instance {
                mesh_handle = mesh.lm_mesh_handle,
                lm_uvs_handle = mesh.lm_uv_handle,
                transform = instance.transform,
                lm_uvs_offset = 0,
                lm_uvs_scale = { 1.0, 1.0 },
                albedo_tex_id = gltf_mesh.base_color_map,
                albedo = { 1.0, 1.0, 1.0 },
            }
            lm_charts := make([]lm.Chart, len(gltf_scene.lm_charts), allocator = context.temp_allocator)
            for &lm_chart, i in lm_charts
            {
                chart := gltf_scene.lm_charts[i]
                lm_chart = lm.Chart {
                    x = chart.x,
                    y = chart.y,
                    offset = chart.offset,
                }
            }
        }
        lm.bake_iteration(&bake, frame_arena, lm_instances, settings.lights, settings.fix_seams, settings.denoise)

        // Main pass
        {
            gpu.cmd_begin_render_pass(cmd_buf, {
                color_attachments = {
                    {
                        texture = color_target,
                        resolve_texture = postprocess_target,
                        clear_color = {0.67, 0.76, 1.00, 1.0},
                        store_op = .Resolve_And_Store
                    },
                },
                depth_attachment = gpu.Render_Attachment { texture = depth_target, clear_color = 1.0 },
            })
            gpu.cmd_set_shaders(cmd_buf, vert_shader_lit, frag_shader_lit)

            gpu.cmd_set_raster_state(cmd_buf, { alpha_to_coverage = true })

            // Set texture and sampler heaps
            gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

            gpu.cmd_set_depth_state(cmd_buf, {mode = {.Read, .Write}, compare = .Less})

            for instance, instance_idx in gltf_scene.instances
            {
                mesh_idx := instance.mesh_idx
                mesh := scene.meshes[mesh_idx]
                base_color_map := gltf_scene.meshes[instance.mesh_idx].base_color_map

                Vert_Data :: struct #all_or_none {
                    positions:             rawptr,
                    normals:               rawptr,
                    uvs:                   rawptr,
                    lm_uvs:                rawptr,
                    lm_chart_indices:      rawptr,

                    lm_charts:             rawptr,
                    lm_chart_base:         u32,

                    model_to_world:        [16]f32,
                    model_to_world_normal: [16]f32,
                    world_to_view:         [16]f32,
                    view_to_proj:          [16]f32,

                    skip_lightmap:         b32,
                }
                verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
                verts_data.cpu^ = {
                    positions             = mesh.pos.gpu.ptr,
                    normals               = mesh.normals.gpu.ptr,
                    uvs                   = mesh.uvs.gpu.ptr,
                    lm_uvs                = mesh.lm_uvs.gpu.ptr,
                    lm_chart_indices      = mesh.lm_chart_indices.gpu.ptr,

                    lm_charts             = scene.lm_charts.gpu.ptr,
                    lm_chart_base         = instance.lm_chart_base,

                    model_to_world        = intr.matrix_flatten(instance.transform),
                    model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                    world_to_view         = intr.matrix_flatten(world_to_view),
                    view_to_proj          = intr.matrix_flatten(view_to_proj),

                    skip_lightmap         = false,
                }

                Frag_Data :: struct #all_or_none {
                    base_color_map:                 u32,
                    base_color_map_sampler:         u32,
                    base_color: [4]f32,

                    lightmap: u32,
                    lightmap_sampler: u32,
                    do_bicubic_sampling: b32,
                    sample_lightmap: b32,
                    sample_diffuse: b32,
                }
                frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
                frag_data.cpu^ = {
                    base_color_map                 = base_color_map,
                    base_color_map_sampler         = sampler_linear_id,
                    base_color = instance.base_color,

                    lightmap = lightmap_id,
                    lightmap_sampler = lm_sampler_linear_id,
                    do_bicubic_sampling = true,
                    sample_lightmap = true,
                    sample_diffuse = true,
                }

                gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, frag_data.gpu, mesh.indices)
            }

            gpu.cmd_end_render_pass(cmd_buf)
            gpu.cmd_barrier(cmd_buf, .Raster_Color_Out, .Fragment_Shader, {})
        }

        // Tonemap
        {
            gpu.cmd_begin_render_pass(
                cmd_buf,
                {color_attachments = {{texture = swapchain, clear_color = {0.7, 0.7, 0.7, 1.0}}}},
            )
            gpu.cmd_set_shaders(cmd_buf, vert_shader_tonemap, frag_shader_tonemap)

            // Set texture and sampler heaps
            gpu.cmd_set_desc_heap(cmd_buf, desc_pool)

            // Disable depth testing for fullscreen quad
            gpu.cmd_set_depth_state(cmd_buf, { mode = {}, compare = .Always })

            // Vertex data for fullscreen quad
            Vert_Data :: struct #all_or_none {
                verts: rawptr,
            }
            verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
            verts_data.cpu.verts = fsq_verts.gpu.ptr

            // Fragment data with all G-buffer textures and selected texture type
            Frag_Data :: struct #all_or_none {
                texture_id: u32,
                sampler_id: u32,
                exposure: f32,
            }
            frag_data := gpu.arena_alloc(frame_arena, Frag_Data)
            frag_data.cpu^ = {
                texture_id = POSTPROCESS_TARGET_IDX,
                sampler_id = sampler_linear_id,
                exposure = settings.exposure,
            }

            // Render fullscreen quad
            gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, frag_data.gpu, fsq_indices)
            gpu.cmd_end_render_pass(cmd_buf)
        }

        gpu.cmd_add_signal_semaphore(cmd_buf, frame_sem, next_frame)
        gpu.queue_submit(.Main, {cmd_buf})

        gpu.swapchain_present(.Main, frame_sem, next_frame)
        next_frame += 1

        free_all(context.temp_allocator)
    }

    gpu.wait_idle()
}

Mesh_GPU :: struct
{
    pos: gpu.slice_t([3]f32),
    normals: gpu.slice_t([3]f32),
    uvs: gpu.slice_t([2]f32),
    lm_uvs: gpu.slice_t([2]f32),
    lm_chart_indices: gpu.slice_t(i32),
    indices: gpu.slice_t(u32),
    idx_count: u32,
    vert_count: u32,
    lm_mesh_handle: lm.Mesh_Handle,
    lm_uv_handle: lm.Lightmap_UV_Handle,
}

upload_mesh :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, mesh: shared.Mesh) -> Mesh_GPU
{
    assert(len(mesh.pos) == len(mesh.normals))
    assert(len(mesh.pos) == len(mesh.uvs))

    positions_staging := gpu.arena_alloc(upload_arena, [3]f32, len(mesh.pos))
    normals_staging := gpu.arena_alloc(upload_arena, [3]f32, len(mesh.normals))
    uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.uvs))
    lm_uvs_staging := gpu.arena_alloc(upload_arena, [2]f32, len(mesh.lm_uvs))
    chart_indices_staging := gpu.arena_alloc(upload_arena, i32, len(mesh.lm_chart_indices))
    indices_staging := gpu.arena_alloc(upload_arena, u32, len(mesh.indices))
    copy(positions_staging.cpu, mesh.pos[:])
    copy(normals_staging.cpu, mesh.normals[:])
    copy(uvs_staging.cpu, mesh.uvs[:])
    copy(lm_uvs_staging.cpu, mesh.lm_uvs[:])
    copy(chart_indices_staging.cpu, mesh.lm_chart_indices[:])
    copy(indices_staging.cpu, mesh.indices[:])

    res: Mesh_GPU
    res.pos = gpu.mem_alloc([3]f32, len(mesh.pos), mem_type = gpu.Memory.GPU)
    res.normals = gpu.mem_alloc([3]f32, len(mesh.normals), mem_type = gpu.Memory.GPU)
    res.uvs = gpu.mem_alloc([2]f32, len(mesh.uvs), mem_type = gpu.Memory.GPU)
    res.lm_uvs = gpu.mem_alloc([2]f32, len(mesh.lm_uvs), mem_type = gpu.Memory.GPU)
    res.lm_chart_indices = gpu.mem_alloc(i32, len(mesh.lm_chart_indices), mem_type = gpu.Memory.GPU)
    res.indices = gpu.mem_alloc(u32, len(mesh.indices), mem_type = gpu.Memory.GPU)
    gpu.cmd_mem_copy(cmd_buf, res.pos, positions_staging)
    gpu.cmd_mem_copy(cmd_buf, res.normals, normals_staging)
    gpu.cmd_mem_copy(cmd_buf, res.uvs, uvs_staging)
    gpu.cmd_mem_copy(cmd_buf, res.lm_uvs, lm_uvs_staging)
    gpu.cmd_mem_copy(cmd_buf, res.lm_chart_indices, chart_indices_staging)
    gpu.cmd_mem_copy(cmd_buf, res.indices, indices_staging)

    res.idx_count = u32(len(mesh.indices))
    res.vert_count = u32(len(mesh.pos))
    return res
}

mesh_destroy :: proc(mesh: ^Mesh_GPU)
{
    gpu.mem_free(mesh.pos)
    gpu.mem_free(mesh.normals)
    gpu.mem_free(mesh.uvs)
    gpu.mem_free(mesh.lm_uvs)
    gpu.mem_free(mesh.lm_chart_indices)
    gpu.mem_free(mesh.indices)
    mesh^ = {}
}

Scene_GPU :: struct
{
    meshes: [dynamic]Mesh_GPU,
    lm_charts: gpu.slice_t(shared.Lightmap_Chart),
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

upload_scene :: proc(scene: shared.Scene, lm_ctx: ^lm.Context, upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, skip_lightmap: bool) -> Scene_GPU
{
    res: Scene_GPU

    // Upload meshes
    for mesh in scene.meshes
    {
        to_add := upload_mesh(upload_arena, cmd_buf, mesh)
        append(&res.meshes, to_add)
    }

    // Upload lm chart infos
    {
        staging := gpu.arena_alloc(upload_arena, shared.Lightmap_Chart, len(scene.lm_charts))
        copy(staging.cpu, scene.lm_charts[:])

        res.lm_charts = gpu.mem_alloc(shared.Lightmap_Chart, len(scene.lm_charts), mem_type = gpu.Memory.GPU)
        gpu.cmd_mem_copy(cmd_buf, res.lm_charts, staging)
    }

    gpu.cmd_barrier(cmd_buf, .Transfer, .All)

    if !skip_lightmap
    {
        for &mesh, i in res.meshes
        {
            mesh_cpu := scene.meshes[i]
            mesh_lm_uvs := mesh_cpu.lm_uvs

            mesh.lm_mesh_handle = lm.add_mesh(lm_ctx, cmd_buf, lm.Mesh_Desc {
                positions_gpu = mesh.pos,
                normals_gpu = mesh.normals,
                uvs_gpu = mesh.uvs,
                indices_gpu = mesh.indices,
                lm_chart_indices = mesh.lm_chart_indices,
            })

            mesh.lm_uv_handle = lm.add_lightmap_uvs(lm_ctx, cmd_buf, lm.Lightmap_UVs_Desc {
                positions_cpu = mesh_cpu.pos[:],
                normals_cpu = mesh_cpu.normals[:],
                lm_uvs_cpu = mesh_cpu.lm_uvs[:],
                indices_cpu = mesh_cpu.indices[:],

                lm_uvs_gpu = mesh.lm_uvs,
            })
        }
    }

    return res
}

scene_destroy :: proc(scene: ^Scene_GPU)
{
    for &mesh in scene.meshes {
        mesh_destroy(&mesh)
    }
    delete(scene.meshes)

    gpu.mem_free(scene.lm_charts)

    scene^ = {}
}

create_target_textures :: proc(window_size_x: u32, window_size_y: u32, desc_pool: ^gpu.Descriptor_Pool) -> (color_target: gpu.Owned_Texture, postprocess_target: gpu.Owned_Texture, depth_target: gpu.Owned_Texture)
{
    // Color
    {
        color_target = gpu.texture_alloc_and_create(gpu.Texture_Desc {
            dimensions   = { u32(window_size_x), u32(window_size_y), 1 },
            format       = .RGBA16_Float,
            mip_count    = 1,
            layer_count  = 1,
            sample_count = 4,
            usage        = { .Color_Attachment, .Sampled },
        })
        COLOR_TARGET_IDX = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(color_target, {}))

        postprocess_target = gpu.texture_alloc_and_create(gpu.Texture_Desc {
            dimensions   = { u32(window_size_x), u32(window_size_y), 1 },
            format       = .RGBA16_Float,
            mip_count    = 1,
            layer_count  = 1,
            sample_count = 1,
            usage        = { .Color_Attachment, .Sampled, .Storage },
        })
        POSTPROCESS_TARGET_IDX = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(postprocess_target, {}))
        POSTPROCESS_TARGET_RW_IDX = gpu.desc_pool_alloc_texture_rw(desc_pool, gpu.texture_rw_view_descriptor(postprocess_target, {}))
    }

    // Depth
    {
        depth_target = gpu.texture_alloc_and_create(gpu.Texture_Desc {
            dimensions   = { u32(window_size_x), u32(window_size_y), 1 },
            format       = .D32_Float,
            mip_count    = 1,
            layer_count  = 1,
            sample_count = 4,
            usage        = { .Depth_Stencil_Attachment },
        })
    }

    return
}

Fullscreen_Vertex :: struct {
    pos: [3]f32,
    uv:  [2]f32,
}

create_fullscreen_quad :: proc(
    upload_arena: ^gpu.Arena,
    cmd_buf: gpu.Command_Buffer,
) -> (
    gpu.slice_t(Fullscreen_Vertex),
    gpu.slice_t(u32),
) {
    fsq_verts := gpu.arena_alloc(upload_arena, Fullscreen_Vertex, 4)
    fsq_verts.cpu[0].pos = {-1.0, 1.0, 0.0} // Top-left
    fsq_verts.cpu[1].pos = {1.0, -1.0, 0.0} // Bottom-right
    fsq_verts.cpu[2].pos = {1.0, 1.0, 0.0} // Top-right
    fsq_verts.cpu[3].pos = {-1.0, -1.0, 0.0} // Bottom-left
    fsq_verts.cpu[0].uv = {0.0, 1.0}
    fsq_verts.cpu[1].uv = {1.0, 0.0}
    fsq_verts.cpu[2].uv = {1.0, 1.0}
    fsq_verts.cpu[3].uv = {0.0, 0.0}

    fsq_indices := gpu.arena_alloc(upload_arena, u32, 6)
    fsq_indices.cpu[0] = 0
    fsq_indices.cpu[1] = 2
    fsq_indices.cpu[2] = 1
    fsq_indices.cpu[3] = 0
    fsq_indices.cpu[4] = 1
    fsq_indices.cpu[5] = 3

    full_screen_quad_verts_local := gpu.mem_alloc(Fullscreen_Vertex, 4, gpu.Memory.GPU)
    full_screen_quad_indices_local := gpu.mem_alloc(u32, 6, gpu.Memory.GPU)

    gpu.cmd_mem_copy(
        cmd_buf,
        full_screen_quad_verts_local,
        fsq_verts,
    )
    gpu.cmd_mem_copy(
        cmd_buf,
        full_screen_quad_indices_local,
        fsq_indices,
    )

    return full_screen_quad_verts_local, full_screen_quad_indices_local
}

// Load textures from Texture_Info and update mesh texture IDs
load_scene_textures_from_gltf :: proc(
    texture_infos: []shared.Gltf_Texture_Info,
    data: ^gltf2.Data,
    scene: ^shared.Scene,
    desc_pool: ^gpu.Descriptor_Pool,
) {
    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)

    for info in texture_infos {
        if cancel_loading_textures {
            return
        }

        if info.mesh_id >= u32(len(scene.meshes)) {
            log.error(
                fmt.tprintf(
                    "Invalid mesh_id %v (only %v meshes available)",
                    info.mesh_id,
                    len(scene.meshes),
                ),
            )
            continue
        }

        sync.mutex_lock(&mutex)
        if event, ok := image_uploaded[info.image_index]; ok {
            sync.mutex_unlock(&mutex)
            sync.one_shot_event_wait(event)
        } else {
            event = new(sync.One_Shot_Event)
            image_uploaded[info.image_index] = event
            sync.mutex_unlock(&mutex)

            img := shared.load_texture_from_gltf(
                info.image_index,
                data,
            )
            defer image.destroy(img)

            texture_idx: u32
            texture := upload_texture(img, &upload_arena)

            texture_idx = gpu.desc_pool_alloc_texture(desc_pool, gpu.texture_view_descriptor(texture, {}))
            if sync.guard(&mutex) do image_to_texture[info.image_index] = {texture, texture_idx}

            sync.one_shot_event_signal(event)

            log.infof(
                "Loaded texture for mesh %v, type %v, texture_id %v",
                info.mesh_id,
                info.texture_type,
                texture_idx,
            )
        }
    }

    for info in texture_infos {
        sync.mutex_lock(&mutex)
        texture := image_to_texture[info.image_index]
        sync.mutex_unlock(&mutex)

        gpu.semaphore_wait(upload_sem, upload_sem_val)

        sync.guard(&mutex)

        switch info.texture_type {
        case .Base_Color:
            scene.meshes[info.mesh_id].base_color_map = texture.texture_idx
        case .Metallic_Roughness: {}
        case .Normal: {}
        }
    }
}

upload_texture :: proc(img: ^image.Image, upload_arena: ^gpu.Arena) -> gpu.Owned_Texture
{
    staging := gpu.arena_alloc_raw(upload_arena, len(img.pixels.buf), 1, 16)
    runtime.mem_copy(staging.cpu, raw_data(img.pixels.buf), len(img.pixels.buf))

    sync.guard(&mutex)
    upload_sem_value_old := upload_sem_val
    upload_sem_val += 1

    texture := gpu.texture_alloc_and_create({
        type = .D2,
        dimensions = {u32(img.width), u32(img.height), 1},
        mip_count = u32(math.log2(f32(max(img.width, img.height)))),
        layer_count = 1,
        sample_count = 1,
        format = .RGBA8_SRGB,
        usage = { .Sampled, .Transfer_Src },
    }, .Transfer)
    append(&loaded_textures, texture)

    // Upload and mipmap generation happen on separate queues so they need to be synchronized using timeline semaphores

    {
        // Upload texture to GPU
        upload_cmd_buf := gpu.commands_begin(.Transfer)
        gpu.cmd_copy_to_texture(upload_cmd_buf, texture, staging)
        gpu.cmd_add_signal_semaphore(upload_cmd_buf, upload_sem, upload_sem_value_old + 1)
        gpu.queue_submit(.Transfer, {upload_cmd_buf})
    }

    // Generate mipmaps
    mipmaps_cmd_buf := gpu.commands_begin(.Main)
    gpu.cmd_barrier(mipmaps_cmd_buf, .Transfer, .Transfer)
    gpu.cmd_generate_mipmaps(mipmaps_cmd_buf, texture)
    gpu.cmd_add_wait_semaphore(mipmaps_cmd_buf, upload_sem, upload_sem_value_old + 1)
    gpu.queue_submit(.Main, {mipmaps_cmd_buf})
    return texture
}

rgba8_to_u32 :: proc(r: u8, g: u8, b: u8, a: u8) -> u32
{
    return u32(a) << 24 | u32(b) << 16 | u32(g) << 8 | u32(r)
}

Lightmap_UVs :: struct
{
    uvs: [dynamic][2]f32,
    chart_indices: [dynamic]u32,
}

Transform_2D :: struct
{
    offset: [2]f32,
    scale: [2]f32,
}

destroy_lm_uvs :: proc(lm_uvs: ^[dynamic]Lightmap_UVs)
{
    for &uvs in lm_uvs do delete(uvs.uvs)
    delete(lm_uvs^)
    lm_uvs^ = {}
}

Sampler_Type :: enum u32 { Point = 0, Bilinear, Bicubic }
Output_Type :: enum u32 { Rasterized = 0, Pathtraced }

Settings :: struct
{
    exposure: f32,
    fix_seams: bool,

    lights: lm.Lights,

    do_reset_bake: bool,
    denoise: bool,
}

make_settings_default :: proc() -> Settings
{
    res: Settings
    res.lights.sun_dir = { 0.18301272, -0.9659258, -0.18301272 }
    res.lights.sun_emission = { 68.0, 62.0, 62.0 }
    res.lights.sun_radius = math.RAD_PER_DEG * 0.2
    res.denoise = true
    return res
}

// Create a 1x1 magenta texture
create_magenta_texture :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
{
    magenta_pixels := [4]u8{255, 0, 255, 255}
    staging := gpu.arena_alloc(upload_arena, u8, 4)
    copy(staging.cpu, magenta_pixels[:])

    texture := gpu.texture_alloc_and_create(
        {
            type = .D2,
            dimensions = {1, 1, 1},
            format = .RGBA8_Unorm,
            usage = {.Sampled},
        },
    )
    gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
    return texture
}

// Create a 1x1 white texture
create_white_texture :: proc(upload_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> gpu.Owned_Texture
{
    magenta_pixels := [4]u8{255, 255, 255, 255}
    staging := gpu.arena_alloc(upload_arena, u8, 4)
    copy(staging.cpu, magenta_pixels[:])

    texture := gpu.texture_alloc_and_create(
        {
            type = .D2,
            dimensions = {1, 1, 1},
            format = .RGBA8_Unorm,
            usage = {.Sampled},
        },
    )
    gpu.cmd_copy_to_texture(cmd_buf, texture, staging)
    return texture
}
