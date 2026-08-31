
#+vet !unused-variables

package main

import intr "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:image"
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

import imgui "../shared/odin-imgui"
import imgui_impl_sdl3 "../shared/odin-imgui/imgui_impl_sdl3"
import imgui_impl_nogfx "../shared/odin-imgui/imgui_impl_nogfx"

import lm "../../"

Frames_In_Flight :: 3
Example_Name_Format :: "Right-click + WASD for first-person controls. Left click to toggle texture type. Current: %v"

Sponza_Scene :: #load("../shared/assets/sponza.glb")

// How many textures to load in a single batch / command buffer
Loader_Chunk_Size :: 16

// Index used for the color target texture
COLOR_TARGET_IDX: u32 = 0
POSTPROCESS_TARGET_IDX: u32 = 0
POSTPROCESS_TARGET_RW_IDX: u32 = 0

LM_SIZE :: 4096

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
    ok_i := sdl.Init({.VIDEO})
    assert(ok_i)

    console_logger := log.create_console_logger()
    defer log.destroy_console_logger(console_logger)
    context.logger = console_logger

    ts_freq := sdl.GetPerformanceFrequency()
    max_delta_time: f32 = 1.0 / 10.0 // 10fps

    window_flags :: sdl.WindowFlags { .HIGH_PIXEL_DENSITY, .VULKAN, .RESIZABLE, .MAXIMIZED }
    window := sdl.CreateWindow("test_lightmapper", 1000, 1000, window_flags)
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

    vert_shader_lit := gpu.shader_create(#load("shaders/lit.vert.spv", []u32), .Vertex)
    frag_shader_lit := gpu.shader_create(#load("shaders/lit.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_lit)
        gpu.shader_destroy(frag_shader_lit)
    }

    vert_shader_uv_debug_viz := gpu.shader_create(#load("shaders/uv_debug_viz.vert.spv", []u32), .Vertex)
    frag_shader_uv_debug_viz := gpu.shader_create(#load("shaders/uv_debug_viz.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_uv_debug_viz)
        gpu.shader_destroy(frag_shader_uv_debug_viz)
    }

    vert_shader_tonemap := gpu.shader_create(#load("shaders/tonemap.vert.spv", []u32), .Vertex)
    frag_shader_tonemap := gpu.shader_create(#load("shaders/tonemap.frag.spv", []u32), .Fragment)
    defer {
        gpu.shader_destroy(vert_shader_tonemap)
        gpu.shader_destroy(frag_shader_tonemap)
    }

    upload_arena := gpu.arena_create()
    defer gpu.arena_destroy(&upload_arena)
    bvh_scratch_arena := gpu.arena_create(mem_type = .GPU)
    defer gpu.arena_destroy(&bvh_scratch_arena)

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

    gltf_scene, texture_infos, gltf_data := shared.load_scene_gltf(Sponza_Scene, magenta_texture_id)
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

    scene := upload_scene(gltf_scene, &lm_ctx, &upload_arena, &bvh_scratch_arena, upload_cmd_buf)
    defer scene_destroy(&scene)

    anisotropy := min(16.0, gpu.device_limits().max_anisotropy)

    sampler_linear_id := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({ max_anisotropy = anisotropy }))
    // Lightmap samplers
    lm_sampler_linear_id  := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({}))
    lm_sampler_point_id   := gpu.desc_pool_alloc_sampler(&desc_pool, gpu.sampler_descriptor({ min_filter = .Nearest, mag_filter = .Nearest, mip_filter = .Nearest }))

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
        dimensions = { LM_SIZE, LM_SIZE, 1 },
        usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
    })
    defer gpu.texture_free_and_destroy(&lightmap)

    ui := make_ui_default()

    bake: lm.Bake
    {
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
        }
        bake = lm.bake_begin(&lm_ctx, LM_SIZE, 3000, lightmap, lm_instances, ui.lights)
    }
    defer lm.bake_destroy(&bake)

    gbuf_world_pos_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(lm.bake_debug_get_gbuffer_world_pos(&bake), {}))
    gbuf_world_normals_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(lm.bake_debug_get_gbuffer_world_normals(&bake), {}))
    lightmap_id := gpu.desc_pool_alloc_texture(&desc_pool, gpu.texture_view_descriptor(lightmap, {}))

    imgui_ctx := init_dear_imgui(window, &desc_pool)
    defer {
        imgui_impl_nogfx.shutdown()
        imgui_impl_sdl3.shutdown()
        imgui.destroy_context(imgui_ctx)
    }

    now_ts := sdl.GetPerformanceCounter()

    pathtrace_gt_counter: u32
    max_gt_accums := u32(1000)

    frame_arenas: [Frames_In_Flight]gpu.Arena
    for &frame_arena in frame_arenas do frame_arena = gpu.arena_create()
    defer for &frame_arena in frame_arenas do gpu.arena_destroy(&frame_arena)
    next_frame := u64(1)
    frame_sem := gpu.semaphore_create(0)
    defer gpu.semaphore_destroy(frame_sem)
    for true
    {
        proceed := handle_window_events(window)
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

        if shared.INPUT.pressing_right_click do pathtrace_gt_counter = 0

        imgui_impl_sdl3.new_frame()
        imgui_impl_nogfx.new_frame()
        imgui.new_frame()

        mask_out_dear_imgui_inputs()

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

        draw_calls := make([dynamic]UV_Mesh_Draw_Call, allocator = context.temp_allocator)
        for instance, instance_idx in gltf_scene.instances
        {
            mesh_idx := instance.mesh_idx
            mesh := scene.meshes[mesh_idx]

            append(&draw_calls, UV_Mesh_Draw_Call {
                vert_shader = vert_shader_uv_debug_viz,
                frag_shader = frag_shader_uv_debug_viz,
                cmd_buf = cmd_buf,
                staging_arena = frame_arena,
                verts = scene.meshes[mesh_idx].lm_uvs,
                indices = scene.meshes[mesh_idx].indices,
                lm_chart_indices = scene.meshes[mesh_idx].lm_chart_indices,
                lm_charts = scene.lm_charts,
                chart_base = instance.lm_chart_base,
                offset = {},
                scale = {},
            })
        }
        ui_update(&ui, draw_calls[:], { gbuf_world_pos_id, gbuf_world_normals_id, lightmap_id }, { "World Position", "World Normals", "Lightmap" }, lm.bake_progress(&bake))
        // ui_update_animation(&ui, delta_time)

        imgui.render()

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
        }
        if ui.do_reset_bake || lm.bake_scene_changed(&bake, lm_instances, ui.lights) {
            lm.bake_reset(&bake)
            pathtrace_gt_counter = 0
        }
        lm.bake_iteration(&bake, frame_arena, lm_instances, ui.lights, ui.fix_seams, ui.denoise)

        switch ui.output_type
        {
            case .Rasterized:
            {
                pathtrace_gt_counter = 0

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
                    metallic_roughness_map := gltf_scene.meshes[instance.mesh_idx].metallic_roughness_map
                    normal_map := gltf_scene.meshes[instance.mesh_idx].normal_map

                    Vert_Data :: struct #all_or_none {
                        positions:             rawptr,
                        normals:               rawptr,
                        uvs:                   rawptr,
                        unique_lm_uvs:         rawptr,
                        instanced_lm_uvs:      rawptr,
                        instanced_lm_uvs_offset: [2]f32,
                        instanced_lm_uvs_scale:  [2]f32,
                        model_to_world:        [16]f32,
                        model_to_world_normal: [16]f32,
                        world_to_view:         [16]f32,
                        view_to_proj:          [16]f32,
                        is_instanced: b32,
                    }
                    verts_data := gpu.arena_alloc(frame_arena, Vert_Data)
                    verts_data.cpu^ = {
                        positions             = mesh.pos.gpu.ptr,
                        normals               = mesh.normals.gpu.ptr,
                        uvs                   = mesh.uvs.gpu.ptr,
                        unique_lm_uvs         = mesh.lm_uvs.gpu.ptr,
                        instanced_lm_uvs      = {}, //scene.instanced_lm_uvs[instance.mesh_idx],
                        instanced_lm_uvs_offset = {},
                        instanced_lm_uvs_scale = {},
                        model_to_world        = intr.matrix_flatten(instance.transform),
                        model_to_world_normal = intr.matrix_flatten(linalg.transpose(linalg.inverse(instance.transform))),
                        world_to_view         = intr.matrix_flatten(world_to_view),
                        view_to_proj          = intr.matrix_flatten(view_to_proj),
                        is_instanced          = false,
                    }

                    lm_sampler: u32
                    switch ui.lm_sampling_type
                    {
                        case .Point:    lm_sampler = lm_sampler_point_id
                        case .Bilinear: lm_sampler = lm_sampler_linear_id
                        case .Bicubic:  lm_sampler = lm_sampler_linear_id
                    }

                    Frag_Data :: struct #all_or_none {
                        base_color_map:                 u32,
                        base_color_map_sampler:         u32,
                        metallic_roughness_map:         u32,
                        metallic_roughness_map_sampler: u32,
                        normal_map:                     u32,
                        normal_map_sampler:             u32,

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
                        metallic_roughness_map         = metallic_roughness_map,
                        metallic_roughness_map_sampler = 0,
                        normal_map                     = normal_map,
                        normal_map_sampler             = 0,

                        lightmap = lightmap_id,
                        lightmap_sampler = lm_sampler,
                        do_bicubic_sampling = ui.lm_sampling_type == .Bicubic,
                        sample_lightmap = b32(ui.sample_lightmap),
                        sample_diffuse = b32(ui.sample_diffuse),
                    }

                    gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, frag_data.gpu, mesh.indices)
                }

                gpu.cmd_end_render_pass(cmd_buf)
                gpu.cmd_barrier(cmd_buf, .Raster_Color_Out, .Fragment_Shader, {})
            }
            case .Pathtraced:
            {
                if pathtrace_gt_counter < max_gt_accums
                {
                    lm.bake_debug_ground_truth(&bake, cmd_buf, frame_arena, linalg.inverse(world_to_view), POSTPROCESS_TARGET_RW_IDX, { f32(window_size_x), f32(window_size_y) }, pathtrace_gt_counter)

                    pathtrace_gt_counter += 1
                }
            }
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
                exposure = ui.exposure,
            }

            // Render fullscreen quad
            gpu.cmd_draw_indexed(cmd_buf, verts_data.gpu, frag_data.gpu, fsq_indices)

            // Render ImGui on top
            draw_data := imgui.get_draw_data()
            imgui_impl_nogfx.render_draw_data(draw_data, cmd_buf)

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
    // bvh: gpu.Owned_BVH,
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
    // gpu.bvh_free_and_destroy(&mesh.bvh)
    gpu.mem_free(mesh.pos)
    gpu.mem_free(mesh.normals)
    gpu.mem_free(mesh.uvs)
    gpu.mem_free(mesh.lm_uvs)
    gpu.mem_free(mesh.indices)
    mesh^ = {}
}

build_blas :: proc(bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer, positions: gpu.slice_t([4]f32), indices: gpu.slice_t(u32), idx_count: u32, vert_count: u32) -> gpu.Owned_BVH
{
    assert(idx_count % 3 == 0)

    desc := gpu.BLAS_Desc {
        hint = .Prefer_Fast_Trace,
        shapes = {
            gpu.BVH_Mesh_Desc {
                vertex_stride = 16,
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

upload_scene :: proc(scene: shared.Scene, lm_ctx: ^lm.Context, upload_arena: ^gpu.Arena, bvh_scratch_arena: ^gpu.Arena, cmd_buf: gpu.Command_Buffer) -> Scene_GPU
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
    for &mesh, i in res.meshes
    {
        mesh_cpu := scene.meshes[i]
        mesh_lm_uvs := mesh_cpu.lm_uvs

        mesh.lm_mesh_handle = lm.add_mesh(lm_ctx, cmd_buf, lm.Mesh_Desc {
            positions_gpu = mesh.pos,
            normals_gpu = mesh.normals,
            uvs_gpu = mesh.uvs,
            indices_gpu = mesh.indices,
        })

        mesh.lm_uv_handle = lm.add_lightmap_uvs(lm_ctx, cmd_buf, lm.Lightmap_UVs_Desc {
            positions_cpu = mesh_cpu.pos[:],
            normals_cpu = mesh_cpu.normals[:],
            lm_uvs_cpu = mesh_cpu.lm_uvs[:],
            indices_cpu = mesh_cpu.indices[:],

            lm_uvs_gpu = mesh.lm_uvs,
        })
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
        case .Metallic_Roughness:
            scene.meshes[info.mesh_id].metallic_roughness_map = texture.texture_idx
        case .Normal:
            scene.meshes[info.mesh_id].normal_map = texture.texture_idx
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

init_dear_imgui :: proc(window: ^sdl.Window, desc_pool: ^gpu.Descriptor_Pool) -> ^imgui.Context
{
    imgui.CHECKVERSION()
    ctx := imgui.create_context(nil)
    io := imgui.get_io()
    io.config_flags += {.Nav_Enable_Keyboard, .Nav_Enable_Gamepad}
    io.display_size = { 1000, 1000 }

    imgui_impl_sdl3.init_for_vulkan(window)

    result := imgui_impl_nogfx.init({
        frames_in_flight = Frames_In_Flight
    }, desc_pool)
    assert(result, "Failed to initialize imgui no_gfx backend")

    dpi_scale := sdl.GetWindowDisplayScale(window)
    set_dear_imgui_font_and_style(dpi_scale)

    imgui_impl_nogfx.create_fonts_texture(desc_pool)

    return ctx
}

handle_window_events :: proc(window: ^sdl.Window) -> (proceed: bool)
{
    // Reset "one-shot" inputs
    for &key in shared.INPUT.keys {
        key.pressed = false
        key.released = false
    }
    shared.INPUT.mouse_dx = 0
    shared.INPUT.mouse_dy = 0
    shared.INPUT.left_click_pressed = false

    event: sdl.Event
    proceed = true
    for sdl.PollEvent(&event) {
        imgui_impl_sdl3.process_event(&event)

        #partial switch event.type {
        case .QUIT:
            proceed = false
        case .WINDOW_CLOSE_REQUESTED:
            {
                if event.window.windowID == sdl.GetWindowID(window) {
                    proceed = false
                }
            }
        // Input events
        case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
            {
                event := event.button
                if event.type == .MOUSE_BUTTON_DOWN {
                    if event.button == sdl.BUTTON_RIGHT {
                        shared.INPUT.pressing_right_click = true
                    } else if event.button == sdl.BUTTON_LEFT {
                        shared.INPUT.left_click_pressed = true
                    }
                } else if event.type == .MOUSE_BUTTON_UP {
                    if event.button == sdl.BUTTON_RIGHT {
                        shared.INPUT.pressing_right_click = false
                    }
                }
            }
        case .KEY_DOWN, .KEY_UP:
            {
                event := event.key
                if event.repeat do break

                if event.type == .KEY_DOWN {
                    shared.INPUT.keys[event.scancode].pressed = true
                    shared.INPUT.keys[event.scancode].pressing = true
                } else {
                    shared.INPUT.keys[event.scancode].pressing = false
                    shared.INPUT.keys[event.scancode].released = true
                }
            }
        case .MOUSE_MOTION:
            {
                event := event.motion
                shared.INPUT.mouse_dx += event.xrel
                shared.INPUT.mouse_dy -= event.yrel // In sdl, up is negative
            }
        }
    }

    return
}

mask_out_dear_imgui_inputs :: proc()
{
    io := imgui.get_io()

    if imgui.is_mouse_clicked(.Right) && !imgui.is_window_hovered({ .Any_Window }) {
        imgui.set_window_focus_str(nil)
    }

    if io.want_capture_mouse {
        shared.INPUT.pressing_right_click = false
        shared.INPUT.left_click_pressed = false
    }
    if io.want_capture_keyboard {
        shared.INPUT.keys = {}
    }
}

set_dear_imgui_font_and_style :: proc(dpi_scale: f32)
{
    io := imgui.get_io()
    // Setup behavior flags
    io.config_flags |= { .Nav_Enable_Keyboard }
    io.config_flags |= { .Docking_Enable }
    // io.MouseDrawCursor = true

    // Setup style
    {
        colors := &imgui.get_style().colors
        colors[imgui.Col.Text]                   = { 1.00, 1.00, 1.00, 1.00 }
        colors[imgui.Col.Text_Disabled]           = { 0.50, 0.50, 0.50, 1.00 }
        colors[imgui.Col.Window_Bg]               = { 0.10, 0.10, 0.10, 0.96 }
        colors[imgui.Col.Child_Bg]                = { 0.00, 0.00, 0.00, 0.00 }
        colors[imgui.Col.Popup_Bg]                = { 0.19, 0.19, 0.19, 0.92 }
        colors[imgui.Col.Border]                 = { 0.19, 0.19, 0.19, 0.29 }
        colors[imgui.Col.Border_Shadow]           = { 0.00, 0.00, 0.00, 0.24 }
        colors[imgui.Col.Frame_Bg]                = { 0.05, 0.05, 0.05, 0.54 }
        colors[imgui.Col.Frame_Bg_Hovered]         = { 0.19, 0.19, 0.19, 0.54 }
        colors[imgui.Col.Frame_Bg_Active]          = { 0.20, 0.22, 0.23, 1.00 }
        colors[imgui.Col.Title_Bg]                = { 0.08, 0.08, 0.08, 1.00 }
        colors[imgui.Col.Title_Bg_Active]          = { 0.00, 0.00, 0.00, 1.00 }
        colors[imgui.Col.Title_Bg_Collapsed]       = { 0.00, 0.00, 0.00, 1.00 }
        colors[imgui.Col.Menu_Bar_Bg]              = { 0.14, 0.14, 0.14, 1.00 }
        colors[imgui.Col.Scrollbar_Bg]            = { 0.05, 0.05, 0.05, 0.54 }
        colors[imgui.Col.Scrollbar_Grab]          = { 0.34, 0.34, 0.34, 0.54 }
        colors[imgui.Col.Scrollbar_Grab_Hovered]   = { 0.40, 0.40, 0.40, 0.54 }
        colors[imgui.Col.Scrollbar_Grab_Active]    = { 0.56, 0.56, 0.56, 0.54 }
        colors[imgui.Col.Check_Mark]              = { 0.33, 0.67, 0.86, 1.00 }
        colors[imgui.Col.Slider_Grab]             = { 0.34, 0.34, 0.34, 0.54 }
        colors[imgui.Col.Slider_Grab_Active]       = { 0.56, 0.56, 0.56, 0.54 }
        colors[imgui.Col.Button]                 = { 0.05, 0.05, 0.05, 0.54 }
        colors[imgui.Col.Button_Hovered]          = { 0.19, 0.19, 0.19, 0.54 }
        colors[imgui.Col.Button_Active]           = { 0.20, 0.22, 0.23, 1.00 }
        colors[imgui.Col.Header]                 = { 0.03, 0.03, 0.03, 0.52 }
        colors[imgui.Col.Header_Hovered]          = { 0.06, 0.06, 0.06, 0.36 }
        colors[imgui.Col.Header_Active]           = { 0.20, 0.22, 0.23, 0.33 }
        colors[imgui.Col.Separator]              = { 0.28, 0.28, 0.28, 0.29 }
        colors[imgui.Col.Separator_Hovered]       = { 0.44, 0.44, 0.44, 0.29 }
        colors[imgui.Col.Separator_Active]        = { 0.40, 0.44, 0.47, 1.00 }
        colors[imgui.Col.Resize_Grip]             = { 0.28, 0.28, 0.28, 0.29 }
        colors[imgui.Col.Resize_Grip_Hovered]      = { 0.44, 0.44, 0.44, 0.29 }
        colors[imgui.Col.Resize_Grip_Active]       = { 0.40, 0.44, 0.47, 1.00 }
        colors[imgui.Col.Tab]                    = { 0.00, 0.00, 0.00, 0.52 }
        colors[imgui.Col.Tab_Hovered]             = { 0.14, 0.14, 0.14, 1.00 }
        colors[imgui.Col.Tab_Selected]            = { 0.20, 0.20, 0.20, 0.36 }
        colors[imgui.Col.Tab_Dimmed]              = { 0.00, 0.00, 0.00, 0.52 }
        colors[imgui.Col.Tab_Dimmed_Selected]      = { 0.14, 0.14, 0.14, 1.00 }
        colors[imgui.Col.Plot_Lines]              = { 1.00, 0.00, 0.00, 1.00 }
        colors[imgui.Col.Plot_Lines_Hovered]       = { 1.00, 0.00, 0.00, 1.00 }
        colors[imgui.Col.Plot_Histogram]         = { 0.33, 0.67, 0.86, 1.00 }
        colors[imgui.Col.Plot_Histogram_Hovered] = { 0.40, 0.75, 0.95, 1.00 }
        colors[imgui.Col.Table_Header_Bg]          = { 0.00, 0.00, 0.00, 0.52 }
        colors[imgui.Col.Table_Border_Strong]      = { 0.00, 0.00, 0.00, 0.52 }
        colors[imgui.Col.Table_Border_Light]       = { 0.28, 0.28, 0.28, 0.29 }
        colors[imgui.Col.Table_Row_Bg]             = { 0.00, 0.00, 0.00, 0.00 }
        colors[imgui.Col.Table_Row_Bg_Alt]          = { 1.00, 1.00, 1.00, 0.06 }
        colors[imgui.Col.Text_Selected_Bg]         = { 0.20, 0.22, 0.23, 1.00 }
        colors[imgui.Col.Drag_Drop_Target]         = { 0.33, 0.67, 0.86, 1.00 }
        //colors[imgui.Col.Nav_Highlight]           = { 0.80, 0.30, 0.20, 1.00 }
        colors[imgui.Col.Nav_Windowing_Highlight]  = { 0.33, 0.67, 0.86, 1.00 }
        colors[imgui.Col.Nav_Windowing_Dim_Bg]      = { 1.00, 0.00, 0.00, 0.20 }
        colors[imgui.Col.Modal_Window_Dim_Bg]       = { 1.00, 0.00, 0.00, 0.35 }
        colors[imgui.Col.Docking_Preview]         = { 0.33, 0.67, 0.86, 1.00 }
        colors[imgui.Col.Docking_Empty_Bg]         = { 0.00, 0.00, 0.00, 0.00 }

        style := imgui.get_style()
        style.window_padding                   = { 8.00, 8.00 }
        style.frame_padding                    = { 5.00, 4.00 }
        style.cell_padding                     = { 6.50, 6.50 }
        style.item_spacing                     = { 6.00, 6.00 }
        style.item_inner_spacing                = { 6.00, 6.00 }
        style.touch_extra_padding               = { 0.00, 0.00 }
        style.indent_spacing                   = 25
        style.scrollbar_size                   = 15
        style.grab_min_size                     = 10
        style.window_border_size                = 1
        style.child_border_size                 = 1
        style.popup_border_size                 = 1
        style.frame_border_size                 = 1
        style.tab_border_size                   = 1
        style.window_rounding                  = 7
        style.child_rounding                   = 4
        style.frame_rounding                   = 3
        style.popup_rounding                   = 4
        style.scrollbar_rounding               = 9
        style.grab_rounding                    = 3
        style.log_slider_deadzone               = 4
        style.tab_rounding                     = 4

        imgui.style_scale_all_sizes(style, auto_cast dpi_scale)
    }

    // Setup font
    {
        font_size: f32 = 17.0
        main_font := imgui.font_atlas_add_font_from_file_ttf(io.fonts, "fonts/Roboto-Medium.ttf", auto_cast (font_size * dpi_scale))
        //imgui.font_atlas_build(io.fonts)
        assert(main_font != nil)
    }
}

gui_show_debug_texture_window :: proc(name: cstring, texture_ids: []u32, texture_names: []cstring, tex_width_int: int, tex_height_int: int, uv_mesh_data: []UV_Mesh_Draw_Call, show: ^bool = nil)
{
    tex_width   := f32(tex_width_int)
    tex_height  := f32(tex_height_int)

    @(static) zoom    : f32 = 8.0
    @(static) pan     : imgui.Vec2 = {0, 0}
    @(static) selected_p : [2]int = { -1, -1 }

    imgui.begin(name, show)

    // Controls
    if imgui.button("Reset")
    {
        zoom = 8.0
        pan  = {0, 0}
    }

    @(static) show_uv_mesh: bool = true
    imgui.checkbox("Show UV Mesh", &show_uv_mesh)

    @(static) item_selected_idx: int = 0
    combo_preview_value := texture_names[item_selected_idx]
    if imgui.begin_combo("Texture", combo_preview_value, {})
    {
        for n := 0; n < len(texture_names); n += 1
        {
            is_selected := item_selected_idx == n
            if imgui.selectable(texture_names[n], is_selected) {
                item_selected_idx = n
            }

            if is_selected {
                imgui.set_item_default_focus()
            }
        }
        imgui.end_combo()
    }

    texture_id := texture_ids[item_selected_idx]

    // Canvas
    canvas_size := imgui.get_content_region_avail()
    canvas_pos  := imgui.get_cursor_screen_pos()
    draw_list   := imgui.get_window_draw_list()

    imgui.draw_list_push_clip_rect(draw_list, canvas_pos,
        canvas_pos + canvas_size, true)

    // Background
    imgui.draw_list_add_rect_filled(draw_list, canvas_pos,
        canvas_pos + canvas_size,
        rgba8_to_u32(30, 30, 30, 255))

    // Checkerboard pattern
    checker_sz := f32(128)
    cols := int(canvas_size.x / checker_sz) + 1
    rows := int(canvas_size.y / checker_sz) + 1
    for row in 0..<rows
    {
        for col in 0..<cols
        {
            if (row + col) % 2 == 0 { continue }

            p0 := canvas_pos + {f32(col) * checker_sz, f32(row) * checker_sz}
            p1 := p0 + {checker_sz, checker_sz}
            imgui.draw_list_add_rect_filled(draw_list, p0, p1,
                rgba8_to_u32(60, 60, 60, 255))
        }
    }

    // Invisible button to capture input over the canvas area
    imgui.invisible_button("canvas", canvas_size, { .Mouse_Button_Left, .Mouse_Button_Right })
    is_hovered := imgui.is_item_hovered()
    is_active  := imgui.is_item_active()

    io := imgui.get_io()

    // Scroll-wheel zoom
    if is_hovered && io.mouse_wheel != 0.0
    {
        old_zoom := zoom
        if io.mouse_wheel > 0 {
            zoom *= f32(1.1)
        } else {
            zoom /= f32(1.1)
        }
        zoom = clamp(zoom, 0.1, 64.0)

        // Mouse position relative to canvas origin
        mouse_canvas := io.mouse_pos - canvas_pos
        // The point on the texture the mouse is over must stay fixed:
        // mouse_canvas = pan + texel_pos * zoom  (before and after)
        // So: pan_new = mouse_canvas - (mouse_canvas - pan_old) * (zoom_new / old_zoom)
        pan.x = mouse_canvas.x - (mouse_canvas.x - pan.x) * (zoom / old_zoom)
        pan.y = mouse_canvas.y - (mouse_canvas.y - pan.y) * (zoom / old_zoom)
    }

    // Drag
    if is_active && imgui.is_mouse_dragging(.Right, 0.0) {
        pan = pan + io.mouse_delta
    }

    // Texture
    img_w := tex_width  * zoom
    img_h := tex_height * zoom
    img_p0 := canvas_pos + pan
    img_p1 := img_p0 + {img_w, img_h}

    // Set sampler to nearest
    imgui.draw_list_add_callback(draw_list, set_nearest_sampler_callback, nil)

    imgui.im_draw_list_add_image(draw_list, imgui.Texture_ID(texture_id),
                                 img_p0, img_p1,
                                 {0, 0}, {1, 1},
                                 rgba8_to_u32(255, 255, 255, 255))

    // Restore sampler
    imgui.draw_list_add_callback(draw_list, set_linear_sampler_callback, nil)

    // Pixel grid (only when zoom >= 4) ---
    if zoom >= 4.0
    {
        grid_col := rgba8_to_u32(0, 0, 0, 120)

        // Vertical lines
        for x in 0..=int(tex_width)
        {
            lx := img_p0.x + f32(x) * zoom
            if lx < canvas_pos.x || lx > canvas_pos.x + canvas_size.x { continue }

            imgui.draw_list_add_line(draw_list,
                                     {lx, max(img_p0.y, canvas_pos.y)},
                                     {lx, min(img_p1.y, canvas_pos.y + canvas_size.y)},
                                     grid_col, 1.0)
        }

        // Horizontal lines
        for y in 0..=int(tex_height)
        {
            ly := img_p0.y + f32(y) * zoom
            if ly < canvas_pos.y || ly > canvas_pos.y + canvas_size.y { continue }

            imgui.draw_list_add_line(draw_list,
                                     {max(img_p0.x, canvas_pos.x), ly},
                                     {min(img_p1.x, canvas_pos.x + canvas_size.x), ly},
                                     grid_col, 1.0)
        }
    }

    // Hovered-pixel outline
    if is_hovered && zoom >= 4.0
    {
        mouse := io.mouse_pos

        // Map mouse from screen-space into texture pixel coords
        rel   := mouse - img_p0
        p     := [2]int { int(rel.x / zoom), int(rel.y / zoom) }

        if is_hovered && imgui.is_mouse_clicked(.Left)
        {
            if p.x >= 0 && p.x < int(tex_width) && p.y >= 0 && p.y < int(tex_height) {
                selected_p = p
            }
        }

        if p.x >= 0 && p.x < int(tex_width) && p.y >= 0 && p.y < int(tex_height)
        {
            // Screen-space corners of that pixel
            p0 := img_p0 + [2]f32 { f32(p.x), f32(p.y) } * zoom
            p1 := p0 + zoom

            outline_col := rgba8_to_u32(255, 255, 255, 220)
            shadow_col  := rgba8_to_u32(0,   0,   0,   160)

            // Shadow for contrast on any background
            imgui.draw_list_add_rect(draw_list, p0 - 1, p1 + 1, shadow_col, 0.0, {}, 2.0)
            // Bright outline
            imgui.draw_list_add_rect(draw_list, p0, p1, outline_col, 0.0, {}, 1.5)

            // Tooltip: pixel coordinates
            imgui.set_tooltip("Pixel (%d, %d)", p.x, p.y)
        }

        // Draw selected pixel highlight
        if selected_p.x >= 0
        {
            spx0 := img_p0.x + f32(selected_p.x) * zoom
            spy0 := img_p0.y + f32(selected_p.y) * zoom
            sp0  := [2]f32 { spx0, spy0 }
            sp1 := sp0 + zoom
            imgui.draw_list_add_rect(draw_list, sp0, sp1, rgba8_to_u32(255, 80, 0, 220), 0.0, {}, 2.0)
        }
    }

    // Draw uvs
    if show_uv_mesh
    {
        vp := imgui.get_main_viewport().size

        for draw_call in uv_mesh_data
        {
            tmp := draw_call
            tmp.scale = {
                tex_width  * zoom / vp.x * 2.0,
                tex_height * zoom / vp.y * 2.0,
            }
            tmp.offset = {
                img_p0.x / vp.x * 2.0 - 1.0,
                img_p0.y / vp.y * 2.0 - 1.0,
            }
            imgui.draw_list_add_callback(draw_list, draw_uv_mesh_callback, &tmp, size_of(tmp))
        }
        imgui.draw_list_add_callback(draw_list, Callback_Reset_Render_State, nil)

        imgui.draw_list_pop_clip_rect(draw_list)
    }

    imgui.end()
}

set_nearest_sampler_callback :: proc "c"(draw_list: ^imgui.Draw_List, cmd: ^imgui.Draw_Cmd)
{
    render_state := cast(^imgui_impl_nogfx.Render_State) imgui.get_platform_io().renderer_render_state
    render_state.sampler_current_id = render_state.sampler_nearest_id
}

set_linear_sampler_callback :: proc "c"(draw_list: ^imgui.Draw_List, cmd: ^imgui.Draw_Cmd)
{
    render_state := cast(^imgui_impl_nogfx.Render_State) imgui.get_platform_io().renderer_render_state
    render_state.sampler_current_id = render_state.sampler_linear_id
}

UV_Mesh_Draw_Call :: struct #all_or_none
{
    vert_shader: gpu.Shader,
    frag_shader: gpu.Shader,
    cmd_buf: gpu.Command_Buffer,
    staging_arena: ^gpu.Arena,
    verts: gpu.slice_t([2]f32),
    indices: gpu.slice_t(u32),
    lm_chart_indices: gpu.slice_t(i32),

    lm_charts: gpu.slice_t(shared.Lightmap_Chart),
    chart_base: u32,

    offset: [2]f32,
    scale: [2]f32,
}

draw_uv_mesh_callback :: proc "c"(draw_list: ^imgui.Draw_List, cmd: ^imgui.Draw_Cmd)
{
    context = runtime.default_context()

    data := cast(^UV_Mesh_Draw_Call) cmd.user_callback_data

    gpu.cmd_set_shaders(data.cmd_buf, data.vert_shader, data.frag_shader)

    Vert_Data :: struct #all_or_none {
        verts: rawptr,
        chart_indices: rawptr,

        lm_charts: rawptr,
        chart_base: u32,

        scale: [2]f32,
        translate: [2]f32,
    }
    vert_data := gpu.arena_alloc(data.staging_arena, Vert_Data)
    vert_data.cpu^ = Vert_Data {
        verts = data.verts.gpu.ptr,
        chart_indices = data.lm_chart_indices.ptr,

        lm_charts = data.lm_charts.ptr,
        chart_base = data.chart_base,

        scale = data.scale,
        translate = data.offset
    }

    gpu.cmd_draw_indexed(data.cmd_buf, vert_data, {}, data.indices)
}

Callback_Reset_Render_State := transmute(imgui.Draw_Callback) i64(-8)

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

UI_State :: struct
{
    exposure: f32,
    fix_seams: bool,
    lm_sampling_type: Sampler_Type,
    output_type: Output_Type,
    sample_lightmap: bool,
    sample_diffuse: bool,

    show_texture_viewer: bool,
    show_settings: bool,
    show_demo_window: bool,

    light_azimuth: f32,    // Degrees
    light_elevation: f32,  // Degrees
    light_radius_deg: f32, // Degrees

    lights: lm.Lights,

    do_reset_bake: bool,
    denoise: bool,
}

make_ui_default :: proc() -> UI_State
{
    res: UI_State
    res.show_texture_viewer = true
    res.show_settings = true
    res.lm_sampling_type = .Bicubic
    res.sample_lightmap = true
    res.sample_diffuse = true

    res.light_azimuth = -45.0
    res.light_elevation = -75.0
    res.light_radius_deg = 0.2

    res.lights.sun_dir = dir_from_spherical_coords(math.RAD_PER_DEG * res.light_azimuth, math.RAD_PER_DEG * res.light_elevation)

    res.lights.sun_emission = { 68.0, 62.0, 62.0 }
    res.lights.sun_radius = math.RAD_PER_DEG * res.light_radius_deg

    res.denoise = true
    return res
}

ui_update :: proc(ui: ^UI_State, debug_viz_draw_calls: []UV_Mesh_Draw_Call, texture_ids: []u32, texture_names: []cstring, bake_progress: f32)
{
    if imgui.begin_main_menu_bar()
    {
        if imgui.begin_menu("Windows")
        {
            imgui.menu_item_bool_ptr("Lightmap Viewer", nil, &ui.show_texture_viewer)
            imgui.menu_item_bool_ptr("Settings", nil, &ui.show_settings)
            imgui.menu_item_bool_ptr("Dear ImGui Demo", nil, &ui.show_demo_window)
            imgui.end_menu()
        }
        imgui.end_main_menu_bar()
    }

    if ui.show_demo_window {
        imgui.show_demo_window(&ui.show_demo_window)
    }

    if ui.show_settings
    {
        if imgui.begin("Settings", &ui.show_settings)
        {
            SETTINGS_WIDTH :: 450
            imgui.push_item_width(SETTINGS_WIDTH)
            defer imgui.pop_item_width()

            // Lightmap sampling
            {
                items := []cstring { "Point", "Bilinear", "Bicubic" }
                @(static) item_selected_idx: int = 2

                combo_preview_value := items[item_selected_idx]
                if imgui.begin_combo("Lightmap Sampling", combo_preview_value, {})
                {
                    for n := 0; n < len(items); n += 1
                    {
                        is_selected := item_selected_idx == n
                        if imgui.selectable(items[n], is_selected) {
                            item_selected_idx = n
                            ui.lm_sampling_type = Sampler_Type(n)
                        }

                        if is_selected {
                            imgui.set_item_default_focus()
                        }
                    }
                    imgui.end_combo()
                }

                imgui.push_item_width(SETTINGS_WIDTH / 2)
                imgui.checkbox("Sample lightmap", &ui.sample_lightmap)
                imgui.same_line()
                imgui.checkbox("Sample diffuse", &ui.sample_diffuse)
                imgui.pop_item_width()
            }

            // Output type
            {
                items := []cstring { "Default", "Ground Truth" }
                @(static) item_selected_idx: int = 0
                combo_preview_value := items[item_selected_idx]
                if imgui.begin_combo("Output", combo_preview_value, {})
                {
                    for n := 0; n < len(items); n += 1
                    {
                        is_selected := item_selected_idx == n
                        if imgui.selectable(items[n], is_selected)
                        {
                            item_selected_idx = n
                            ui.output_type = Output_Type(n)
                        }

                        if is_selected {
                            imgui.set_item_default_focus()
                        }
                    }
                    imgui.end_combo()
                }
            }

            imgui.separator_text("Bake settings")
            {
                imgui.checkbox("Denoise", &ui.denoise)
                imgui.progress_bar(bake_progress, size_arg = [2]f32 { SETTINGS_WIDTH, 0 })
            }

            imgui.separator_text("Scene settings (require bake reset)")
            {
                imgui.push_item_width(SETTINGS_WIDTH / 2)
                imgui.drag_float("###azimuth", &ui.light_azimuth, 0.5, -180, 180)
                imgui.same_line()
                imgui.drag_float("Sun Angle", &ui.light_elevation, 0.5, -90, 90)
                ui.lights.sun_dir = dir_from_spherical_coords(math.RAD_PER_DEG * ui.light_azimuth, math.RAD_PER_DEG * ui.light_elevation)
                imgui.pop_item_width()

                imgui.drag_float("Sun Radius (degrees)", &ui.light_radius_deg, 0.01, 0.0000001)
                ui.lights.sun_radius = math.RAD_PER_DEG * ui.light_radius_deg

                imgui.push_item_width(SETTINGS_WIDTH / 3)
                imgui.drag_float("###emission_x", &ui.lights.sun_emission.x, 1)
                imgui.same_line()
                imgui.drag_float("###emission_y", &ui.lights.sun_emission.y, 1)
                imgui.same_line()
                imgui.drag_float("Sun Emission", &ui.lights.sun_emission.z, 1)
                imgui.pop_item_width()

                ui.do_reset_bake = false
                if imgui.button("Reset Bake") do ui.do_reset_bake = true
            }

            imgui.separator_text("Postprocessing settings")
            imgui.drag_float("Exposure", &ui.exposure, 0.01)
            imgui.checkbox("Fix seams", &ui.fix_seams)
        }

        imgui.end()
    }

    if ui.show_texture_viewer
    {
        gui_show_debug_texture_window("Lightmap Viewer", texture_ids, texture_names, LM_SIZE, LM_SIZE, debug_viz_draw_calls, &ui.show_texture_viewer)
    }
}

// Used for social media posts.
ui_update_animation :: proc(ui: ^UI_State, delta_time: f32)
{
    min_t := f32(0.0)
    max_t := f32(5.0)
    @(static) t := f32(0.0)
    t = min(t + delta_time, max_t)

    first_angle_x  := f32(-45.0)
    second_angle_x := f32(60.0)

    ease_in_out_cubic :: proc(t: f32) -> f32
    {
        return 4.0 * t * t * t if t < 0.5 else 1.0 - math.pow(-2.0 * t + 2.0, 3.0) / 2.0;
    }

    ui.light_azimuth = math.lerp(first_angle_x, second_angle_x, ease_in_out_cubic(max(0.0, t - min_t) / (max_t - min_t)))
    ui.lights.sun_dir = dir_from_spherical_coords(math.RAD_PER_DEG * ui.light_azimuth, math.RAD_PER_DEG * ui.light_elevation)
}

dir_from_spherical_coords :: proc(azimuth: f32, elevation: f32) -> [3]f32
{
    return [3]f32{
        math.cos(elevation) * math.cos(azimuth),
        math.sin(elevation),
        math.cos(elevation) * math.sin(azimuth),
    }
}

// Create a 1x1 magenta texture (useful as default/missing texture indicator)
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
