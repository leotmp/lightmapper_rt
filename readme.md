
# lightmapper_rt

WIP.

## API Usage

```odin
// --- Initialize no_gfx context for lightmapper_rt
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME)
gpu.vk_add_opt_device_extension(vk.KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)
ok := gpu.init()
ensure(ok)
defer gpu.cleanup()

// --- Create the lightmap texture
lightmap := gpu.texture_alloc_and_create({
    format = .RGBA16_Float,
    dimensions = { LM_SIZE, LM_SIZE, 1 },
    usage = { .Sampled, .Storage, .Transfer_Src, .Color_Attachment }
})
defer gpu.texture_free_and_destroy(&lightmap)

// TODO: This should be avoided!
lm_instances := /* Convert your scene into []lm.Instance */
bake := lm.bake_begin(&lm_ctx, LM_SIZE, 3000, lightmap, lm_instances, ui.lights)
defer lm.bake_destroy(&bake)

// --- Main loop
for true
{
    // Per-frame operations...

    lm_instances := /* Convert your scene into []lm.Instance */
    if lm.bake_scene_changed(&bake, lm_instances, lm_lights) {
        lm.bake_reset(&bake)
    }
    lm.bake_iteration(&bake, frame_arena, lm_instances, ui.lights, ui.fix_seams, ui.denoise)
}

gpu.wait_idle()
```
